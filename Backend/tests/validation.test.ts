import { describe, expect, it } from "vitest";

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
  reorderLibraryFilesSchema,
  signInSchema,
  startKnowledgeIngestionSchema,
  syncReadingStatesSchema,
  updateFolderSchema,
} from "../src/validation.js";

describe("API input validation", () => {
  it("accepts a bounded reading-assistant request", () => {
    expect(
      aiRespondSchema.parse({
        prompt: "Explain this passage.",
        sourceText: "All happy families are alike.",
      }),
    ).toEqual({
      prompt: "Explain this passage.",
      sourceText: "All happy families are alike.",
    });
  });

  it("rejects an oversized reading-assistant prompt", () => {
    expect(() =>
      aiRespondSchema.parse({ prompt: "x".repeat(4_001) }),
    ).toThrow();
  });

  it("accepts email/password auth and rejects short passwords", () => {
    expect(
      signInSchema.safeParse({ email: "reader@example.com", password: "long-enough" })
        .success,
    ).toBe(true);
    expect(
      signInSchema.safeParse({ email: "reader@example.com", password: "short" })
        .success,
    ).toBe(false);
    expect(refreshSessionSchema.safeParse({ refreshToken: "token" }).success).toBe(
      true,
    );
  });

  it("accepts a bounded highlight question with nearby context", () => {
    const result = highlightQuestionSchema.safeParse({
      question: "What does this mean?",
      history: [],
      publication: {
        title: "A Book",
        author: "An Author",
        format: "pdf",
      },
      selection: {
        text: "A selected passage",
        contextBefore: "Before",
        contextAfter: "After",
        resourceId: "page-4",
        progression: 0.5,
      },
    });

    expect(result.success).toBe(true);
  });

  it("accepts a conversation with optional bounded passage context", () => {
    const result = chatStreamSchema.safeParse({
      messages: [
        { role: "reader", text: "What is happening here?" },
      ],
      context: {
        publication: {
          title: "Moby-Dick",
          author: "Herman Melville",
          format: "epub",
        },
        selection: {
          text: "diligent study and a series of systematic visits to it",
          contextBefore: "Before",
          contextAfter: "After",
          resourceId: "chapter-3.xhtml",
          progression: 0.12,
        },
      },
    });

    expect(result.success).toBe(true);
    expect(
      chatStreamSchema.safeParse({
        messages: [{ role: "assistant", text: "I should not be last." }],
      }).success,
    ).toBe(false);
  });

  it("accepts the current-page context scope", () => {
    const result = chatStreamSchema.safeParse({
      messages: [{ role: "reader", text: "Explain this page." }],
      context: {
        publication: {
          id: "11111111-1111-4111-8111-111111111111",
          title: "Moby-Dick",
          format: "epub",
          textAccess: "cloudSearchable",
        },
        scope: "page",
        currentProgression: 0.12,
      },
    });

    expect(result.success).toBe(true);
  });

  it("accepts bounded chat attachments and a separate title request", () => {
    expect(
      chatStreamSchema.safeParse({
        messages: [
          {
            role: "reader",
            text: "What is shown here?",
            attachments: [
              {
                kind: "image",
                filename: "page.png",
                mediaType: "image/png",
                data: Buffer.from("image").toString("base64"),
              },
            ],
          },
        ],
      }).success,
    ).toBe(true);
    expect(chatTitleSchema.safeParse({ firstMessage: "Explain this claim" }).success)
      .toBe(true);
  });

  it("accepts a nested folder", () => {
    const result = createFolderSchema.safeParse({
      name: "Research",
      parentId: "a6a7f040-8fb5-4dda-8b0b-90edecbcf8ea",
    });

    expect(result.success).toBe(true);
  });

  it("rejects an empty folder update", () => {
    expect(updateFolderSchema.safeParse({}).success).toBe(false);
  });

  it("accepts a bounded library file order", () => {
    expect(
      reorderLibraryFilesSchema.safeParse({
        fileIds: ["11111111-1111-4111-8111-111111111111"],
      }).success,
    ).toBe(true);
    expect(
      reorderLibraryFilesSchema.safeParse({ fileIds: ["not-a-uuid"] }).success,
    ).toBe(false);
  });

  it.each([
    "application/epub+zip",
    "application/pdf",
    "text/plain",
  ])("accepts Reader media type %s", (mediaType) => {
    const result = createUploadSchema.safeParse({
      clientFileId: "a6a7f040-8fb5-4dda-8b0b-90edecbcf8ea",
      displayName: "A Book",
      originalFilename: "book.epub",
      mediaType,
      byteSize: 1024,
      sha256: "a".repeat(64),
    });

    expect(result.success).toBe(true);
  });

  it("rejects an invalid client file ID", () => {
    expect(
      createUploadSchema.safeParse({
        clientFileId: "same-book",
        displayName: "A Book",
        originalFilename: "book.epub",
        mediaType: "application/epub+zip",
        byteSize: 1024,
      }).success,
    ).toBe(false);
  });

  it("accepts bounded locator-preserving reading-state sync", () => {
    const validState = {
      fileId: "a6a7f040-8fb5-4dda-8b0b-90edecbcf8ea",
      locator: {
        publicationFingerprint: "fingerprint",
        resourceID: "page-41",
        position: 40,
        progression: 0.25,
      },
      progress: 0.25,
      lastOpenedAt: 1_788_000_000,
      updatedAt: 1_788_000_000,
    };

    expect(
      syncReadingStatesSchema.safeParse({
        deviceId: "4665e9bd-b4bd-4946-9356-70da1215ef31",
        states: [validState],
      }).success,
    ).toBe(true);
    expect(
      syncReadingStatesSchema.safeParse({
        deviceId: "4665e9bd-b4bd-4946-9356-70da1215ef31",
        states: [{ ...validState, progress: 1.1 }],
      }).success,
    ).toBe(false);
  });

  it("requires explicit account-deletion confirmation", () => {
    expect(
      deleteAccountSchema.safeParse({ confirmation: "DELETE" }).success,
    ).toBe(true);
    expect(
      deleteAccountSchema.safeParse({ confirmation: "delete" }).success,
    ).toBe(false);
  });

  it("bounds catalog search, interest, and explicit file matching", () => {
    expect(
      catalogSearchQuerySchema.parse({ query: "  moby dick  ", limit: "12" }),
    ).toEqual({
      query: "moby dick",
      locale: "en-US",
      limit: 12,
      includeFallback: false,
    });
    expect(
      catalogSearchQuerySchema.parse({
        query: "recent book",
        includeFallback: "true",
      }).includeFallback,
    ).toBe(true);
    expect(
      catalogSearchQuerySchema.safeParse({
        query: "recent book",
        includeFallback: "yes",
      }).success,
    ).toBe(false);
    expect(
      catalogSearchQuerySchema.safeParse({ query: "x", limit: 100 }).success,
    ).toBe(false);
    expect(
      catalogInterestSchema.safeParse({ workGroupId: 12, emailOptIn: true }).success,
    ).toBe(true);
    expect(
      catalogInterestSchema.safeParse({
        source: "google_books",
        externalId: "google-volume",
        title: "Recent Book",
        authors: "A. Writer",
      }).success,
    ).toBe(true);
    expect(
      catalogInterestSchema.safeParse({
        source: "google_books",
        externalId: "google-volume",
        title: "Recent Book",
        workGroupId: 12,
      }).success,
    ).toBe(false);
    expect(
      catalogMatchSchema.safeParse({
        workGroupId: 12,
        editionId: 14,
        source: "catalog_offer",
      }).success,
    ).toBe(false);
    expect(
      catalogMatchSchema.safeParse({
        workGroupId: 12,
        workId: 13,
        editionId: 14,
        source: "catalog_offer",
      }).success,
    ).toBe(true);
  });

  it("accepts bounded, locator-preserving book knowledge batches", () => {
    expect(
      startKnowledgeIngestionSchema.safeParse({
        title: "A Book",
        author: "An Author",
        format: "epub",
        fingerprint: "fingerprint",
        parserVersion: 1,
        totalChunks: 1,
        totalCharacters: 16,
        annotations: [],
      }).success,
    ).toBe(true);
    expect(
      putKnowledgeChunksSchema.safeParse({
        fingerprint: "fingerprint",
        chunks: [
          {
            ordinal: 0,
            resourceId: "chapter-1.xhtml",
            resourceTitle: "Chapter 1",
            text: "A bounded chunk.",
            positionStart: 0,
            positionEnd: 16,
            progressionStart: 0,
            progressionEnd: 0.1,
          },
        ],
      }).success,
    ).toBe(true);
    expect(
      completeKnowledgeIngestionSchema.safeParse({
        fingerprint: "fingerprint",
        expectedChunks: 1,
        expectedCharacters: 16,
      }).success,
    ).toBe(true);
  });
});
