#!/usr/bin/env bash
# Run every tests/*.sh and <flavor>/tests/*.sh with the stub gcloud on PATH.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/lib/test_stub:$PATH"
rc=0
for f in "$ROOT"/tests/*.sh "$ROOT"/*/tests/*.sh; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == run_all.sh ]] && continue
  echo "=== $f"
  bash "$f" || rc=1
done
exit $rc
