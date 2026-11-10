# single-region-ha

Regional GKE **Autopilot** cluster in one region, private nodes, Gateway API load balancer, Cloud Armor allowing a single IP, optional Google-managed TLS for a custom domain. Bash wrapping `gcloud`; no Terraform.

## Diagram

```
 Your IP (--allowed-ip)                      Cloudflare DNS (grey cloud / DNS-only)
        │                                      app.maqlabs.ai  A  -> LB static IP
        ▼
 ┌───────────────────────────────────────────── Google edge ────────────────┐
 │ Global external Application LB (Gateway: gke-l7-global-external-managed) │
 │   TLS: Certificate Manager cert map (Google-managed, DNS-authorized)     │
 │   Cloud Armor: rule 1000 allow <ip>/32 ; rule 2147483647 deny(403)      │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                │ container-native LB (NEGs, pod IPs)
 ┌──────────── VPC <name>-vpc (custom mode), region us-central1 ────────────┐
 │  subnet <name>-subnet  + secondary ranges pods/services, PGA on          │
 │  ┌──────── Autopilot regional cluster (control plane replicated x3) ───┐ │
 │  │  zone a: pod   zone b: pod   zone c: pod   (topologySpread, PDB)   │ │
 │  └────────────────────────── private nodes ────────────────────────────┘ │
 │  Cloud Router + Cloud NAT  (egress only)                                 │
 └──────────────────────────────────────────────────────────────────────────┘
```

## Architecture & HA rationale
- **Regional cluster**: control plane and Autopilot nodes spread over 3 zones; a zone outage or control-plane upgrade doesn't take the API down.
- **App**: 3 replicas, `topologySpreadConstraints` on `topology.kubernetes.io/zone` (maxSkew 1, DoNotSchedule), PDB `minAvailable: 2`, resource requests (Autopilot bills on them).
- **Private nodes + Cloud NAT**: no node public IPs; control plane reachable only from `--master-authorized-networks` (defaults to `--allowed-ip`).
- **Network**: custom-mode VPC, secondary ranges (pods `10.20.0.0/16`, services `10.30.0.0/20`), Private Google Access, plus a proxy-only subnet (`10.40.0.0/23`).
- **Regular release channel + weekend maintenance window**; Dataplane V2 and Workload Identity are Autopilot defaults (not set explicitly).
- **Deletion protection** on the cluster; `destroy.sh` lifts it only with `--yes`.
- **Optional Backup for GKE** (`--enable-backup`): daily 03:00, 7-day retention.

### Gateway vs Ingress — decision
Gateway API (preferred on Autopilot, GKE-managed controller, supports Cloud Armor via `GCPBackendPolicy`). **Deviation from "regional LB"**: I use the **global** external Application LB class (`gke-l7-global-external-managed`) with a Certificate Manager cert map (`networking.gke.io/certmap`), because the GKE docs (Gateway security / Deploying Gateways) state that `CertificateMap` and Google-managed Compute Engine SSL certificates are not supported on regional Gateways. The backends are still the regional cluster's NEGs, so the data path is single-region; only the LB frontend is global anycast.

A regional Gateway (`gke-l7-regional-external-managed`) is feasible as an opt-in variant: use a regional Certificate Manager certificate (same region as the Gateway, referenced via `networking.gke.io/cert-manager-certs`) or a regional SSL certificate. It also needs a regional static IP, a per-region DNS authorization, a regional Cloud Armor policy, and the proxy-only subnet (already created by `create.sh`). The feature set of regional Google-managed certificates is unverified, so check current docs before relying on it.

## Honest limits
- **The region is the ceiling.** A full `us-central1` outage takes the app down. Multi-zone ≠ multi-region; see `multi-region-ha/`.
- Cloud Armor is IP allowlist only: not authentication. Whoever shares your IP (office NAT, CGNAT) gets in. Dynamic home IPs need re-running/updating the rule.
- Managed cert stays PROVISIONING until the Cloudflare records resolve (15–60+ min). Cloudflare proxy (orange cloud) must be **off**, or the DNS authorization / Armor client-IP view breaks.
- Autopilot has no node-level control (no SSH/DaemonSets with privileges, etc).
- Backup for GKE protects data, not against a regional outage unless restored elsewhere.

## Cost notes (approximate, check current pricing)
- Autopilot cluster fee (~$0.10/h per cluster, one free zonal/Autopilot cluster credit per billing account) + pod CPU/memory requests (3 × 250m/256Mi is small).
- Cloud NAT gateway hourly + per-GB; global forwarding rule + static IP; Cloud Armor policy and per-rule/per-request charges; Certificate Manager is mostly free for managed certs; Backup for GKE per-protected-pod + storage.
- Idle floor is roughly tens of USD/month; delete with `destroy.sh` when done.

## Flags
| Flag | Required | Notes |
|---|---|---|
| `--project-id` | yes | |
| `--name` | yes | prefix for all resources; lowercase, ≤30 chars |
| `--allowed-ip` | yes | IPv4 or IPv4/CIDR, validated; `/32` assumed; `0.0.0.0/0` rejected |
| `--region` | no | default `us-central1` |
| `--domain` | no | FQDN for managed TLS; DNS records printed |
| `--master-authorized-networks` | no | comma CIDRs; default = `--allowed-ip`; `create.sh` and `destroy.sh` also accept `--authorized-networks` as an alias; CIDRs containing `/0` are rejected |
| `--enable-backup` | no | Backup for GKE plan |
| `--dry-run` | no | print mutating commands only |

