import { beforeEach, describe, expect, it, vi } from "vitest";

import { generateReaderResponse } from "../src/ai.js";
import {
  buildHighlightQuestionMessages,
  buildHighlightQuestionPrompt,
  highlightQuestionInstructions,
} from "../src/features/highlight-question/prompt.js";
import { answerHighlightQuestion } from "../src/features/highlight-question/service.js";

vi.mock("../src/ai.js", () => ({
  generateReaderResponse: vi.fn(),
}));

const input = {
  question: "Why does this distinction matter?",
  history: [
    { role: "reader" as const, text: "What is the claim?" },
    { role: "assistant" as const, text: "It distinguishes two concepts." },
  ],
  publication: {
    title: "The Test Book",
    author: "A. Reader",
    format: "epub" as const,
  },
  selection: {
    text: "Knowledge is not the same thing as certainty.",
    contextBefore: "The author first defines a conjecture.",
    contextAfter: "The next paragraph gives a counterexample.",
    resourceId: "chapter-2.xhtml",
    progression: 0.42,
  },
};

describe("highlight question feature", () => {
  beforeEach(() => {
    vi.mocked(generateReaderResponse).mockReset();
  });

  it("keeps the feature prompt explicit and reviewable", () => {
    const prompt = buildHighlightQuestionPrompt(input);

    expect(prompt).toContain("Why does this distinction matter?");
    expect(prompt).toContain(input.selection.text);
    expect(prompt).toContain("untrusted publication text");
    expect(prompt).not.toContain("What is the claim?");
    expect(highlightQuestionInstructions).toContain(
      "Never claim to have read any part",
    );
    expect(highlightQuestionInstructions).toContain("Use plain text only");

    expect(buildHighlightQuestionMessages(input)).toEqual([
      { role: "user", content: "What is the claim?" },
      {
        role: "assistant",
        content: "It distinguishes two concepts.",
      },
      { role: "user", content: prompt },
    ]);
  });

  it("inherits the shared AI primitive with bounded output", async () => {
    vi.mocked(generateReaderResponse).mockResolvedValue({
      text: "It separates fallible knowledge from psychological confidence.",
      model: "test-model",
      finishReason: "stop",
      attempts: 1,
      usage: {
        inputTokens: undefined,
        outputTokens: undefined,
        reasoningTokens: undefined,
        totalTokens: undefined,
      },
    });

    await answerHighlightQuestion(input);

    expect(generateReaderResponse).toHaveBeenCalledWith({
      messages: buildHighlightQuestionMessages(input),
      taskInstructions: highlightQuestionInstructions,
      maxOutputTokens: 1_600,
    });
  });
});
