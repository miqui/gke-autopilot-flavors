#!/usr/bin/env bash
# Offline tests for multi-region-ha. Uses lib/test_stub/gcloud (never touches GCP).
set -uo pipefail
# shellcheck disable=SC2015
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MR="$HERE/.."
STUB_DIR="$MR/../lib/test_stub"
export PATH="$STUB_DIR:$PATH"
CURL_STUB_LOG="$(mktemp "${TMPDIR:-/tmp}/mr-curl.XXXXXX")"; export CURL_STUB_LOG
LOG="$(mktemp "${TMPDIR:-/tmp}/mr-stub.XXXXXX")"
export GCLOUD_STUB_LOG="$LOG"
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); echo "ok   - $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL - $1"; }
assert_contains() { grep -qF -- "$2" <<<"$3" && pass "$1" || fail "$1 (missing: $2)"; }
assert_not_contains() { grep -qF -- "$2" <<<"$3" && fail "$1 (unexpected: $2)" || pass "$1"; }

COMMON=(--project-id test-proj --name mrha --domain app.maqlabs.ai --authorized-networks 198.51.100.0/24)

out="$("$MR/create.sh" "${COMMON[@]}" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "create dry-run exits 0" || fail "create dry-run rc=$rc"
assert_contains "default region a" "--region us-central1" "$out"
assert_contains "default region b" "--region us-east1" "$out"
assert_contains "custom-mode vpc" "--subnet-mode custom" "$out"
assert_contains "private autopilot" "create-auto mrha-a" "$out"
assert_contains "private nodes" "--enable-private-nodes" "$out"
assert_contains "regular channel" "--release-channel regular" "$out"
assert_contains "maintenance window" "--maintenance-window-start" "$out"
assert_contains "authorized networks" "--master-authorized-networks 198.51.100.0/24" "$out"
assert_contains "NAT per region" "routers nats create mrha-nat-us-east1" "$out"
assert_contains "hc firewall ranges" "35.191.0.0/16" "$out"
assert_contains "hc firewall ranges 130" "130.211.0.0/22" "$out"
assert_contains "EXTERNAL_MANAGED" "--load-balancing-scheme EXTERNAL_MANAGED" "$out"
assert_contains "cert dns authorization" "dns-authorizations create mrha-dnsauth" "$out"
assert_contains "cert map entry" "maps entries create mrha-certmap-entry" "$out"
assert_contains "armor allow caller ip /32" "--src-ip-ranges 203.0.113.7/32" "$out"
assert_contains "armor default deny 403" "rules update 2147483647" "$out"
assert_contains "armor deny-403 action" "--action deny-403" "$out"
assert_contains "armor attached" "--security-policy mrha-armor" "$out"
assert_contains "https 443" "--ports 443" "$out"
assert_contains "http 80 redirect" "--ports 80" "$out"
assert_contains "cloudflare note" "NOT proxied" "$out"
assert_not_contains "dry-run never executes (+ prefix)" "+ gcloud" "$out"
# every gcloud command line carries --project
bad="$(grep -E '^\[DRY-RUN\] gcloud ' <<<"$out" | grep -v -- '--project test-proj' || true)"
[[ -z "$bad" ]] && pass "all dry-run gcloud calls pass --project" || fail "missing --project: $bad"
[[ ! -s "$LOG" ]] && pass "dry-run made zero gcloud invocations" || fail "dry-run invoked gcloud: $(head -3 "$LOG")"

# region overrides
out="$("$MR/create.sh" "${COMMON[@]}" --region-a europe-west1 --region-b europe-west4 --dry-run 2>&1)"
assert_contains "region override" "--region europe-west4" "$out"

# --allowed-ip removed; IP is auto-detected (stub curl)
out="$("$MR/create.sh" "${COMMON[@]}" --allowed-ip 203.0.113.7 --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && pass "--allowed-ip rejected" || fail "--allowed-ip accepted"
assert_contains "--allowed-ip hint" "auto-detected" "$out"
"$MR/create.sh" "${COMMON[@]}" --allowed-ip=203.0.113.7 --dry-run >/dev/null 2>&1 && fail "--allowed-ip=IP accepted" || pass "--allowed-ip=IP rejected"
"$MR/create.sh" "${COMMON[@]}" --allowed-ip 0.0.0.0/0 --dry-run >/dev/null 2>&1 && fail "--allowed-ip 0.0.0.0/0 accepted" || pass "--allowed-ip 0.0.0.0/0 rejected"
: >"$CURL_STUB_LOG"
out="$(CURL_STUB_IP=198.51.100.9 "$MR/create.sh" "${COMMON[@]}" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "detection success" || fail "detection rc=$rc"
assert_contains "logs auto-detected /32" "Cloud Armor will allow only 198.51.100.9/32 (auto-detected)" "$out"
assert_contains "armor rule uses detected /32" "--src-ip-ranges 198.51.100.9/32" "$out"
assert_not_contains "0.0.0.0/0 never produced" "0.0.0.0/0" "$out"
[[ "$(wc -l <"$CURL_STUB_LOG")" -eq 1 ]] && grep -q 'checkip.amazonaws.com' "$CURL_STUB_LOG" && grep -q -- '-4 -fsS --max-time 5' "$CURL_STUB_LOG" && pass "only first URL queried (curl -4 -fsS --max-time 5)" || fail "unexpected curl calls"
: >"$CURL_STUB_LOG"
out="$(CURL_STUB_FAIL=checkip.amazonaws.com "$MR/create.sh" "${COMMON[@]}" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'api.ipify.org' "$CURL_STUB_LOG" && pass "fallback to 2nd URL" || fail "no fallback to 2nd URL"
out="$(CURL_STUB_FAIL="checkip.amazonaws.com api.ipify.org" "$MR/create.sh" "${COMMON[@]}" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "fallback to 3rd URL" || fail "no fallback to 3rd URL"
out="$(CURL_STUB_ALL_FAIL=1 "$MR/create.sh" "${COMMON[@]}" --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && pass "all URLs fail => die" || fail "all URLs failed but exit 0"
assert_contains "clear failure message" "could not auto-detect" "$out"
for badip in 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 127.0.0.1 169.254.1.1 0.0.0.0 999.1.1.1 1.2.3 abc 1.2.3.4/32 ::1; do
  CURL_STUB_IP="$badip" "$MR/create.sh" "${COMMON[@]}" --dry-run >/dev/null 2>&1 && fail "detected ip accepted: $badip" || pass "detected ip rejected: $badip"
