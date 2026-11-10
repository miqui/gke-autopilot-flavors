#!/usr/bin/env bash
# Tear down everything create.sh made, in reverse order. Idempotent. Requires --yes.
set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

usage() {
  cat <<EOF
Usage: destroy.sh --project-id P --name N [--region-a R] [--region-b R] --yes [--dry-run]
  --yes  required confirmation; without it nothing is deleted
EOF
}

parse_multi_args "$@"
((ASSUME_YES == 1)) || { usage; die "refusing to destroy without --yes"; }
preflight
P=(--project "$PROJECT_ID")

delete_if_exists "forwarding rule $FR_HTTP" gcloud compute forwarding-rules describe "$FR_HTTP" --global "${P[@]}" -- \
  gcloud compute forwarding-rules delete "$FR_HTTP" --global --quiet "${P[@]}"
delete_if_exists "forwarding rule $FR_HTTPS" gcloud compute forwarding-rules describe "$FR_HTTPS" --global "${P[@]}" -- \
  gcloud compute forwarding-rules delete "$FR_HTTPS" --global --quiet "${P[@]}"
delete_if_exists "http proxy $PROXY_HTTP" gcloud compute target-http-proxies describe "$PROXY_HTTP" --global "${P[@]}" -- \
  gcloud compute target-http-proxies delete "$PROXY_HTTP" --global --quiet "${P[@]}"
delete_if_exists "https proxy $PROXY_HTTPS" gcloud compute target-https-proxies describe "$PROXY_HTTPS" --global "${P[@]}" -- \
  gcloud compute target-https-proxies delete "$PROXY_HTTPS" --global --quiet "${P[@]}"
delete_if_exists "url-map $URLMAP_REDIR" gcloud compute url-maps describe "$URLMAP_REDIR" --global "${P[@]}" -- \
  gcloud compute url-maps delete "$URLMAP_REDIR" --global --quiet "${P[@]}"
delete_if_exists "url-map $URLMAP" gcloud compute url-maps describe "$URLMAP" --global "${P[@]}" -- \
  gcloud compute url-maps delete "$URLMAP" --global --quiet "${P[@]}"
delete_if_exists "backend service $BACKEND" gcloud compute backend-services describe "$BACKEND" --global "${P[@]}" -- \
  gcloud compute backend-services delete "$BACKEND" --global --quiet "${P[@]}"
delete_if_exists "cloud armor $ARMOR" gcloud compute security-policies describe "$ARMOR" "${P[@]}" -- \
  gcloud compute security-policies delete "$ARMOR" --quiet "${P[@]}"
delete_if_exists "health check $HC" gcloud compute health-checks describe "$HC" --global "${P[@]}" -- \
  gcloud compute health-checks delete "$HC" --global --quiet "${P[@]}"
delete_if_exists "static IP $IP_NAME" gcloud compute addresses describe "$IP_NAME" --global "${P[@]}" -- \
  gcloud compute addresses delete "$IP_NAME" --global --quiet "${P[@]}"
delete_if_exists "cert map entry $CERT_ENTRY" gcloud certificate-manager maps entries describe "$CERT_ENTRY" --map "$CERT_MAP" "${P[@]}" -- \
  gcloud certificate-manager maps entries delete "$CERT_ENTRY" --map "$CERT_MAP" --quiet "${P[@]}"
delete_if_exists "cert map $CERT_MAP" gcloud certificate-manager maps describe "$CERT_MAP" "${P[@]}" -- \
  gcloud certificate-manager maps delete "$CERT_MAP" --quiet "${P[@]}"
delete_if_exists "certificate $CERT" gcloud certificate-manager certificates describe "$CERT" "${P[@]}" -- \
  gcloud certificate-manager certificates delete "$CERT" --quiet "${P[@]}"
delete_if_exists "dns authorization $DNS_AUTH" gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" "${P[@]}" -- \
  gcloud certificate-manager dns-authorizations delete "$DNS_AUTH" --quiet "${P[@]}"

delete_if_exists "cluster $CLUSTER_B" gcloud container clusters describe "$CLUSTER_B" --region "$REGION_B" "${P[@]}" -- \
  gcloud container clusters delete "$CLUSTER_B" --region "$REGION_B" --quiet "${P[@]}"
delete_if_exists "cluster $CLUSTER_A" gcloud container clusters describe "$CLUSTER_A" --region "$REGION_A" "${P[@]}" -- \
  gcloud container clusters delete "$CLUSTER_A" --region "$REGION_A" --quiet "${P[@]}"

# Leftover standalone NEGs (not always removed with the cluster)
negs="$(list_negs 2>/dev/null || true)"
while read -r neg zone; do
  [[ -n "$neg" ]] || continue
  log_info "deleting leftover NEG $neg ($zone)"
  run gcloud compute network-endpoint-groups delete "$neg" --zone "$zone" --quiet "${P[@]}"
done <<<"$negs"

delete_if_exists "nat $NAT_B" gcloud compute routers nats describe "$NAT_B" --router "$ROUTER_B" --region "$REGION_B" "${P[@]}" -- \
  gcloud compute routers nats delete "$NAT_B" --router "$ROUTER_B" --region "$REGION_B" --quiet "${P[@]}"
delete_if_exists "nat $NAT_A" gcloud compute routers nats describe "$NAT_A" --router "$ROUTER_A" --region "$REGION_A" "${P[@]}" -- \
  gcloud compute routers nats delete "$NAT_A" --router "$ROUTER_A" --region "$REGION_A" --quiet "${P[@]}"
delete_if_exists "router $ROUTER_B" gcloud compute routers describe "$ROUTER_B" --region "$REGION_B" "${P[@]}" -- \
  gcloud compute routers delete "$ROUTER_B" --region "$REGION_B" --quiet "${P[@]}"
delete_if_exists "router $ROUTER_A" gcloud compute routers describe "$ROUTER_A" --region "$REGION_A" "${P[@]}" -- \
  gcloud compute routers delete "$ROUTER_A" --region "$REGION_A" --quiet "${P[@]}"
delete_if_exists "firewall $FW_HC" gcloud compute firewall-rules describe "$FW_HC" "${P[@]}" -- \
  gcloud compute firewall-rules delete "$FW_HC" --quiet "${P[@]}"
delete_if_exists "subnet $SUBNET_B" gcloud compute networks subnets describe "$SUBNET_B" --region "$REGION_B" "${P[@]}" -- \
  gcloud compute networks subnets delete "$SUBNET_B" --region "$REGION_B" --quiet "${P[@]}"
delete_if_exists "subnet $SUBNET_A" gcloud compute networks subnets describe "$SUBNET_A" --region "$REGION_A" "${P[@]}" -- \
  gcloud compute networks subnets delete "$SUBNET_A" --region "$REGION_A" --quiet "${P[@]}"
delete_if_exists "vpc $VPC" gcloud compute networks describe "$VPC" "${P[@]}" -- \
  gcloud compute networks delete "$VPC" --quiet "${P[@]}"
log_info "destroy complete"
