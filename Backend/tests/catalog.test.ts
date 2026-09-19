import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import {
  CatalogStoreError,
  matchLibraryPublication,
  registerCatalogInterest,
  searchCatalog,
} from "../src/features/catalog/service.js";

describe("catalog service", () => {
  it("maps private catalog RPC rows onto the public API contract", async () => {
    const rpc = vi.fn().mockImplementation((name: string) =>
      Promise.resolve(
        name === "catalog_search"
          ? {
              data: [
                {
          work_group_id: 12,
          work_id: 13,
          edition_id: 14,
          title: "Pride and Prejudice",
          subtitle: null,
          authors: "Austen, Jane",
          translators: "",
          publisher: null,
          release_year: null,
          page_count: null,
          description: null,
          cover_url: "https://example.com/cover.jpg",
          primary_identifier: null,
          availability: "read_now",
          library_publication_id: null,
          download_url: "https://example.com/book.epub",
          download_media_type: "application/epub+zip",
          relevance: 1001,
                },
              ],
              error: null,
            }
          : { data: [], error: null },
      ),
    );
    const client = {
      rpc,
      storage: { from: vi.fn() },
    } as unknown as SupabaseClient;

    await expect(
      searchCatalog(client, "user-id", "pride", "en-US", 20),
    ).resolves.toEqual([
      {
        source: "reader_catalog",
        externalId: null,
        workGroupId: 12,
        workId: 13,
        editionId: 14,
        title: "Pride and Prejudice",
        subtitle: null,
        authors: "Austen, Jane",
        translators: "",
        publisher: null,
        releaseYear: null,
        pageCount: null,
        description: null,
        coverUrl: "https://example.com/cover.jpg",
        primaryIdentifier: null,
        availability: "read_now",
        libraryPublicationId: null,
        downloadUrl: "https://example.com/book.epub",
        downloadMediaType: "application/epub+zip",
      },
    ]);
    expect(rpc).toHaveBeenCalledWith("catalog_search", {
      p_query: "pride",
      p_locale: "en-US",
      p_user_id: "user-id",
      p_limit: 20,
    });
    expect(rpc).toHaveBeenCalledWith("catalog_resolve_materialized_files", {
      p_edition_ids: [14],
      p_territory: null,
    });
  });

  it("prefers a territory-eligible stored file and signs it briefly", async () => {
    const rpc = vi.fn().mockImplementation((name: string) =>
      Promise.resolve(
        name === "catalog_search"
          ? {
              data: [
                {
                  work_group_id: 12,
                  work_id: 13,
                  edition_id: 14,
                  title: "Pride and Prejudice",
                  subtitle: null,
                  authors: "Austen, Jane",
                  translators: "",
                  publisher: null,
                  release_year: null,
                  page_count: null,
                  description: null,
                  cover_url: null,
                  primary_identifier: null,
                  availability: "read_now",
                  library_publication_id: null,
                  download_url: "https://www.gutenberg.org/old.epub",
                  download_media_type: "application/epub+zip",
                  relevance: 1001,
                },
              ],
              error: null,
            }
          : {
              data: [
                {
                  edition_id: 14,
                  storage_bucket: "reader-catalog-files",
                  storage_path: "project_gutenberg/gutenberg-1342/hash.epub",
                  media_type: "application/epub+zip",
                  byte_size: 1024,
                  sha256: "a".repeat(64),
                },
              ],
              error: null,
            },
      ),
    );
    const createSignedUrls = vi.fn().mockResolvedValue({
      data: [
        {
          path: "project_gutenberg/gutenberg-1342/hash.epub",
          signedUrl: "https://storage.example/signed.epub",
          error: null,
        },
      ],
      error: null,
    });
    const from = vi.fn().mockReturnValue({ createSignedUrls });
    const client = { rpc, storage: { from } } as unknown as SupabaseClient;

    const results = await searchCatalog(
      client,
      "user-id",
      "pride",
      "en-US",
      20,
      "US",
    );

    expect(results[0]).toMatchObject({
      availability: "read_now",
      downloadUrl: "https://storage.example/signed.epub",
      downloadMediaType: "application/epub+zip",
    });
    expect(rpc).toHaveBeenCalledWith("catalog_resolve_materialized_files", {
      p_edition_ids: [14],
      p_territory: "US",
    });
    expect(from).toHaveBeenCalledWith("reader-catalog-files");
    expect(createSignedUrls).toHaveBeenCalledWith(
      ["project_gutenberg/gutenberg-1342/hash.epub"],
      15 * 60,
    );
  });

  it("does not hide database failures behind an empty catalog", async () => {
    const client = {
      rpc: vi.fn().mockResolvedValue({ data: null, error: new Error("offline") }),
    } as unknown as SupabaseClient;

    await expect(
      searchCatalog(client, "user-id", "pride", "en-US", 20),
    ).rejects.toBeInstanceOf(CatalogStoreError);
  });

  it("records interest idempotently for the authenticated user", async () => {
    const upsert = vi.fn().mockResolvedValue({ error: null });
    const client = {
      from: vi.fn().mockReturnValue({ upsert }),
    } as unknown as SupabaseClient;

    await registerCatalogInterest(client, "user-id", {
      workGroupId: 42,
      emailOptIn: true,
    });

    expect(upsert).toHaveBeenCalledWith(
      {
        user_id: "user-id",
        work_group_id: 42,
        email_opt_in: true,
        active: true,
      },
      { onConflict: "user_id,work_group_id" },
    );
  });

  it("records provider-scoped interest without inventing a canonical work", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: null });
    const client = { rpc } as unknown as SupabaseClient;

    await registerCatalogInterest(client, "user-id", {
      source: "google_books",
      externalId: "google-volume",
      title: "Recent Book",
      authors: "A. Writer",
      primaryIdentifier: "isbn:9781234567890",
      emailOptIn: false,
    });

    expect(rpc).toHaveBeenCalledWith("catalog_register_provider_interest", {
      p_user_id: "user-id",
      p_source_code: "google_books",
      p_external_id: "google-volume",
      p_title: "Recent Book",
      p_authors: "A. Writer",
      p_primary_identifier: "isbn:9781234567890",
      p_email_opt_in: false,
    });
  });

  it("matches only a ready file owned by the authenticated user", async () => {
    const maybeSingle = vi.fn().mockResolvedValue({
      data: { id: "file-id" },
      error: null,
    });
    const fileQuery = {
      select: vi.fn(),
      eq: vi.fn(),
      maybeSingle,
    };
    fileQuery.select.mockReturnValue(fileQuery);
    fileQuery.eq.mockReturnValue(fileQuery);
    const upsert = vi.fn().mockResolvedValue({ error: null });
    const from = vi.fn((table: string) =>
      table === "library_files" ? fileQuery : { upsert },
    );
    const client = { from } as unknown as SupabaseClient;

    await matchLibraryPublication(client, "user-id", "file-id", {
      workGroupId: 12,
      workId: 13,
      editionId: 14,
      source: "catalog_offer",
    });

    expect(fileQuery.eq).toHaveBeenNthCalledWith(1, "id", "file-id");
    expect(fileQuery.eq).toHaveBeenNthCalledWith(2, "user_id", "user-id");
    expect(fileQuery.eq).toHaveBeenNthCalledWith(3, "status", "ready");
    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        publication_id: "file-id",
        user_id: "user-id",
        work_group_id: 12,
        work_id: 13,
        edition_id: 14,
        match_level: "edition",
        match_method: "catalog_offer",
      }),
      { onConflict: "publication_id" },
    );
  });

  it("rejects a catalog match when the owned file is not ready", async () => {
    const maybeSingle = vi.fn().mockResolvedValue({ data: null, error: null });
    const fileQuery = {
      select: vi.fn(),
      eq: vi.fn(),
      maybeSingle,
    };
    fileQuery.select.mockReturnValue(fileQuery);
    fileQuery.eq.mockReturnValue(fileQuery);
    const upsert = vi.fn();
    const client = {
      from: vi.fn((table: string) =>
        table === "library_files" ? fileQuery : { upsert },
      ),
    } as unknown as SupabaseClient;

    await expect(
      matchLibraryPublication(client, "user-id", "file-id", {
        workGroupId: 12,
        source: "user_file",
      }),
    ).rejects.toBeInstanceOf(CatalogStoreError);
    expect(upsert).not.toHaveBeenCalled();
  });
});