done
# authorized networks default to detected /32 when omitted
out="$("$MR/create.sh" --project-id test-proj --name mrha --domain app.maqlabs.ai --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "--authorized-networks optional" || fail "create without --authorized-networks rc=$rc"
assert_contains "authorized networks default = detected /32" "--master-authorized-networks 203.0.113.7/32" "$out"
"$MR/create.sh" "${COMMON[@]}" --region-a us-east1 --dry-run >/dev/null 2>&1 && fail "identical regions accepted" || pass "identical regions rejected"
# existing armor rule => update path (static check; dry-run never reports resources as existing)
grep -q 'security-policies rules update 1000.*ALLOWED_IP_CIDR' "$MR/create.sh" && pass "armor rule 1000 updated when it exists" || fail "armor update path missing"

# destroy
out="$("$MR/destroy.sh" --project-id test-proj --name mrha --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && pass "destroy without --yes refuses" || fail "destroy ran without --yes"
assert_contains "destroy refusal message" "--yes" "$out"
out="$("$MR/destroy.sh" --project-id test-proj --name mrha --yes --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "destroy --yes --dry-run exits 0" || fail "destroy dry-run rc=$rc"
l_fr="$(grep -n 'forwarding-rules delete mrha-fr-https' <<<"$out" | cut -d: -f1 | head -1)"
l_cl="$(grep -n 'clusters delete mrha-a' <<<"$out" | cut -d: -f1 | head -1)"
l_vpc="$(grep -n 'networks delete mrha-vpc' <<<"$out" | cut -d: -f1 | head -1)"
[[ -n "$l_fr" && -n "$l_cl" && -n "$l_vpc" && $l_fr -lt $l_cl && $l_cl -lt $l_vpc ]] && pass "destroy reverse order (LB < clusters < vpc)" || fail "destroy order wrong ($l_fr,$l_cl,$l_vpc)"

# destroy real path with stub where nothing exists: idempotent, no delete calls
: >"$LOG"
ABS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mr-abs.XXXXXX")"
cat >"$ABS_DIR/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GCLOUD_STUB_LOG:-/dev/null}"
case "$*" in
  *"auth list"*) echo stub@example.com ;;
  *"projects describe"*) exit 0 ;;
  *describe*|*" list "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$ABS_DIR/gcloud"
PATH="$ABS_DIR:$PATH" "$MR/destroy.sh" --project-id test-proj --name mrha --yes >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "destroy idempotent when nothing exists" || fail "destroy rc=$rc when absent"
grep -q ' delete ' "$LOG" && fail "destroy issued deletes for absent resources" || pass "no deletes for absent resources"
# destroy with everything 'existing' via stub: deletes issued with --project
: >"$LOG"
"$MR/destroy.sh" --project-id test-proj --name mrha --yes >/dev/null 2>&1
grep ' delete ' "$LOG" | grep -vq -- '--project test-proj' && fail "a stub delete lacked --project" || pass "stub deletes all carry --project"
grep -q 'networks delete mrha-vpc' "$LOG" && pass "stub destroy deletes vpc" || fail "stub destroy did not delete vpc"

# attach_negs dry-run
out="$("$MR/attach_negs.sh" --project-id test-proj --name mrha --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "attach_negs dry-run ok" || fail "attach_negs rc=$rc"

# verify (stub: all describes succeed, health empty -> reports failures, must still run read-only)
: >"$LOG"
"$MR/verify.sh" --project-id test-proj --name mrha >/dev/null 2>&1
grep -E ' (create|delete|update|add-backend|import) ' "$LOG" && fail "verify is not read-only" || pass "verify issued only read calls"
grep -vq -- '--project test-proj' "$LOG" && fail "verify call lacking --project" || pass "verify calls carry --project"

# manifest
m="$(cat "$MR/manifests/app.yaml")"
assert_contains "replicas 3" "replicas: 3" "$m"
assert_contains "zone spread" "topology.kubernetes.io/zone" "$m"
assert_contains "PDB" "kind: PodDisruptionBudget" "$m"
assert_contains "requests" "requests:" "$m"
assert_contains "NEG annotation" 'cloud.google.com/neg: '"'"'{"exposed_ports":{"80":{"name":"@NEG_NAME@"}}}'"'" "$m"

# syntax + shellcheck
for f in "$MR"/*.sh "$MR"/tests/*.sh; do bash -n "$f" && pass "bash -n $(basename "$f")" || fail "bash -n $f"; done
if command -v shellcheck >/dev/null; then
  shellcheck -x "$MR"/*.sh "$MR"/tests/*.sh && pass "shellcheck clean" || fail "shellcheck"
else echo "skip - shellcheck not installed"; fi

rm -f "$LOG" "$ABS_DIR/gcloud"; rmdir "$ABS_DIR" 2>/dev/null
echo "passed=$PASSES failed=$FAILS"
[[ $FAILS -eq 0 ]]
