# Reader Backend

Optional backend services for Reader. This package lives in `Backend/` of the Reader monorepo; local opening, reading, search, highlights, annotations, and persisted conversations continue to work without it.

## Work from the monorepo root

```sh
make setup
make backend-check
make backend-dev
```

The equivalent package-local commands are:

```sh
npm ci
npm run check
npm run dev
```

## Stack

- Supabase Auth
- Supabase Postgres
- Supabase Storage
- Hono on Vercel backend compute
- Vercel AI SDK and AI Gateway

## Deployment

Create or select a Vercel project with its Root Directory set to `Backend`.
Link each worktree once and deploy previews from the monorepo root:

```sh
make backend-link VERCEL_PROJECT=YOUR_VERCEL_PROJECT_NAME
make backend-preview
```

Use `vercel deploy --prod` from the monorepo root only when a production
deployment is intentional. The complete Supabase, environment-variable, AI
Gateway, Vercel, and native-app setup is in [`../SETUP.md`](../SETUP.md).

## Highlight questions

The native app authenticates with email/password through:

- `POST /v1/auth/sign-up`
- `POST /v1/auth/sign-in`
- `POST /v1/auth/refresh`

`POST /v1/ai/highlight-question` requires the returned Supabase access token. It accepts one selected passage, bounded nearby context, up to eight recent messages about that passage, and the reader's current question.

The complete feature prompt is intentionally reviewable in `src/features/highlight-question/prompt.ts`. The feature service in `src/features/highlight-question/service.ts` inherits the shared model, Gateway, output, and usage behavior from `src/ai.ts`.

The default model is `openai/gpt-5-mini` through Vercel AI Gateway with minimal reasoning. Passage answers use a 1,600-token budget. A length-limited result is retried once at 3,200 tokens; a second incomplete result is rejected instead of being returned to the app. Recent turns are sent as native user/assistant messages, and production logs record only model and token metadata, never publication text or questions.

## Book knowledge

Opening a managed book prepares its normalized publication text in the background and stores bounded, locator-preserving chunks in Postgres. Reading never waits for this optional network work. The fast path is:

1. `POST /v1/publications/:publicationId/ingestions` starts or deduplicates an ingestion and refreshes annotations.
2. `PUT /v1/publications/:publicationId/chunks` accepts bounded batches. Native clients send up to four batches concurrently.
3. `POST /v1/publications/:publicationId/complete` marks the publication parsed only after the exact chunk count, total character count, and contiguous ordinal range exist.
4. `GET /v1/publications/:publicationId/knowledge` reports text access and processing status.

`POST /v1/ai/chat/stream` can then execute `search_book` and `search_annotations`. `upToHere` scope is enforced in the SQL search functions, not only in the prompt. Explicit `wholeBook` scope inserts normalized text up to a 600,000-character budget and falls back to tools above it.

This milestone indexes selectable text and adds no Reducto dependency. OCR, figures, tables, and image-grounded PDF answers remain a future layout-aware parser adapter.

Run `npm run benchmark:book` with `BACKEND_URL`, `BOOK_TEXT_PATH`, `BENCHMARK_EMAIL`, and `BENCHMARK_PASSWORD` to measure authenticated Vercel ingestion and warm deduplication against a disposable publication. The production Supabase data-plane benchmark on 2026-08-19 inserted and indexed 499,600 characters across 82 chunks in 78.93 ms; 25 full-text searches measured 3.432 ms at p50 and 3.754 ms at p95. The disposable publication was deleted immediately afterward.

## Catalog discovery

Authenticated catalog routes are:

- `GET /v1/catalog/search?q=pride&locale=en-US&limit=20`
- `POST /v1/catalog/interests`
- `PUT /v1/files/:fileId/catalog-match`

Canonical and provider tables live in private schemas. The backend uses service-only database functions for search and ingestion; clients receive only the bounded API contract.

`GOOGLE_BOOKS_API_KEY` optionally enables live Google Books results when a fallback-capable client requests them and the canonical catalog returns fewer than five matches. Google results remain external and cannot be used as canonical work IDs. Search responses are not persisted: identical in-flight requests are coalesced, and a completed response is cached only when Google explicitly returns a positive public cache lifetime. When a user chooses **notify me**, Reader stores the Google volume ID plus a bounded title, author, and identifier snapshot as user demand; it does not store the full API response or create a canonical work.

After applying the catalog migrations, seed a bounded Project Gutenberg slice with production Supabase service credentials:

```sh
npm run catalog:seed:gutenberg -- --pages 10
```

The script is retry-safe per Gutendex page and never stores credentials. Start with a bounded run and inspect catalog counts, cover URLs, EPUB offers, and search latency before increasing `--pages` or using a dump-scale loader.

After the bounded verification, resume or complete the full Gutenberg catalog with:

```bash
npm run catalog:seed:gutenberg -- --all
```

The full run retries transient HTTP/database failures and records its last completed page under `Backend/.catalog-state/`, which is ignored by Git. Re-running the command resumes at the next page. Pass `--start-page N` only when intentionally overriding the checkpoint, or `--batch-pages N` to tune how many Gutendex pages are fetched and ingested together (default: 5).

After the catalog file-materialization migration is applied, download a bounded set of verified Gutenberg EPUBs into the private catalog bucket:

```bash
npm run catalog:materialize -- --source project_gutenberg --max-files 25
```

The materializer accepts only allowlisted HTTPS source hosts, follows and revalidates redirects, streams no more than 50 MiB, validates the EPUB-required uncompressed `mimetype` entry, hashes the exact bytes with SHA-256, uploads to a content-addressed path, and registers the immutable file idempotently. Gutenberg files are recorded as U.S. public domain and are served from private storage only when the request territory is `US`. Use `--all` only after the bounded run has verified storage, rights, search, signed download, and cost behavior.

Potential additional full-text providers include Gallica public-domain OPDS and unrestricted OCR, Standard Ebooks after feed approval, export-ready Wikisource, and audited Internet Archive collections with affirmative item rights. Google public-domain EPUB/PDF links remain on-demand external offers and are not mirrored.
