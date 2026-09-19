import {
  streamReaderResponse,
  type ReaderResponseStream,
} from "../../ai.js";
import {
  buildReaderChatMessages,
  readerChatInstructions,
  type ReaderChatPromptInput,
} from "./prompt.js";
import {
  prepareBookContext,
  type BookEvidenceSummary,
} from "../book-knowledge/context.js";
import type { BookKnowledgeSearching } from "../book-knowledge/store.js";

export type ReaderChatStream = ReaderResponseStream & {
  evidence: BookEvidenceSummary;
};

export async function streamReaderChat(
  input: ReaderChatPromptInput,
  store: BookKnowledgeSearching,
): Promise<ReaderChatStream> {
  const prepared = await prepareBookContext(
    input,
    buildReaderChatMessages(input),
    store,
  );
  const response = streamReaderResponse({
    messages: prepared.messages,
    taskInstructions: readerChatInstructions,
    maxOutputTokens: 1_600,
    tools: prepared.tools,
    stopWhen: prepared.stopWhen,
  });
  return { ...response, evidence: prepared.evidence };
}
