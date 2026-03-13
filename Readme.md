# openziti-5gc

Zero-trust overlay for a 5G core network — protects the N2 / N3 / N4 interfaces of [free5gc](https://free5gc.org/) with [OpenZiti](https://openziti.io/) mTLS tunnels, while keeping gNB and core completely isolated at the network level.
---

## Architecture

```
  gnb-ns (10.10.1.2)          router-ns (10.10.1.1 / 10.10.2.1)        core-ns (10.10.2.2)
  ┌──────────────────┐        ┌──────────────────────────────────┐       ┌──────────────────┐
  │  UERANSIM gNB    │        │  Ziti Controller  :1280 / :6262  │       │  free5gc NFs     │
  │  n2-sctp-gateway │──UDP──►│  Ziti Edge Router :3022          │──UDP─►│  n2-sctp-gateway │
  │  ziti-edge-tunnel│  mTLS  │  (fabric, mTLS encrypted)        │  mTLS │  ziti-edge-tunnel│
  │  (run / tproxy)  │        └──────────────────────────────────┘       │  (run-host)      │
  └──────────────────┘                                                    └──────────────────┘
        ▲ iptables DROP between gnb-ns ↔ core-ns — all traffic must pass through Ziti ▲
```

| Interface | Protocol | Ziti service | Transport over Ziti |
|-----------|----------|--------------|---------------------|
| N2 (NGAP) | SCTP:38412 | `n2-ngap-service` | UDP (n2-sctp-gateway preserves SCTP metadata) |
| N3 UL (GTP-U) | UDP:2152 | `n3-gtpu-service` | UDP |
| N3 DL (GTP-U) | UDP:2152 | `n3-gtpu-dl-service` | UDP |
| N4 (PFCP) | UDP:8805 | `n4-pfcp-service` | UDP |

---

## Prerequisites

- Ubuntu 22.04 / 24.04, kernel 4.x+
- [free5gc](https://free5gc.org/) built and configured
- [UERANSIM](https://github.com/aligungr/UERANSIM) built
- `curl`, `unzip`, `jq` installed
- `yq` v4: `sudo curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq`

---

## Quick Start

```bash
# 1. Download binaries & create directories
make dirs download

# 2. Create three isolated network namespaces & compile the N2 gateway
sudo make ns-create

# 3. Generate PKI certificates
make pki

# 4. Initialize and start Ziti Controller (in router-ns)
make controller

# 5. Register and start Ziti Router (in router-ns)
make router

# 6. Apply services, identities, and policies to the controller
make apply

# 7. Enroll all identities
make enroll

# 8. Start free5gc (in core-ns)
sudo make core

# 9. Start tunnelers + N2 gateway (both namespaces)
sudo make tunneler

# 10. Start gNB then UE (in gnb-ns)
sudo make gnb
sudo make ue
```
---

## Make Targets

| Target | Description |
|--------|-------------|
| `make dirs` | Create `bin/`, `pki/`, `data/`, `logs/` |
| `make download` | Download `ziti` v1.6.13 and `ziti-edge-tunnel` v1.10.10 |
| `make build-n2-gateway` | Compile the custom N2 SCTP-aware gateway |
| `sudo make ns-create` | Create gnb-ns / router-ns / core-ns with veth pairs |
| `make pki` | Generate Root CA, controller and router certs |
| `make controller` | Init DB + start Controller in router-ns |
| `make router` | Enroll + start Edge Router in router-ns |
| `make apply` | Push services / identities / policies to controller |
| `make enroll` | Enroll all identity JWTs → JSON credential files |
| `sudo make core` | Start free5gc NFs in core-ns |
| `sudo make tunneler` | Start `ziti-edge-tunnel` + n2-gateway in both namespaces |
| `sudo make gnb` | Start UERANSIM gNB in gnb-ns |
| `sudo make ue` | Start UERANSIM UE in gnb-ns |
| `make status` | Show running state of all components |
| `sudo make verify` | Passive verification (packet capture checks) |
| `sudo make stop-all` | Stop all services |
| `make clean` | Remove runtime data (keep binaries & config) |
| `make clean-all` | Remove everything including PKI |

---

## Project Structure

```
openziti-5gc/
├── Makefile                     # All operations — run `make help`
├── controller/
│   └── ctrl-config.yaml         # Controller configuration
├── router/
│   └── router-config.yaml       # Edge Router configuration
├── policies/
│   ├── services.yml             # N2 / N3 / N4 service definitions
│   ├── identities.yml           # gNB & core identity definitions
│   ├── service-policies.yml     # Dial / Bind access policies
│   └── edge-router-policies.yml # Router access policies
├── n2-gateway/                  # Custom SCTP-aware N2 gateway (Go)
├── scripts/
│   ├── setup-namespaces.sh      # Create / delete 3 namespaces
│   ├── apply.sh                 # Push YAML policies to controller
│   ├── start-core.sh            # Start free5gc in core-ns
│   └── start-gnb.sh             # Start UERANSIM in gnb-ns
└── systemd/                     # systemd unit files for each component
```

---

## Documentation

For full technical details — OpenZiti concepts, namespace topology, PKI design, service and policy configuration, data-flow analysis, packet-capture verification, and multi-host deployment — see **[docs.md](docs.md)**.

