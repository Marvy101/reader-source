#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest_path="$repo_root/TestCorpus/manifest.json"
download_dir="$repo_root/TestCorpus/Downloads"

for command_name in curl ruby shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$download_dir"

fixture_rows="$(
  ruby -rjson -e '
    manifest = JSON.parse(File.read(ARGV.fetch(0)))
    manifest.fetch("fixtures").each do |fixture|
      puts [
        fixture.fetch("fileName"),
        fixture.fetch("sourceURL"),
        fixture.fetch("sizeBytes"),
        fixture.fetch("sha256")
      ].join("\t")
    end
  ' "$manifest_path"
)"

verify_file() {
  local file_path="$1"
  local expected_size="$2"
  local expected_sha="$3"
  local actual_size
  local actual_sha

  actual_size="$(stat -f '%z' "$file_path")"
  actual_sha="$(shasum -a 256 "$file_path" | awk '{print $1}')"

  [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]
}

while IFS=$'\t' read -r file_name source_url expected_size expected_sha; do
  destination="$download_dir/$file_name"
  partial="$destination.partial"

  if [[ -f "$destination" ]] && verify_file "$destination" "$expected_size" "$expected_sha"; then
    echo "Verified $file_name"
    continue
  fi

  echo "Downloading $file_name"
  curl \
    --fail \
    --location \
    --retry 3 \
    --continue-at - \
    --output "$partial" \
    "$source_url"

  if ! verify_file "$partial" "$expected_size" "$expected_sha"; then
    echo "Checksum or size mismatch for $file_name" >&2
    echo "The upstream edition may have changed. Review it before updating the manifest." >&2
    exit 1
  fi

  mv -f "$partial" "$destination"
  echo "Verified $file_name"
done <<< "$fixture_rows"

echo "Corpus ready at $download_dir"
