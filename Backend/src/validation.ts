import { z } from "zod";

const optionalFolderId = z.string().uuid().nullable().optional();
const email = z.string().trim().email().max(320);
const password = z.string().min(8).max(128);

export const signUpSchema = z.object({ email, password });
export const signInSchema = z.object({ email, password });
export const refreshSessionSchema = z.object({
  refreshToken: z.string().trim().min(1).max(4_096),
});

export const createFolderSchema = z.object({
  name: z.string().trim().min(1).max(200),
  parentId: optionalFolderId,
});

export const updateFolderSchema = z
  .object({
    name: z.string().trim().min(1).max(200).optional(),
    parentId: optionalFolderId,
  })
  .refine((input) => input.name !== undefined || input.parentId !== undefined, {
    message: "At least one field is required",
  });

export const createUploadSchema = z.object({
  clientFileId: z.string().uuid().optional(),
  displayName: z.string().trim().min(1).max(500),
  originalFilename: z.string().trim().min(1).max(500),
  mediaType: z.enum([
    "application/epub+zip",
    "application/pdf",
    "text/plain",
  ]),
  byteSize: z.number().int().positive(),
  sha256: z.string().regex(/^[a-f0-9]{64}$/).optional(),
  folderId: optionalFolderId,
});

export const updateFileSchema = z
  .object({
    displayName: z.string().trim().min(1).max(500).optional(),
    folderId: optionalFolderId,
  })
  .refine(
    (input) => input.displayName !== undefined || input.folderId !== undefined,
    { message: "At least one field is required" },
  );

export const reorderLibraryFilesSchema = z.object({
  fileIds: z.array(z.string().uuid()).max(2_000),
});

const readingStateSchema = z.object({
  fileId: z.string().uuid(),
  locator: z.record(z.string(), z.unknown()).refine(
    (locator) => JSON.stringify(locator).length <= 64_000,
    { message: "A reading locator may contain at most 64,000 characters" },
  ),
  progress: z.number().min(0).max(1),
  lastOpenedAt: z.number().finite().min(0).max(4_102_444_800),
  updatedAt: z.number().finite().min(0).max(4_102_444_800),
});

export const syncReadingStatesSchema = z.object({
  deviceId: z.string().uuid(),
  states: z.array(readingStateSchema).max(500),
});

export const deleteAccountSchema = z.object({
  confirmation: z.literal("DELETE"),
});

export const catalogSearchQuerySchema = z.object({
  query: z.string().trim().min(2).max(500),
  locale: z
    .string()
    .trim()
    .regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/)
    .default("en-US"),
  limit: z.coerce.number().int().min(1).max(50).default(20),
  includeFallback: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),
});

export const catalogInterestSchema = z.union([
  z
    .object({
      workGroupId: z.number().int().positive(),
      emailOptIn: z.boolean().default(false),
    })
    .strict(),
  z
    .object({
      source: z.literal("google_books"),
      externalId: z.string().trim().min(1).max(1_000),
      title: z.string().trim().min(1).max(1_000),
      authors: z.string().trim().max(2_000).default(""),
      primaryIdentifier: z.string().trim().min(1).max(1_000).nullish(),
      emailOptIn: z.boolean().default(false),
    })
    .strict(),
]);

export const catalogMatchSchema = z
  .object({
    workGroupId: z.number().int().positive(),
    workId: z.number().int().positive().optional(),
    editionId: z.number().int().positive().optional(),
    source: z.enum(["catalog_offer", "user_file"]),
  })
  .refine((input) => input.editionId === undefined || input.workId !== undefined, {
    message: "An edition match requires a work ID",
    path: ["workId"],
  });

export const aiRespondSchema = z.object({
  prompt: z.string().trim().min(1).max(4_000),
  sourceText: z.string().trim().min(1).max(12_000).optional(),
});

const publicationSchema = z.object({
  title: z.string().trim().min(1).max(500),
  author: z.string().trim().max(500).optional(),
  format: z.enum(["pdf", "epub", "plainText"]),
});

const selectionSchema = z.object({
  text: z.string().trim().min(1).max(8_000),
  contextBefore: z.string().max(3_000).default(""),
  contextAfter: z.string().max(3_000).default(""),
  resourceId: z.string().trim().min(1).max(1_000),
  progression: z.number().min(0).max(1),
});

const publicationKnowledgeAnnotationSchema = z.object({
  id: z.string().uuid(),
  selectedText: z.string().trim().min(1).max(20_000),
  note: z.string().trim().max(20_000).nullable().optional(),
  resourceId: z.string().trim().min(1).max(1_000),
  position: z.number().int().min(0),
  progression: z.number().min(0).max(1),
  locator: z.record(z.string(), z.unknown()),
  createdAt: z.string().datetime(),
});

