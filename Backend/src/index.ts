import { Hono, type Context } from "hono";
import { streamSSE } from "hono/streaming";
import type { SupabaseClient, User } from "@supabase/supabase-js";
import type { ZodType } from "zod";

import { generateReaderResponse } from "./ai.js";
import { missingRequiredConfig, readConfig } from "./config.js";
import { streamReaderChat } from "./features/chat/service.js";
import { nameReaderChat } from "./features/chat-title/service.js";
import { answerHighlightQuestion } from "./features/highlight-question/service.js";
import { SupabaseBookKnowledgeStore } from "./features/book-knowledge/store.js";
import { filterOwnedReadingStates } from "./reading-state-sync.js";
import {
  CatalogStoreError,
  matchLibraryPublication,
  registerCatalogInterest,
  searchCatalog,
} from "./features/catalog/service.js";
import {
  mergeCatalogResults,
  searchGoogleBooks,
} from "./features/catalog/google-books.js";
import {
  completeKnowledgeIngestion,
  KnowledgeIngestionMismatchError,
  KnowledgeIngestionNotFoundError,
  putKnowledgeChunks,
  startKnowledgeIngestion,
} from "./features/book-knowledge/ingestion.js";
import {
  createAdminClient,
  createPublicClient,
  createUserClient,
  isConfigured,
  isSupabaseReachable,
} from "./supabase.js";
import {
  aiRespondSchema,
  catalogInterestSchema,
  catalogMatchSchema,
  catalogSearchQuerySchema,
  chatStreamSchema,
  chatTitleSchema,
  completeKnowledgeIngestionSchema,
  createFolderSchema,
  createUploadSchema,
  deleteAccountSchema,
  highlightQuestionSchema,
  putKnowledgeChunksSchema,
  refreshSessionSchema,
  signInSchema,
  signUpSchema,
  startKnowledgeIngestionSchema,
  syncReadingStatesSchema,
  updateFileSchema,
  updateFolderSchema,
  reorderLibraryFilesSchema,
} from "./validation.js";

type Variables = {
  requestId: string;
  user: User;
  userClient: SupabaseClient;
  adminClient: SupabaseClient;
};

export const app = new Hono<{ Variables: Variables }>();

app.use("*", async (context, next) => {
  const requestId =
    context.req.header("x-request-id")?.trim() || crypto.randomUUID();

  context.set("requestId", requestId);
  await next();
  context.header("x-request-id", requestId);
});

app.get("/", (context) => {
  return context.json({
    service: "reader-backend",
    status: "ok",
  });
});

app.get("/health/live", (context) => {
  return context.json({ status: "ok" });
});

app.get("/health/ready", async (context) => {
  const missing = missingRequiredConfig(readConfig());

  if (missing.length > 0) {
    return context.json(
      {
        status: "not_ready",
        missing,
      },
      503,
    );
  }

  const config = readConfig();
  if (!isConfigured(config) || !(await isSupabaseReachable(config))) {
    return context.json(
      {
        status: "not_ready",
        unavailable: ["supabase"],
      },
      503,
    );
  }

  return context.json({ status: "ok" });
});

function bearerToken(header: string | undefined): string | undefined {
  const match = header?.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || undefined;
}

async function validatedBody<T>(
  context: Context<{ Variables: Variables }>,
  schema: ZodType<T>,
): Promise<
  | { success: true; data: T }
  | { success: false; response: Response }
> {
  let body: unknown;

  try {
    body = await context.req.json();
  } catch {
    return {
      success: false,
      response: context.json(
        {
          error: {
            code: "invalid_json",
            message: "Request body must be valid JSON",
            requestId: context.get("requestId"),
          },
        },
        400,
      ),
    };
  }

  const result = schema.safeParse(body);
  if (!result.success) {
    return {
      success: false,
      response: context.json(
        {
          error: {
            code: "invalid_request",
            message: "Request validation failed",
            issues: result.error.issues.map((issue) => ({
              path: issue.path.join("."),
              message: issue.message,
            })),
            requestId: context.get("requestId"),
          },
        },
        400,
      ),
    };
  }

  return { success: true, data: result.data };
}

