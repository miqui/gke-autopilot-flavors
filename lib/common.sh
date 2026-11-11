#!/usr/bin/env bash
# Shared helpers for gke-autopilot-flavors scripts.
# Source with: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
NAME="${NAME:-}"
REGION="${REGION:-}"
DRY_RUN="${DRY_RUN:-0}"
REMAINING_ARGS=()

log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "${1:?require_cmd needs a command}" >/dev/null 2>&1 || die "required command not found: $1"
}

# run <cmd...>: echo the command; execute unless DRY_RUN=1.
run() {
  local out
  out="$(printf '%q ' "$@")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[DRY-RUN] %s\n' "${out% }"
    return 0
  fi
  printf '+ %s\n' "${out% }"
  "$@"
}

# parse_common_args "$@": sets PROJECT_ID NAME REGION DRY_RUN REMAINING_ARGS.
parse_common_args() {
  REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        if declare -F usage >/dev/null; then usage; else echo "No usage available"; fi
        exit 0 ;;
      --project-id) [[ $# -ge 2 ]] || die "--project-id requires a value"; PROJECT_ID="$2"; shift 2 ;;
      --name)       [[ $# -ge 2 ]] || die "--name requires a value"; NAME="$2"; shift 2 ;;
      --region)     [[ $# -ge 2 ]] || die "--region requires a value"; REGION="$2"; shift 2 ;;
      --dry-run)    DRY_RUN=1; shift ;;
      *)            REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
  [[ -n "$PROJECT_ID" ]] || die "--project-id is required"
  [[ -n "$NAME" ]] || die "--name is required"
  [[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "--name must match ^[a-z][a-z0-9-]{1,30}$ (got: $NAME)"
  return 0
}

# preflight: verify tooling and (unless DRY_RUN) auth + project.
preflight() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "dry-run: skipping gcloud auth checks"
    return 0
  fi
  require_cmd gcloud
  local acct
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  [[ -n "$acct" ]] || die "no active gcloud account; run: gcloud auth login"
  gcloud projects describe "$PROJECT_ID" --project "$PROJECT_ID" >/dev/null 2>&1 \
    || die "project not found or inaccessible: $PROJECT_ID"
  log_info "using account $acct, project $PROJECT_ID"
}

# ensure_apis <api...>
ensure_apis() {
  [[ $# -gt 0 ]] || return 0
  run gcloud services enable "$@" --project "$PROJECT_ID"
}

# resource_exists <gcloud describe cmd...>: 0 if exists, 1 otherwise (always 1 in DRY_RUN).
resource_exists() {
  [[ "${DRY_RUN}" == "1" ]] && return 1
  "$@" >/dev/null 2>&1
}

# is_public_ipv4 <ip>: 0 if strict dotted-quad (octets 0-255, no leading zeros)
# and NOT 0.0.0.0 / loopback / private / link-local.
is_public_ipv4() {
  local ip="${1:-}" o a b
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((o <= 255)) || return 1; done
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  [[ "$ip" != 0.0.0.0 ]] || return 1
  ((a != 10 && a != 127)) || return 1
  ((a != 172 || b < 16 || b > 31)) || return 1
  ((a != 192 || b != 168)) || return 1
  ((a != 169 || b != 254)) || return 1
  return 0
}

# detect_public_ipv4: print this machine's public IPv4 (local network call, not GCP).
# Tries several echo services in order; dies if none returns a valid public IPv4.
detect_public_ipv4() {
  local url raw ip
  for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
    raw="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null)" || continue
    ip="$(printf '%s' "$raw" | tr -d '[:space:]')"
    if is_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  die "could not auto-detect a public IPv4 (tried checkip.amazonaws.com, api.ipify.org, ifconfig.me); check your network/VPN/proxy"
}

# set_allowed_ip_cidr: detect caller IP, set global ALLOWED_IP_CIDR=<ip>/32 and log it.
ALLOWED_IP_CIDR=""
set_allowed_ip_cidr() {
  local ip
  ip="$(detect_public_ipv4)" || exit 1
  ALLOWED_IP_CIDR="$ip/32"
  log_info "Cloud Armor will allow only $ALLOWED_IP_CIDR (auto-detected)"
}