export const startKnowledgeIngestionSchema = z.object({
  title: z.string().trim().min(1).max(500),
  author: z.string().trim().max(500).optional(),
  format: z.enum(["pdf", "epub", "plainText"]),
  fingerprint: z.string().trim().min(1).max(500),
  parserVersion: z.number().int().min(1).max(1_000).default(1),
  totalChunks: z.number().int().min(1).max(20_000),
  totalCharacters: z.number().int().min(1).max(50_000_000),
  annotations: z.array(publicationKnowledgeAnnotationSchema).max(10_000).default([]),
});

const publicationKnowledgeChunkSchema = z
  .object({
    ordinal: z.number().int().min(0).max(19_999),
    resourceId: z.string().trim().min(1).max(1_000),
    resourceTitle: z.string().trim().max(1_000).nullable().optional(),
    text: z.string().trim().min(1).max(100_000),
    positionStart: z.number().int().min(0),
    positionEnd: z.number().int().min(0),
    progressionStart: z.number().min(0).max(1),
    progressionEnd: z.number().min(0).max(1),
  })
  .refine(
    (chunk) =>
      chunk.positionEnd >= chunk.positionStart &&
      chunk.progressionEnd >= chunk.progressionStart,
    { message: "Chunk ranges must be ordered" },
  );

export const putKnowledgeChunksSchema = z
  .object({
    fingerprint: z.string().trim().min(1).max(500),
    chunks: z.array(publicationKnowledgeChunkSchema).min(1).max(100),
  })
  .refine(
    (input) =>
      input.chunks.reduce((total, chunk) => total + chunk.text.length, 0) <=
      1_000_000,
    { message: "A chunk batch may contain at most 1,000,000 characters" },
  );

export const completeKnowledgeIngestionSchema = z.object({
  fingerprint: z.string().trim().min(1).max(500),
  expectedChunks: z.number().int().min(1).max(20_000),
  expectedCharacters: z.number().int().min(1).max(50_000_000),
});

const chatAttachmentSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("image"),
    filename: z.string().trim().min(1).max(255),
    mediaType: z.enum([
      "image/jpeg",
      "image/png",
      "image/gif",
      "image/webp",
    ]),
    data: z.string().min(1).max(3_400_000),
  }),
  z.object({
    kind: z.literal("pdf"),
    filename: z.string().trim().min(1).max(255),
    mediaType: z.literal("application/pdf"),
    data: z.string().min(1).max(3_400_000),
  }),
  z.object({
    kind: z.literal("text"),
    filename: z.string().trim().min(1).max(255),
    mediaType: z.enum([
      "text/plain",
      "text/markdown",
      "text/csv",
    ]),
    data: z.string().min(1).max(1_400_000),
  }),
]);

const chatMessageSchema = z.object({
  role: z.enum(["reader", "assistant"]),
  text: z.string().trim().min(1).max(4_000),
  attachments: z.array(chatAttachmentSchema).max(4).default([]),
});

export const chatStreamSchema = z
  .object({
    messages: z.array(chatMessageSchema).min(1).max(16),
    context: z
      .object({
        publication: publicationSchema.extend({
          id: z.string().uuid().optional(),
          textAccess: z
            .enum(["cloudSearchable", "localOnly", "restricted", "unavailable"])
            .default("unavailable"),
        }),
        scope: z
          .enum(["passage", "page", "upToHere", "wholeBook"])
          .default("passage"),
        currentProgression: z.number().min(0).max(1).default(1),
        selection: selectionSchema.optional(),
      })
      .optional(),
  })
  .refine((input) => input.messages.at(-1)?.role === "reader", {
    message: "The final message must come from the reader",
    path: ["messages"],
  })
  .refine(
    (input) =>
      input.messages.reduce(
        (total, message) =>
          total + message.attachments.reduce(
            (messageTotal, attachment) => messageTotal + attachment.data.length,
            0,
          ),
        0,
      ) <= 3_400_000,
    {
      message: "Attachments are too large",
      path: ["messages"],
    },
  );

export const chatTitleSchema = z.object({
  firstMessage: z.string().trim().min(1).max(2_000),
});

export const highlightQuestionSchema = z.object({
  question: z.string().trim().min(1).max(2_000),
  history: z
    .array(
      z.object({
        role: z.enum(["reader", "assistant"]),
        text: z.string().trim().min(1).max(4_000),
      }),
    )
    .max(8)
    .default([]),
  publication: publicationSchema,
  selection: selectionSchema,
});