function configuredPublicClient(
  context: Context<{ Variables: Variables }>,
): SupabaseClient | Response {
  const config = readConfig();
  if (!isConfigured(config)) {
    return context.json(
      {
        error: {
          code: "service_not_ready",
          message: "Authentication is not configured",
          requestId: context.get("requestId"),
        },
      },
      503,
    );
  }
  return createPublicClient(config);
}

function serializedSession(
  session: {
    access_token: string;
    refresh_token: string;
    expires_at?: number;
    user: User;
  },
) {
  return {
    accessToken: session.access_token,
    refreshToken: session.refresh_token,
    expiresAt: session.expires_at ?? null,
    user: {
      id: session.user.id,
      email: session.user.email ?? null,
    },
  };
}

function authUnavailable(
  context: Context<{ Variables: Variables }>,
  error: unknown,
): Response {
  console.error("Authentication provider unavailable", {
    error,
    requestId: context.get("requestId"),
  });
  return context.json(
    {
      error: {
        code: "auth_unavailable",
        message: "Authentication is temporarily unavailable",
        requestId: context.get("requestId"),
      },
    },
    502,
  );
}

app.post("/v1/auth/sign-up", async (context) => {
  const body = await validatedBody(context, signUpSchema);
  if (!body.success) return body.response;
  const client = configuredPublicClient(context);
  if (client instanceof Response) return client;

  const { data, error } = await client.auth.signUp(body.data);
  if (error) {
    if (!error.status || error.status >= 500) {
      return authUnavailable(context, error);
    }
    return context.json(
      {
        error: {
          code: "sign_up_failed",
          message: error.message,
          requestId: context.get("requestId"),
        },
      },
      400,
    );
  }

  return context.json(
    {
      session: data.session ? serializedSession(data.session) : null,
      user: data.user
        ? { id: data.user.id, email: data.user.email ?? null }
        : null,
      requiresEmailConfirmation: data.session === null,
    },
    201,
  );
});

app.post("/v1/auth/sign-in", async (context) => {
  const body = await validatedBody(context, signInSchema);
  if (!body.success) return body.response;
  const client = configuredPublicClient(context);
  if (client instanceof Response) return client;

  const { data, error } = await client.auth.signInWithPassword(body.data);
  if (error && (!error.status || error.status >= 500)) {
    return authUnavailable(context, error);
  }
  if (error || !data.session) {
    return context.json(
      {
        error: {
          code: "invalid_credentials",
          message: "The email or password is incorrect",
          requestId: context.get("requestId"),
        },
      },
      401,
    );
  }

  return context.json({ session: serializedSession(data.session) });
});

app.post("/v1/auth/refresh", async (context) => {
  const body = await validatedBody(context, refreshSessionSchema);
  if (!body.success) return body.response;
  const client = configuredPublicClient(context);
  if (client instanceof Response) return client;

  const { data, error } = await client.auth.refreshSession({
    refresh_token: body.data.refreshToken,
  });
  if (error && (!error.status || error.status >= 500)) {
    return authUnavailable(context, error);
  }
  if (error || !data.session) {
    return context.json(
      {
        error: {
          code: "invalid_refresh_token",
          message: "The session has expired. Sign in again.",
          requestId: context.get("requestId"),
        },
      },
      401,
    );
  }

  return context.json({ session: serializedSession(data.session) });
});

