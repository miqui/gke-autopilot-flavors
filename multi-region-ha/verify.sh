#!/usr/bin/env bash
# Read-only verification of the multi-region-ha deployment. Exit 1 if any check fails.
set -euo pipefail
# shellcheck disable=SC2015
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

usage() { echo "Usage: verify.sh --project-id P --name N [--region-a R] [--region-b R] [--domain D]"; }

parse_multi_args "$@"
P=(--project "$PROJECT_ID")
FAIL=0
ok()   { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; FAIL=1; }
check() { # label cmd...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

check "vpc $VPC" gcloud compute networks describe "$VPC" "${P[@]}"
check "subnet $SUBNET_A" gcloud compute networks subnets describe "$SUBNET_A" --region "$REGION_A" "${P[@]}"
check "subnet $SUBNET_B" gcloud compute networks subnets describe "$SUBNET_B" --region "$REGION_B" "${P[@]}"
check "nat $NAT_A" gcloud compute routers nats describe "$NAT_A" --router "$ROUTER_A" --region "$REGION_A" "${P[@]}"
check "nat $NAT_B" gcloud compute routers nats describe "$NAT_B" --router "$ROUTER_B" --region "$REGION_B" "${P[@]}"
check "firewall $FW_HC" gcloud compute firewall-rules describe "$FW_HC" "${P[@]}"

for pair in "$CLUSTER_A:$REGION_A" "$CLUSTER_B:$REGION_B"; do
  cn="${pair%%:*}"; rg="${pair##*:}"
  st="$(gcloud container clusters describe "$cn" --region "$rg" --project "$PROJECT_ID" --format 'value(status)' 2>/dev/null || true)"
  [[ "$st" == "RUNNING" ]] && ok "cluster $cn RUNNING" || bad "cluster $cn status='${st:-missing}'"
  priv="$(gcloud container clusters describe "$cn" --region "$rg" --project "$PROJECT_ID" --format 'value(privateClusterConfig.enablePrivateNodes)' 2>/dev/null || true)"
  [[ "$priv" == "True" || "$priv" == "true" ]] && ok "cluster $cn private nodes" || bad "cluster $cn private nodes (got '${priv:-?}')"
done

negs="$(list_negs 2>/dev/null || true)"
nneg="$(grep -c . <<<"$negs" || true)"
((nneg >= 2)) && ok "NEGs discovered: $nneg" || bad "expected >=2 zonal NEGs named $NEG_NAME, found $nneg"

check "backend service $BACKEND" gcloud compute backend-services describe "$BACKEND" --global "${P[@]}"
pol="$(gcloud compute backend-services describe "$BACKEND" --global "${P[@]}" --format 'value(securityPolicy.basename())' 2>/dev/null || true)"
[[ "$pol" == "$ARMOR" ]] && ok "cloud armor attached ($ARMOR)" || bad "cloud armor not attached (got '${pol:-none}')"
act="$(gcloud compute security-policies rules describe 2147483647 --security-policy "$ARMOR" "${P[@]}" --format 'value(action)' 2>/dev/null || true)"
[[ "$act" == "deny(403)" ]] && ok "armor default rule deny(403)" || bad "armor default rule action='${act:-?}'"

health="$(gcloud compute backend-services get-health "$BACKEND" --global "${P[@]}" --format 'value(status.healthStatus[].healthState)' 2>/dev/null || true)"
if grep -q HEALTHY <<<"$health"; then ok "at least one HEALTHY backend endpoint"; else bad "no HEALTHY endpoints yet"; fi

check "url-map $URLMAP" gcloud compute url-maps describe "$URLMAP" --global "${P[@]}"
check "https forwarding rule $FR_HTTPS" gcloud compute forwarding-rules describe "$FR_HTTPS" --global "${P[@]}"
check "http redirect forwarding rule $FR_HTTP" gcloud compute forwarding-rules describe "$FR_HTTP" --global "${P[@]}"

cs="$(gcloud certificate-manager certificates describe "$CERT" "${P[@]}" --format 'value(managed.state)' 2>/dev/null || true)"
case "$cs" in
  ACTIVE) ok "certificate ACTIVE";;
  PROVISIONING) bad "certificate PROVISIONING - add the Cloudflare ACME CNAME (DNS only) and wait";;
  *) bad "certificate state='${cs:-missing}'";;
esac
as="$(gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" "${P[@]}" --format 'value(dnsResourceRecord.name,dnsResourceRecord.data)' 2>/dev/null || true)"
echo "INFO  ACME record (name data): ${as:-n/a}"
echo "INFO  LB IP: $(gcloud compute addresses describe "$IP_NAME" --global "${P[@]}" --format 'value(address)' 2>/dev/null || echo n/a)"

exit "$FAIL"
