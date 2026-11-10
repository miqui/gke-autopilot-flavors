# multi-region-ha — two Autopilot regions behind one global external Application LB

Bash wrapping `gcloud` (GKE **Autopilot only**). Shared helpers come from `../lib/common.sh`.

```
                       Internet (only the auto-detected caller IP/32 passes Cloud Armor, rest = 403)
                                      |
                        Cloudflare DNS (grey cloud / DNS-only)
                         A  app.maqlabs.ai -> global static IP
                                      |
        +------------------------------------------------------------+
        |  Global external Application LB (EXTERNAL_MANAGED)          |
        |  :80 -> 301 -> :443 | cert map (Certificate Manager)        |
        |  url-map -> backend service (HTTP, RATE balancing,          |
        |             Cloud Armor, conn. draining, health check)      |
        +-------------------+--------------------+-------------------+
                            | zonal NEGs         | zonal NEGs
                  (name: <name>-web-neg)   (name: <name>-web-neg)
        +-------------------v------+   +---------v-----------------+
        | us-central1 (--region-a) |   | us-east1 (--region-b)     |
        | subnet + pods/svc ranges |   | subnet + pods/svc ranges  |
        | private Autopilot <name>-a|  | private Autopilot <name>-b|
        | web x3 over 3 zones + PDB|   | web x3 over 3 zones + PDB |
        | Cloud Router + NAT       |   | Cloud Router + NAT        |
        +--------------------------+   +---------------------------+
                    one custom-mode global VPC  (+ FW: 130.211.0.0/22, 35.191.0.0/16 -> tcp:8080)
```

## Why Option A (standalone NEGs + one global LB)

Each cluster's Service carries `cloud.google.com/neg: '{"exposed_ports":{"80":{"name":"<name>-web-neg"}}}'`, so GKE creates one zonal NEG per zone with a **predictable name**. `attach_negs.sh` discovers them (`network-endpoint-groups list --filter name~...`) and attaches all of them, from both clusters, to a single backend service using `RATE` balancing (`--max-rate-per-endpoint`). When a region is unhealthy or over capacity the LB spills traffic to the other region by proximity. Everything is plain `gcloud`; no fleet, no MCS, no extra controllers.

Not chosen (documented only):

- **B. Multi-cluster Gateway (fleet + MCS + `gke-l7-global-external-managed-mc`)** — declarative and Kubernetes-native, but requires a fleet, Multi-cluster Services, a config cluster, and a Gateway API controller; more moving parts and a config-cluster dependency. Pick it if you want routing in Kubernetes manifests.
- **C. DNS routing (per-region regional LBs + geo/failover DNS)** — simplest, but failover is gated by DNS TTLs and resolver caching, and there is no spillover. Also DNS lives on Cloudflare here, so health-based steering would need Cloudflare load balancing.

## Usage

```
./create.sh  --project-id P --name N --domain app.maqlabs.ai \
             [--authorized-networks 198.51.100.0/24] [--region-a us-central1] [--region-b us-east1] [--dry-run]
./verify.sh  --project-id P --name N [--region-a ..] [--region-b ..]     # read-only
./destroy.sh --project-id P --name N --yes [--region-a ..] [--region-b ..] [--dry-run]
```

| Flag (create.sh) | Required | Notes |
|---|---|---|
| `--project-id`, `--name` | yes | |
| `--domain` | yes | FQDN served by the LB |
| `--authorized-networks` | no | comma CIDRs for the control planes; default = auto-detected `<ip>/32`; `/0` rejected |
| `--region-a` / `--region-b` | no | defaults `us-central1` / `us-east1`; must differ |
| `--dry-run` | no | print commands only |

There is **no `--allowed-ip` flag** (passing it is an "Unknown argument" error). `create.sh` auto-detects the public IPv4 of the machine it runs on (`curl -4` against checkip.amazonaws.com, then api.ipify.org, then ifconfig.me; strict IPv4; private/loopback/link-local/`0.0.0.0` rejected; fails if none works) and Cloud Armor allows only `<that-ip>/32`. Detection is a local network call, so it also runs under `--dry-run`.

> **Warning:** re-running `create.sh` from a different network re-detects the IP and **updates** Armor rule 1000 (`security-policies rules update`), locking out the previous IP. Behind a VPN, proxy or CGNAT the detected address is the egress address (possibly shared or changing), not necessarily your machine's — check the `Cloud Armor will allow only ...` log line.

`create.sh` is re-runnable (each resource is describe-checked first). At the end it **prints the DNS records** to add in Cloudflare, both **DNS only (grey cloud, not proxied)**:

- `CNAME` ACME challenge name → value from the Certificate Manager DNS authorization
- `A` `<domain>` → the global static IP

`verify.sh` reports the certificate state (`PROVISIONING` until the CNAME resolves, then `ACTIVE`), cluster status, NEG count, backend health, Cloud Armor attachment and default-deny rule.

## Failure modes

