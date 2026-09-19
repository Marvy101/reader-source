import { describe, expect, it, vi } from "vitest";

import {
  completeKnowledgeIngestion,
  KnowledgeIngestionMismatchError,
} from "../src/features/book-knowledge/ingestion.js";

function clientWithTotals(totals: {
  chunk_count: number;
  character_count: number;
  minimum_ordinal: number;
  maximum_ordinal: number;
}) {
  const updateEq = vi.fn(async () => ({ error: null }));
  const update = vi.fn(() => ({ eq: updateEq }));
  const maybeSingle = vi.fn(async () => ({
    data: { fingerprint: "fingerprint", processing_status: "processing" },
    error: null,
  }));
  const eq = vi.fn(() => ({ maybeSingle }));
  const select = vi.fn(() => ({ eq }));
  const from = vi.fn(() => ({ select, update }));
  const single = vi.fn(async () => ({ data: totals, error: null }));
  const rpc = vi.fn(() => ({ single }));

  return {
    client: { from, rpc } as never,
    update,
  };
}

describe("book ingestion completion", () => {
  it("marks a locator-complete upload parsed", async () => {
    const { client, update } = clientWithTotals({
      chunk_count: 2,
      character_count: 12_000,
      minimum_ordinal: 0,
      maximum_ordinal: 1,
    });

    await completeKnowledgeIngestion(
      client,
      "11111111-1111-4111-8111-111111111111",
      "fingerprint",
      2,
      12_000,
    );

    expect(update).toHaveBeenCalledWith(
      expect.objectContaining({ processing_status: "parsed" }),
    );
  });

  it("rejects a same-count upload with truncated text", async () => {
    const { client, update } = clientWithTotals({
      chunk_count: 2,
      character_count: 11_500,
      minimum_ordinal: 0,
      maximum_ordinal: 1,
    });

    await expect(
      completeKnowledgeIngestion(
        client,
        "11111111-1111-4111-8111-111111111111",
        "fingerprint",
        2,
        12_000,
      ),
    ).rejects.toMatchObject({
      name: KnowledgeIngestionMismatchError.name,
      actualChunks: 2,
      actualCharacters: 11_500,
    });
    expect(update).not.toHaveBeenCalled();
  });
});
