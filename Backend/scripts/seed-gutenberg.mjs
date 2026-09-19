import { createClient } from "@supabase/supabase-js";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

function positiveIntegerFlag(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  const value = Number(process.argv[index + 1]);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${name} must be followed by a positive integer`);
  }
  return value;
}

function stringFlag(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  const value = process.argv[index + 1]?.trim();
  if (!value || value.startsWith("--")) {
    throw new Error(`${name} must be followed by a value`);
  }
  return value;
}

const supabaseUrl = process.env.SUPABASE_URL?.trim();
const secretKey = process.env.SUPABASE_SECRET_KEY?.trim();
if (!supabaseUrl || !secretKey) {
  throw new Error("SUPABASE_URL and SUPABASE_SECRET_KEY are required");
}

const pages = positiveIntegerFlag("--pages", 1);
const batchPages = positiveIntegerFlag("--batch-pages", 5);
const ingestAll = process.argv.includes("--all");
const checkpointPath = resolve(
  stringFlag("--checkpoint", ".catalog-state/gutenberg.json"),
);
const explicitStartPage = process.argv.includes("--start-page")
  ? positiveIntegerFlag("--start-page", 1)
  : null;
const delayMilliseconds = positiveIntegerFlag("--delay-ms", 100);
const maximumAttempts = positiveIntegerFlag("--max-attempts", 5);
const client = createClient(supabaseUrl, secretKey, {
  auth: {
    autoRefreshToken: false,
    detectSessionInUrl: false,
    persistSession: false,
  },
});

function wait(milliseconds) {
  return new Promise((resolveWait) => setTimeout(resolveWait, milliseconds));
}

async function withRetry(label, operation) {
  let lastError;
  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt === maximumAttempts) break;
      const backoff = Math.min(30_000, 500 * 2 ** (attempt - 1));
      console.warn(JSON.stringify({ label, attempt, retryInMilliseconds: backoff }));
      await wait(backoff);
    }
  }
  throw lastError;
}

async function fetchPage(page) {
  const url = new URL("https://gutendex.com/books/");
  url.searchParams.set("page", String(page));
  const response = await fetch(url, {
    headers: { "user-agent": "Reader catalog ingestion/1.0" },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    throw new Error(`Gutendex page ${page} returned HTTP ${response.status}`);
  }
  const payload = await response.json();
  if (!Array.isArray(payload.results)) {
    throw new Error(`Gutendex page ${page} did not contain a results array`);
  }
  return payload;
}

async function ingest(results, page) {
  const { data, error } = await client.rpc("catalog_ingest_gutenberg", {
    p_books: results,
  });
  if (error) {
    throw new Error(`Catalog ingest failed on page ${page}: ${error.message}`);
  }
  return data;
}

async function fetchBatch(startPage, remainingPages) {
  const firstPayload = await withRetry(`fetch page ${startPage}`, () =>
    fetchPage(startPage),
  );
  const pageSize = firstPayload.results.length;
  if (!Number.isInteger(firstPayload.count) || firstPayload.count < 0) {
    throw new Error(`Gutendex page ${startPage} did not contain a valid count`);
  }
  const lastPage =
    pageSize > 0 ? Math.ceil(firstPayload.count / pageSize) : startPage;
  const requestedPages = Math.min(batchPages, remainingPages);
  const endPage = Math.min(startPage + requestedPages - 1, lastPage);
  const remainingPayloads = await Promise.all(
    Array.from({ length: Math.max(0, endPage - startPage) }, (_, index) => {
      const page = startPage + index + 1;
      return withRetry(`fetch page ${page}`, () => fetchPage(page));
    }),
  );
  return {
    endPage,
    hasNext: endPage < lastPage,
    results: [firstPayload, ...remainingPayloads].flatMap(
      (payload) => payload.results,
    ),
  };
}

async function loadCheckpoint() {
  try {
    return JSON.parse(await readFile(checkpointPath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function saveCheckpoint(checkpoint) {
  await mkdir(dirname(checkpointPath), { recursive: true });
  const temporaryPath = `${checkpointPath}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(checkpoint, null, 2)}\n`);
  await rename(temporaryPath, checkpointPath);
}

const checkpoint = await loadCheckpoint();
if (ingestAll && checkpoint?.completed && explicitStartPage === null) {
  console.info(
    JSON.stringify({
      event: "gutenberg_seed_already_complete",
      lastCompletedPage: checkpoint.lastCompletedPage,
      total: checkpoint.totalRecords,
      checkpointPath,
    }),
  );
  process.exit(0);
}
const startPage =
  explicitStartPage ??
  (Number.isInteger(checkpoint?.lastCompletedPage)
    ? checkpoint.lastCompletedPage + 1
    : 1);
const maximumPages = ingestAll ? Number.POSITIVE_INFINITY : pages;
let total = Number.isInteger(checkpoint?.totalRecords)
  ? checkpoint.totalRecords
  : 0;

console.info(
  JSON.stringify({
    event: "gutenberg_seed_started",
    startPage,
    mode: ingestAll ? "all" : "bounded",
    pages: ingestAll ? null : pages,
    batchPages,
    checkpointPath,
  }),
);

for (let offset = 0; offset < maximumPages; offset += batchPages) {
  const page = startPage + offset;
  const remainingPages = maximumPages - offset;
  const batch = await fetchBatch(page, remainingPages);
  const result = await withRetry(`ingest pages ${page}-${batch.endPage}`, () =>
    ingest(batch.results, `${page}-${batch.endPage}`),
  );
  total += batch.results.length;
  await saveCheckpoint({
    source: "project_gutenberg",
    lastCompletedPage: batch.endPage,
    totalRecords: total,
    completed: !batch.hasNext,
    updatedAt: new Date().toISOString(),
  });
  console.info(
    JSON.stringify({
      event: "gutenberg_batch_completed",
      startPage: page,
      endPage: batch.endPage,
      batchRecords: batch.results.length,
      total,
      result,
    }),
  );
  if (!batch.hasNext) break;
  await wait(delayMilliseconds);
}

console.info(JSON.stringify({ event: "gutenberg_seed_finished", total }));
