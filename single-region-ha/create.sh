#!/usr/bin/env bash
# single-region-ha: regional GKE Autopilot + private nodes + NAT + Gateway API LB + Cloud Armor (allow-one-IP).
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<U
Usage: $0 --project-id ID --name NAME --allowed-ip IP[/CIDR] [options]
Required:
  --project-id ID                 GCP project
  --name NAME                     Resource name prefix / cluster name
  --allowed-ip IP|CIDR            Only IPv4 allowed through Cloud Armor (default rule denies all)
Optional:
  --region R                      Default us-central1
  --domain FQDN                   Hostname for Google-managed TLS (DNS printed for Cloudflare)
  --master-authorized-networks L  Comma CIDRs for control-plane access (default: --allowed-ip)
  --enable-backup                 Backup for GKE plan (daily, 7d retention)
  --dry-run                       Print mutating commands, do not run
  -h, --help
U
}

ALLOWED_IP=""; DOMAIN=""; MAN=""; ENABLE_BACKUP=0
validate_ipv4() {
  local v="$1" ip mask o
  ip="${v%%/*}"; mask=32; [[ "$v" == */* ]] && mask="${v#*/}"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
  [[ "$mask" =~ ^[0-9]{1,2}$ ]] && ((10#$mask <= 32)) || return 1
  return 0
}
validate_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while (($#)); do
  case "$1" in
    --allowed-ip) ALLOWED_IP="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --master-authorized-networks|--authorized-networks) MAN="${2:-}"; shift 2 ;;
    --enable-backup) ENABLE_BACKUP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done
REGION="${REGION:-us-central1}"
[[ -n "$ALLOWED_IP" ]] || { usage; die "--allowed-ip is required"; }
validate_ipv4 "$ALLOWED_IP" || die "--allowed-ip must be IPv4 or IPv4/CIDR: $ALLOWED_IP"
[[ "$ALLOWED_IP" != 0.0.0.0/0 ]] || die "--allowed-ip 0.0.0.0/0 would defeat the allowlist"
[[ "$ALLOWED_IP" == */* ]] || ALLOWED_IP="$ALLOWED_IP/32"
if [[ -n "$DOMAIN" ]]; then validate_domain "$DOMAIN" || die "Invalid --domain: $DOMAIN"; fi
MAN="${MAN:-$ALLOWED_IP}"
IFS=, read -ra _m <<<"$MAN"
for c in "${_m[@]}"; do validate_ipv4 "$c" || die "Bad master authorized network: $c"; [[ "$c" != */0 ]] || die "authorized networks must not include 0.0.0.0/0"; done
[[ "$NAME" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die "--name must be lowercase letters/digits/hyphens, <=30 chars"

NET="$NAME-vpc"; SUBNET="$NAME-subnet"; PROXY="$NAME-proxy-only"
ROUTER="$NAME-router"; NAT="$NAME-nat"; POLICY="$NAME-armor"
IPNAME="$NAME-ip"; CERTMAP="$NAME-certmap"; CERT="$NAME-cert"; DNSAUTH="$NAME-dnsauth"

preflight
ensure_apis container.googleapis.com compute.googleapis.com certificatemanager.googleapis.com \
  gkebackup.googleapis.com cloudresourcemanager.googleapis.com
P=(--project "$PROJECT_ID")

# --- Network ---------------------------------------------------------------
resource_exists gcloud compute networks describe "$NET" "${P[@]}" ||
  run gcloud compute networks create "$NET" --subnet-mode=custom "${P[@]}"
resource_exists gcloud compute networks subnets describe "$SUBNET" --region "$REGION" "${P[@]}" ||
  run gcloud compute networks subnets create "$SUBNET" --network "$NET" --region "$REGION" \
    --range 10.10.0.0/20 --secondary-range "pods=10.20.0.0/16,services=10.30.0.0/20" \
    --enable-private-ip-google-access "${P[@]}"
# Proxy-only subnet: required by regional managed LBs; kept so the Gateway class can be switched to a regional one.
resource_exists gcloud compute networks subnets describe "$PROXY" --region "$REGION" "${P[@]}" ||
  run gcloud compute networks subnets create "$PROXY" --network "$NET" --region "$REGION" \
    --range 10.40.0.0/23 --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE "${P[@]}"
resource_exists gcloud compute routers describe "$ROUTER" --region "$REGION" "${P[@]}" ||
  run gcloud compute routers create "$ROUTER" --network "$NET" --region "$REGION" "${P[@]}"
resource_exists gcloud compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" "${P[@]}" ||
  run gcloud compute routers nats create "$NAT" --router "$ROUTER" --region "$REGION" \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges "${P[@]}"

# --- Cluster ---------------------------------------------------------------
if ! resource_exists gcloud container clusters describe "$NAME" --region "$REGION" "${P[@]}"; then
  run gcloud container clusters create-auto "$NAME" --region "$REGION" "${P[@]}" \
    --network "$NET" --subnetwork "$SUBNET" \
    --cluster-secondary-range-name pods --services-secondary-range-name services \
    --enable-private-nodes --enable-master-authorized-networks \
    --master-authorized-networks "$MAN" \
    --release-channel regular \
    --maintenance-window-start "2026-01-03T06:00:00Z" --maintenance-window-end "2026-01-03T12:00:00Z" \
    --maintenance-window-recurrence "FREQ=WEEKLY;BYDAY=SA,SU" \
    --deletion-protection
fi
# Gateway API controller (UNVERIFIED whether already default on Autopilot; idempotent).
run gcloud container clusters update "$NAME" --region "$REGION" --gateway-api=standard "${P[@]}"

# --- Cloud Armor: allow only caller IP, default deny ------------------------
resource_exists gcloud compute security-policies describe "$POLICY" "${P[@]}" ||
  run gcloud compute security-policies create "$POLICY" --description "allow $ALLOWED_IP only" "${P[@]}"
resource_exists gcloud compute security-policies rules describe 1000 --security-policy "$POLICY" "${P[@]}" ||
  run gcloud compute security-policies rules create 1000 --security-policy "$POLICY" \
    --src-ip-ranges "$ALLOWED_IP" --action allow "${P[@]}"
run gcloud compute security-policies rules update 2147483647 --security-policy "$POLICY" \
  --action "deny-403" "${P[@]}"

# --- Static IP + managed TLS (Certificate Manager) ---------------------------
resource_exists gcloud compute addresses describe "$IPNAME" --global "${P[@]}" ||
  run gcloud compute addresses create "$IPNAME" --global --ip-version IPV4 "${P[@]}"
if [[ -n "$DOMAIN" ]]; then
  resource_exists gcloud certificate-manager dns-authorizations describe "$DNSAUTH" "${P[@]}" ||
    run gcloud certificate-manager dns-authorizations create "$DNSAUTH" --domain "$DOMAIN" "${P[@]}"
  resource_exists gcloud certificate-manager certificates describe "$CERT" "${P[@]}" ||
    run gcloud certificate-manager certificates create "$CERT" --domains "$DOMAIN" \
      --dns-authorizations "$DNSAUTH" "${P[@]}"
  resource_exists gcloud certificate-manager maps describe "$CERTMAP" "${P[@]}" ||
    run gcloud certificate-manager maps create "$CERTMAP" "${P[@]}"
  resource_exists gcloud certificate-manager maps entries describe "$NAME-entry" --map "$CERTMAP" "${P[@]}" ||
    run gcloud certificate-manager maps entries create "$NAME-entry" --map "$CERTMAP" \
      --certificates "$CERT" --hostname "$DOMAIN" "${P[@]}"
fi

# --- Backup for GKE (optional) -----------------------------------------------
if ((ENABLE_BACKUP)); then
  run gcloud container clusters update "$NAME" --region "$REGION" --update-addons=BackupRestore=ENABLED "${P[@]}"
  resource_exists gcloud beta container backup-restore backup-plans describe "$NAME-daily" --location "$REGION" "${P[@]}" ||
    run gcloud beta container backup-restore backup-plans create "$NAME-daily" --location "$REGION" \
      --cluster "projects/$PROJECT_ID/locations/$REGION/clusters/$NAME" --all-namespaces \
      --include-secrets --include-volume-data --cron-schedule "0 3 * * *" --backup-retain-days 7 "${P[@]}"
fi

# --- Workloads ----------------------------------------------------------------
if [[ "${DRY_RUN:-0}" == 1 ]]; then
  log_info "[dry-run] would kubectl-apply manifests/ with NAME=$NAME POLICY=$POLICY IPNAME=$IPNAME CERTMAP=$CERTMAP DOMAIN=${DOMAIN:-<none>}"
else
  require_cmd kubectl
  run gcloud container clusters get-credentials "$NAME" --region "$REGION" "${P[@]}"
  for f in "$HERE"/manifests/*.yaml; do
    sed -e "s|__NAME__|$NAME|g" -e "s|__POLICY__|$POLICY|g" -e "s|__IPNAME__|$IPNAME|g" \
        -e "s|__CERTMAP__|$CERTMAP|g" -e "s|__DOMAIN__|${DOMAIN:-app.example.invalid}|g" "$f" | kubectl apply -f -
  done
fi

# --- DNS instructions -----------------------------------------------------------
LBIP=""
if [[ "${DRY_RUN:-0}" != 1 ]]; then
  LBIP="$(gcloud compute addresses describe "$IPNAME" --global "${P[@]}" --format='value(address)' 2>/dev/null || true)"
fi
echo
log_info "Add these records in Cloudflare (DNS only / grey cloud, NOT proxied):"
if [[ -n "$DOMAIN" ]]; then
  echo "  A      $DOMAIN   ->  ${LBIP:-<LB IP: gcloud compute addresses describe $IPNAME --global --project $PROJECT_ID --format='value(address)'>}"
  echo "  CNAME  <name/target from: gcloud certificate-manager dns-authorizations describe $DNSAUTH --project $PROJECT_ID --format='value(dnsResourceRecord)'>"
  echo "  Cert becomes ACTIVE only after both resolve; allow 15-60+ min."
else
  echo "  (no --domain given: LB IP ${LBIP:-<pending>}; the Gateway listens HTTPS only, so --domain is needed for a usable endpoint)"
fi
log_info "Done. Run ./verify.sh --project-id $PROJECT_ID --name $NAME --region $REGION"
