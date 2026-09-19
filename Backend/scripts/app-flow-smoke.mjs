import { randomUUID } from "node:crypto";
import { strict as assert } from "node:assert";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const backendUrl = required("BACKEND_URL").replace(/\/$/, "");
const runId = randomUUID();
const email = `reader-app-smoke-${runId}@example.com`;
const password = `Reader-${randomUUID()}-Aa1!`;
let accessToken;

async function request(path, body, token) {
  const response = await fetch(`${backendUrl}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

try {
  console.log("Step: create an email/password account through Reader");
  const signUp = await request("/v1/auth/sign-up", { email, password });
  assert.equal(signUp.status, 201);
  assert.ok(signUp.body.user?.id);
  assert.ok(
    signUp.body.session,
    "Supabase requires email confirmation; live AI smoke needs a confirmed test account",
  );
  accessToken = signUp.body.session.accessToken;

  console.log("Step: refresh the Reader session");
  const refreshed = await request("/v1/auth/refresh", {
    refreshToken: signUp.body.session.refreshToken,
  });
  assert.equal(refreshed.status, 200);
  accessToken = refreshed.body.session.accessToken;

  console.log("Step: ask about a selected passage");
  const answer = await request(
    "/v1/ai/highlight-question",
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
  console.log("App-flow smoke passed");
} finally {
  if (accessToken) {
    console.log("Step: delete the disposable account");
    const deletion = await fetch(`${backendUrl}/v1/account`, {
      method: "DELETE",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ confirmation: "DELETE" }),
    });
    assert.equal(deletion.status, 204);
  }
}
