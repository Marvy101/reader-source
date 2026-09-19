import { createClient } from "@supabase/supabase-js";

import {
  assertPermittedDownloadUrl,
  maximumCatalogFileBytes,
  readBoundedBody,
  sha256Hex,
  sourcePolicy,
  storagePath,
  validateEpub,
} from "./lib/catalog-file.mjs";

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

const sourceCode = stringFlag("--source", "project_gutenberg");
const policy = sourcePolicy(sourceCode);
const batchSize = Math.min(positiveIntegerFlag("--batch-size", 25), 100);
const concurrency = Math.min(positiveIntegerFlag("--concurrency", 3), 10);
const ingestAll = process.argv.includes("--all");
const maximumFiles = ingestAll
  ? Number.POSITIVE_INFINITY
  : positiveIntegerFlag("--max-files", 100);
const maximumAttempts = positiveIntegerFlag("--max-attempts", 4);
const bucket = "reader-catalog-files";
const client = createClient(supabaseUrl, secretKey, {
  auth: {
    autoRefreshToken: false,
    detectSessionInUrl: false,
    persistSession: false,
  },
});

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function withRetry(label, operation) {
  let lastError;
  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt === maximumAttempts) break;
      const retryInMilliseconds = Math.min(30_000, 750 * 2 ** (attempt - 1));
      console.warn(JSON.stringify({ label, attempt, retryInMilliseconds }));
      await wait(retryInMilliseconds);
    }
  }
  throw lastError;
}

async function download(candidate) {
  const requestedUrl = assertPermittedDownloadUrl(candidate.download_url, policy);
  const response = await fetch(requestedUrl, {
    headers: { "user-agent": "Reader catalog file materializer/1.0" },
    redirect: "follow",
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) {
    throw new Error(`Catalog file returned HTTP ${response.status}`);
  }
  assertPermittedDownloadUrl(response.url, policy);
  const body = await readBoundedBody(response, maximumCatalogFileBytes);
  validateEpub(body);
  return body;
}

async function ensureUploaded(path, body, sha256) {
  const storage = client.storage.from(bucket);
  const { error } = await storage.upload(path, body, {
    cacheControl: "31536000",
    contentType: "application/epub+zip",
    upsert: false,
  });
  if (!error) return;

  const { data: existing, error: downloadError } = await storage.download(path);
  if (downloadError || !existing) throw error;
  const existingBytes = new Uint8Array(await existing.arrayBuffer());
  if (existingBytes.byteLength !== body.byteLength || sha256Hex(existingBytes) !== sha256) {
    throw new Error("Existing storage object does not match its content-addressed path");
  }
}

async function materialize(candidate) {
  const body = await withRetry(`download offer ${candidate.offer_id}`, () =>
    download(candidate),
  );
  const sha256 = sha256Hex(body);
  const path = storagePath(sourceCode, candidate.external_id, sha256, "epub");
  await withRetry(`upload offer ${candidate.offer_id}`, () =>
    ensureUploaded(path, body, sha256),
  );
  const { data, error } = await client.rpc("catalog_register_materialized_file", {
    p_offer_id: candidate.offer_id,
    p_sha256: sha256,
    p_media_type: "application/epub+zip",
    p_byte_size: body.byteLength,
    p_storage_bucket: bucket,
    p_storage_path: path,
    p_rights_status: policy.rightsStatus,
    p_license_code: policy.licenseCode,
    p_territories: policy.territories,
  });
  if (error) throw new Error(`Catalog file registration failed: ${error.message}`);
  return data;
}

async function mapConcurrent(items, worker) {
  const output = new Array(items.length);
  let nextIndex = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex;
        nextIndex += 1;
        output[index] = await worker(items[index]);
      }
    }),
  );
  return output;
}

let afterOfferId = 0;
let completed = 0;
let failed = 0;

console.info(
  JSON.stringify({
    event: "catalog_materialization_started",
    sourceCode,
    maximumFiles: Number.isFinite(maximumFiles) ? maximumFiles : null,
    batchSize,
    concurrency,
  }),
);

while (completed + failed < maximumFiles) {
  const remaining = maximumFiles - completed - failed;
  const { data, error } = await client.rpc("catalog_materialization_candidates", {
    p_source_code: sourceCode,
    p_after_offer_id: afterOfferId,
    p_limit: Math.min(batchSize, remaining),
  });
  if (error) throw new Error(`Catalog candidate lookup failed: ${error.message}`);
  if (!Array.isArray(data) || data.length === 0) break;

  const outcomes = await mapConcurrent(data, async (candidate) => {
    try {
      const result = await materialize(candidate);
      return { candidate, result, error: null };
    } catch (errorValue) {
      const message = errorValue instanceof Error ? errorValue.message : String(errorValue);
      return { candidate, result: null, error: message };
    }
  });

  for (const outcome of outcomes) {
    afterOfferId = Math.max(afterOfferId, outcome.candidate.offer_id);
    if (outcome.error) {
      failed += 1;
      console.error(
        JSON.stringify({
          event: "catalog_materialization_failed",
          offerId: outcome.candidate.offer_id,
          externalId: outcome.candidate.external_id,
          error: outcome.error,
        }),
      );
    } else {
      completed += 1;
      console.info(
        JSON.stringify({
          event: "catalog_materialization_completed",
          offerId: outcome.candidate.offer_id,
          externalId: outcome.candidate.external_id,
          completed,
          failed,
          result: outcome.result,
        }),
      );
    }
  }
}

console.info(
  JSON.stringify({
    event: "catalog_materialization_finished",
    sourceCode,
    completed,
    failed,
    lastOfferId: afterOfferId,
  }),
);

if (failed > 0) process.exitCode = 1;
