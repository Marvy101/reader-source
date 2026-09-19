import { describe, expect, it } from "vitest";

type CatalogFileModule = {
  assertPermittedDownloadUrl: (
    value: string,
    policy: { hosts: string[] },
  ) => URL;
  readBoundedBody: (response: Response, maximumBytes?: number) => Promise<Uint8Array>;
  sha256Hex: (bytes: Uint8Array) => string;
  sourcePolicy: (sourceCode: string) => {
    hosts: string[];
    rightsStatus: string;
    licenseCode: string;
    territories: string[];
  };
  storagePath: (
    sourceCode: string,
    externalId: string,
    sha256: string,
    extension: string,
  ) => string;
  validateEpub: (bytes: Uint8Array) => void;
};

const moduleUrl = new URL("../scripts/lib/catalog-file.mjs", import.meta.url);
const catalogFile = (await import(moduleUrl.href)) as CatalogFileModule;

function minimalEpub(): Uint8Array {
  const fileName = new TextEncoder().encode("mimetype");
  const content = new TextEncoder().encode("application/epub+zip");
  const bytes = new Uint8Array(30 + fileName.length + content.length);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x04034b50, true);
  view.setUint16(8, 0, true);
  view.setUint32(18, content.length, true);
  view.setUint32(22, content.length, true);
  view.setUint16(26, fileName.length, true);
  view.setUint16(28, 0, true);
  bytes.set(fileName, 30);
  bytes.set(content, 30 + fileName.length);
  return bytes;
}

describe("catalog file materialization", () => {
  it("accepts only HTTPS downloads from the source allowlist", () => {
    const policy = catalogFile.sourcePolicy("project_gutenberg");

    expect(
      catalogFile.assertPermittedDownloadUrl(
        "https://www.gutenberg.org/cache/epub/1342/pg1342.epub",
        policy,
      ).hostname,
    ).toBe("www.gutenberg.org");
    expect(() =>
      catalogFile.assertPermittedDownloadUrl(
        "https://archive.org/download/untrusted/book.epub",
        policy,
      ),
    ).toThrow("not permitted");
    expect(() =>
      catalogFile.assertPermittedDownloadUrl(
        "http://www.gutenberg.org/book.epub",
        policy,
      ),
    ).toThrow("HTTPS");
  });

  it("validates the EPUB mimetype entry before hashing and storage", () => {
    const epub = minimalEpub();

    expect(() => catalogFile.validateEpub(epub)).not.toThrow();
    expect(catalogFile.sha256Hex(epub)).toMatch(/^[a-f0-9]{64}$/);
    expect(() => catalogFile.validateEpub(new Uint8Array(58))).toThrow(
      "not a ZIP",
    );
  });

  it("stops reading a response when it crosses the byte limit", async () => {
    await expect(
      catalogFile.readBoundedBody(new Response(new Uint8Array(5)), 4),
    ).rejects.toThrow("exceeds 4 bytes");
  });

  it("uses deterministic content-addressed storage paths", () => {
    expect(
      catalogFile.storagePath(
        "project_gutenberg",
        "gutenberg:1342",
        "a".repeat(64),
        "epub",
      ),
    ).toBe(`project_gutenberg/gutenberg-1342/${"a".repeat(64)}.epub`);
  });
});
