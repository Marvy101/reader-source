import { beforeEach, describe, expect, it, vi } from "vitest";

import { streamReaderResponse } from "../src/ai.js";
import {
  buildReaderChatMessages,
  readerChatInstructions,
} from "../src/features/chat/prompt.js";
import { streamReaderChat } from "../src/features/chat/service.js";
import type { BookKnowledgeSearching } from "../src/features/book-knowledge/store.js";

vi.mock("../src/ai.js", () => ({
  streamReaderResponse: vi.fn(),
}));

const input = {
  messages: [
    { role: "reader" as const, text: "What is the claim?" },
    { role: "assistant" as const, text: "It distinguishes two ideas." },
    { role: "reader" as const, text: "Why does that matter?" },
  ],
  context: {
    publication: {
      title: "The Test Book",
      author: "A. Reader",
      format: "epub" as const,
      textAccess: "localOnly" as const,
    },
    scope: "passage" as const,
    currentProgression: 0.42,
    selection: {
      text: "Knowledge is not the same thing as certainty.",
      contextBefore: "The author first defines a conjecture.",
      contextAfter: "The next paragraph gives a counterexample.",
      resourceId: "chapter-2.xhtml",
      progression: 0.42,
    },
  },
};

const emptyStore: BookKnowledgeSearching = {
  loadPage: vi.fn(async () => []),
  loadWholeBook: vi.fn(async () => []),
  searchBook: vi.fn(async () => []),
  searchAnnotations: vi.fn(async () => []),
};

describe("Reader chat feature", () => {
  beforeEach(() => {
    vi.mocked(streamReaderResponse).mockReset();
  });

  it("keeps prior turns natural and bounds passage evidence to the latest turn", () => {
    const messages = buildReaderChatMessages(input);

    expect(messages.slice(0, 2)).toEqual([
      { role: "user", content: "What is the claim?" },
      { role: "assistant", content: "It distinguishes two ideas." },
    ]);
    expect(messages[2]).toEqual({
      role: "user",
      content: expect.stringContaining("Why does that matter?"),
    });
    expect(messages[2]).toEqual({
      role: "user",
      content: expect.stringContaining(input.context.selection.text),
    });
    expect(readerChatInstructions).toContain("untrusted evidence");
    expect(readerChatInstructions).toContain("plain text only");
  });

  it("starts the shared streaming primitive with a bounded output", async () => {
    const stream = { model: "test", result: {} } as ReturnType<
      typeof streamReaderResponse
    >;
    vi.mocked(streamReaderResponse).mockReturnValue(stream);

    await expect(streamReaderChat(input, emptyStore)).resolves.toMatchObject(stream);
    expect(streamReaderResponse).toHaveBeenCalledWith({
      messages: buildReaderChatMessages(input),
      taskInstructions: readerChatInstructions,
      maxOutputTokens: 1_600,
      stopWhen: undefined,
      tools: undefined,
    });
  });

  it("passes images and PDFs as native model parts and decodes text documents", () => {
    const messages = buildReaderChatMessages({
      messages: [
        {
          role: "reader",
          text: "Compare these",
          attachments: [
            {
              kind: "image",
              filename: "page.png",
              mediaType: "image/png",
              data: Buffer.from("image").toString("base64"),
            },
            {
              kind: "pdf",
              filename: "notes.pdf",
              mediaType: "application/pdf",
              data: Buffer.from("pdf").toString("base64"),
            },
            {
              kind: "text",
              filename: "draft.md",
              mediaType: "text/markdown",
              data: Buffer.from("untrusted notes").toString("base64"),
            },
          ],
        },
      ],
    });

    expect(messages).toHaveLength(1);
    const content = messages[0].content;
    expect(Array.isArray(content)).toBe(true);
    expect(content).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: "image", mediaType: "image/png" }),
        expect.objectContaining({
          type: "file",
          mediaType: "application/pdf",
          filename: "notes.pdf",
        }),
        expect.objectContaining({
          type: "text",
          text: expect.stringContaining("untrusted notes"),
        }),
      ]),
    );
  });
});
