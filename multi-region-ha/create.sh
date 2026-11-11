#!/usr/bin/env bash
# multi-region-ha: 2 private Autopilot clusters (2 regions) behind one global external Application LB.
set -euo pipefail
# shellcheck disable=SC2034
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# shellcheck source=attach_negs.sh
source "$MR_DIR/attach_negs.sh"

usage() {
  cat <<EOF
Usage: create.sh --project-id P --name N --domain D [--authorized-networks CIDR[,CIDR]] [options]
  --region-a R   first region  (default us-central1)
  --region-b R   second region (default us-east1)
  --domain D     custom domain served by the LB (e.g. app.maqlabs.ai); DNS lives on Cloudflare
  --authorized-networks  CIDRs allowed to reach the GKE control plane endpoints (default: auto-detected IP/32)
  --dry-run      print gcloud/kubectl commands without executing
Cloud Armor lets through ONLY this machine's public IPv4 (auto-detected as <ip>/32; everything else gets 403).
EOF
}

parse_multi_args "$@"
[[ -n "$DOMAIN" ]] || { usage; die "--domain is required"; }
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || die "--domain looks invalid: $DOMAIN"
set_allowed_ip_cidr   # local network call (also in --dry-run); sets ALLOWED_IP_CIDR=<ip>/32
AUTH_NETS="${AUTH_NETS:-$ALLOWED_IP_CIDR}"
IFS=, read -ra _an <<<"$AUTH_NETS"
for _c in "${_an[@]}"; do
  validate_ipv4_cidr "$_c" || die "bad --authorized-networks entry: $_c"
  [[ "$_c" != */0 ]] || die "--authorized-networks must not include 0.0.0.0/0"
done

preflight
ensure_apis compute.googleapis.com container.googleapis.com certificatemanager.googleapis.com

P=(--project "$PROJECT_ID")

network() {
  create_if_missing "vpc $VPC" gcloud compute networks describe "$VPC" "${P[@]}" -- \
    gcloud compute networks create "$VPC" --subnet-mode custom "${P[@]}"
  create_if_missing "subnet $SUBNET_A" gcloud compute networks subnets describe "$SUBNET_A" --region "$REGION_A" "${P[@]}" -- \
    gcloud compute networks subnets create "$SUBNET_A" --network "$VPC" --region "$REGION_A" --range "$SUBNET_A_RANGE" \
      --secondary-range "$RANGE_PODS=$PODS_A_RANGE,$RANGE_SVC=$SVC_A_RANGE" --enable-private-ip-google-access "${P[@]}"
  create_if_missing "subnet $SUBNET_B" gcloud compute networks subnets describe "$SUBNET_B" --region "$REGION_B" "${P[@]}" -- \
    gcloud compute networks subnets create "$SUBNET_B" --network "$VPC" --region "$REGION_B" --range "$SUBNET_B_RANGE" \
      --secondary-range "$RANGE_PODS=$PODS_B_RANGE,$RANGE_SVC=$SVC_B_RANGE" --enable-private-ip-google-access "${P[@]}"
  local r rtr nat reg
  for r in A B; do
    if [[ $r == A ]]; then rtr=$ROUTER_A; nat=$NAT_A; reg=$REGION_A; else rtr=$ROUTER_B; nat=$NAT_B; reg=$REGION_B; fi
    create_if_missing "router $rtr" gcloud compute routers describe "$rtr" --region "$reg" "${P[@]}" -- \
      gcloud compute routers create "$rtr" --network "$VPC" --region "$reg" "${P[@]}"
    if resource_exists gcloud compute routers nats describe "$nat" --router "$rtr" --region "$reg" "${P[@]}"; then
      log_info "exists, skipping: nat $nat"
    else
      log_info "creating: nat $nat"
      run gcloud compute routers nats create "$nat" --router "$rtr" --region "$reg" \
        --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges "${P[@]}"
    fi
  done
  # Google health-check/LB probe ranges must reach the pods (NEG endpoints, port 8080).
  create_if_missing "firewall $FW_HC" gcloud compute firewall-rules describe "$FW_HC" "${P[@]}" -- \
    gcloud compute firewall-rules create "$FW_HC" --network "$VPC" --direction INGRESS --action allow \
      --rules tcp:8080 --source-ranges 130.211.0.0/22,35.191.0.0/16 "${P[@]}"
}

