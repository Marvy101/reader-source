import { generateText } from "ai";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  chatTitleModel,
  nameReaderChat,
} from "../src/features/chat-title/service.js";

vi.mock("ai", () => ({
  generateText: vi.fn(),
}));

describe("Reader chat title feature", () => {
  beforeEach(() => {
    vi.mocked(generateText).mockReset();
  });

  it("uses the nano model and normalizes a concise title", async () => {
    vi.mocked(generateText).mockResolvedValue({
      text: "\"Melville's Intentional Confusion.\"",
      usage: {
        inputTokens: 12,
        outputTokens: 5,
        totalTokens: 17,
      },
    } as Awaited<ReturnType<typeof generateText>>);

    const response = await nameReaderChat("Is the confusion intentional?");

    expect(response).toMatchObject({
      title: "melville's intentional confusion",
      model: chatTitleModel,
    });
    expect(generateText).toHaveBeenCalledWith(
      expect.objectContaining({
        model: "openai/gpt-5.4-nano",
        prompt: "Is the confusion intentional?",
        maxOutputTokens: 24,
      }),
    );
  });
});
