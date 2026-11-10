#!/usr/bin/env bash
# Tests for lib/common.sh. Uses stub gcloud only; never contacts GCP.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/lib/test_stub:$PATH"
TMP="$(mktemp -d)"
export GCLOUD_STUB_LOG="$TMP/gcloud.log"; : > "$GCLOUD_STUB_LOG"
FAILS=0
LAST=""
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
# t <desc> <expected-rc> <script-body>  (runs in subshell with lib sourced)
t() {
  local desc="$1" want="$2" body="$3" out rc
  out="$(bash -c "source '$ROOT/lib/common.sh'; $body" 2>&1)"; rc=$?
  LAST="$out"
  if [[ $rc -eq $want ]]; then ok "$desc"; else fail "$desc (rc=$rc want=$want): $out"; fi
}
has() { if [[ "$LAST" == *"$2"* ]]; then ok "$1"; else fail "$1: missing '$2' in: $LAST"; fi; }

t "stub gcloud is on PATH" 0 '[[ "$(command -v gcloud)" == */lib/test_stub/gcloud ]]'
t "parse ok" 0 'parse_common_args --project-id p --name my-c --region r1 --dry-run x y; [[ $PROJECT_ID == p && $NAME == my-c && $REGION == r1 && $DRY_RUN == 1 && "${REMAINING_ARGS[*]}" == "x y" ]]'
t "defaults" 0 'parse_common_args --project-id p --name my-c; [[ -z $REGION && $DRY_RUN == 0 ]]'
t "missing project" 1 'parse_common_args --name my-c'; has "missing project msg" "--project-id is required"
t "missing name" 1 'parse_common_args --project-id p'; has "missing name msg" "--name is required"
t "bad name uppercase" 1 'parse_common_args --project-id p --name Bad'
t "bad name too short" 1 'parse_common_args --project-id p --name a'
t "bad name leading digit" 1 'parse_common_args --project-id p --name 1ab'
t "help uses usage()" 0 'usage(){ echo USAGE-TEXT; }; parse_common_args --help'; has "help output" "USAGE-TEXT"
t "run dry-run does not execute" 0 "DRY_RUN=1; run touch '$TMP/nope'; [[ ! -e '$TMP/nope' ]]"; has "dry-run prints" "[DRY-RUN] touch"
t "run executes" 0 "run touch '$TMP/yes'; [[ -e '$TMP/yes' ]]"
t "run propagates failure" 1 'run false'
t "require_cmd present" 0 'require_cmd bash'
t "require_cmd missing" 1 'require_cmd no_such_cmd_xyz'
t "die exits 1" 1 'die boom'; has "die msg" "boom"
t "preflight dry-run skips gcloud" 0 'DRY_RUN=1; PATH=/usr/bin:/bin; preflight'
: > "$GCLOUD_STUB_LOG"
t "preflight real path w/ stub" 0 'PROJECT_ID=p; preflight'
if grep -q -- "--project p" "$GCLOUD_STUB_LOG"; then ok "preflight passes --project"; else fail "preflight --project"; fi
t "preflight no account" 1 'PROJECT_ID=p; export GCLOUD_STUB_NO_ACCOUNT=1; preflight'
: > "$GCLOUD_STUB_LOG"
t "ensure_apis" 0 'PROJECT_ID=p; ensure_apis container.googleapis.com compute.googleapis.com'
if grep -q "services enable container.googleapis.com compute.googleapis.com --project p" "$GCLOUD_STUB_LOG"; then ok "ensure_apis args logged"; else fail "ensure_apis args"; fi
: > "$GCLOUD_STUB_LOG"
t "ensure_apis dry-run no call" 0 'PROJECT_ID=p; DRY_RUN=1; ensure_apis a.googleapis.com'
if [[ ! -s "$GCLOUD_STUB_LOG" ]]; then ok "dry-run made no gcloud call"; else fail "dry-run called gcloud"; fi
t "resource_exists true" 0 'resource_exists gcloud x describe y --project p'
t "resource_exists false" 1 'export GCLOUD_STUB_FAIL_DESCRIBE=1; resource_exists gcloud x describe y --project p'
t "resource_exists dry-run" 1 'DRY_RUN=1; resource_exists gcloud x describe y'
t "detect_public_ipv4 success" 0 'ip="$(detect_public_ipv4)"; [[ $ip == 203.0.113.7 ]]'
t "detect falls back to 2nd URL" 0 'export CURL_STUB_FAIL=checkip.amazonaws.com CURL_STUB_LOG='"$TMP"'/c.log; [[ "$(detect_public_ipv4)" == 203.0.113.7 ]]; grep -q api.ipify.org '"$TMP"'/c.log'
t "detect all fail dies" 1 'export CURL_STUB_ALL_FAIL=1; detect_public_ipv4'; has "detect fail msg" "could not auto-detect"
t "detect rejects private 10/8" 1 'export CURL_STUB_IP=10.0.0.5; detect_public_ipv4'
t "detect rejects 192.168/16" 1 'export CURL_STUB_IP=192.168.0.5; detect_public_ipv4'
t "detect rejects loopback" 1 'export CURL_STUB_IP=127.0.0.1; detect_public_ipv4'
t "detect rejects link-local" 1 'export CURL_STUB_IP=169.254.0.1; detect_public_ipv4'
t "detect rejects 0.0.0.0" 1 'export CURL_STUB_IP=0.0.0.0; detect_public_ipv4'
t "detect rejects octet>255" 1 'export CURL_STUB_IP=256.1.1.1; detect_public_ipv4'
t "detect rejects html junk" 1 'export CURL_STUB_IP="<html>1.2.3.4</html>"; detect_public_ipv4'
t "set_allowed_ip_cidr sets /32" 0 'set_allowed_ip_cidr; [[ $ALLOWED_IP_CIDR == 203.0.113.7/32 ]]'; has "set_allowed_ip_cidr logs" "Cloud Armor will allow only 203.0.113.7/32 (auto-detected)"
echo
if [[ $FAILS -eq 0 ]]; then echo "ALL PASSED"; else echo "$FAILS FAILED"; exit 1; fi