`destroy.sh` takes `--project-id --name [--region] --yes [--dry-run]`; `verify.sh` takes `--project-id --name [--region] [--domain]` and is read-only.

### Unverified flags (written from knowledge, not checked against a live gcloud)
`create-auto --deletion-protection`, `--maintenance-window-*`/`--maintenance-window-recurrence` combination, `clusters update --gateway-api=standard`, `--update-addons=BackupRestore=ENABLED`, `gcloud beta container backup-restore backup-plans create` flags, `certificate-manager maps entries create --hostname`, `GCPBackendPolicy` apiVersion/`targetRef` shape, `clusters update --no-deletion-protection`, and verify.sh's `--format` field paths. Run `gcloud <cmd> --help` before first real use.

## Run manually
Only offline validation was performed. Nothing here has been run against GCP.

```bash
./tests/test_single.sh        # stub gcloud, shellcheck: passed=41 failed=0
./create.sh --project-id PROJECT --name demo --allowed-ip 203.0.113.7 --domain app.maqlabs.ai --enable-backup --dry-run
```

Real `--dry-run` output (gcloud stubbed to report "resource absent"; uses the lib's `run`):

```
[DRY-RUN] gcloud services enable container.googleapis.com compute.googleapis.com certificatemanager.googleapis.com gkebackup.googleapis.com cloudresourcemanager.googleapis.com --project demo-proj
[DRY-RUN] gcloud compute networks create demo-vpc --subnet-mode=custom --project demo-proj
[DRY-RUN] gcloud compute networks subnets create demo-subnet --network demo-vpc --region us-central1 --range 10.10.0.0/20 --secondary-range pods=10.20.0.0/16,services=10.30.0.0/20 --enable-private-ip-google-access --project demo-proj
[DRY-RUN] gcloud compute networks subnets create demo-proxy-only --network demo-vpc --region us-central1 --range 10.40.0.0/23 --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --project demo-proj
[DRY-RUN] gcloud compute routers create demo-router --network demo-vpc --region us-central1 --project demo-proj
[DRY-RUN] gcloud compute routers nats create demo-nat --router demo-router --region us-central1 --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --project demo-proj
[DRY-RUN] gcloud container clusters create-auto demo --region us-central1 --project demo-proj --network demo-vpc --subnetwork demo-subnet --cluster-secondary-range-name pods --services-secondary-range-name services --enable-private-nodes --enable-master-authorized-networks --master-authorized-networks 203.0.113.7/32 --release-channel regular --maintenance-window-start 2026-01-03T06:00:00Z --maintenance-window-end 2026-01-03T12:00:00Z --maintenance-window-recurrence FREQ=WEEKLY;BYDAY=SA,SU --deletion-protection
[DRY-RUN] gcloud container clusters update demo --region us-central1 --gateway-api=standard --project demo-proj
[DRY-RUN] gcloud compute security-policies create demo-armor --description allow 203.0.113.7/32 only --project demo-proj
[DRY-RUN] gcloud compute security-policies rules create 1000 --security-policy demo-armor --src-ip-ranges 203.0.113.7/32 --action allow --project demo-proj
[DRY-RUN] gcloud compute security-policies rules update 2147483647 --security-policy demo-armor --action deny-403 --project demo-proj
[DRY-RUN] gcloud compute addresses create demo-ip --global --ip-version IPV4 --project demo-proj
[DRY-RUN] gcloud certificate-manager dns-authorizations create demo-dnsauth --domain app.maqlabs.ai --project demo-proj
...
  A      app.maqlabs.ai   ->  <LB IP: gcloud compute addresses describe demo-ip --global --project demo-proj --format='value(address)'>
  CNAME  <name/target from: gcloud certificate-manager dns-authorizations describe demo-dnsauth --project demo-proj --format='value(dnsResourceRecord)'>
```
(Output trimmed with `...`; the lib's `[DRY-RUN]` prefix format may differ from the real lib.)

After a real create: add the printed A record and the DNS-authorization CNAME in Cloudflare as **DNS only**, then `./verify.sh --project-id PROJECT --name demo --domain app.maqlabs.ai`. Teardown: `./destroy.sh --project-id PROJECT --name demo --yes`.

## Production checklist
- [ ] Replace the sample hello-app image; set real requests/limits, probes, and graceful shutdown.
- [ ] Verify every "unverified" flag above with `--help`; pin a gcloud version in CI.
- [ ] Decide on a stable `--allowed-ip` (or replace allowlist with IAP/auth); add an alert on Armor deny spikes.
- [ ] Restrict `--master-authorized-networks`; consider the DNS-based control-plane endpoint.
- [ ] Confirm cert is ACTIVE; add CAA record and HTTP→HTTPS redirect route.
- [ ] Enable `--enable-backup`, test a restore into a scratch cluster.
- [ ] Logging/monitoring alerts, budget alerts, org policies, least-privilege IAM for deployers.
- [ ] Decide on multi-region if the RTO/RPO cannot tolerate a regional outage.
