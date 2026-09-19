import type { CatalogSearchResult } from "./service.js";

type GoogleVolume = {
  id?: unknown;
  volumeInfo?: {
    title?: unknown;
    subtitle?: unknown;
    authors?: unknown;
    publisher?: unknown;
    publishedDate?: unknown;
    description?: unknown;
    pageCount?: unknown;
    industryIdentifiers?: unknown;
    imageLinks?: unknown;
  };
  accessInfo?: {
    publicDomain?: unknown;
    epub?: GoogleDownloadFormat;
    pdf?: GoogleDownloadFormat;
  };
};

type GoogleDownloadFormat = {
  isAvailable?: unknown;
  downloadLink?: unknown;
};

type GoogleBooksResponse = {
  items?: unknown;
};

type GoogleIndustryIdentifier = {
  type?: unknown;
  identifier?: unknown;
};

const cache = new Map<string, { expiresAt: number; results: CatalogSearchResult[] }>();
const inFlight = new Map<string, Promise<CatalogSearchResult[]>>();
const maximumCacheEntries = 200;

function stringValue(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized ? normalized : null;
}

function positiveInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : null;
}

function strings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(stringValue).filter((item): item is string => item !== null);
}

function releaseYear(value: unknown): number | null {
  const date = stringValue(value);
  const match = date?.match(/^(\d{4})/);
  return match ? Number(match[1]) : null;
}

function coverUrl(value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  const links = value as Record<string, unknown>;
  const candidate =
    stringValue(links.extraLarge) ??
    stringValue(links.large) ??
    stringValue(links.medium) ??
    stringValue(links.thumbnail) ??
    stringValue(links.smallThumbnail);
  return candidate?.replace(/^http:/, "https:") ?? null;
}

function primaryIdentifier(value: unknown, googleVolumeId: string): string {
  const identifiers = Array.isArray(value)
    ? (value as GoogleIndustryIdentifier[])
    : [];
  for (const preferredType of ["ISBN_13", "ISBN_10"]) {
    const match = identifiers.find(
      (identifier) => stringValue(identifier.type) === preferredType,
    );
    const identifier = stringValue(match?.identifier);
    if (identifier) return `isbn:${identifier.replace(/[^0-9X]/gi, "")}`;
  }
  return `google_books:${googleVolumeId}`;
}

function publicDomainDownload(
  accessInfo: GoogleVolume["accessInfo"],
): { url: string; mediaType: string } | null {
  if (accessInfo?.publicDomain !== true) return null;
  for (const [format, mediaType] of [
    [accessInfo.epub, "application/epub+zip"],
    [accessInfo.pdf, "application/pdf"],
  ] as const) {
    const url = format?.isAvailable === true
      ? stringValue(format.downloadLink)
      : null;
    if (url) return { url: url.replace(/^http:/, "https:"), mediaType };
  }
  return null;
}

function mapVolume(volume: GoogleVolume): CatalogSearchResult | null {
  const externalId = stringValue(volume.id);
  const title = stringValue(volume.volumeInfo?.title);
  if (!externalId || !title) return null;
  const download = publicDomainDownload(volume.accessInfo);

  return {
    source: "google_books",
    externalId,
    workGroupId: null,
    workId: null,
    editionId: null,
    title,
    subtitle: stringValue(volume.volumeInfo?.subtitle),
    authors: strings(volume.volumeInfo?.authors).join(", "),
    translators: "",
    publisher: stringValue(volume.volumeInfo?.publisher),
    releaseYear: releaseYear(volume.volumeInfo?.publishedDate),
    pageCount: positiveInteger(volume.volumeInfo?.pageCount),
    description: stringValue(volume.volumeInfo?.description),
    coverUrl: coverUrl(volume.volumeInfo?.imageLinks),
    primaryIdentifier: primaryIdentifier(
      volume.volumeInfo?.industryIdentifiers,
      externalId,
    ),
    availability: download ? "read_now" : "notify_me",
    libraryPublicationId: null,
    downloadUrl: download?.url ?? null,
    downloadMediaType: download?.mediaType ?? null,
  };
}

