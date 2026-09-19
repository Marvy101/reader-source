import { generateText, streamText } from "ai";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  defaultAiModel,
  defaultMaxOutputTokens,
  generateReaderResponse,
  ReaderAIIncompleteResponseError,
  retryMaxOutputTokens,
  streamReaderResponse,
} from "../src/ai.js";

vi.mock("ai", () => ({
  generateText: vi.fn(),
  streamText: vi.fn(),
}));

describe("Reader AI Gateway service", () => {
  beforeEach(() => {
    vi.mocked(generateText).mockReset();
    vi.mocked(streamText).mockReset();
  });

  it("starts a bounded Gateway text stream with the shared Reader prompt", () => {
    const streamResult = { textStream: {} } as ReturnType<typeof streamText>;
    vi.mocked(streamText).mockReturnValue(streamResult);

    const response = streamReaderResponse({
      messages: [{ role: "user", content: "Explain this." }],
      taskInstructions: "Stay grounded.",
      maxOutputTokens: 900,
    });

    expect(response).toEqual({ model: defaultAiModel, result: streamResult });
    expect(streamText).toHaveBeenCalledWith(
      expect.objectContaining({
        model: defaultAiModel,
        messages: [{ role: "user", content: "Explain this." }],
        system: expect.stringContaining("Stay grounded."),
        maxOutputTokens: 900,
        providerOptions: {
          openai: { reasoningEffort: "minimal" },
        },
      }),
    );
  });

  it("uses the Gateway model with bounded output and grounded source text", async () => {
    vi.mocked(generateText).mockResolvedValue({
      text: "It argues that habit shapes character.",
      finishReason: "stop",
      usage: {
        inputTokens: 32,
        outputTokens: 9,
        outputTokenDetails: { reasoningTokens: 2 },
        totalTokens: 41,
      },
    } as Awaited<ReturnType<typeof generateText>>);

    const response = await generateReaderResponse({
      prompt: "What is the argument?",
      sourceText: "We are what we repeatedly do.",
    });

    expect(generateText).toHaveBeenCalledWith(
      expect.objectContaining({
        model: defaultAiModel,
        maxOutputTokens: defaultMaxOutputTokens,
        prompt: expect.stringContaining("We are what we repeatedly do."),
        system: expect.stringContaining("reading assistant"),
        providerOptions: {
          openai: { reasoningEffort: "minimal" },
        },
      }),
    );
    expect(response).toEqual({
      text: "It argues that habit shapes character.",
      model: defaultAiModel,
      finishReason: "stop",
      attempts: 1,
      usage: {
        inputTokens: 32,
        outputTokens: 9,
        reasoningTokens: 2,
        totalTokens: 41,
      },
    });
  });

  it("allows a deployment-level model override", async () => {
    vi.mocked(generateText).mockResolvedValue({
      text: "Answer",
      finishReason: "stop",
      usage: { outputTokenDetails: {} },
    } as Awaited<ReturnType<typeof generateText>>);

    const response = await generateReaderResponse(
      { prompt: "Question" },
      "anthropic/claude-sonnet-5",
    );

    expect(response.model).toBe("anthropic/claude-sonnet-5");
    expect(generateText).toHaveBeenCalledWith(
      expect.objectContaining({
        model: "anthropic/claude-sonnet-5",
        providerOptions: undefined,
      }),
    );
  });

  it("retries a length-limited response with a larger budget", async () => {
    vi.mocked(generateText)
      .mockResolvedValueOnce({
        text: "An unfinished",
        finishReason: "length",
        usage: { outputTokenDetails: {} },
      } as Awaited<ReturnType<typeof generateText>>)
      .mockResolvedValueOnce({
        text: "A complete answer.",
        finishReason: "stop",
        usage: {
          inputTokens: 10,
          outputTokens: 4,
          outputTokenDetails: { reasoningTokens: 1 },
          totalTokens: 15,
        },
      } as Awaited<ReturnType<typeof generateText>>);

    const response = await generateReaderResponse({
      prompt: "Question",
      maxOutputTokens: 1_000,
    });

    expect(generateText).toHaveBeenCalledTimes(2);
    expect(generateText).toHaveBeenLastCalledWith(
      expect.objectContaining({ maxOutputTokens: retryMaxOutputTokens }),
    );
    expect(response.text).toBe("A complete answer.");
    expect(response.attempts).toBe(2);
  });

  it("never returns a response that is still truncated after retry", async () => {
    vi.mocked(generateText).mockResolvedValue({
      text: "Still unfinished",
      finishReason: "length",
      usage: { outputTokenDetails: {} },
    } as Awaited<ReturnType<typeof generateText>>);

    await expect(
      generateReaderResponse({ prompt: "Question" }),
    ).rejects.toBeInstanceOf(ReaderAIIncompleteResponseError);
    expect(generateText).toHaveBeenCalledTimes(2);
  });
});
