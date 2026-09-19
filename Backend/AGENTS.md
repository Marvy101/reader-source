# Reader backend instructions

These instructions extend the repository-root `AGENTS.md`.

- Reading must never depend on the backend. Opening, importing, reading, searching, highlighting, and annotating local files must continue to work when the backend is unavailable.
- Run backend commands from the monorepo root with `make backend-check` and `make backend-dev`, or from this directory with the corresponding npm scripts.
- Keep database changes as additive migrations in `Backend/supabase/migrations/` and validate retry and idempotency behavior for ingestion and file operations.
- Never commit `.env` files, pulled secrets, or `.vercel/` project metadata.
- Deploy through the linked Vercel project using the repository-root CLI
  commands. Its Root Directory is `Backend`; health routes remain
  `/health/live` and `/health/ready`.
- If a backend route or payload changes, update the native client and its tests in the same monorepo pull request.