cluster() { # name region subnet pods_range svc_range
  local cname=$1 reg=$2 subnet=$3
  create_if_missing "autopilot cluster $cname ($reg)" gcloud container clusters describe "$cname" --region "$reg" "${P[@]}" -- \
    gcloud container clusters create-auto "$cname" --region "$reg" --network "$VPC" --subnetwork "$subnet" \
      --cluster-secondary-range-name "$RANGE_PODS" --services-secondary-range-name "$RANGE_SVC" \
      --enable-private-nodes --enable-master-authorized-networks --master-authorized-networks "$AUTH_NETS" \
      --release-channel regular \
      --maintenance-window-start "2026-01-03T04:00:00Z" --maintenance-window-end "2026-01-03T12:00:00Z" \
      --maintenance-window-recurrence "FREQ=WEEKLY;BYDAY=SA,SU" "${P[@]}"
}

deploy_app() { # cluster region
  local cname=$1 reg=$2 out
  out="${TMPDIR:-/tmp}/$NAME-app-$reg.yaml"
  sed -e "s/@NEG_NAME@/$NEG_NAME/g" -e "s/@REGION@/$reg/g" "$MR_DIR/manifests/app.yaml" >"$out"
  run gcloud container clusters get-credentials "$cname" --region "$reg" "${P[@]}"
  run kubectl --context "gke_${PROJECT_ID}_${reg}_${cname}" apply -f "$out"
}

certs() {
  create_if_missing "dns authorization $DNS_AUTH" gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" "${P[@]}" -- \
    gcloud certificate-manager dns-authorizations create "$DNS_AUTH" --domain "$DOMAIN" "${P[@]}"
  create_if_missing "certificate $CERT" gcloud certificate-manager certificates describe "$CERT" "${P[@]}" -- \
    gcloud certificate-manager certificates create "$CERT" --domains "$DOMAIN" --dns-authorizations "$DNS_AUTH" "${P[@]}"
  create_if_missing "certificate map $CERT_MAP" gcloud certificate-manager maps describe "$CERT_MAP" "${P[@]}" -- \
    gcloud certificate-manager maps create "$CERT_MAP" "${P[@]}"
  create_if_missing "certificate map entry $CERT_ENTRY" gcloud certificate-manager maps entries describe "$CERT_ENTRY" --map "$CERT_MAP" "${P[@]}" -- \
    gcloud certificate-manager maps entries create "$CERT_ENTRY" --map "$CERT_MAP" --hostname "$DOMAIN" --certificates "$CERT" "${P[@]}"
}

armor() {
  create_if_missing "cloud armor policy $ARMOR" gcloud compute security-policies describe "$ARMOR" "${P[@]}" -- \
    gcloud compute security-policies create "$ARMOR" --description "allow only $ALLOWED_IP_CIDR" "${P[@]}"
  # Default rule (priority 2147483647) is created as allow; flip to deny(403). Idempotent.
  run gcloud compute security-policies rules update 2147483647 --security-policy "$ARMOR" --action deny-403 "${P[@]}"
  if resource_exists gcloud compute security-policies rules describe 1000 --security-policy "$ARMOR" "${P[@]}"; then
    # Re-running from a different network re-detects the IP and updates the allow rule.
    run gcloud compute security-policies rules update 1000 --security-policy "$ARMOR" --src-ip-ranges "$ALLOWED_IP_CIDR" --action allow "${P[@]}"
  else
    run gcloud compute security-policies rules create 1000 --security-policy "$ARMOR" --src-ip-ranges "$ALLOWED_IP_CIDR" --action allow \
      --description "caller IP only" "${P[@]}"
  fi
}

