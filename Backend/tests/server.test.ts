import { afterEach, describe, expect, it, vi } from "vitest";

import { app } from "../src/index.js";

const originalEnvironment = { ...process.env };

afterEach(() => {
  process.env = { ...originalEnvironment };
  vi.unstubAllGlobals();
});

describe("reader backend", () => {
  it("serves a liveness response with a request ID", async () => {
    const response = await app.request("/health/live", {
      headers: { "x-request-id": "test-request" },
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toBe("test-request");
    await expect(response.json()).resolves.toEqual({ status: "ok" });
  });

  it("reports missing configuration without exposing secrets", async () => {
    delete process.env.SUPABASE_URL;
    delete process.env.SUPABASE_PUBLISHABLE_KEY;
    delete process.env.SUPABASE_SECRET_KEY;

    const response = await app.request("/health/ready");

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({
      status: "not_ready",
      missing: [
        "SUPABASE_URL",
        "SUPABASE_PUBLISHABLE_KEY",
        "SUPABASE_SECRET_KEY",
      ],
    });
  });

  it("becomes ready when Supabase is configured", async () => {
    process.env.SUPABASE_URL = "https://example.supabase.co";
    process.env.SUPABASE_PUBLISHABLE_KEY = "publishable-key";
    process.env.SUPABASE_SECRET_KEY = "secret-key";
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));

    const response = await app.request("/health/ready");

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ok" });
  });

  it("reports a configured but unreachable Supabase dependency", async () => {
    process.env.SUPABASE_URL = "https://example.supabase.co";
    process.env.SUPABASE_PUBLISHABLE_KEY = "publishable-key";
    process.env.SUPABASE_SECRET_KEY = "secret-key";
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("DNS failed")));

    const response = await app.request("/health/ready");

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({
      status: "not_ready",
      unavailable: ["supabase"],
    });
  });

  it("returns structured not-found errors", async () => {
    const response = await app.request("/missing", {
      headers: { "x-request-id": "missing-request" },
    });

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({
      error: {
        code: "not_found",
        message: "Route not found",
        requestId: "missing-request",
      },
    });
  });

  it("protects versioned API routes", async () => {
    const response = await app.request("/v1/folders", {
      headers: { "x-request-id": "unauthorized-request" },
    });

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({
      error: {
        code: "unauthorized",
        message: "A Supabase access token is required",
        requestId: "unauthorized-request",
      },
    });
  });

  it("lets auth routes reach service configuration without a bearer token", async () => {
    delete process.env.SUPABASE_URL;
    delete process.env.SUPABASE_PUBLISHABLE_KEY;
    delete process.env.SUPABASE_SECRET_KEY;

    const response = await app.request("/v1/auth/sign-in", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        email: "reader@example.com",
        password: "long-enough",
      }),
    });

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({
      error: {
        code: "service_not_ready",
        message: "Authentication is not configured",
        requestId: expect.any(String),
      },
    });
  });
});
