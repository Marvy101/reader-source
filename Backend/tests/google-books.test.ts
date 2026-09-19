import { describe, expect, it, vi } from "vitest";

import {
  mergeCatalogResults,
  searchGoogleBooks,
} from "../src/features/catalog/google-books.js";
import type { CatalogSearchResult } from "../src/features/catalog/service.js";

describe("Google Books catalog fallback", () => {
  it("maps a live volume without inventing canonical catalog IDs", async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          items: [
            {
              id: "google-volume",
              volumeInfo: {
                title: "Recent Book",
                subtitle: "A Test",
                authors: ["A. Writer"],
                publisher: "Test Press",
                publishedDate: "2026-05-12",
                pageCount: 321,
                description: "A recent book.",
                industryIdentifiers: [
                  { type: "ISBN_13", identifier: "978-1-234-56789-0" },
                ],
                imageLinks: { thumbnail: "http://books.google.com/cover.jpg" },
              },
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );

    await expect(
      searchGoogleBooks("recent unique book", "secret-key", 10, fetcher),
    ).resolves.toEqual([
      {
        source: "google_books",
        externalId: "google-volume",
        workGroupId: null,
        workId: null,
        editionId: null,
        title: "Recent Book",
        subtitle: "A Test",
        authors: "A. Writer",
        translators: "",
        publisher: "Test Press",
        releaseYear: 2026,
        pageCount: 321,
        description: "A recent book.",
        coverUrl: "https://books.google.com/cover.jpg",
        primaryIdentifier: "isbn:9781234567890",
        availability: "notify_me",
        libraryPublicationId: null,
        downloadUrl: null,
        downloadMediaType: null,
      },
    ]);

    const requested = fetcher.mock.calls[0]?.[0] as URL;
    expect(requested.origin).toBe("https://www.googleapis.com");
    expect(requested.searchParams.get("key")).toBe("secret-key");
    expect(requested.searchParams.get("maxResults")).toBe("10");
  });

  it("keeps canonical results first and removes fallback duplicates", () => {
    const canonical: CatalogSearchResult = {
      source: "reader_catalog",
      externalId: null,
      workGroupId: 1,
      workId: 2,
      editionId: 3,
      title: "Pride and Prejudice",
      subtitle: null,
      authors: "Jane Austen",
      translators: "",
      publisher: "Project Gutenberg",
      releaseYear: 1813,
      pageCount: null,
      description: null,
      coverUrl: null,
      primaryIdentifier: "isbn:9780141439518",
      availability: "read_now",
      libraryPublicationId: null,
      downloadUrl: "https://example.com/pride.epub",
      downloadMediaType: "application/epub+zip",
    };
    const duplicate = {
      ...canonical,
      source: "google_books" as const,
      externalId: "duplicate",
      workGroupId: null,
      workId: null,
      editionId: null,
      availability: "notify_me" as const,
      downloadUrl: null,
      downloadMediaType: null,
    };
    const newBook = {
      ...duplicate,
      externalId: "new-book",
      title: "A Different Book",
      primaryIdentifier: "isbn:9780000000002",
    };

    expect(mergeCatalogResults([canonical], [duplicate, newBook], 10)).toEqual([
      canonical,
      newBook,
    ]);
  });

  it("exposes a public-domain Google download without persisting it", async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          items: [
            {
              id: "public-domain-volume",
              volumeInfo: { title: "An Old Book" },
              accessInfo: {
                publicDomain: true,
                epub: {
                  isAvailable: true,
                  downloadLink: "http://books.google.com/download.epub",
                },
              },
            },
          ],
        }),
        { status: 200 },
      ),
    );

    const results = await searchGoogleBooks(
      "public domain download unique",
      "secret-key",
      5,
      fetcher,
    );

    expect(results[0]).toMatchObject({
      externalId: "public-domain-volume",
      availability: "read_now",
      downloadUrl: "https://books.google.com/download.epub",
      downloadMediaType: "application/epub+zip",
    });
  });

  it("does not turn a fallback failure into an empty success", async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response("quota", { status: 429 }));

    await expect(
      searchGoogleBooks("quota failure unique", "secret-key", 10, fetcher),
    ).rejects.toThrow("Google Books returned HTTP 429");
  });

  it("coalesces identical in-flight searches without retaining uncached results", async () => {
    let release: ((response: Response) => void) | undefined;
    const fetcher = vi.fn().mockImplementation(
      () =>
        new Promise<Response>((resolve) => {
          release = resolve;
        }),
    );
    const first = searchGoogleBooks("coalesced unique query", "secret-key", 5, fetcher);
    const second = searchGoogleBooks("coalesced unique query", "secret-key", 5, fetcher);
    release?.(new Response(JSON.stringify({ items: [] }), { status: 200 }));

    await expect(Promise.all([first, second])).resolves.toEqual([[], []]);
    expect(fetcher).toHaveBeenCalledTimes(1);

    fetcher.mockResolvedValueOnce(
      new Response(JSON.stringify({ items: [] }), { status: 200 }),
    );
    await searchGoogleBooks("coalesced unique query", "secret-key", 5, fetcher);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("reuses a response only when Google explicitly permits shared caching", async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ items: [] }), {
        status: 200,
        headers: { "cache-control": "public, max-age=60" },
      }),
    );

    await searchGoogleBooks("cache-permitted unique query", "secret-key", 5, fetcher);
    await searchGoogleBooks("cache-permitted unique query", "secret-key", 5, fetcher);

    expect(fetcher).toHaveBeenCalledTimes(1);
  });
});
