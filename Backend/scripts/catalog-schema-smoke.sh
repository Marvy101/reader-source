#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend_dir="$(cd "$script_dir/.." && pwd)"
container_name="reader-catalog-schema-$$"
database_name="reader_catalog_test"
benchmark_rows="${CATALOG_BENCHMARK_ROWS:-50000}"

if [[ ! "$benchmark_rows" =~ ^[0-9]+$ ]] || (( benchmark_rows < 50000 )); then
  echo "CATALOG_BENCHMARK_ROWS must be an integer of at least 50000" >&2
  exit 1
fi

cleanup() {
  docker rm --force "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run \
  --detach \
  --rm \
  --name "$container_name" \
  --env POSTGRES_PASSWORD=reader \
  --env POSTGRES_DB="$database_name" \
  postgres:17-alpine >/dev/null

for _ in $(seq 1 30); do
  if docker exec "$container_name" pg_isready --username postgres --dbname "$database_name" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "$container_name" pg_isready --username postgres --dbname "$database_name" >/dev/null

run_sql() {
  local sql_file="$1"
  docker exec --interactive "$container_name" \
    psql \
      --username postgres \
      --dbname "$database_name" \
      --set ON_ERROR_STOP=1 \
      --set catalog_benchmark_rows="$benchmark_rows" \
    < "$sql_file"
}

run_sql "$backend_dir/supabase/tests/bootstrap.sql"

while IFS= read -r migration; do
  echo "Applying $(basename "$migration")"
  run_sql "$migration"
done < <(find "$backend_dir/supabase/migrations" -maxdepth 1 -type f -name '*.sql' | sort)

run_sql "$backend_dir/supabase/tests/catalog_foundation.sql"
run_sql "$backend_dir/supabase/tests/catalog_serving.sql"
run_sql "$backend_dir/supabase/tests/catalog_materialization.sql"
run_sql "$backend_dir/supabase/tests/catalog_performance.sql"
