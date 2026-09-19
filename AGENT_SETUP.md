# Reader agent setup

This guide prepares Codex or Claude Code to work on Reader. No MCP server is
required to build, test, or modify the project. MCP connections are optional
helpers for inspecting infrastructure you own.

## 1. Install the toolchain

The native app requires:

- macOS 15 or later
- Xcode 16 or later, selected at
  `/Applications/Xcode.app/Contents/Developer`
- Git and Make, included with the Xcode command-line tools

The optional backend requires Node.js 24 and npm. Use a Node version manager
if another Node release is currently active.

These tools are useful for specific tasks:

- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only when `project.yml`
  changes
- [Vercel CLI](https://vercel.com/docs/cli), for local backend development and
  deployments
- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started),
  for local database work and migrations
- [GitHub CLI](https://cli.github.com/), for pull requests

Install the agent you want to use:

```sh
npm install --global @openai/codex
npm install --global @anthropic-ai/claude-code
```

Start `codex` or `claude` from the repository root. Codex reads `AGENTS.md`.
Claude Code reads `CLAUDE.md`, which imports the same shared instructions.
Instructions below `Backend/` add the backend-specific rules.

Keep personal agent preferences outside the repository. Codex supports a
global `~/.codex/AGENTS.md` and a local ignored `AGENTS.override.md`. Claude
Code supports `~/.claude/CLAUDE.md` and a local ignored `CLAUDE.local.md`.

## 2. Bootstrap and verify the repository

Install the backend dependencies:

```sh
make setup
```

Run the backend checks:

```sh
make backend-check
```

Run native tests with isolated build output:

```sh
make reader-test DERIVED_DATA_PATH=/tmp/reader-agent-derived-data
```

Run both suites with:

```sh
make check DERIVED_DATA_PATH=/tmp/reader-agent-derived-data
```

The local reader works without a backend or cloud credentials. Follow
`SETUP.md` to create your own Supabase project, configure Vercel and AI
Gateway, and point the app at your backend. Never assume that the maintainer's
deployed backend is available to a fork.

## 3. Optional MCP connections

MCP access is not part of the build. Add only the services needed for a task,
scope them to infrastructure you control, and keep approval prompts enabled.
Use migration files and the documented CLIs for lasting or destructive
changes so the work remains reviewable.

### Supabase

Replace `YOUR_PROJECT_REF` with the reference for your own Supabase project.
The suggested connection is project-scoped and read-only.

For Codex:

```sh
codex mcp add supabase --url "https://mcp.supabase.com/mcp?project_ref=YOUR_PROJECT_REF&read_only=true&features=database,docs,debugging,development"
codex mcp login supabase
```

For Claude Code:

```sh
claude mcp add --scope project --transport http supabase "https://mcp.supabase.com/mcp?project_ref=YOUR_PROJECT_REF&read_only=true&features=database,docs,debugging,development"
```

Run `/mcp` inside Claude Code to authenticate. Do not commit a real project
reference, access token, database password, or generated `.mcp.json`.

For CLI-based local database work, run Supabase through npm so contributors do
not need a global install:

```sh
npx supabase@latest --help
```

### Vercel

For Codex:

```sh
codex mcp add vercel --url https://mcp.vercel.com
codex mcp login vercel
```

For Claude Code:

```sh
claude mcp add --scope project --transport http vercel https://mcp.vercel.com
```

Run `/mcp` inside Claude Code to authenticate. Use `vercel login` and the
repository Make targets for the canonical backend workflow:

```sh
make backend-link
make backend-dev
make backend-preview
```

Production deployment requires the project owner's authorization.

## 4. Agent task checklist

1. Read `AGENTS.md` and the nearest directory instructions.
2. Identify whether the change affects the native app, backend, or their shared
   API contract. Contract changes must update and validate both sides.
3. Keep local reading functional when the backend is unavailable.
4. Use synthetic, public-domain, or otherwise redistributable test inputs.
5. Run the checks relevant to the files changed and report the result.
6. Keep credentials, downloaded books, private screenshots, personal paths,
   and local agent configuration out of commits.