- One zone down: that region's other zones' NEGs keep serving; the PDB (`minAvailable: 2`) and zone spread keep pods up.
- One region down or unhealthy: LB health checks mark its NEG endpoints unhealthy and traffic goes to the other region (RATE balancing allows spillover).
- Both regions down: the LB returns 502; nothing serves.
- Traffic from any IP other than the auto-detected `<ip>/32`: 403 from Cloud Armor (default rule, priority 2147483647).
- Health-check firewall missing or wrong port: all endpoints show UNHEALTHY → 502. The flavor creates the rule for 130.211.0.0/22 and 35.191.0.0/16 on tcp:8080; keep it.
- Certificate stuck in PROVISIONING: the ACME CNAME is missing or proxied in Cloudflare; HTTPS handshakes fail until ACTIVE.
- NEGs not yet created: `attach_negs.sh` waits (up to ~5 min), then fails; re-run it once pods are ready.
- Control plane unreachable from your machine: your IP isn't in `--authorized-networks`.
- Config drift: Cloud Armor allow-IP changes are applied by re-running `create.sh` from the new network (the IP is re-detected and rule 1000 is updated).

## Cost notes

- Autopilot: pay per pod request (3 x 250m CPU / 256Mi per region here) plus the cluster management fee (free tier credit applies to one zonal/Autopilot cluster per billing account; the second is billed).
- Cloud NAT: hourly gateway charge per region plus per-GB processed, two regions.
- Global LB: forwarding rules (two: 443, 80) hourly, plus data processing and egress.
- Cloud Armor: per policy + per rule + per request.
- Static IP in use is free; unused is billed. Cross-region spillover incurs inter-region egress.
- Certificate Manager: Google-managed certs are free; load balancing is the cost driver.

Run `destroy.sh --yes` when done.

## Run manually

Only offline validation was executed (no GCP resources touched; `gcloud` replaced by `../lib/test_stub/gcloud` in tests). Real `--dry-run` output (excerpt, `./create.sh --project-id my-proj --name mrha --domain app.maqlabs.ai --authorized-networks 198.51.100.0/24 --dry-run`). **The IP `203.0.113.7` came from a stub `curl` (`lib/test_stub/curl`, documentation-range address), not real detection**; on your machine it shows your own detected IP:

```
[INFO] Cloud Armor will allow only 203.0.113.7/32 (auto-detected)
[INFO] dry-run: skipping gcloud auth checks
[INFO] creating: vpc mrha-vpc
[INFO] creating: nat mrha-nat-us-central1
[DRY-RUN] gcloud compute routers nats create mrha-nat-us-central1 --router mrha-rtr-us-central1 --region us-central1 --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --project my-proj
[INFO] creating: cloud armor policy mrha-armor
[DRY-RUN] gcloud compute security-policies create mrha-armor --description allow\ only\ 203.0.113.7/32 --project my-proj
[DRY-RUN] gcloud compute security-policies rules update 2147483647 --security-policy mrha-armor --action deny-403 --project my-proj
[DRY-RUN] gcloud compute security-policies rules create 1000 --security-policy mrha-armor --src-ip-ranges 203.0.113.7/32 --action allow --description caller\ IP\ only --project my-proj
[INFO] creating: backend service mrha-backend
[DRY-RUN] gcloud compute backend-services create mrha-backend --global --load-balancing-scheme EXTERNAL_MANAGED --protocol HTTP --health-checks mrha-hc --global-health-checks --connection-draining-timeout 60 --security-policy mrha-armor --project my-proj
[INFO] [dry-run] no NEGs discovered; would attach each zonal NEG
=== Add these records in Cloudflare (DNS only / grey cloud, NOT proxied) ===
  CNAME  <run: gcloud certificate-manager dns-authorizations describe mrha-dnsauth>  ->  <see above>
  A      app.maqlabs.ai  ->  <LB IP: gcloud compute addresses describe mrha-lb-ip --global>
[INFO] create complete
```

```
./destroy.sh --project-id my-proj --name mrha
[ERROR] refusing to destroy without --yes
```

Offline tests: `bash tests/test_multi.sh` (shellcheck + dry-run assertions + stub gcloud/curl-driven destroy/verify/IP detection).

## Production checklist

- [ ] Restrict `--authorized-networks` to your admin/CI ranges; consider a bastion or Connect Gateway.
- [ ] Replace the sample nginx app and image with a pinned, scanned image from Artifact Registry; add real readiness probes.
- [ ] Tune `--max-rate-per-endpoint` (currently 100) to real per-pod capacity so spillover triggers at the right load.
- [ ] Widen Cloud Armor beyond a single IP when going public; add WAF/rate rules and enable logging.
- [ ] Add monitoring/alerts (backend health, 5xx rate, cert expiry) and uptime checks per region.
- [ ] Review maintenance windows/exclusions so the two regions never upgrade at the same time.
- [ ] Add Workload Identity, NetworkPolicy, and Binary Authorization as required.
- [ ] Confirm Cloudflare records stay DNS-only; rotate nothing in Cloudflare after the cert is ACTIVE without re-checking.
- [ ] Test regional failover (scale one region to 0) before relying on it; check quotas in both regions.
- [ ] Back up state-bearing parts separately; this flavor is stateless.
