# Reader

[![Monorepo CI](https://github.com/Marvy101/reader-source/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Marvy101/reader-source/actions/workflows/ci.yml)

**An open-source, native AI reading workspace for macOS.**

**[Download Reader for macOS →](https://reader.marvy101.com)**

Reader keeps the book, your notes, web research, and an AI conversation in one
quiet workspace. Import PDF, EPUB, and TXT files; read in a native interface;
highlight and annotate passages; simplify difficult writing; ask questions
about a selection, the current page, everything up to your position, or the
whole book; and open chat, a dictionary, or the web beside the text.

The library and reading experience are local-first. Books, progress,
highlights, notes, search, and saved conversations remain usable without an
account or backend. Supabase sync and AI features are optional additions.

<p align="center">
  <img src="media/reader-demo.gif" alt="Reader library, reading, highlighting, notes, contextual AI, and research workspace demo" width="960">
</p>

## Features

- **Native reading:** import and read PDF, EPUB, and plain-text books in a
  focused macOS interface built with SwiftUI, PDFKit, and WebKit.
- **Contextual AI:** chat about a selected passage, the current page, the book
  up to your reading position, or the complete book.
- **Inline understanding:** rewrite a difficult passage in clearer language
  without leaving the page.
- **Highlights and notes:** preserve selections, annotations, and reading
  context alongside the book.
- **One reading workspace:** place the book beside AI chat, a system
  dictionary, another book, or a native browser.
- **Local library:** organize books into folders, search across the library,
  resume progress, and keep local data in SQLite.
- **Optional private cloud:** sync originals, reading state, annotations, and
  searchable book context through your own Supabase and Vercel backend.
- **Local-first failure model:** opening, reading, searching, highlighting, and
  annotating do not depend on cloud availability.

This monorepo contains the native Reader app and its optional Hono, Supabase,
and Vercel backend.

## Run

Requires macOS 15 or later and Xcode 16 or later. Open `Reader.xcodeproj`
in Xcode and run the `Reader` scheme. Node.js and backend credentials are not
required to build the native app. Cloud and AI features need a backend. The
checked-in backend URL is the local Vercel development address at
`http://127.0.0.1:3000`; it never sends a fork to maintainer infrastructure.
Follow [SETUP.md](SETUP.md) to create your own Supabase and Vercel projects and
point the app at them.

From Terminal:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project Reader.xcodeproj \
  -scheme Reader \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build test
```

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

The generated `.xcodeproj` is committed so XcodeGen is helpful, not required, for someone opening the app.

Install and check the backend from the same repository root:

```sh
make setup
make backend-check
```

Run the backend locally through Vercel:

```sh
make backend-link
make backend-dev
```

Deploy a preview from the same root:

```sh
make backend-preview
```

Run both native and backend checks:

```sh
make check
```

The backend package has more detail in [`Backend/README.md`](Backend/README.md).
The complete app-only and cloud setup is in [SETUP.md](SETUP.md).

I know you're just having your agent run this, so here's a guide made specifically for it lol: [AGENT_SETUP.md](AGENT_SETUP.md).

## Repository layout

```text
Reader/          Native Swift and SwiftUI source
ReaderTests/     Native tests
Backend/         Hono, Supabase, and Vercel backend
TestCorpus/      Reproducible public-domain format corpus
```

## How it works

The app owns a shared Reader Core for search, locators, selections, annotations, progress intent, and capabilities. Format adapters translate those concepts into the rendering primitive that fits:

```text
SwiftUI reading experience
└── Reader Core
    ├── PDF adapter → PDFKit
    └── Reflowable adapter → owned EPUB/TXT parser + hardened WKWebView
```

Reader uses [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for archive extraction and [GRDB](https://github.com/groue/GRDB.swift) for SQLite persistence. Rendering remains owned by Reader through PDFKit and its EPUB/TXT WebKit adapter.

## Mac first, never Mac only

Reader is built natively in Swift, making it easy to bring to iOS and iPadOS; that goal guides technical decisions so one shared codebase can support macOS, iOS, and iPadOS.

## What is implemented

- Native macOS app with SwiftUI
- Local PDF, EPUB, and TXT import into an app-managed copy
- PDFKit fixed-page rendering
- Custom EPUB/TXT extraction and WebKit reading surface
- Shared native search and annotation model above both adapters
- Embedded EPUB covers and first-page PDF covers
- Supabase account entry plus optional, private cloud copies of imported originals
- Import-time background preparation for whole-book AI search and annotations
- Authenticated launch and foreground reconciliation for existing or interrupted local books
- Truthful cloud status derived from confirmed file and searchable-text preparation
- Local SQLite persistence for library entries, progress, highlights, and conversations
- EPUB is vertically reflowed by section; pagination and full standards coverage are still open
- Local reading remains available when cloud sync or AI preparation fails

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and contribution terms.

## License

Reader is open source under the [MIT License](LICENSE). You may use,
copy, modify, publish, distribute, sublicense, and sell copies of the software
subject to the license terms.
