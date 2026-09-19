# Contributing to Reader

Reader is source available under the [Reader Personal Use and Source Sharing
License](LICENSE). Source forks and patches are welcome under those terms.
Contributions retain their authors' copyright and use the same license.

Read [AGENTS.md](AGENTS.md) before making changes. Keep native and optional
backend changes in this repository, use a dedicated branch, and submit a
pull request. Explain the problem, the resulting behavior, and validation.

Open the committed Xcode project to build the native app. Changes to
`project.yml` require regenerating the project with XcodeGen. For tests:

```sh
make reader-test DERIVED_DATA_PATH=/tmp/reader-contribution-derived-data
```

For backend changes, follow [Backend/AGENTS.md](Backend/AGENTS.md) and run
`make setup` and `make backend-check`. Backend setup requires Node.js 24.
Use your own development infrastructure and credentials.

Do not commit credentials, personal documents, downloaded books, local
builds, or private screenshots. The reproducible corpus is described in
[TestCorpus/README.md](TestCorpus/README.md). Report reproduction steps with
synthetic or redistributable inputs. Changes to rendering, persistence,
locators, DRM, import ownership, or sync require the architectural checks
in AGENTS.md.

Third-party dependencies and assets retain their own licenses. Do not
submit code or assets you do not have permission to license under these
terms. Publishing a compiled fork or an App Store version requires separate
written permission, even if it is free.
