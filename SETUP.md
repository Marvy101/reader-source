# Reader setup

Reader can run as a local reading app without accounts, Supabase, Vercel, or
AI credentials. The cloud stack is optional and enables accounts, private file
sync, reading-state sync, catalog services, and AI features.

## Requirements

- macOS 15 or later
- Xcode 16 or later
- Node.js 24 for the optional backend
- A Supabase project and a Vercel project for cloud features
- An AI Gateway API key only for AI requests made outside Vercel

Do not put secrets in Swift files, `project.yml`, Git, or any variable prefixed
for client exposure. `SUPABASE_SECRET_KEY` and `AI_GATEWAY_API_KEY` belong only
in the backend environment.

## Run the local app

Open `Reader.xcodeproj` and run the `Reader` scheme, or run:

```sh
make reader-test DERIVED_DATA_PATH=/tmp/reader-derived-data
```

Local import, reading, search, highlights, notes, and saved conversations work
without the backend. Account and AI actions will not work until the app points
at a configured backend.

## Create the Supabase project

1. Create a project in the Supabase dashboard and save its project reference
   and database password.
2. In the project's API Keys settings, copy the Project URL, publishable key,
   and secret key. A legacy `anon` key can substitute for the publishable key,
   and a legacy `service_role` key can substitute for the secret key. Never
   expose the secret or `service_role` value in the app.
3. Install Docker Desktop if you want to run the full Supabase stack locally.
   Docker is not required merely to push the checked-in migrations remotely.
4. Authenticate, link the new project, inspect the migration plan, and apply it:

```sh
npx supabase@latest login
npx supabase@latest link --workdir Backend --project-ref YOUR_PROJECT_REF
npx supabase@latest db push --workdir Backend --dry-run
npx supabase@latest db push --workdir Backend
```

The migrations create the database schema, row-level security policies,
functions, triggers, and the private `reader-files` and
`reader-catalog-files` Storage buckets. Do not create those pieces manually.

Email/password authentication is used by the app. Keep the Email provider
enabled under Authentication Providers. If email confirmation is enabled,
new users must confirm their email before they receive an app session. Add
redirect URLs only if you later add a link-based auth flow; the current app
uses email and password directly.

For a disposable local Supabase stack:

```sh
npx supabase@latest start --workdir Backend
npx supabase@latest db reset --workdir Backend
npx supabase@latest status --workdir Backend
```

`db reset` deletes and rebuilds the local database. Do not run it against a
remote project.

## Configure and deploy the backend on Vercel

Install dependencies and the Vercel CLI:

```sh
make setup
npm install --global vercel
vercel login
```

Create a Vercel project from this repository. Set its Root Directory to
`Backend`. The project may have any name; from the repository root, link it
with:

```sh
make backend-link VERCEL_PROJECT=YOUR_VERCEL_PROJECT_NAME
```

Add these variables in Vercel Project Settings under Environment Variables for
Development, Preview, and Production:

| Variable | Required | Value |
| --- | --- | --- |
| `SUPABASE_URL` | Yes | Supabase Project URL |
| `SUPABASE_PUBLISHABLE_KEY` | Yes | Supabase publishable key or legacy `anon` key |
| `SUPABASE_SECRET_KEY` | Yes | Supabase secret key or legacy `service_role` key; mark sensitive |
| `AI_GATEWAY_MODEL` | No | Defaults to `openai/gpt-5-mini` |
| `GOOGLE_BOOKS_API_KEY` | No | Enables Google Books fallback results |
| `AI_GATEWAY_API_KEY` | Local only | AI Gateway key for requests outside Vercel |

There is no general “Vercel API key” inside Reader. `vercel login` authorizes
the deployment CLI. AI calls use `AI_GATEWAY_API_KEY` during local development.
Create it in the Vercel AI Gateway API Keys page and place it in
`Backend/.env.local`, never in source control:

```sh
cp Backend/.env.example Backend/.env.local
```

Fill in `Backend/.env.local` for local development. Vercel deployments receive
`VERCEL_OIDC_TOKEN` automatically, so they do not need a stored
`AI_GATEWAY_API_KEY`. The backend's AI SDK uses that Vercel identity.

Run checks and start the backend locally:

```sh
make backend-check
make backend-dev
```

Deploy a preview, verify it, and only then promote or deploy production:

```sh
make backend-preview
curl https://YOUR_PREVIEW_URL/health/live
curl https://YOUR_PREVIEW_URL/health/ready
```

`/health/live` proves that the process is running. `/health/ready` also checks
that required Supabase configuration is present and reachable.

## Point Reader at your backend

The checked-in value is `http://127.0.0.1:3000`, which matches `vercel dev`.
For a persistent deployed fork, change `READER_BACKEND_URL` in `project.yml`,
then run `xcodegen generate`. For a one-off command-line build, override it
without editing the repository:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project Reader.xcodeproj \
  -scheme Reader \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/reader-derived-data \
  READER_BACKEND_URL=https://YOUR_BACKEND_URL \
  CODE_SIGNING_ALLOWED=NO \
  build
```

In Xcode, the same value is under the Reader target's Build Settings as the
user-defined setting `READER_BACKEND_URL`.

After changing the URL, create a test account in Reader, confirm its email if
required, import a public-domain test book, and verify both health routes. AI
answers additionally prove that AI Gateway authentication and model access are
working.

## Optional catalog data

The migrations create an empty catalog. Reader still imports local files
without seeding it. To add a bounded public-domain Project Gutenberg sample:

```sh
cd Backend
npm run catalog:seed:gutenberg -- --pages 10
npm run catalog:materialize -- --source project_gutenberg --max-files 25
```

Review storage use, rights metadata, and search behavior before increasing
either limit. See [Backend/README.md](Backend/README.md) for the full catalog
workflow and smoke-test commands.
