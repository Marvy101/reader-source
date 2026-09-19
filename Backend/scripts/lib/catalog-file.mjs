import { createHash } from "node:crypto";

export const maximumCatalogFileBytes = 50 * 1024 * 1024;

const sourcePolicies = new Map([
  [
    "project_gutenberg",
    {
      hosts: ["gutenberg.org"],
      rightsStatus: "public_domain",
      licenseCode: "US-PD",
      territories: ["US"],
    },
  ],
]);

export function sourcePolicy(sourceCode) {
  const policy = sourcePolicies.get(sourceCode);
  if (!policy) {
    throw new Error(`Catalog file materialization is not enabled for ${sourceCode}`);
  }
  return policy;
}

export function assertPermittedDownloadUrl(value, policy) {
  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new Error("Catalog file downloads must use HTTPS");
  }
  const permitted = policy.hosts.some(
    (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
  );
  if (!permitted) {
    throw new Error(`Catalog file download host is not permitted: ${url.hostname}`);
  }
  return url;
}

export async function readBoundedBody(response, maximumBytes = maximumCatalogFileBytes) {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new Error(`Catalog file exceeds ${maximumBytes} bytes`);
  }
  if (!response.body) throw new Error("Catalog file response did not contain a body");

  const chunks = [];
  let total = 0;
  const reader = response.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel("catalog file size limit exceeded");
      throw new Error(`Catalog file exceeds ${maximumBytes} bytes`);
    }
    chunks.push(value);
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export function validateEpub(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 58) {
    throw new Error("EPUB is too small to contain the required mimetype entry");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== 0x04034b50) {
    throw new Error("EPUB is not a ZIP archive");
  }
  if (view.getUint16(8, true) !== 0) {
    throw new Error("EPUB mimetype entry must be stored without compression");
  }
  const fileNameLength = view.getUint16(26, true);
  const extraLength = view.getUint16(28, true);
  const fileNameStart = 30;
  const fileNameEnd = fileNameStart + fileNameLength;
  const contentStart = fileNameEnd + extraLength;
  if (contentStart + 20 > bytes.byteLength) {
    throw new Error("EPUB mimetype entry is truncated");
  }
  const decoder = new TextDecoder();
  const fileName = decoder.decode(bytes.subarray(fileNameStart, fileNameEnd));
  const mimetype = decoder.decode(bytes.subarray(contentStart, contentStart + 20));
  if (fileName !== "mimetype" || mimetype !== "application/epub+zip") {
    throw new Error("EPUB does not begin with the required mimetype entry");
  }
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function safePathSegment(value) {
  const segment = value
    .normalize("NFKD")
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 160);
  if (!segment) throw new Error("Catalog source identifier cannot form a path");
  return segment;
}

export function storagePath(sourceCode, externalId, sha256, extension) {
  return `${sourceCode}/${safePathSegment(externalId)}/${sha256}.${extension}`;
}
