#!/usr/bin/env bash
# Read-only post-deploy checks.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
usage() { echo "Usage: $0 --project-id ID --name NAME [--region R] [--domain FQDN]"; }
DOMAIN=""
parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while (($#)); do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done
REGION="${REGION:-us-central1}"
preflight
P=(--project "$PROJECT_ID"); FAIL=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then log_info "PASS $d"; else log_warn "FAIL $d"; FAIL=1; fi; }
val() { gcloud container clusters describe "$NAME" --region "$REGION" "${P[@]}" --format="value($1)"; }
check "cluster RUNNING" test "$(val status)" = RUNNING
check "regional (location=$REGION)" test "$(val location)" = "$REGION"
check "autopilot enabled" test "$(val autopilot.enabled)" = True
check "private nodes" test "$(val privateClusterConfig.enablePrivateNodes)" = True
check "deletion protection" test "$(val deletionProtection)" = True
check "release channel REGULAR" test "$(val releaseChannel.channel)" = REGULAR
check "Cloud NAT exists" gcloud compute routers nats describe "$NAME-nat" --router "$NAME-router" --region "$REGION" "${P[@]}"
check "Cloud Armor default rule deny" bash -c "gcloud compute security-policies rules describe 2147483647 --security-policy '$NAME-armor' --project '$PROJECT_ID' --format='value(action)' | grep -q deny"
check "Cloud Armor allow rule 1000" gcloud compute security-policies rules describe 1000 --security-policy "$NAME-armor" "${P[@]}"
if command -v kubectl >/dev/null; then
  check "deployment ready" kubectl rollout status "deploy/$NAME-app" --timeout=60s
  check "PDB present" kubectl get pdb "$NAME-app"
  check "gateway programmed" bash -c "kubectl get gateway $NAME-gw -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
  kubectl get pods -l "app=$NAME-app" -o wide || true
fi
if [[ -n "$DOMAIN" ]]; then
  check "certificate ACTIVE" bash -c "gcloud certificate-manager certificates describe '$NAME-cert' --project '$PROJECT_ID' --format='value(managed.state)' | grep -q ACTIVE"
fi
exit "$FAIL"