function cached(key: string): CatalogSearchResult[] | null {
  const entry = cache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    cache.delete(key);
    return null;
  }
  return entry.results;
}

function permittedCacheLifetimeMilliseconds(response: Response): number {
  const directive = response.headers.get("cache-control")?.toLocaleLowerCase();
  if (!directive || directive.includes("no-store") || directive.includes("private")) {
    return 0;
  }
  const maximumAge = directive.match(/(?:^|,)\s*max-age=(\d+)/)?.[1];
  if (!maximumAge) return 0;
  return Math.min(Number(maximumAge) * 1_000, 24 * 60 * 60 * 1_000);
}

function remember(
  key: string,
  results: CatalogSearchResult[],
  lifetimeMilliseconds: number,
): void {
  if (lifetimeMilliseconds <= 0) return;
  if (cache.size >= maximumCacheEntries) {
    const oldestKey = cache.keys().next().value;
    if (oldestKey) cache.delete(oldestKey);
  }
  cache.set(key, {
    expiresAt: Date.now() + lifetimeMilliseconds,
    results,
  });
}

export async function searchGoogleBooks(
  query: string,
  apiKey: string,
  limit: number,
  fetcher: typeof fetch = fetch,
): Promise<CatalogSearchResult[]> {
  const boundedLimit = Math.max(1, Math.min(limit, 20));
  const cacheKey = `${query.toLocaleLowerCase()}:${boundedLimit}`;
  const existing = cached(cacheKey);
  if (existing) return existing;
  const pending = inFlight.get(cacheKey);
  if (pending) return pending;

  const request = performSearch(
    query,
    apiKey,
    boundedLimit,
    cacheKey,
    fetcher,
  );
  inFlight.set(cacheKey, request);
  try {
    return await request;
  } finally {
    inFlight.delete(cacheKey);
  }
}

async function performSearch(
  query: string,
  apiKey: string,
  boundedLimit: number,
  cacheKey: string,
  fetcher: typeof fetch,
): Promise<CatalogSearchResult[]> {
  const url = new URL("https://www.googleapis.com/books/v1/volumes");
  url.searchParams.set("q", query);
  url.searchParams.set("maxResults", String(boundedLimit));
  url.searchParams.set("printType", "books");
  url.searchParams.set("projection", "full");
  url.searchParams.set("key", apiKey);

  const response = await fetcher(url, {
    headers: { "user-agent": "Reader catalog fallback/1.0" },
    signal: AbortSignal.timeout(4_000),
  });
  if (!response.ok) {
    throw new Error(`Google Books returned HTTP ${response.status}`);
  }

  const payload = (await response.json()) as GoogleBooksResponse;
  const volumes = Array.isArray(payload.items)
    ? (payload.items as GoogleVolume[])
    : [];
  const results = volumes
    .map(mapVolume)
    .filter((result): result is CatalogSearchResult => result !== null);
  remember(
    cacheKey,
    results,
    permittedCacheLifetimeMilliseconds(response),
  );
  return results;
}

function normalizedIdentity(result: CatalogSearchResult): string {
  if (result.primaryIdentifier?.startsWith("isbn:")) {
    return result.primaryIdentifier.toLocaleLowerCase();
  }
  return `${result.title}:${result.authors}`
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLocaleLowerCase();
}

export function mergeCatalogResults(
  primary: CatalogSearchResult[],
  fallback: CatalogSearchResult[],
  limit: number,
): CatalogSearchResult[] {
  const seen = new Set(primary.map(normalizedIdentity));
  const merged = [...primary];
  for (const result of fallback) {
    const identity = normalizedIdentity(result);
    if (seen.has(identity)) continue;
    seen.add(identity);
    merged.push(result);
    if (merged.length >= limit) break;
  }
  return merged.slice(0, limit);
}
