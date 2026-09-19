import { strict as assert } from "node:assert";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const backendUrl = required("BACKEND_URL").replace(/\/$/, "");
const textPath = required("BOOK_TEXT_PATH");
const benchmarkEmail = required("BENCHMARK_EMAIL");
const benchmarkPassword = required("BENCHMARK_PASSWORD");

function splitText(text, maximumCharacters = 6_000, overlap = 250) {
  const chunks = [];
  let start = 0;
  while (start < text.length) {
    let end = Math.min(start + maximumCharacters, text.length);
    if (end < text.length) {
      const boundary = text.lastIndexOf(" ", end);
      if (boundary > start + maximumCharacters / 2) end = boundary;
    }
    const chunkText = text.slice(start, end).trim();
    if (chunkText) {
      chunks.push({
        ordinal: chunks.length,
        resourceId: "text",
        resourceTitle: "Complete text",
        text: chunkText,
        positionStart: start,
        positionEnd: end,
        progressionStart: start / text.length,
        progressionEnd: end / text.length,
      });
    }
    if (end >= text.length) break;
    start = Math.max(end - overlap, start + 1);
  }
  return chunks;
}

function makeBatches(chunks, maximumCount = 100, maximumCharacters = 900_000) {
  const batches = [];
  let batch = [];
  let characters = 0;
  for (const chunk of chunks) {
    if (
      batch.length > 0 &&
      (batch.length >= maximumCount || characters + chunk.text.length > maximumCharacters)
    ) {
      batches.push(batch);
      batch = [];
      characters = 0;
    }
    batch.push(chunk);
    characters += chunk.text.length;
  }
  if (batch.length > 0) batches.push(batch);
  return batches;
}

async function timed(operation) {
  const startedAt = performance.now();
  const value = await operation();
  return { value, milliseconds: performance.now() - startedAt };
}

async function backend(path, accessToken, options = {}) {
  const response = await fetch(`${backendUrl}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...options.headers,
    },
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`${options.method ?? "GET"} ${path} returned ${response.status}: ${text}`);
  }
  return body;
}

async function streamChat(accessToken, publicationId) {
  const startedAt = performance.now();
  const response = await fetch(`${backendUrl}/v1/ai/chat/stream`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      messages: [
        {
          role: "reader",
          text: "Search the book. What happens when Alice follows the White Rabbit?",
          attachments: [],
        },
      ],
      context: {
        publication: {
          id: publicationId,
          title: "Live Book Benchmark",
          author: "Reader",
          format: "plainText",
          textAccess: "cloudSearchable",
        },
        scope: "wholeBook",
        currentProgression: 1,
      },
    }),
  });
  if (!response.ok) {
    throw new Error(`Chat returned ${response.status}: ${await response.text()}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let firstEventMilliseconds;
  let stream = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (firstEventMilliseconds === undefined) {
      firstEventMilliseconds = performance.now() - startedAt;
    }
    stream += decoder.decode(value, { stream: true });
  }
  stream += decoder.decode();
  const evidenceMatch = stream.match(/event: evidence\ndata: (.+)/);
  const completeMatch = stream.match(/event: complete\ndata: (.+)/);
  assert.ok(completeMatch, `Chat did not complete: ${stream.slice(-1_000)}`);
  return {
    firstEventMilliseconds,
    totalMilliseconds: performance.now() - startedAt,
    evidence: evidenceMatch ? JSON.parse(evidenceMatch[1]) : null,
  };
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(Math.ceil(sorted.length * fraction) - 1, sorted.length - 1)];
}

