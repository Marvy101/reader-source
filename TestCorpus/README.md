# Public-domain reader test corpus

This corpus makes renderer work measurable against memorable books instead of toy lorem ipsum files.

The manifest is committed. Downloaded binaries are not. Run:

```sh
./scripts/download_test_corpus.sh
```

The downloader verifies exact byte counts and SHA-256 hashes. Upstream Project Gutenberg files can be revised; checksum failure is a signal to review the new edition and intentionally update the manifest.

Sandboxed macOS tests cannot reliably read files directly from `Documents`
without a user-selected security scope. Before running corpus tests from Xcode,
stage the verified binaries inside Reader's container:

```sh
./scripts/stage_test_corpus.sh
```

The test target prefers that staged copy when present and otherwise uses
`TestCorpus/Downloads/`, which keeps CI and non-sandboxed test runs portable.

## Coverage

| Fixture | Format/profile | Size | Cover path | Primary stress |
| --- | --- | ---: | --- | --- |
| Alice | UTF-8 TXT | 174 KB | None | fallback cover, plain text |
| Alice | EPUB3 | 189 KB | Embedded | small reflowable control |
| Alice | MOBI8/KF8 | 256 KB | Embedded | legacy Kindle parsing |
| Moby-Dick | EPUB3 | 813 KB | Embedded | long text in a compact package |
| War and Peace | EPUB3 | 1.8 MB | Embedded | 369 content documents |
| Pride and Prejudice | Illustrated EPUB3 | 24.8 MB | Embedded | 164 images, memory and lazy loading |
| Project Gutenberg history | Born-digital PDF | 96 KB | Page one | tiny selectable PDF |
| Alice WPA poster | Image-only PDF | 249 KB | Page one | zero extractable text |
| Alice | OCR scan PDF | 25.4 MB | Page one | scan rendering and OCR selection |
| Frankenstein | OCR scan PDF | 57.6 MB | Page one | large-file memory and cancellation |

Exact bytes, hashes, rights pages, source URLs, page counts, text counts, and structural expectations live in [`manifest.json`](manifest.json).

## Two corpus layers

These real books are the human-recognition and performance layer. They are not sufficient for standards correctness.

A renderer candidate must also be tested against:

- the [W3C EPUB 3 tests](https://w3c.github.io/epub-tests/);
- [Readium test publications](https://github.com/readium/readium-test-files);
- malformed and hostile packages;
- RTL, vertical writing, fixed-layout, MathML, SVG, media overlays, and accessibility cases; and
- password-protected, encrypted, truncated, and decompression-bomb fixtures created specifically for security testing.

Those fixtures should remain a separate conformance/security suite rather than making this memorable-book corpus unreadable.

## Cover-art expectations

Cover acquisition should be deterministic:

1. use a declared embedded cover;
2. otherwise use a suitable first page for fixed documents;
3. otherwise search for a legally usable explicit source when the product supports it;
4. otherwise use a future AI fallback-cover pipeline when that capability is available.

Never overwrite the original file while generating or attaching a cover.
