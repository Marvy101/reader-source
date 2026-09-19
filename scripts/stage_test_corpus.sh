#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
corpus_root="$repo_root/TestCorpus"
download_dir="$corpus_root/Downloads"
container_id="${READER_TEST_CONTAINER_ID:-com.example.reader}"
stage_root="${READER_TEST_CORPUS_STAGE_ROOT:-$HOME/Library/Containers/$container_id/Data/Library/Application Support/Reader/TestCorpus}"

if [[ ! -f "$corpus_root/manifest.json" || ! -d "$download_dir" ]]; then
  echo "Download the corpus first with ./scripts/download_test_corpus.sh" >&2
  exit 1
fi

mkdir -p "$stage_root/Downloads"
ditto "$corpus_root/manifest.json" "$stage_root/manifest.json"
ditto "$download_dir" "$stage_root/Downloads"

echo "Sandbox-readable corpus staged at $stage_root"
