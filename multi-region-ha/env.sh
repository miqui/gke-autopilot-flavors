#!/usr/bin/env bash
# Shared names + flag parsing for the multi-region-ha flavor. Source after lib.
# shellcheck shell=bash disable=SC2034
MR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$MR_DIR/../lib/common.sh"

REGION_A="us-central1"; REGION_B="us-east1"
DOMAIN=""; AUTH_NETS=""; ASSUME_YES=0
SUBNET_A_RANGE="10.10.0.0/20"; PODS_A_RANGE="10.20.0.0/16"; SVC_A_RANGE="10.30.0.0/20"
SUBNET_B_RANGE="10.11.0.0/20"; PODS_B_RANGE="10.21.0.0/16"; SVC_B_RANGE="10.31.0.0/20"

parse_multi_args() {
  parse_common_args "$@"
  local i=0 args=("${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}")
  while ((i < ${#args[@]})); do
    case "${args[i]}" in
      --region-a) REGION_A="${args[i+1]:?--region-a needs a value}"; i=$((i+2));;
      --region-b) REGION_B="${args[i+1]:?--region-b needs a value}"; i=$((i+2));;
      --domain) DOMAIN="${args[i+1]:?--domain needs a value}"; i=$((i+2));;
      --allowed-ip|--allowed-ip=*) usage; die "unknown argument: ${args[i]} (--allowed-ip was removed; the caller's public IPv4 is auto-detected at runtime)";;
      --authorized-networks) AUTH_NETS="${args[i+1]:?--authorized-networks needs a value}"; i=$((i+2));;
      --yes) ASSUME_YES=1; i=$((i+1));;
      *) usage; die "unknown argument: ${args[i]}";;
    esac
  done
  [[ "$REGION_A" != "$REGION_B" ]] || die "--region-a and --region-b must differ"
  derive_names
}

derive_names() {
  VPC="$NAME-vpc"; FW_HC="$NAME-allow-lb-hc"
  SUBNET_A="$NAME-$REGION_A"; SUBNET_B="$NAME-$REGION_B"
  RANGE_PODS="pods"; RANGE_SVC="services"
  ROUTER_A="$NAME-rtr-$REGION_A"; ROUTER_B="$NAME-rtr-$REGION_B"
  NAT_A="$NAME-nat-$REGION_A"; NAT_B="$NAME-nat-$REGION_B"
  CLUSTER_A="$NAME-a"; CLUSTER_B="$NAME-b"
  NEG_NAME="$NAME-web-neg"
  IP_NAME="$NAME-lb-ip"; HC="$NAME-hc"; BACKEND="$NAME-backend"
  URLMAP="$NAME-urlmap"; URLMAP_REDIR="$NAME-redirect"
  PROXY_HTTPS="$NAME-https-proxy"; PROXY_HTTP="$NAME-http-proxy"
  FR_HTTPS="$NAME-fr-https"; FR_HTTP="$NAME-fr-http"
  ARMOR="$NAME-armor"
  DNS_AUTH="$NAME-dnsauth"; CERT="$NAME-cert"; CERT_MAP="$NAME-certmap"; CERT_ENTRY="$NAME-certmap-entry"
}

validate_ipv4_cidr() { # a.b.c.d or a.b.c.d/nn
  local v="$1" ip mask
  ip="${v%%/*}"; mask=""
  if [[ "$v" == */* ]]; then mask="${v#*/}"; [[ -n "$mask" ]] || return 1; fi
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
  [[ -z "$mask" ]] || { [[ "$mask" =~ ^[0-9]{1,2}$ ]] && ((10#$mask <= 32)); }
}

# create_if_missing LABEL describe-cmd... -- create-cmd...
create_if_missing() {
  local label="$1"; shift
  local -a d=() c=(); local seen=0 a
  for a in "$@"; do
    if [[ $a == "--" && $seen -eq 0 ]]; then seen=1; elif ((seen)); then c+=("$a"); else d+=("$a"); fi
  done
  if resource_exists "${d[@]}"; then log_info "exists, skipping: $label"; else log_info "creating: $label"; run "${c[@]}"; fi
}

# delete_if_exists LABEL describe-cmd... -- delete-cmd...
delete_if_exists() {
  local label="$1"; shift
  local -a d=() c=(); local seen=0 a
  for a in "$@"; do
    if [[ $a == "--" && $seen -eq 0 ]]; then seen=1; elif ((seen)); then c+=("$a"); else d+=("$a"); fi
  done
  if [[ "${DRY_RUN:-0}" == "1" ]]; then log_info "deleting: $label"; run "${c[@]}"
  elif resource_exists "${d[@]}"; then log_info "deleting: $label"; run "${c[@]}"; else log_info "absent, skipping: $label"; fi
}

# qgcloud <gcloud args>: read-only query, quiet; never executes in dry-run
qgcloud() { [[ "${DRY_RUN:-0}" == "1" ]] && return 1; gcloud "$@" 2>/dev/null; }

# prints "<neg-name> <zone>" lines for every zonal NEG matching the stable name
list_negs() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0  # never query GCP in dry-run
  gcloud compute network-endpoint-groups list --project "$PROJECT_ID" \
    --filter "name~^${NEG_NAME}\$" --format 'value(name,zone.basename())'
}