app.use("/v1/*", async (context, next) => {
  if (context.req.path.startsWith("/v1/auth/")) {
    await next();
    return;
  }

  const token = bearerToken(context.req.header("authorization"));
  if (!token) {
    return context.json(
      {
        error: {
          code: "unauthorized",
          message: "A Supabase access token is required",
          requestId: context.get("requestId"),
        },
      },
      401,
    );
  }

  const config = readConfig();
  if (!isConfigured(config)) {
    return context.json(
      {
        error: {
          code: "service_not_ready",
          message: "Supabase is not configured",
          requestId: context.get("requestId"),
        },
      },
      503,
    );
  }

  const userClient = createUserClient(config, token);
  const { data, error } = await userClient.auth.getUser(token);

  if (error || !data.user) {
    return context.json(
      {
        error: {
          code: "unauthorized",
          message: "The access token is invalid or expired",
          requestId: context.get("requestId"),
        },
      },
      401,
    );
  }

  context.set("user", data.user);
  context.set("userClient", userClient);
  context.set("adminClient", createAdminClient(config));
  await next();
});

app.get("/v1/me", (context) => {
  const user = context.get("user");
  return context.json({
    id: user.id,
    email: user.email ?? null,
  });
});

app.get("/v1/catalog/search", async (context) => {
  const query = catalogSearchQuerySchema.safeParse({
    query: context.req.query("q"),
    locale: context.req.query("locale") ?? "en-US",
    limit: context.req.query("limit") ?? "20",
    includeFallback: context.req.query("includeFallback") ?? "false",
  });
  if (!query.success) {
    return context.json(
      {
        error: {
          code: "invalid_request",
          message: "Catalog search parameters are invalid",
          issues: query.error.issues.map((issue) => ({
            path: issue.path.join("."),
            message: issue.message,
          })),
          requestId: context.get("requestId"),
        },
      },
      400,
    );
  }

  try {
    const localResults = await searchCatalog(
      context.get("adminClient"),
      context.get("user").id,
      query.data.query,
      query.data.locale,
      query.data.limit,
      context.req.header("x-vercel-ip-country") ?? null,
    );
    const config = readConfig();
    let results = localResults;
    if (
      config.googleBooksApiKey &&
      query.data.includeFallback &&
      query.data.query.length >= 3 &&
      localResults.length < Math.min(query.data.limit, 5)
    ) {
      try {
        const fallback = await searchGoogleBooks(
          query.data.query,
          config.googleBooksApiKey,
          query.data.limit - localResults.length,
        );
        results = mergeCatalogResults(localResults, fallback, query.data.limit);
      } catch (error) {
        console.warn("Google Books catalog fallback failed", {
          error,
          requestId: context.get("requestId"),
        });
      }
    }
    return context.json({ results });
  } catch (error) {
    console.error("Catalog search failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
    });
    return context.json(
      {
        error: {
          code: "catalog_unavailable",
          message: "Catalog search is temporarily unavailable",
          requestId: context.get("requestId"),
        },
      },
      502,
    );
  }
});

app.post("/v1/catalog/interests", async (context) => {
  const body = await validatedBody(context, catalogInterestSchema);
  if (!body.success) return body.response;

  try {
    await registerCatalogInterest(
      context.get("adminClient"),
      context.get("user").id,
      body.data,
    );
    return context.json({ registered: true }, 201);
  } catch (error) {
    console.error("Catalog interest registration failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
    });
    return context.json(
      {
        error: {
          code: "catalog_interest_failed",
          message: "Reader could not save that request",
          requestId: context.get("requestId"),
        },
      },
      error instanceof CatalogStoreError ? 409 : 502,
    );
  }
});

app.put("/v1/files/:fileId/catalog-match", async (context) => {
  const body = await validatedBody(context, catalogMatchSchema);
  if (!body.success) return body.response;

  try {
    await matchLibraryPublication(
      context.get("adminClient"),
      context.get("user").id,
      context.req.param("fileId"),
      body.data,
    );
    return context.json({ matched: true });
  } catch (error) {
    console.error("Library file catalog match failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
      fileId: context.req.param("fileId"),
    });
    return context.json(
      {
        error: {
          code: "catalog_match_failed",
          message: "Reader could not match that file to the catalog",
          requestId: context.get("requestId"),
        },
      },
      error instanceof CatalogStoreError ? 409 : 502,
    );
  }
});

