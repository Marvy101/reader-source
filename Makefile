DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
DERIVED_DATA_PATH ?= /tmp/reader-monorepo-derived-data
VERCEL_PROJECT ?= reader-backend

.PHONY: setup backend-check backend-link backend-dev backend-preview reader-test check

setup:
	npm --prefix Backend ci

backend-check:
	npm --prefix Backend run check

backend-link:
	vercel link --project "$(VERCEL_PROJECT)" --yes

backend-dev:
	vercel dev

backend-preview:
	vercel deploy --yes

reader-test:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild \
		-project Reader.xcodeproj \
		-scheme Reader \
		-destination 'platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		CODE_SIGNING_ALLOWED=NO \
		test

check: backend-check reader-test
