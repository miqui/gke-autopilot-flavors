#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && ok || bad` is intentional; ok() never fails
# Offline tests: stub gcloud on PATH, never touches GCP. Run: ./tests/test_single.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# Local stub: logs args; `describe` fails (resource absent) unless STUB_EXISTS=1.
cat >"$TMP/bin/gcloud" <<'S'
#!/usr/bin/env bash
echo "$*" >>"${GCLOUD_STUB_LOG:?}"
case "$*" in *"auth list"*) echo stub@example.com; exit 0;; *"projects describe"*) exit 0;; *" describe "*) [[ "${STUB_EXISTS:-0}" == 1 ]] && exit 0 || exit 1 ;; esac
exit 0
S
chmod +x "$TMP/bin/gcloud"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/kubectl"; chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$HERE/../lib/test_stub:$PATH" GCLOUD_STUB_LOG="$TMP/log" CURL_STUB_LOG="$TMP/curl.log"
: >"$GCLOUD_STUB_LOG"

PASS=0; FAILN=0
ok() { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAILN=$((FAILN+1)); echo "FAIL - $1"; }
expect_fail() { local d="$1"; shift; if "$@" >"$TMP/out" 2>&1; then bad "$d (exit 0)"; else ok "$d"; fi; }
expect_ok() { local d="$1"; shift; if "$@" >"$TMP/out" 2>&1; then ok "$d"; else bad "$d"; sed 's/^/     /' "$TMP/out"; fi; }
C=(--project-id test-proj --name demo)
A=("$HERE/create.sh" "${C[@]}")

expect_fail "rejects bad domain" "${A[@]}" --domain 'bad_domain' --dry-run
expect_fail "rejects unknown flag" "${A[@]}" --bogus --dry-run
expect_fail "requires --project-id" "$HERE/create.sh" --name demo --dry-run
# --allowed-ip was removed: any form is an unknown argument with a hint
expect_fail "--allowed-ip rejected" "${A[@]}" --allowed-ip 203.0.113.7 --dry-run
grep -q 'auto-detected' "$TMP/out" && ok "--allowed-ip error hints auto-detect" || bad "no auto-detect hint"
expect_fail "--allowed-ip=IP rejected" "${A[@]}" --allowed-ip=203.0.113.7 --dry-run
expect_fail "--allowed-ip 0.0.0.0/0 rejected" "${A[@]}" --allowed-ip 0.0.0.0/0 --dry-run

# auto-detection (stub curl; no real network)
: >"$CURL_STUB_LOG"
expect_ok "detection: first URL success" env CURL_STUB_IP=198.51.100.9 "${A[@]}" --dry-run
grep -q 'allow only 198.51.100.9/32 (auto-detected)' "$TMP/out" && ok "logs auto-detected /32" || bad "missing auto-detected log"
grep -q -- '--src-ip-ranges 198.51.100.9/32' "$TMP/out" && ok "armor rule uses detected /32" || bad "armor rule not detected IP"
grep -q -- '--master-authorized-networks 198.51.100.9/32' "$TMP/out" && ok "master networks default = detected /32" || bad "master networks default wrong"
[[ "$(wc -l <"$CURL_STUB_LOG")" -eq 1 ]] && grep -q 'checkip.amazonaws.com' "$CURL_STUB_LOG" && grep -q -- '-4 -fsS --max-time 5' "$CURL_STUB_LOG" && ok "only first URL queried (curl -4 -fsS --max-time 5)" || bad "unexpected curl calls"
: >"$CURL_STUB_LOG"
expect_ok "detection: falls back to 2nd URL" env CURL_STUB_FAIL=checkip.amazonaws.com "${A[@]}" --dry-run
grep -q 'api.ipify.org' "$CURL_STUB_LOG" && ok "fallback queried ipify" || bad "ipify not queried"
expect_ok "detection: falls back to 3rd URL" env CURL_STUB_FAIL="checkip.amazonaws.com api.ipify.org" "${A[@]}" --dry-run
expect_fail "detection: all URLs fail => die" env CURL_STUB_ALL_FAIL=1 "${A[@]}" --dry-run
grep -q 'could not auto-detect' "$TMP/out" && ok "clear failure message" || bad "no failure message"
for badip in 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 127.0.0.1 169.254.1.1 0.0.0.0 999.1.1.1 1.2.3 abc 1.2.3.4/32 ::1; do
  expect_fail "detected '$badip' rejected" env CURL_STUB_IP="$badip" "${A[@]}" --dry-run
