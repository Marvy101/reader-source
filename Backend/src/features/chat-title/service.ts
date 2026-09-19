import { generateText } from "ai";

export const chatTitleModel = "openai/gpt-5.4-nano";

const chatTitleSystemPrompt = `Name a reading conversation from its first reader message.

Return only a concise title using 2 to 5 lowercase words. Do not use quotation marks, punctuation, labels, or generic titles such as "new conversation" or "reader question".`;

function cleanTitle(value: string, firstMessage: string): string {
  const cleaned = value
    .trim()
    .split(/\r?\n/, 1)[0]
    .replace(/^title\s*:\s*/i, "")
    .replace(/^["'“”‘’]+|["'“”‘’]+$/g, "")
    .replace(/[.!?:;,\-–—]+$/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase()
    .slice(0, 60)
    .trim();

  if (cleaned) return cleaned;

  return firstMessage
    .trim()
    .replace(/[^\p{L}\p{N}\s'-]/gu, "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 5)
    .join(" ")
    .toLocaleLowerCase()
    .slice(0, 60) || "conversation";
}

export async function nameReaderChat(firstMessage: string): Promise<{
  title: string;
  model: string;
  usage: {
    inputTokens: number | undefined;
    outputTokens: number | undefined;
    totalTokens: number | undefined;
  };
}> {
  const result = await generateText({
    model: chatTitleModel,
    system: chatTitleSystemPrompt,
    prompt: firstMessage,
    maxOutputTokens: 24,
    providerOptions: {
      openai: {
        reasoningEffort: "minimal",
      },
    },
  });

  return {
    title: cleanTitle(result.text, firstMessage),
    model: chatTitleModel,
    usage: {
      inputTokens: result.usage.inputTokens,
      outputTokens: result.usage.outputTokens,
      totalTokens: result.usage.totalTokens,
    },
  };
}
