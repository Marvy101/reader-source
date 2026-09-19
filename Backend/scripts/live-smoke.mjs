import { createHash, randomUUID } from "node:crypto";
import { strict as assert } from "node:assert";

import { createClient } from "@supabase/supabase-js";
import WebSocket from "ws";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const backendUrl = required("BACKEND_URL").replace(/\/$/, "");
const supabaseUrl = required("SUPABASE_URL");
const publishableKey = required("SUPABASE_PUBLISHABLE_KEY");
const secretKey = required("SUPABASE_SECRET_KEY");

const authOptions = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
};

const admin = createClient(supabaseUrl, secretKey, {
  auth: authOptions,
  realtime: { transport: WebSocket },
});
const cleanupUserIds = new Set();
const cleanupPaths = new Set();

async function api(accessToken, path, options = {}) {
  const response = await fetch(`${backendUrl}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...options.headers,
    },
  });

  const text = await response.text();
  return {
    status: response.status,
    body: text ? JSON.parse(text) : null,
  };
}

async function publicApi(path, options = {}) {
  const response = await fetch(`${backendUrl}${path}`, {
    ...options,
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...options.headers,
    },
  });

  const text = await response.text();
  return {
    status: response.status,
    body: text ? JSON.parse(text) : null,
  };
}

async function createTestUser(label, runId, password) {
  const email = `reader-smoke-${label}-${runId}@example.com`;
  const { data: created, error: createError } =
    await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });

  if (createError) throw createError;
  cleanupUserIds.add(created.user.id);

  const client = createClient(supabaseUrl, publishableKey, {
    auth: authOptions,
    realtime: { transport: WebSocket },
  });
  const signedIn = await publicApi("/v1/auth/sign-in", {
    method: "POST",
    body: JSON.stringify({ email, password }),
  });
  assert.equal(signedIn.status, 200);
  assert.equal(signedIn.body.session.user.id, created.user.id);

  return {
    client,
    id: created.user.id,
    token: signedIn.body.session.accessToken,
    refreshToken: signedIn.body.session.refreshToken,
  };
}

async function main() {
  console.log("Step: create disposable users");
  const runId = randomUUID();
  const password = `Reader-${randomUUID()}-Aa1!`;
  const userA = await createTestUser("a", runId, password);
  const userB = await createTestUser("b", runId, password);

  console.log("Step: sign up through Vercel");
  const signUp = await publicApi("/v1/auth/sign-up", {
    method: "POST",
    body: JSON.stringify({
      email: `reader-smoke-signup-${runId}@example.com`,
      password,
    }),
  });
  assert.equal(signUp.status, 201);
  assert.ok(signUp.body.user?.id);
  cleanupUserIds.add(signUp.body.user.id);

  console.log("Step: authenticate through Vercel");
  const refreshed = await publicApi("/v1/auth/refresh", {
    method: "POST",
    body: JSON.stringify({ refreshToken: userA.refreshToken }),
  });
  assert.equal(refreshed.status, 200);
  userA.token = refreshed.body.session.accessToken;
  const meA = await api(userA.token, "/v1/me");
  assert.equal(meA.status, 200);
  assert.equal(meA.body.id, userA.id);

  if (process.env.RUN_AI_SMOKE === "1") {
    console.log("Step: ask about a selected passage through Vercel AI Gateway");
    const aiResponse = await api(userA.token, "/v1/ai/highlight-question", {
      method: "POST",
      body: JSON.stringify({
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
          contextAfter: "It then turns to the role of deliberate practice.",
          resourceId: "text",
          progression: 0.5,
        },
      }),
    });
    if (aiResponse.status !== 200) {
      console.error("AI Gateway response", aiResponse);
    }
    assert.equal(aiResponse.status, 200);
    assert.equal(typeof aiResponse.body.response.text, "string");
    assert.ok(aiResponse.body.response.text.length > 0);
    assert.equal(aiResponse.body.response.model, "openai/gpt-5-mini");
    assert.notEqual(aiResponse.body.response.finishReason, "length");
    assert.ok(aiResponse.body.response.attempts >= 1);
  }

  console.log("Step: create and isolate nested folders");
  const rootFolder = await api(userA.token, "/v1/folders", {
    method: "POST",
    body: JSON.stringify({ name: "Research" }),
  });
  assert.equal(rootFolder.status, 201);

  const childFolder = await api(userA.token, "/v1/folders", {
    method: "POST",
    body: JSON.stringify({
      name: "Papers",
      parentId: rootFolder.body.folder.id,
    }),
  });
  assert.equal(childFolder.status, 201);

  const cycle = await api(
    userA.token,
    `/v1/folders/${rootFolder.body.folder.id}`,
    {
      method: "PATCH",
      body: JSON.stringify({ parentId: childFolder.body.folder.id }),
    },
  );
  assert.equal(cycle.status, 409);
  assert.equal(cycle.body.error.code, "folder_cycle");

  const crossUserFolder = await api(
    userB.token,
    `/v1/folders/${rootFolder.body.folder.id}`,
    {
      method: "PATCH",
      body: JSON.stringify({ name: "Stolen" }),
    },
  );
  assert.equal(crossUserFolder.status, 404);

  const emptyFolder = await api(userA.token, "/v1/folders", {
    method: "POST",
    body: JSON.stringify({ name: "Delete Me" }),
  });
  assert.equal(emptyFolder.status, 201);
  const emptyFolderDelete = await api(
    userA.token,
    `/v1/folders/${emptyFolder.body.folder.id}`,
    { method: "DELETE" },
  );
  assert.equal(emptyFolderDelete.status, 204);

  console.log("Step: create signed upload intent");
  const fileContents = Buffer.from("Reader backend live smoke test.\n");
  const uploadIntent = await api(userA.token, "/v1/files/uploads", {
    method: "POST",
    body: JSON.stringify({
      displayName: "Backend Smoke Test",
      originalFilename: "smoke-test.txt",
      mediaType: "text/plain",
      byteSize: fileContents.byteLength,
      sha256: createHash("sha256").update(fileContents).digest("hex"),
      folderId: childFolder.body.folder.id,
    }),
  });
  assert.equal(uploadIntent.status, 201);
  cleanupPaths.add(uploadIntent.body.upload.path);

  console.log("Step: upload directly to Supabase Storage");
  const { error: uploadError } = await userA.client.storage
    .from(uploadIntent.body.upload.bucket)
    .uploadToSignedUrl(
      uploadIntent.body.upload.path,
      uploadIntent.body.upload.token,
      fileContents,
      { contentType: "text/plain" },
    );
  if (uploadError) throw uploadError;

  console.log("Step: verify and complete upload");
  const completed = await api(
    userA.token,
    `/v1/files/${uploadIntent.body.file.id}/complete`,
    { method: "POST" },
  );
  assert.equal(completed.status, 200);
  assert.equal(completed.body.file.status, "ready");

  console.log("Step: protect non-empty folders and cross-user files");
  const nonEmptyDelete = await api(
    userA.token,
    `/v1/folders/${childFolder.body.folder.id}`,
    { method: "DELETE" },
  );
  assert.equal(nonEmptyDelete.status, 409);
  assert.equal(nonEmptyDelete.body.error.code, "folder_not_empty");

  const movedFile = await api(
    userA.token,
    `/v1/files/${uploadIntent.body.file.id}`,
    {
      method: "PATCH",
      body: JSON.stringify({ folderId: null }),
    },
  );
  assert.equal(movedFile.status, 200);
  assert.equal(movedFile.body.file.folder_id, null);

  const rootFiles = await api(userA.token, "/v1/files");
  assert.equal(rootFiles.status, 200);
  assert.equal(rootFiles.body.files.length, 1);

  const crossUserFile = await api(
    userB.token,
    `/v1/files/${uploadIntent.body.file.id}`,
    {
      method: "PATCH",
      body: JSON.stringify({ displayName: "Stolen" }),
    },
  );
  assert.equal(crossUserFile.status, 404);

  console.log("Step: sign and verify download");
  const download = await api(
    userA.token,
    `/v1/files/${uploadIntent.body.file.id}/download`,
    { method: "POST" },
  );
  assert.equal(download.status, 200);
  const downloaded = await fetch(download.body.url);
  assert.equal(downloaded.status, 200);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), fileContents);

  console.log("Step: isolate billing entitlements");
  const { error: entitlementError } = await admin.from("entitlements").insert({
    user_id: userA.id,
    entitlement_key: "reader.pro",
    source: "live-smoke-test",
  });
  if (entitlementError) throw entitlementError;

  const entitlementsA = await api(userA.token, "/v1/entitlements");
  assert.equal(entitlementsA.status, 200);
  assert.equal(entitlementsA.body.entitlements.length, 1);

  const entitlementsB = await api(userB.token, "/v1/entitlements");
  assert.equal(entitlementsB.status, 200);
  assert.equal(entitlementsB.body.entitlements.length, 0);

  console.log("Step: delete account A and all owned data");
  const deleteA = await api(userA.token, "/v1/account", {
    method: "DELETE",
    body: JSON.stringify({ confirmation: "DELETE" }),
  });
  if (deleteA.status !== 204) {
    console.error("Account deletion response", deleteA);
  }
  assert.equal(deleteA.status, 204);
  cleanupUserIds.delete(userA.id);
  cleanupPaths.delete(uploadIntent.body.upload.path);

  const { data: remainingObjects, error: listError } = await admin.storage
    .from("reader-files")
    .list(userA.id, { limit: 100 });
  if (listError) throw listError;
  assert.equal(remainingObjects.length, 0);

  const { count: remainingFolders, error: foldersError } = await admin
    .from("folders")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userA.id);
  if (foldersError) throw foldersError;
  assert.equal(remainingFolders, 0);

  const meBAfterDeletion = await api(userB.token, "/v1/me");
  assert.equal(meBAfterDeletion.status, 200);
  assert.equal(meBAfterDeletion.body.id, userB.id);

  console.log("Step: verify user B survives, then delete user B");
  const deleteB = await api(userB.token, "/v1/account", {
    method: "DELETE",
    body: JSON.stringify({ confirmation: "DELETE" }),
  });
  assert.equal(deleteB.status, 204);
  cleanupUserIds.delete(userB.id);

  console.log("Live backend smoke test passed.");
}

try {
  await main();
} finally {
  if (cleanupPaths.size > 0) {
    const { error } = await admin.storage
      .from("reader-files")
      .remove([...cleanupPaths]);
    if (error) console.error("Storage cleanup failed", error.message);
  }
  for (const userId of cleanupUserIds) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) console.error("User cleanup failed", error.message);
  }
}