done
expect_ok "172.32.0.1 (outside 172.16/12) accepted" env CURL_STUB_IP=172.32.0.1 "${A[@]}" --dry-run
expect_ok "whitespace trimmed" env CURL_STUB_IP="  203.0.113.7  " "${A[@]}" --dry-run
if grep -q '0\.0\.0\.0/0' "$TMP/out"; then bad "0.0.0.0/0 produced"; else ok "0.0.0.0/0 never produced"; fi

: >"$GCLOUD_STUB_LOG"
expect_ok "dry-run create succeeds" "${A[@]}" --domain app.maqlabs.ai --enable-backup --dry-run
cp "$TMP/out" "$TMP/create.out"
grep -q 'create-auto demo' "$TMP/create.out" && ok "prints create-auto" || bad "create-auto missing"
for pat in 'enable-private-nodes' 'deletion-protection' 'release-channel regular' '2147483647' 'deny-403' \
           '203.0.113.7/32' 'enable-private-ip-google-access' 'nats create' 'backup-plans create' 'maintenance-window' 'DNS only'; do
  grep -q -- "$pat" "$TMP/create.out" && ok "output has: $pat" || bad "output missing: $pat"
done
grep -q 'A      app.maqlabs.ai' "$TMP/create.out" && ok "prints Cloudflare A record" || bad "no A record line"
# dry-run must not have executed any mutating gcloud call
if grep -Eq ' (create|create-auto|delete|update|add-iam-policy-binding) ' "$GCLOUD_STUB_LOG"; then bad "dry-run executed mutation"; grep -E ' (create|delete|update) ' "$GCLOUD_STUB_LOG"; else ok "dry-run executed no mutating gcloud"; fi
# every gcloud call carries --project
if grep -v -- '--project test-proj' "$GCLOUD_STUB_LOG" | grep -q .; then bad "gcloud call without --project:"; grep -v -- '--project test-proj' "$GCLOUD_STUB_LOG"; else ok "all stub gcloud calls pass --project"; fi

# idempotency: everything exists -> no create commands printed
# real lib: resource_exists is always false in dry-run, so use a live run against the stub
expect_ok "re-run when resources exist (stub)" env STUB_EXISTS=1 "${A[@]}" --domain app.maqlabs.ai
if grep -q 'compute networks create\|create-auto' "$TMP/out"; then bad "re-run would recreate"; else ok "existing resources are not recreated"; fi
grep -q 'security-policies rules update 1000.*--src-ip-ranges 203.0.113.7/32' "$TMP/out" && ok "existing armor rule is updated (new IP)" || bad "armor rule not updated on re-run"
grep -q 'security-policies rules create 1000' "$TMP/out" && bad "armor rule re-created" || ok "armor rule not re-created"

# destroy
D=("$HERE/destroy.sh" "${C[@]}")
expect_fail "destroy refuses without --yes" "${D[@]}" --dry-run
: >"$GCLOUD_STUB_LOG"
expect_ok "destroy --yes --dry-run (all exist)" env STUB_EXISTS=1 "${D[@]}" --yes --dry-run
grep -q 'no-deletion-protection' "$TMP/out" && ok "destroy lifts deletion protection" || bad "no-deletion-protection missing"
grep -q 'networks delete demo-vpc' "$TMP/out" && ok "destroy deletes vpc" || bad "vpc delete missing"
expect_ok "destroy --yes (all absent, stub) is idempotent" "${D[@]}" --yes
grep -q 'delete' "$TMP/out" && bad "absent resources got delete" || ok "no deletes when absent"

# verify is read-only
: >"$GCLOUD_STUB_LOG"
"$HERE/verify.sh" "${C[@]}" >/dev/null 2>&1
if grep -Eq ' (create|delete|update) ' "$GCLOUD_STUB_LOG"; then bad "verify mutates"; else ok "verify.sh read-only"; fi

# manifests
M="$HERE/manifests"
grep -q 'replicas: 3' "$M/app.yaml" && ok "replicas>=3" || bad replicas
grep -q 'topology.kubernetes.io/zone' "$M/app.yaml" && ok "zone spread" || bad spread
grep -q 'kind: PodDisruptionBudget' "$M/app.yaml" && ok "PDB" || bad pdb
grep -q 'requests:' "$M/app.yaml" && ok "resource requests" || bad requests
grep -q 'cloud.google.com/neg' "$M/app.yaml" && ok "NEG annotation" || bad neg
grep -q 'kind: GCPBackendPolicy' "$M/gateway.yaml" && grep -q 'securityPolicy' "$M/gateway.yaml" && ok "Armor via GCPBackendPolicy" || bad armor
command -v shellcheck >/dev/null && { shellcheck -x "$HERE"/*.sh "$HERE"/tests/*.sh && ok shellcheck || bad shellcheck; }

echo "passed=$PASS failed=$FAILN"
[[ $FAILN -eq 0 ]]
