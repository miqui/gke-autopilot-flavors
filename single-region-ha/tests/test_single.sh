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
export PATH="$TMP/bin:$PATH" GCLOUD_STUB_LOG="$TMP/log"
: >"$GCLOUD_STUB_LOG"

PASS=0; FAILN=0
ok() { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAILN=$((FAILN+1)); echo "FAIL - $1"; }
expect_fail() { local d="$1"; shift; if "$@" >"$TMP/out" 2>&1; then bad "$d (exit 0)"; else ok "$d"; fi; }
expect_ok() { local d="$1"; shift; if "$@" >"$TMP/out" 2>&1; then ok "$d"; else bad "$d"; sed 's/^/     /' "$TMP/out"; fi; }
C=(--project-id test-proj --name demo)
A=("$HERE/create.sh" "${C[@]}")

expect_fail "create requires --allowed-ip" "${A[@]}" --dry-run
expect_fail "rejects hostname as ip" "${A[@]}" --allowed-ip foo.com --dry-run
expect_fail "rejects octet > 255" "${A[@]}" --allowed-ip 300.1.1.1 --dry-run
expect_fail "rejects /33" "${A[@]}" --allowed-ip 1.2.3.4/33 --dry-run
expect_fail "rejects 0.0.0.0/0" "${A[@]}" --allowed-ip 0.0.0.0/0 --dry-run
expect_fail "rejects ipv6" "${A[@]}" --allowed-ip ::1 --dry-run
expect_fail "rejects bad domain" "${A[@]}" --allowed-ip 1.2.3.4 --domain 'bad_domain' --dry-run
expect_fail "rejects unknown flag" "${A[@]}" --allowed-ip 1.2.3.4 --bogus --dry-run
expect_fail "requires --project-id" "$HERE/create.sh" --name demo --allowed-ip 1.2.3.4 --dry-run

: >"$GCLOUD_STUB_LOG"
expect_ok "dry-run create succeeds" "${A[@]}" --allowed-ip 203.0.113.7 --domain app.maqlabs.ai --enable-backup --dry-run
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
expect_ok "re-run when resources exist (stub)" env STUB_EXISTS=1 "${A[@]}" --allowed-ip 203.0.113.7 --domain app.maqlabs.ai
if grep -q 'compute networks create\|create-auto' "$TMP/out"; then bad "re-run would recreate"; else ok "existing resources are not recreated"; fi

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