load_balancer() {
  create_if_missing "global static IP $IP_NAME" gcloud compute addresses describe "$IP_NAME" --global "${P[@]}" -- \
    gcloud compute addresses create "$IP_NAME" --global --ip-version IPV4 "${P[@]}"
  create_if_missing "health check $HC" gcloud compute health-checks describe "$HC" --global "${P[@]}" -- \
    gcloud compute health-checks create http "$HC" --global --use-serving-port --request-path / "${P[@]}"
  create_if_missing "backend service $BACKEND" gcloud compute backend-services describe "$BACKEND" --global "${P[@]}" -- \
    gcloud compute backend-services create "$BACKEND" --global --load-balancing-scheme EXTERNAL_MANAGED \
      --protocol HTTP --health-checks "$HC" --global-health-checks --connection-draining-timeout 60 \
      --security-policy "$ARMOR" "${P[@]}"
  run gcloud compute backend-services update "$BACKEND" --global --security-policy "$ARMOR" "${P[@]}"
  attach_negs

  create_if_missing "url-map $URLMAP" gcloud compute url-maps describe "$URLMAP" --global "${P[@]}" -- \
    gcloud compute url-maps create "$URLMAP" --global --default-service "$BACKEND" "${P[@]}"
  create_if_missing "https proxy $PROXY_HTTPS" gcloud compute target-https-proxies describe "$PROXY_HTTPS" --global "${P[@]}" -- \
    gcloud compute target-https-proxies create "$PROXY_HTTPS" --global --url-map "$URLMAP" \
      --certificate-map "$CERT_MAP" "${P[@]}"
  create_if_missing "forwarding rule $FR_HTTPS" gcloud compute forwarding-rules describe "$FR_HTTPS" --global "${P[@]}" -- \
    gcloud compute forwarding-rules create "$FR_HTTPS" --global --load-balancing-scheme EXTERNAL_MANAGED \
      --network-tier PREMIUM --address "$IP_NAME" --target-https-proxy "$PROXY_HTTPS" --ports 443 "${P[@]}"

  # HTTP :80 -> 301 HTTPS
  local yaml="${TMPDIR:-/tmp}/$NAME-redirect.yaml"
  cat >"$yaml" <<EOF
name: $URLMAP_REDIR
defaultUrlRedirect:
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
  httpsRedirect: true
EOF
  if resource_exists gcloud compute url-maps describe "$URLMAP_REDIR" --global "${P[@]}"; then
    log_info "exists, skipping: url-map $URLMAP_REDIR"
  else
    log_info "creating: url-map $URLMAP_REDIR"
    run gcloud compute url-maps import "$URLMAP_REDIR" --global --source "$yaml" --quiet "${P[@]}"
  fi
  create_if_missing "http proxy $PROXY_HTTP" gcloud compute target-http-proxies describe "$PROXY_HTTP" --global "${P[@]}" -- \
    gcloud compute target-http-proxies create "$PROXY_HTTP" --global --url-map "$URLMAP_REDIR" "${P[@]}"
  create_if_missing "forwarding rule $FR_HTTP" gcloud compute forwarding-rules describe "$FR_HTTP" --global "${P[@]}" -- \
    gcloud compute forwarding-rules create "$FR_HTTP" --global --load-balancing-scheme EXTERNAL_MANAGED \
      --network-tier PREMIUM --address "$IP_NAME" --target-http-proxy "$PROXY_HTTP" --ports 80 "${P[@]}"
}

print_dns() {
  local ip acme_name acme_data
  ip="$(qgcloud compute addresses describe "$IP_NAME" --global "${P[@]}" --format 'value(address)' || true)"
  acme_name="$(qgcloud certificate-manager dns-authorizations describe "$DNS_AUTH" "${P[@]}" --format 'value(dnsResourceRecord.name)' || true)"
  acme_data="$(qgcloud certificate-manager dns-authorizations describe "$DNS_AUTH" "${P[@]}" --format 'value(dnsResourceRecord.data)' || true)"
  cat <<EOF

=== Add these records in Cloudflare (DNS only / grey cloud, NOT proxied) ===
  CNAME  ${acme_name:-<run: gcloud certificate-manager dns-authorizations describe $DNS_AUTH>}  ->  ${acme_data:-<see above>}
  A      $DOMAIN  ->  ${ip:-<LB IP: gcloud compute addresses describe $IP_NAME --global>}
Certificate stays PROVISIONING until the CNAME resolves; check with verify.sh.
EOF
}

network
cluster "$CLUSTER_A" "$REGION_A" "$SUBNET_A"
cluster "$CLUSTER_B" "$REGION_B" "$SUBNET_B"
deploy_app "$CLUSTER_A" "$REGION_A"
deploy_app "$CLUSTER_B" "$REGION_B"
certs
armor
load_balancer
print_dns
log_info "create complete"
