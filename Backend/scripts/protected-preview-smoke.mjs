import { randomUUID } from "node:crypto";
import { strict as assert } from "node:assert";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const deployment = required("BACKEND_URL");
const scope = process.env.VERCEL_SCOPE?.trim();
const runId = randomUUID();
const email = `reader-preview-smoke-${runId}@example.com`;
const password = `Reader-${randomUUID()}-Aa1!`;
let accessToken;

async function request(path, method, body, token) {
  const curlArguments = [
    "curl",
    path,
    "--deployment",
    deployment,
    "--",
    "--silent",
    "--request",
    method,
    "--header",
    "content-type: application/json",
    "--write-out",
    "\n%{http_code}",
  ];
  if (scope) {
    curlArguments.splice(4, 0, "--scope", scope);
  }
  if (token) {
    curlArguments.push("--header", `authorization: Bearer ${token}`);
  }
  if (body !== undefined) {
    curlArguments.push("--data", JSON.stringify(body));
  }

  const { stdout } = await run("vercel", curlArguments, {
    cwd: process.cwd(),
    maxBuffer: 1_000_000,
  });
  const lines = stdout.trimEnd().split("\n");
  const status = Number(lines.pop());
  const responseBody = lines.join("\n");
  return {
    status,
    body: responseBody ? JSON.parse(responseBody) : null,
  };
}

try {
  console.log("Step: create an account through the protected preview");
  const signUp = await request(
    "/v1/auth/sign-up",
    "POST",
    { email, password },
  );
  if (signUp.status !== 201) {
    console.error("Sign-up response", signUp.body);
  }
  assert.equal(signUp.status, 201);
  assert.ok(signUp.body.user?.id);
  assert.ok(
    signUp.body.session,
    "Supabase requires email confirmation; use a confirmed test account for the AI smoke",
  );
  accessToken = signUp.body.session.accessToken;

  console.log("Step: refresh the Reader session");
  const refreshed = await request("/v1/auth/refresh", "POST", {
    refreshToken: signUp.body.session.refreshToken,
  });
  assert.equal(refreshed.status, 200);
  accessToken = refreshed.body.session.accessToken;

  console.log("Step: ask about a selected passage");
  const answer = await request(
    "/v1/ai/highlight-question",
    "POST",
    {
      question: "What claim is this sentence making?",
      history: [],
      publication: {
        title: "Smoke Test Book",
        author: "Reader",
        format: "plainText",
      },
      selection: {
        text: "We are what we repeatedly do.",
        contextBefore: "The passage is discussing habit and character.",
        contextAfter: "It then turns to deliberate practice.",
        resourceId: "text",
        progression: 0.5,
      },
    },
    accessToken,
  );
  assert.equal(answer.status, 200);
  assert.equal(typeof answer.body.response.text, "string");
  assert.ok(answer.body.response.text.length > 0);
  assert.equal(typeof answer.body.response.model, "string");
  console.log("Protected preview smoke passed");
} finally {
  if (accessToken) {
    console.log("Step: delete the disposable account");
    const deletion = await request(
      "/v1/account",
      "DELETE",
      { confirmation: "DELETE" },
      accessToken,
    );
    assert.equal(deletion.status, 204);
  }
}
