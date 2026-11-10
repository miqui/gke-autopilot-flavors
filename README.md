# gke-autopilot-flavors

Experiments with **GKE Autopilot-only** cluster flavors. Each flavor lives in its own
subdirectory and is provisioned by bash scripts that wrap the `gcloud` CLI.

> **Cost warning:** running these scripts against a real project creates billable
> resources (Autopilot pods, load balancers, static IPs, multi-cluster ingress, egress).
> Always use `--dry-run` first and tear everything down when finished. You are responsible
> for any charges.

## Layout

```
lib/common.sh          shared bash helpers (arg parsing, dry-run, preflight)
lib/test_stub/gcloud   offline gcloud stub used by tests (logs args, no GCP calls)
tests/                 test runner (run_all.sh) and tests for lib/
<flavor>/              one directory per flavor, with its own README, scripts and tests
.github/workflows/     CI: `lint` (shellcheck + bash -n) and `test` (stubbed gcloud)
```

## Flavors

| Flavor | Description |
| --- | --- |
| [single-region-ha](single-region-ha/) | Highly available Autopilot cluster in a single region |
| [multi-region-ha](multi-region-ha/) | Autopilot clusters across multiple regions |

## Shared library

Scripts `source lib/common.sh`, which provides `log_info`, `log_warn`, `die`, `require_cmd`,
`run` (prints commands; only prints when `DRY_RUN=1`), `parse_common_args`
(`--project-id`, `--name`, `--region`, `--dry-run`, `--help`), `preflight`, `ensure_apis`
and `resource_exists`, plus `detect_public_ipv4` / `set_allowed_ip_cidr` (auto-detect the caller's
public IPv4 via `curl -4` against checkip.amazonaws.com → api.ipify.org → ifconfig.me; sets
`ALLOWED_IP_CIDR=<ip>/32`). Every `gcloud` call passes `--project "$PROJECT_ID"` explicitly.

### Cloud Armor allow-IP is auto-detected

Neither flavor takes an `--allowed-ip` flag (passing it is an error). `create.sh` detects the public
IPv4 of the machine it runs on (also during `--dry-run`; it is a local network call, not GCP) and
Cloud Armor allows only that `/32`. Re-running `create.sh` from a different network re-detects the IP
and **updates** the allow rule; VPN/proxy/CGNAT egress addresses are detected as-is, so check the logged
`Cloud Armor will allow only <ip>/32 (auto-detected)` line. Tests stub `curl` (`lib/test_stub/curl`), so
no real network is used.

## Prerequisites

- bash 4+ compatible shell, `gcloud` CLI (only for real runs; not needed for `--dry-run` or tests)
- A GCP project with billing enabled (real runs only)
- `shellcheck` for linting

## Run manually

Offline checks only (no GCP access required); these are the commands used to validate this repo:

```bash
# run all tests with the stubbed gcloud
bash tests/run_all.sh

# lint
shellcheck -x lib/common.sh lib/test_stub/gcloud lib/test_stub/curl tests/*.sh
```

See each flavor's README for its own commands.

## License

[MIT](LICENSE)