app.post("/v1/ai/respond", async (context) => {
  const body = await validatedBody(context, aiRespondSchema);
  if (!body.success) return body.response;

  try {
    const response = await generateReaderResponse(body.data);
    return context.json({ response });
  } catch (error) {
    console.error("AI Gateway request failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
    });

    return context.json(
      {
        error: {
          code: "ai_unavailable",
          message: "The reading assistant is temporarily unavailable",
          requestId: context.get("requestId"),
        },
      },
      502,
    );
  }
});

app.post("/v1/ai/highlight-question", async (context) => {
  const body = await validatedBody(context, highlightQuestionSchema);
  if (!body.success) return body.response;

  try {
    const response = await answerHighlightQuestion(body.data);
    console.info("Highlight question completed", {
      requestId: context.get("requestId"),
      userId: context.get("user").id,
      model: response.model,
      finishReason: response.finishReason,
      attempts: response.attempts,
      usage: response.usage,
    });
    return context.json({ response });
  } catch (error) {
    console.error("Highlight question failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
    });

    return context.json(
      {
        error: {
          code: "ai_unavailable",
          message: "The reading assistant is temporarily unavailable",
          requestId: context.get("requestId"),
        },
      },
      502,
    );
  }
});

app.post("/v1/ai/chat/stream", async (context) => {
  const body = await validatedBody(context, chatStreamSchema);
  if (!body.success) return body.response;

  const requestId = context.get("requestId");
  const userId = context.get("user").id;
  const response = await streamReaderChat(
    body.data,
    new SupabaseBookKnowledgeStore(context.get("userClient")),
  );

  return streamSSE(context, async (stream) => {
    let emittedText = false;

    try {
      for await (const text of response.result.textStream) {
        emittedText = emittedText || text.length > 0;
        await stream.writeSSE({
          event: "delta",
          data: JSON.stringify({ text }),
        });
      }

      const [finishReason, usage] = await Promise.all([
        response.result.finishReason,
        response.result.usage,
      ]);

      if (!emittedText || finishReason === "length") {
        await stream.writeSSE({
          event: "error",
          data: JSON.stringify({
            code: "incomplete_response",
            message: "Reader could not finish that response. Try again.",
          }),
        });
        return;
      }

      console.info("Reader chat completed", {
        requestId,
        userId,
        model: response.model,
        finishReason,
        usage,
      });
      await stream.writeSSE({
        event: "evidence",
        data: JSON.stringify(response.evidence),
      });
      await stream.writeSSE({
        event: "complete",
        data: JSON.stringify({ model: response.model, finishReason }),
      });
    } catch (error) {
      console.error("Reader chat failed", { error, requestId, userId });
      await stream.writeSSE({
        event: "error",
        data: JSON.stringify({
          code: "ai_unavailable",
          message: "The reading assistant is temporarily unavailable",
        }),
      });
    }
  });
});

app.post("/v1/publications/:publicationId/ingestions", async (context) => {
  const body = await validatedBody(context, startKnowledgeIngestionSchema);
  if (!body.success) return body.response;

  const result = await startKnowledgeIngestion(
    context.get("userClient"),
    context.get("user").id,
    context.req.param("publicationId"),
    body.data,
  );
  return context.json(
    {
      publicationId: context.req.param("publicationId"),
      processingStatus: result.needsChunks ? "processing" : "parsed",
      needsChunks: result.needsChunks,
    },
    result.needsChunks ? 202 : 200,
  );
});

app.put("/v1/publications/:publicationId/chunks", async (context) => {
  const body = await validatedBody(context, putKnowledgeChunksSchema);
  if (!body.success) return body.response;

  try {
    await putKnowledgeChunks(
      context.get("userClient"),
      context.get("user").id,
      context.req.param("publicationId"),
      body.data.fingerprint,
      body.data.chunks,
    );
    return context.json({ accepted: body.data.chunks.length }, 202);
  } catch (error) {
    if (error instanceof KnowledgeIngestionNotFoundError) {
      return context.json(
        {
          error: {
            code: "knowledge_ingestion_not_found",
            message: error.message,
            requestId: context.get("requestId"),
          },
        },
        409,
      );
    }
    throw error;
  }
});

