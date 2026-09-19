# Reader repository instructions

## Monorepo layout

- The native app and shared Apple-platform code remain at the repository root.
- The optional Hono, Supabase, and Vercel backend lives in `Backend/` and has additional instructions in `Backend/AGENTS.md`.
- Make all new native, backend, schema, and shared-contract changes in this repository.
- When an API contract changes, update and validate both `Reader/Networking` and `Backend/` in the same task and pull request.
- From the repository root, use `make setup`, `make backend-check`, `make reader-test`, and `make check` for the common workflows.
- Deploy the backend from this repository root with the Vercel CLI and keep
  the Vercel project's Root Directory set to `Backend`. Follow `SETUP.md` for
  fork-specific Supabase, Vercel, and AI Gateway configuration.

## Agent workflow

- Read `README.md`, `SETUP.md`, and the instructions nearest the code being
  changed. Work under `Backend/` also follows `Backend/AGENTS.md`.
- Preserve unrelated edits. Use a feature branch or worktree when the local
  repository policy calls for one.
- Run the relevant checks before handing work back. Do not merge or deploy
  without the repository maintainer's authorization.
- Never commit credentials, local service links, personal instructions, or
  agent-specific state. Put private preferences in the agent's global or local
  configuration instead.

## Apple platform direction

This is a macOS-first product, not a macOS-only product.

- Every domain model, persistence decision, renderer boundary, file-access flow, and major UI structure must be evaluated for a future native iOS and iPadOS target.
- macOS, iOS, and iPadOS must remain in this repository and, unless evidence forces a change, in this Xcode project.
- Keep reusable Swift and SwiftUI code platform-neutral. Isolate AppKit- or UIKit-specific code behind narrow adapters or target-specific folders.
- Do not quietly make Mac Catalyst, pure AppKit, or separate renderers the permanent cross-platform strategy. Record the tradeoff and test it before committing.
- A macOS-only implementation is acceptable for the current milestone when the shared contract remains portable and the platform-specific choice is explicit.
- Prefer capabilities over fake universal abstractions. EPUB, PDF, comics, plain text, and audio do not need to share rendering internals.

## High-risk architecture

Do not add or replace a rendering engine, persistence framework, locator schema, DRM system, import ownership model, or sync architecture without:

1. testing it against the repository corpus;
2. documenting macOS and iOS implications;
3. recording licensing and exit costs; and
4. documenting the decision and tradeoffs in the pull request.

## Test corpus

- Keep reproducible corpus definitions and download tooling in Git.
- Keep downloaded public-domain binaries under `TestCorpus/Downloads/`; this directory is intentionally ignored by Git.
- Do not add copyrighted commercial books to the repository or its download manifest.
- Preserve source URLs, public-domain status, expected format capabilities, byte size, and SHA-256 checksums.