try {
  const sourceText = await readFile(textPath, "utf8");
  const chunks = splitText(sourceText);
  const batches = makeBatches(chunks);
  const publicationId = randomUUID();
  const fingerprint = createHash("sha256").update(sourceText).digest("hex");
  const signIn = await fetch(`${backendUrl}/v1/auth/sign-in`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: benchmarkEmail, password: benchmarkPassword }),
  });
  const signInBody = await signIn.json();
  assert.equal(signIn.status, 200);
  const accessToken = signInBody.session.accessToken;

  const startPayload = {
    title: "Live Book Benchmark",
    author: "Reader",
    format: "plainText",
    fingerprint,
    parserVersion: 1,
    totalChunks: chunks.length,
    totalCharacters: chunks.reduce((total, chunk) => total + chunk.text.length, 0),
    annotations: [],
  };

  const coldStartedAt = performance.now();
  const start = await timed(() =>
    backend(`/v1/publications/${publicationId}/ingestions`, accessToken, {
      method: "POST",
      body: JSON.stringify(startPayload),
    }),
  );
  assert.equal(start.value.needsChunks, true);

  const upload = await timed(async () => {
    for (let index = 0; index < batches.length; index += 4) {
      await Promise.all(
        batches.slice(index, index + 4).map((batch) =>
          backend(`/v1/publications/${publicationId}/chunks`, accessToken, {
            method: "PUT",
            body: JSON.stringify({ fingerprint, chunks: batch }),
          }),
        ),
      );
    }
  });

  const complete = await timed(() =>
    backend(`/v1/publications/${publicationId}/complete`, accessToken, {
      method: "POST",
      body: JSON.stringify({
        fingerprint,
        expectedChunks: chunks.length,
        expectedCharacters: startPayload.totalCharacters,
      }),
    }),
  );
  assert.equal(complete.value.processingStatus, "parsed");
  const coldMilliseconds = performance.now() - coldStartedAt;

  const knowledge = await backend(
    `/v1/publications/${publicationId}/knowledge`,
    accessToken,
  );
  assert.equal(knowledge.processingStatus, "parsed");

  const warmMilliseconds = [];
  for (let index = 0; index < 10; index += 1) {
    const warm = await timed(() =>
      backend(`/v1/publications/${publicationId}/ingestions`, accessToken, {
        method: "POST",
        body: JSON.stringify(startPayload),
      }),
    );
    assert.equal(warm.value.needsChunks, false);
    warmMilliseconds.push(warm.milliseconds);
  }

  const chat = process.env.RUN_AI_BENCHMARK === "1"
    ? await streamChat(accessToken, publicationId)
    : null;

  console.log(
    JSON.stringify(
      {
        backendUrl,
        input: {
          path: textPath,
          sourceCharacters: sourceText.length,
          uploadedCharacters: startPayload.totalCharacters,
          chunks: chunks.length,
          batches: batches.length,
        },
        coldIndexMilliseconds: Number(coldMilliseconds.toFixed(1)),
        phases: {
          startMilliseconds: Number(start.milliseconds.toFixed(1)),
          uploadMilliseconds: Number(upload.milliseconds.toFixed(1)),
          completeMilliseconds: Number(complete.milliseconds.toFixed(1)),
        },
        warmCheck: {
          samples: warmMilliseconds.length,
          p50Milliseconds: Number(percentile(warmMilliseconds, 0.5).toFixed(1)),
          p95Milliseconds: Number(percentile(warmMilliseconds, 0.95).toFixed(1)),
        },
        chat: chat && {
          firstEventMilliseconds: Number(chat.firstEventMilliseconds.toFixed(1)),
          totalMilliseconds: Number(chat.totalMilliseconds.toFixed(1)),
          evidence: chat.evidence,
        },
      },
      null,
      2,
    ),
  );
} finally {
  if (process.env.DELETE_BENCHMARK_ACCOUNT === "1") {
    assert.match(benchmarkEmail, /^reader-book-benchmark-/);
    const signIn = await fetch(`${backendUrl}/v1/auth/sign-in`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: benchmarkEmail, password: benchmarkPassword }),
    });
    if (signIn.ok) {
      const session = (await signIn.json()).session;
      await fetch(`${backendUrl}/v1/account`, {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${session.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ confirmation: "DELETE" }),
      });
    }
  }
}
