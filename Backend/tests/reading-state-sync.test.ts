import { describe, expect, it } from "vitest";

import { filterOwnedReadingStates } from "../src/reading-state-sync.js";

describe("reading-state ownership filtering", () => {
  it("matches Swift uppercase UUIDs to lowercase Postgres UUIDs", () => {
    const state = {
      fileId: "A5D31415-5DA1-42C1-B49E-86F529DC02A6",
      progress: 0.4,
    };

    expect(
      filterOwnedReadingStates(
        [state],
        ["a5d31415-5da1-42c1-b49e-86f529dc02a6"],
      ),
    ).toEqual([state]);
  });

  it("still drops states for files the user does not own", () => {
    expect(
      filterOwnedReadingStates(
        [
          {
            fileId: "A5D31415-5DA1-42C1-B49E-86F529DC02A6",
          },
        ],
        ["0a921350-f2c4-42b4-b02e-9ef68013ed53"],
      ),
    ).toEqual([]);
  });
});
