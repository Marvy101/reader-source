import { describe, expect, it } from "vitest";

import { missingRequiredConfig, readConfig } from "../src/config.js";

describe("runtime configuration", () => {
  it("reports missing Supabase configuration", () => {
    const config = readConfig({});

    expect(missingRequiredConfig(config)).toEqual([
      "SUPABASE_URL",
      "SUPABASE_PUBLISHABLE_KEY",
      "SUPABASE_SECRET_KEY",
    ]);
  });

  it("accepts configured Supabase values", () => {
    const config = readConfig({
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_PUBLISHABLE_KEY: "publishable-key",
      SUPABASE_SECRET_KEY: "secret-key",
    });

    expect(missingRequiredConfig(config)).toEqual([]);
  });

  it("reads Google Books as an optional catalog fallback", () => {
    const config = readConfig({ GOOGLE_BOOKS_API_KEY: "google-key" });

    expect(config.googleBooksApiKey).toBe("google-key");
    expect(missingRequiredConfig(config)).toEqual([
      "SUPABASE_URL",
      "SUPABASE_PUBLISHABLE_KEY",
      "SUPABASE_SECRET_KEY",
    ]);
  });
});
