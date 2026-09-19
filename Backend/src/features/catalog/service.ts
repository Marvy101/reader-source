import type { SupabaseClient } from "@supabase/supabase-js";

export type CatalogAvailability =
  | "read_now"
  | "in_library"
  | "add_own_file"
  | "notify_me";

export type CatalogSearchResult = {
  source: "reader_catalog" | "google_books";
  externalId: string | null;
  workGroupId: number | null;
  workId: number | null;
  editionId: number | null;
  title: string;
  subtitle: string | null;
  authors: string;
  translators: string;
  publisher: string | null;
  releaseYear: number | null;
  pageCount: number | null;
  description: string | null;
  coverUrl: string | null;
  primaryIdentifier: string | null;
  availability: CatalogAvailability;
  libraryPublicationId: string | null;
  downloadUrl: string | null;
  downloadMediaType: string | null;
};

export type CatalogInterestInput =
  | {
      workGroupId: number;
      emailOptIn: boolean;
    }
  | {
      source: "google_books";
      externalId: string;
      title: string;
      authors: string;
      primaryIdentifier?: string | null;
      emailOptIn: boolean;
    };

type CatalogSearchRow = {
  work_group_id: number;
  work_id: number | null;
  edition_id: number | null;
  title: string;
  subtitle: string | null;
  authors: string;
  translators: string;
  publisher: string | null;
  release_year: number | null;
  page_count: number | null;
  description: string | null;
  cover_url: string | null;
  primary_identifier: string | null;
  availability: CatalogAvailability;
  library_publication_id: string | null;
  download_url: string | null;
  download_media_type: string | null;
};

type MaterializedFileRow = {
  edition_id: number;
  storage_bucket: string;
  storage_path: string;
  media_type: string;
};

type SignedFile = {
  path?: string | null;
  signedUrl?: string | null;
  error?: unknown;
};

export class CatalogStoreError extends Error {
  constructor(message: string, readonly cause?: unknown) {
    super(message);
    this.name = "CatalogStoreError";
  }
}

export async function searchCatalog(
  client: SupabaseClient,
  userId: string,
  query: string,
  locale: string,
  limit: number,
  territory: string | null = null,
): Promise<CatalogSearchResult[]> {
  const { data, error } = await client.rpc("catalog_search", {
    p_query: query,
    p_locale: locale,
    p_user_id: userId,
    p_limit: limit,
  });
  if (error) {
    throw new CatalogStoreError("Catalog search failed", error);
  }

  const results: CatalogSearchResult[] = ((data ?? []) as CatalogSearchRow[]).map((row) => ({
    source: "reader_catalog",
    externalId: null,
    workGroupId: row.work_group_id,
    workId: row.work_id,
    editionId: row.edition_id,
    title: row.title,
    subtitle: row.subtitle,
    authors: row.authors,
    translators: row.translators,
    publisher: row.publisher,
    releaseYear: row.release_year,
    pageCount: row.page_count,
    description: row.description,
    coverUrl: row.cover_url,
    primaryIdentifier: row.primary_identifier,
    availability: row.availability,
    libraryPublicationId: row.library_publication_id,
    downloadUrl: row.download_url,
    downloadMediaType: row.download_media_type,
  }));
  return preferMaterializedFiles(client, results, territory);
}

async function preferMaterializedFiles(
  client: SupabaseClient,
  results: CatalogSearchResult[],
  territory: string | null,
): Promise<CatalogSearchResult[]> {
  const editionIds = results
    .map((result) => result.editionId)
    .filter((editionId): editionId is number => editionId !== null);
  if (editionIds.length === 0) return results;

  const { data, error } = await client.rpc("catalog_resolve_materialized_files", {
    p_edition_ids: editionIds,
    p_territory: territory,
  });
  if (error || !Array.isArray(data) || data.length === 0) return results;

  const rows = data as MaterializedFileRow[];
  const signedByEdition = new Map<
    number,
    { url: string; mediaType: string }
  >();
  const rowsByBucket = new Map<string, MaterializedFileRow[]>();
  for (const row of rows) {
    const bucketRows = rowsByBucket.get(row.storage_bucket) ?? [];
    bucketRows.push(row);
    rowsByBucket.set(row.storage_bucket, bucketRows);
  }

  for (const [bucket, bucketRows] of rowsByBucket) {
    const { data: signed, error: signedError } = await client.storage
      .from(bucket)
      .createSignedUrls(
        bucketRows.map((row) => row.storage_path),
        15 * 60,
      );
    if (signedError || !Array.isArray(signed)) continue;
    const signedByPath = new Map(
      (signed as SignedFile[])
        .filter(
          (item): item is SignedFile & { path: string; signedUrl: string } =>
            typeof item.path === "string" &&
            typeof item.signedUrl === "string" &&
            !item.error,
        )
        .map((item) => [item.path, item.signedUrl]),
    );
    for (const row of bucketRows) {
      const url = signedByPath.get(row.storage_path);
      if (url) {
        signedByEdition.set(row.edition_id, {
          url,
          mediaType: row.media_type,
        });
      }
    }
  }

  return results.map((result) => {
    if (result.editionId === null) return result;
    const materialized = signedByEdition.get(result.editionId);
    if (!materialized) return result;
    return {
      ...result,
      availability: "read_now",
      downloadUrl: materialized.url,
      downloadMediaType: materialized.mediaType,
    };
  });
}

export async function registerCatalogInterest(
  client: SupabaseClient,
  userId: string,
  input: CatalogInterestInput,
): Promise<void> {
  const { error } = "workGroupId" in input
    ? await client.from("catalog_interests").upsert(
        {
          user_id: userId,
          work_group_id: input.workGroupId,
          email_opt_in: input.emailOptIn,
          active: true,
        },
        { onConflict: "user_id,work_group_id" },
      )
    : await client.rpc("catalog_register_provider_interest", {
        p_user_id: userId,
        p_source_code: input.source,
        p_external_id: input.externalId,
        p_title: input.title,
        p_authors: input.authors,
        p_primary_identifier: input.primaryIdentifier ?? null,
        p_email_opt_in: input.emailOptIn,
      });
  if (error) {
    throw new CatalogStoreError("Catalog interest could not be saved", error);
  }
}

export async function matchLibraryPublication(
  client: SupabaseClient,
  userId: string,
  publicationId: string,
  input: {
    workGroupId: number;
    workId?: number;
    editionId?: number;
    source: "catalog_offer" | "user_file";
  },
): Promise<void> {
  const { data: file, error: fileError } = await client
    .from("library_files")
    .select("id")
    .eq("id", publicationId)
    .eq("user_id", userId)
    .eq("status", "ready")
    .maybeSingle();
  if (fileError) {
    throw new CatalogStoreError("Library file lookup failed", fileError);
  }
  if (!file) {
    throw new CatalogStoreError("The library file is not ready for matching");
  }

  const matchLevel = input.editionId
    ? "edition"
    : input.workId
      ? "work"
      : "work_group";
  const { error } = await client
    .from("library_publication_catalog_matches")
    .upsert(
      {
        publication_id: publicationId,
        user_id: userId,
        work_group_id: input.workGroupId,
        work_id: input.workId ?? null,
        edition_id: input.editionId ?? null,
        origin_content_file_id: null,
        match_level: matchLevel,
        match_method: input.source === "catalog_offer" ? "catalog_offer" : "manual",
        confidence: 1,
        evidence: { source: input.source },
      },
      { onConflict: "publication_id" },
    );
  if (error) {
    throw new CatalogStoreError("Library file catalog match failed", error);
  }
}
