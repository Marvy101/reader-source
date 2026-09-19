import { describe, expect, it, vi } from "vitest";

import { prepareBookContext } from "../src/features/book-knowledge/context.js";
import type { BookKnowledgeSearching } from "../src/features/book-knowledge/store.js";
import { buildReaderChatMessages } from "../src/features/chat/prompt.js";

const baseInput = {
  messages: [{ role: "reader" as const, text: "What changes here?" }],
  context: {
    publication: {
      id: "11111111-1111-4111-8111-111111111111",
      title: "A Book",
      author: "An Author",
      format: "epub" as const,
      textAccess: "cloudSearchable" as const,
    },
    scope: "upToHere" as const,
    currentProgression: 0.4,
  },
};

function store(): BookKnowledgeSearching {
  return {
    loadPage: vi.fn(async () => []),
    loadWholeBook: vi.fn(async () => []),
    searchBook: vi.fn(async () => [
      {
        ordinal: 2,
        resourceId: "chapter-2.xhtml",
        resourceTitle: "Chapter 2",
        text: "The earlier promise changes the meaning.",
        positionStart: 120,
        positionEnd: 160,
        progressionStart: 0.32,
        progressionEnd: 0.34,
      },
    ]),
    searchAnnotations: vi.fn(async () => []),
  };
}

describe("book context", () => {
  it("exposes search tools with a hard current-reading boundary", async () => {
    const knowledge = store();
    const prepared = await prepareBookContext(
      baseInput,
      buildReaderChatMessages(baseInput),
      knowledge,
    );

    expect(prepared.tools).toHaveProperty("search_book");
    const search = prepared.tools?.search_book;
    const output = await search?.execute?.(
      { query: "earlier promise", limit: 6 },
      { toolCallId: "test", messages: [], abortSignal: undefined },
    );
    expect(knowledge.searchBook).toHaveBeenCalledWith(
      baseInput.context.publication.id,
      "earlier promise",
      0.4,
      6,
    );
    expect(output).toEqual({
      passages: [expect.objectContaining({ citation: "B1" })],
    });
    expect(prepared.evidence.label).toBe("searched 1 passage");
  });

  it("packs a small whole book directly into context", async () => {
    const knowledge = store();
    vi.mocked(knowledge.loadWholeBook).mockResolvedValue([
      {
        ordinal: 0,
        resourceId: "chapter-1.xhtml",
        resourceTitle: "Chapter 1",
        text: "The complete short book.",
        positionStart: 0,
        positionEnd: 24,
        progressionStart: 0,
        progressionEnd: 1,
      },
    ]);
    const input = {
      ...baseInput,
      context: { ...baseInput.context, scope: "wholeBook" as const },
    };
    const prepared = await prepareBookContext(
      input,
      buildReaderChatMessages(input),
      knowledge,
    );

    expect(prepared.tools).toHaveProperty("search_annotations");
    expect(prepared.tools).not.toHaveProperty("search_book");
    expect(prepared.evidence.label).toBe("whole book included");
    expect(JSON.stringify(prepared.messages)).toContain("complete short book");
  });

  it("loads the current page directly without searching the rest of the book", async () => {
    const knowledge = store();
    vi.mocked(knowledge.loadPage).mockResolvedValue([
      {
        ordinal: 4,
        resourceId: "chapter-3.xhtml",
        resourceTitle: "Chapter 3",
        text: "The complete current page.",
        positionStart: 0,
        positionEnd: 26,
        progressionStart: 0.38,
        progressionEnd: 0.42,
      },
    ]);
    const input = {
      ...baseInput,
      context: { ...baseInput.context, scope: "page" as const },
    };

    const prepared = await prepareBookContext(
      input,
      buildReaderChatMessages(input),
      knowledge,
    );

    expect(knowledge.loadPage).toHaveBeenCalledWith(
      baseInput.context.publication.id,
      0.4,
    );
    expect(prepared.tools).toBeUndefined();
    expect(prepared.evidence.label).toBe("current page included");
    expect(JSON.stringify(prepared.messages)).toContain("complete current page");
  });
});
