import type { SupabaseClient } from "@supabase/supabase-js";

export type StartKnowledgeIngestionInput = {
  title: string;
  author?: string;
  format: "pdf" | "epub" | "plainText";
  fingerprint: string;
  parserVersion: number;
  totalChunks: number;
  totalCharacters: number;
  annotations: Array<{
    id: string;
    selectedText: string;
    note?: string | null;
    resourceId: string;
    position: number;
    progression: number;
    locator: Record<string, unknown>;
    createdAt: string;
  }>;
};

export type KnowledgeChunkInput = {
  ordinal: number;
  resourceId: string;
  resourceTitle?: string | null;
  text: string;
  positionStart: number;
  positionEnd: number;
  progressionStart: number;
  progressionEnd: number;
};

export async function startKnowledgeIngestion(
  client: SupabaseClient,
  userId: string,
  publicationId: string,
  input: StartKnowledgeIngestionInput,
): Promise<{ needsChunks: boolean }> {
  const { data: existing, error: readError } = await client
    .from("publication_knowledge")
    .select("fingerprint,parser_version,processing_status,chunk_count,character_count")
    .eq("id", publicationId)
    .maybeSingle();
  if (readError) throw readError;

  const needsChunks = !(
    existing?.fingerprint === input.fingerprint &&
    existing?.parser_version === input.parserVersion &&
    existing?.processing_status === "parsed" &&
    existing?.chunk_count === input.totalChunks &&
    Number(existing?.character_count) === input.totalCharacters
  );

  const { error: upsertError } = await client
    .from("publication_knowledge")
    .upsert({
      id: publicationId,
      user_id: userId,
      title: input.title,
      author: input.author ?? null,
      format: input.format,
      fingerprint: input.fingerprint,
      text_access: "cloud_searchable",
      processing_status: needsChunks ? "processing" : "parsed",
      parser_kind: "reader_extracted_text",
      parser_version: input.parserVersion,
      chunk_count: input.totalChunks,
      character_count: input.totalCharacters,
      last_error: null,
      parsed_at: needsChunks ? null : new Date().toISOString(),
    });
  if (upsertError) throw upsertError;

  if (needsChunks) {
    const { error: deleteChunksError } = await client
      .from("publication_chunks")
      .delete()
      .eq("publication_id", publicationId);
    if (deleteChunksError) throw deleteChunksError;
  }

  const { error: deleteAnnotationsError } = await client
    .from("publication_annotations")
    .delete()
    .eq("publication_id", publicationId);
  if (deleteAnnotationsError) throw deleteAnnotationsError;

  if (input.annotations.length > 0) {
    const { error: annotationsError } = await client
      .from("publication_annotations")
      .insert(
        input.annotations.map((annotation) => ({
          id: annotation.id,
          publication_id: publicationId,
          user_id: userId,
          selected_text: annotation.selectedText,
          note: annotation.note ?? null,
          resource_id: annotation.resourceId,
          position: annotation.position,
          progression: annotation.progression,
          locator: annotation.locator,
          created_at: annotation.createdAt,
        })),
      );
    if (annotationsError) throw annotationsError;
  }

  return { needsChunks };
}

export async function putKnowledgeChunks(
  client: SupabaseClient,
  userId: string,
  publicationId: string,
  fingerprint: string,
  chunks: KnowledgeChunkInput[],
): Promise<void> {
  await requireMatchingIngestion(client, publicationId, fingerprint);
  const { error } = await client.from("publication_chunks").upsert(
    chunks.map((chunk) => ({
      publication_id: publicationId,
      user_id: userId,
      ordinal: chunk.ordinal,
      resource_id: chunk.resourceId,
      resource_title: chunk.resourceTitle ?? null,
      text: chunk.text,
      position_start: chunk.positionStart,
      position_end: chunk.positionEnd,
      progression_start: chunk.progressionStart,
      progression_end: chunk.progressionEnd,
    })),
    { onConflict: "publication_id,ordinal" },
  );
  if (error) throw error;
}

export async function completeKnowledgeIngestion(
  client: SupabaseClient,
  publicationId: string,
  fingerprint: string,
  expectedChunks: number,
  expectedCharacters: number,
): Promise<void> {
  await requireMatchingIngestion(client, publicationId, fingerprint);
  const { data, error } = await client
    .rpc("publication_ingestion_totals", {
      target_publication_id: publicationId,
    })
    .single();
  if (error) throw error;

  const totals = data as {
    chunk_count?: number | string;
    character_count?: number | string;
    minimum_ordinal?: number | string | null;
    maximum_ordinal?: number | string | null;
  } | null;
  const actualChunks = Number(totals?.chunk_count ?? 0);
  const actualCharacters = Number(totals?.character_count ?? 0);
  const hasCompleteOrdinals =
    Number(totals?.minimum_ordinal) === 0 &&
    Number(totals?.maximum_ordinal) === expectedChunks - 1;

  if (
    actualChunks !== expectedChunks ||
    actualCharacters !== expectedCharacters ||
    !hasCompleteOrdinals
  ) {
    throw new KnowledgeIngestionMismatchError(
      expectedChunks,
      actualChunks,
      expectedCharacters,
      actualCharacters,
    );
  }

  const { error: updateError } = await client
    .from("publication_knowledge")
    .update({
      processing_status: "parsed",
      chunk_count: expectedChunks,
      character_count: expectedCharacters,
      parsed_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", publicationId);
  if (updateError) throw updateError;
}

async function requireMatchingIngestion(
  client: SupabaseClient,
  publicationId: string,
  fingerprint: string,
): Promise<void> {
  const { data, error } = await client
    .from("publication_knowledge")
    .select("fingerprint,processing_status")
    .eq("id", publicationId)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.fingerprint !== fingerprint) {
    throw new KnowledgeIngestionNotFoundError();
  }
  if (data.processing_status !== "processing" && data.processing_status !== "parsed") {
    throw new KnowledgeIngestionNotFoundError();
  }
}

export class KnowledgeIngestionNotFoundError extends Error {
  constructor() {
    super("No matching publication ingestion is active");
    this.name = "KnowledgeIngestionNotFoundError";
  }
}

export class KnowledgeIngestionMismatchError extends Error {
  constructor(
    readonly expectedChunks: number,
    readonly actualChunks: number,
    readonly expectedCharacters: number,
    readonly actualCharacters: number,
  ) {
    super("The uploaded publication text is incomplete");
    this.name = "KnowledgeIngestionMismatchError";
  }
}