app.post("/v1/publications/:publicationId/complete", async (context) => {
  const body = await validatedBody(context, completeKnowledgeIngestionSchema);
  if (!body.success) return body.response;

  try {
    await completeKnowledgeIngestion(
      context.get("userClient"),
      context.req.param("publicationId"),
      body.data.fingerprint,
      body.data.expectedChunks,
      body.data.expectedCharacters,
    );
    return context.json({
      publicationId: context.req.param("publicationId"),
      processingStatus: "parsed",
    });
  } catch (error) {
    if (error instanceof KnowledgeIngestionMismatchError) {
      return context.json(
        {
          error: {
            code: "knowledge_ingestion_incomplete",
            message: error.message,
            requestId: context.get("requestId"),
          },
        },
        409,
      );
    }
    if (error instanceof KnowledgeIngestionNotFoundError) {
      return context.json(
        {
          error: {
            code: "knowledge_ingestion_not_found",
            message: error.message,
            requestId: context.get("requestId"),
          },
        },
        409,
      );
    }
    throw error;
  }
});

app.get("/v1/publications/:publicationId/knowledge", async (context) => {
  const { data, error } = await context
    .get("userClient")
    .from("publication_knowledge")
    .select(
      "id,text_access,processing_status,parser_kind,parser_version,chunk_count,character_count,parsed_at,updated_at",
    )
    .eq("id", context.req.param("publicationId"))
    .maybeSingle();
  if (error) throw error;
  if (!data) {
    return context.json(
      {
        error: {
          code: "publication_knowledge_not_found",
          message: "Publication knowledge is not available",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }
  return context.json({ knowledge: data });
});

app.post("/v1/ai/chat/title", async (context) => {
  const body = await validatedBody(context, chatTitleSchema);
  if (!body.success) return body.response;

  try {
    const response = await nameReaderChat(body.data.firstMessage);
    console.info("Reader chat titled", {
      requestId: context.get("requestId"),
      userId: context.get("user").id,
      model: response.model,
      usage: response.usage,
    });
    return context.json({ response });
  } catch (error) {
    console.error("Reader chat title failed", {
      error,
      requestId: context.get("requestId"),
      userId: context.get("user").id,
    });
    return context.json(
      {
        error: {
          code: "ai_unavailable",
          message: "Reader could not name this conversation",
          requestId: context.get("requestId"),
        },
      },
      502,
    );
  }
});

app.get("/v1/folders", async (context) => {
  const { data, error } = await context
    .get("userClient")
    .from("folders")
    .select("id,parent_id,name,created_at,updated_at")
    .order("created_at", { ascending: true });

  if (error) throw error;
  return context.json({ folders: data });
});

app.post("/v1/folders", async (context) => {
  const body = await validatedBody(context, createFolderSchema);
  if (!body.success) return body.response;

  const { data, error } = await context
    .get("userClient")
    .from("folders")
    .insert({
      name: body.data.name,
      parent_id: body.data.parentId ?? null,
      user_id: context.get("user").id,
    })
    .select("id,parent_id,name,created_at,updated_at")
    .single();

  if (error?.code === "23505") {
    return context.json(
      {
        error: {
          code: "folder_already_exists",
          message: "A folder with this name already exists here",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }
  if (error) throw error;

  return context.json({ folder: data }, 201);
});

app.patch("/v1/folders/:folderId", async (context) => {
  const body = await validatedBody(context, updateFolderSchema);
  if (!body.success) return body.response;

  const updates: Record<string, string | null> = {};
  if (body.data.name !== undefined) updates.name = body.data.name;
  if (body.data.parentId !== undefined) {
    updates.parent_id = body.data.parentId;
  }

  const { data, error } = await context
    .get("userClient")
    .from("folders")
    .update(updates)
    .eq("id", context.req.param("folderId"))
    .select("id,parent_id,name,created_at,updated_at")
    .maybeSingle();

  if (error?.code === "23505") {
    return context.json(
      {
        error: {
          code: "folder_already_exists",
          message: "A folder with this name already exists here",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }
  if (error?.code === "P0001") {
    return context.json(
      {
        error: {
          code: "folder_cycle",
          message: "A folder cannot be moved inside itself or its descendants",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }
  if (error) throw error;
  if (!data) {
    return context.json(
      {
        error: {
          code: "folder_not_found",
          message: "Folder not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  return context.json({ folder: data });
});

app.delete("/v1/folders/:folderId", async (context) => {
  const { data, error } = await context
    .get("userClient")
    .from("folders")
    .delete()
    .eq("id", context.req.param("folderId"))
    .select("id")
    .maybeSingle();

  if (error?.code === "23503") {
    return context.json(
      {
        error: {
          code: "folder_not_empty",
          message: "Move or delete this folder's contents first",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }
  if (error) throw error;
  if (!data) {
    return context.json(
      {
        error: {
          code: "folder_not_found",
          message: "Folder not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  return context.body(null, 204);
});

app.get("/v1/files", async (context) => {
  const folderId = context.req.query("folderId");
  const includeAll = context.req.query("all") === "true";
  let query = context
    .get("userClient")
    .from("library_files")
    .select(
      "id,folder_id,display_name,original_filename,media_type,byte_size,sha256,status,sort_order,created_at,updated_at",
    )
    .order("sort_order", { ascending: true })
    .order("created_at", { ascending: true });

  if (!includeAll) {
    query = folderId
      ? query.eq("folder_id", folderId)
      : query.is("folder_id", null);
  }

  const { data, error } = await query;
  if (error) throw error;
  return context.json({ files: data });
});

app.put("/v1/files/order", async (context) => {
  const body = await validatedBody(context, reorderLibraryFilesSchema);
  if (!body.success) return body.response;

  const { error } = await context
    .get("userClient")
    .rpc("reorder_library_files", { p_file_ids: body.data.fileIds });

  if (error) throw error;
  return context.body(null, 204);
});

app.post("/v1/files/uploads", async (context) => {
  const body = await validatedBody(context, createUploadSchema);
  if (!body.success) return body.response;

  const fileId = body.data.clientFileId ?? crypto.randomUUID();
  const userId = context.get("user").id;
  const storagePath = `${userId}/${fileId}/original`;
  const userClient = context.get("userClient");
  const fileColumns =
    "id,folder_id,display_name,original_filename,media_type,byte_size,sha256,status,created_at,updated_at";

  const { data: existing, error: existingError } = await userClient
    .from("library_files")
    .select(`${fileColumns},storage_path`)
    .eq("id", fileId)
    .maybeSingle();

  if (existingError) throw existingError;
  if (
    existing &&
    (existing.byte_size !== body.data.byteSize ||
      existing.media_type !== body.data.mediaType ||
      (body.data.sha256 !== undefined && existing.sha256 !== body.data.sha256))
  ) {
    return context.json(
      {
        error: {
          code: "file_identity_conflict",
          message: "That file ID already belongs to different content",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }

  if (existing?.status === "ready") {
    const { storage_path: _, ...file } = existing;
    return context.json({ file, needsUpload: false, upload: null });
  }

  let file = existing;
  if (!file) {
    const { data, error: insertError } = await userClient
      .from("library_files")
      .insert({
        id: fileId,
        user_id: userId,
        folder_id: body.data.folderId ?? null,
        display_name: body.data.displayName,
        original_filename: body.data.originalFilename,
        media_type: body.data.mediaType,
        byte_size: body.data.byteSize,
        sha256: body.data.sha256 ?? null,
        storage_path: storagePath,
      })
      .select(`${fileColumns},storage_path`)
      .single();

    if (insertError) throw insertError;
    file = data;
  }

  const { data: upload, error: uploadError } = await userClient.storage
    .from("reader-files")
    .createSignedUploadUrl(file.storage_path, { upsert: true });

  if (uploadError) {
    if (!existing) {
      await userClient.from("library_files").delete().eq("id", fileId);
    }
    throw uploadError;
  }

  const { storage_path: _, ...responseFile } = file;

  return context.json(
    {
      file: responseFile,
      needsUpload: true,
      upload: {
        bucket: "reader-files",
        path: upload.path,
        token: upload.token,
        signedUrl: upload.signedUrl,
      },
    },
    existing ? 200 : 201,
  );
});

app.post("/v1/files/:fileId/complete", async (context) => {
  const userClient = context.get("userClient");
  const { data: file, error: fileError } = await userClient
    .from("library_files")
    .select("id,storage_path,byte_size,media_type,status")
    .eq("id", context.req.param("fileId"))
    .maybeSingle();

  if (fileError) throw fileError;
  if (!file) {
    return context.json(
      {
        error: {
          code: "file_not_found",
          message: "File not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  const { data: object, error: objectError } = await userClient.storage
    .from("reader-files")
    .info(file.storage_path);

  if (objectError) {
    return context.json(
      {
        error: {
          code: "upload_incomplete",
          message: "The uploaded object is not available yet",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }

  if (object.size !== undefined && object.size !== file.byte_size) {
    return context.json(
      {
        error: {
          code: "upload_size_mismatch",
          message: "The uploaded object size does not match the request",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }

  if (
    object.contentType !== undefined &&
    object.contentType !== file.media_type
  ) {
    return context.json(
      {
        error: {
          code: "upload_type_mismatch",
          message: "The uploaded object type does not match the request",
          requestId: context.get("requestId"),
        },
      },
      409,
    );
  }

  const { data, error } = await userClient
    .from("library_files")
    .update({ status: "ready" })
    .eq("id", file.id)
    .select(
      "id,folder_id,display_name,original_filename,media_type,byte_size,sha256,status,created_at,updated_at",
    )
    .single();

  if (error) throw error;
  return context.json({ file: data });
});

app.patch("/v1/files/:fileId", async (context) => {
  const body = await validatedBody(context, updateFileSchema);
  if (!body.success) return body.response;

  const updates: Record<string, string | null> = {};
  if (body.data.displayName !== undefined) {
    updates.display_name = body.data.displayName;
  }
  if (body.data.folderId !== undefined) updates.folder_id = body.data.folderId;

  const { data, error } = await context
    .get("userClient")
    .from("library_files")
    .update(updates)
    .eq("id", context.req.param("fileId"))
    .select(
      "id,folder_id,display_name,original_filename,media_type,byte_size,sha256,status,created_at,updated_at",
    )
    .maybeSingle();

  if (error) throw error;
  if (!data) {
    return context.json(
      {
        error: {
          code: "file_not_found",
          message: "File not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  return context.json({ file: data });
});

app.post("/v1/files/:fileId/download", async (context) => {
  const userClient = context.get("userClient");
  const { data: file, error: fileError } = await userClient
    .from("library_files")
    .select("storage_path,status")
    .eq("id", context.req.param("fileId"))
    .eq("status", "ready")
    .maybeSingle();

  if (fileError) throw fileError;
  if (!file) {
    return context.json(
      {
        error: {
          code: "file_not_found",
          message: "A ready file was not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  const { data, error } = await userClient.storage
    .from("reader-files")
    .createSignedUrl(file.storage_path, 60);

  if (error) throw error;
  return context.json({ url: data.signedUrl, expiresIn: 60 });
});

app.delete("/v1/files/:fileId", async (context) => {
  const userClient = context.get("userClient");
  const { data: file, error: fileError } = await userClient
    .from("library_files")
    .select("id,storage_path")
    .eq("id", context.req.param("fileId"))
    .maybeSingle();

  if (fileError) throw fileError;
  if (!file) {
    return context.json(
      {
        error: {
          code: "file_not_found",
          message: "File not found",
          requestId: context.get("requestId"),
        },
      },
      404,
    );
  }

  const { error: storageError } = await userClient.storage
    .from("reader-files")
    .remove([file.storage_path]);
  if (storageError) throw storageError;

  const { error: deleteError } = await userClient
    .from("library_files")
    .delete()
    .eq("id", file.id);
  if (deleteError) throw deleteError;

  return context.body(null, 204);
});

app.post("/v1/reading-states/sync", async (context) => {
  const body = await validatedBody(context, syncReadingStatesSchema);
  if (!body.success) return body.response;

  const userId = context.get("user").id;
  const userClient = context.get("userClient");
  const fileIds = [...new Set(body.data.states.map((state) => state.fileId))];

  if (fileIds.length > 0) {
    const { data: files, error: filesError } = await userClient
      .from("library_files")
      .select("id")
      .in("id", fileIds);
    if (filesError) throw filesError;

    const rows = filterOwnedReadingStates(
      body.data.states,
      files.map((file) => file.id),
    )
      .map((state) => ({
        user_id: userId,
        file_id: state.fileId,
        locator: state.locator,
        progress: state.progress,
        last_opened_at: new Date(state.lastOpenedAt * 1_000).toISOString(),
        device_id: body.data.deviceId,
        client_updated_at: new Date(state.updatedAt * 1_000).toISOString(),
      }));
    if (rows.length > 0) {
      const { error: upsertError } = await userClient
        .from("reading_states")
        .upsert(rows, { onConflict: "user_id,file_id" });
      if (upsertError) throw upsertError;
    }
  }

  const { data: states, error: statesError } = await userClient
    .from("reading_states")
    .select(
      "file_id,locator,progress,last_opened_at,device_id,client_updated_at",
    )
    .order("last_opened_at", { ascending: false });
  if (statesError) throw statesError;

  return context.json({
    readingStates: states.map((state) => ({
      fileId: state.file_id,
      locator: state.locator,
      progress: Number(state.progress),
      lastOpenedAt: Date.parse(state.last_opened_at) / 1_000,
      deviceId: state.device_id,
      updatedAt: Date.parse(state.client_updated_at) / 1_000,
    })),
  });
});

app.get("/v1/entitlements", async (context) => {
  const { data, error } = await context
    .get("userClient")
    .from("entitlements")
    .select("entitlement_key,source,active,expires_at")
    .eq("active", true);

  if (error) throw error;
  return context.json({ entitlements: data });
});

app.delete("/v1/account", async (context) => {
  const body = await validatedBody(context, deleteAccountSchema);
  if (!body.success) return body.response;

  const userId = context.get("user").id;
  const userClient = context.get("userClient");
  const adminClient = context.get("adminClient");

  const { error: requestError } = await userClient
    .from("account_deletion_requests")
    .upsert({ user_id: userId, status: "processing", last_error: null });
  if (requestError) throw requestError;

  const { data: files, error: filesError } = await userClient
    .from("library_files")
    .select("storage_path");
  if (filesError) throw filesError;

  const paths = files.map((file) => file.storage_path);
  for (let index = 0; index < paths.length; index += 1_000) {
    const batch = paths.slice(index, index + 1_000);
    const { error: storageError } = await adminClient.storage
      .from("reader-files")
      .remove(batch);
    if (storageError) throw storageError;
  }

  const { error: deleteUserError } = await adminClient.auth.admin.deleteUser(
    userId,
  );
  if (deleteUserError) throw deleteUserError;

  return context.body(null, 204);
});

app.notFound((context) => {
  return context.json(
    {
      error: {
        code: "not_found",
        message: "Route not found",
        requestId: context.get("requestId"),
      },
    },
    404,
  );
});

app.onError((error, context) => {
  console.error("Unhandled request error", {
    error,
    requestId: context.get("requestId"),
  });

  return context.json(
    {
      error: {
        code: "internal_error",
        message: "Internal server error",
        requestId: context.get("requestId"),
      },
    },
    500,
  );
});

export default app;
