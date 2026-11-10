#!/usr/bin/env bash
# Attach every zonal NEG named <name>-web-neg (all zones, both clusters) to the global backend service.
# Re-runnable: already-attached NEGs are skipped.
# Usage: attach_negs.sh --project-id P --name N [--dry-run]
set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
usage() { echo "usage: attach_negs.sh --project-id P --name N [--dry-run]"; }

attach_negs() {
  local tries="${NEG_WAIT_TRIES:-30}" n=0 found="" attached
  while ((n < tries)); do
    found="$(list_negs || true)"; [[ -n "$found" ]] && break
    log_info "waiting for NEGs named $NEG_NAME (GKE creates them once the Service has pods)..."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then break; fi
    sleep 10; n=$((n+1))
  done
  if [[ -z "$found" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then log_info "[dry-run] no NEGs discovered; would attach each zonal NEG"; return 0; fi
    die "no NEGs found matching $NEG_NAME"
  fi
  attached="$(qgcloud compute backend-services describe "$BACKEND" --global --project "$PROJECT_ID" --format 'value(backends[].group)' || true)"
  local neg zone
  while read -r neg zone; do
    [[ -n "$neg" ]] || continue
    if [[ "$attached" == *"/zones/$zone/networkEndpointGroups/$neg"* ]]; then log_info "already attached: $neg ($zone)"; continue; fi
    run gcloud compute backend-services add-backend "$BACKEND" --global --project "$PROJECT_ID" \
      --network-endpoint-group "$neg" --network-endpoint-group-zone "$zone" \
      --balancing-mode RATE --max-rate-per-endpoint 100
  done <<<"$found"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse_multi_args "$@"; attach_negs
fi
