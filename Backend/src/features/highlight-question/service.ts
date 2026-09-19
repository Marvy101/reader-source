import {
  generateReaderResponse,
  type ReaderResponse,
} from "../../ai.js";
import {
  buildHighlightQuestionMessages,
  highlightQuestionInstructions,
  type HighlightQuestionPromptInput,
} from "./prompt.js";

export async function answerHighlightQuestion(
  input: HighlightQuestionPromptInput,
): Promise<ReaderResponse> {
  return generateReaderResponse({
    messages: buildHighlightQuestionMessages(input),
    taskInstructions: highlightQuestionInstructions,
    maxOutputTokens: 1_600,
  });
}
