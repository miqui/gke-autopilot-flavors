#!/usr/bin/env bash
# Idempotent teardown of everything create.sh makes. Requires --yes.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<U
Usage: $0 --project-id ID --name NAME [--region R] [--yes] [--dry-run]
Deletes cluster (disables deletion protection first), LB IP, cert objects, Cloud Armor, NAT, router, subnets, VPC.
Only resources named "<NAME>-*" / NAME are touched. Without --yes nothing is deleted.
U
}
YES=0
parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while (($#)); do
  case "$1" in
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done
REGION="${REGION:-us-central1}"
((YES)) || { usage; die "Refusing to delete without --yes"; }
preflight
# Dry-run must preview every delete: lib resource_exists is always false in dry-run.
exists() { [[ "${DRY_RUN:-0}" == 1 ]] && return 0; resource_exists "$@"; }
P=(--project "$PROJECT_ID")
NET="$NAME-vpc"; SUBNET="$NAME-subnet"; PROXY="$NAME-proxy-only"; ROUTER="$NAME-router"; NAT="$NAME-nat"
POLICY="$NAME-armor"; IPNAME="$NAME-ip"; CERTMAP="$NAME-certmap"; CERT="$NAME-cert"; DNSAUTH="$NAME-dnsauth"

# Delete k8s Gateway first so the LB (and its backend->Armor reference) is released.
if exists gcloud container clusters describe "$NAME" --region "$REGION" "${P[@]}"; then
  if [[ "${DRY_RUN:-0}" != 1 ]] && command -v kubectl >/dev/null; then
    { gcloud container clusters get-credentials "$NAME" --region "$REGION" "${P[@]}" &&
      kubectl delete gateway,httproute,gcpbackendpolicy -l '!nonexistent' -n default --ignore-not-found --wait=true; } ||
      log_warn "k8s cleanup skipped"
  fi
  if exists gcloud beta container backup-restore backup-plans describe "$NAME-daily" --location "$REGION" "${P[@]}"; then
    run gcloud beta container backup-restore backup-plans delete "$NAME-daily" --location "$REGION" --quiet "${P[@]}"
  fi
  run gcloud container clusters update "$NAME" --region "$REGION" --no-deletion-protection "${P[@]}"
  run gcloud container clusters delete "$NAME" --region "$REGION" --quiet "${P[@]}"
else
  log_info "cluster $NAME absent"
fi

del() { # del <desc> <describe cmd...> -- <delete cmd...>
  local desc="$1"; shift; local d=() x=()
  while (($#)) && [[ "$1" != -- ]]; do d+=("$1"); shift; done; shift; x=("$@")
  if exists "${d[@]}"; then run "${x[@]}"; else log_info "$desc absent"; fi
}
del cert-map-entry gcloud certificate-manager maps entries describe "$NAME-entry" --map "$CERTMAP" "${P[@]}" -- \
  gcloud certificate-manager maps entries delete "$NAME-entry" --map "$CERTMAP" --quiet "${P[@]}"
del cert-map gcloud certificate-manager maps describe "$CERTMAP" "${P[@]}" -- gcloud certificate-manager maps delete "$CERTMAP" --quiet "${P[@]}"
del cert gcloud certificate-manager certificates describe "$CERT" "${P[@]}" -- gcloud certificate-manager certificates delete "$CERT" --quiet "${P[@]}"
del dns-auth gcloud certificate-manager dns-authorizations describe "$DNSAUTH" "${P[@]}" -- gcloud certificate-manager dns-authorizations delete "$DNSAUTH" --quiet "${P[@]}"
del armor gcloud compute security-policies describe "$POLICY" "${P[@]}" -- gcloud compute security-policies delete "$POLICY" --quiet "${P[@]}"
del address gcloud compute addresses describe "$IPNAME" --global "${P[@]}" -- gcloud compute addresses delete "$IPNAME" --global --quiet "${P[@]}"
del nat gcloud compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" "${P[@]}" -- gcloud compute routers nats delete "$NAT" --router "$ROUTER" --region "$REGION" --quiet "${P[@]}"
del router gcloud compute routers describe "$ROUTER" --region "$REGION" "${P[@]}" -- gcloud compute routers delete "$ROUTER" --region "$REGION" --quiet "${P[@]}"
del proxy-subnet gcloud compute networks subnets describe "$PROXY" --region "$REGION" "${P[@]}" -- gcloud compute networks subnets delete "$PROXY" --region "$REGION" --quiet "${P[@]}"
del subnet gcloud compute networks subnets describe "$SUBNET" --region "$REGION" "${P[@]}" -- gcloud compute networks subnets delete "$SUBNET" --region "$REGION" --quiet "${P[@]}"
del vpc gcloud compute networks describe "$NET" "${P[@]}" -- gcloud compute networks delete "$NET" --quiet "${P[@]}"
log_info "Teardown complete (remember to remove the Cloudflare records)."
