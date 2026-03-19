# OpenZiti 5GC — Performance Experiment

This document records experiment steps and results for comparing:

1) **Baseline (no OpenZiti, underlay N2/N3): UE → gNB → CN → DN**
2) **Via-Ziti (N3 over OpenZiti): UE → gNB → Ziti → CN → DN**

## 1. Topology

### Namespaces
- `gnb-ns`: UERANSIM side (client)
- `router-ns`: OpenZiti controller + edge router
- `core-ns`: free5gc core side (CN)
- `dn-ns`: optional Data Network namespace (iperf3 server)

### DN network
- DN subnet: `10.10.5.0/24`
- `dn-ns` DN IP: `10.10.5.2/24`

### Test endpoints

**DN iperf3 server**
- `dn-ns`: `10.10.5.2:5201`

**UE iperf3 client**
- run inside `gnb-ns`
- bind to UE PDU interface address on `uesimtun0` (e.g. `10.60.0.x`)

## 2. Prerequisites

### Build/dirs
```bash
make dirs
```

### Namespaces
```bash
sudo make ns-create
sudo make dn-create
```

## 3. Bring up OpenZiti control plane (controller + edge router)

If starting from a clean state (or after deleting `pki/`):

```bash
make pki
make controller-init
make start-controller

# IMPORTANT: after controller-init (fresh DB), the edge router must be re-enrolled
make router-init
make start-router
```

Apply services/identities/policies + enroll identities:
```bash
make apply
make enroll-gnb
make enroll-core
```

## 4. Start core + tunnelers

Via-Ziti requires the core-side tunnelers to be running.

```bash
sudo make core
sudo make tunneler
```

## 5. Start DN server

### 5.1 DN iperf3 server (dn-ns)

Server must be reachable from `core-ns` over underlay:
```bash
sudo make start-iperf-dn
```

Quick check:
```bash
sudo ip netns exec dn-ns ss -ltnup | grep ':5201'
```

## 6. Tests (UE → CN → DN)

### 6.1 Baseline (no OpenZiti, underlay N2/N3)

This baseline uses **no Ziti tunnelers** and carries both N2 and N3 over the underlay. Because the project normally isolates `gnb-ns` and `core-ns`, you must temporarily allow forwarding in `router-ns`.

Allow underlay forwarding (baseline only):
```bash
sudo ip netns exec router-ns iptables -I FORWARD 1 -s 10.10.1.0/24 -d 10.10.2.0/24 -j ACCEPT
sudo ip netns exec router-ns iptables -I FORWARD 1 -s 10.10.2.0/24 -d 10.10.1.0/24 -j ACCEPT
```

Ensure `core-ns` can route *back* to the gNB subnet (required for underlay N2 replies):
```bash
sudo ip netns exec core-ns ip route replace 10.10.1.0/24 via 10.10.2.1 dev veth-core
```

Stop tunnelers (baseline):
```bash
sudo ip netns exec gnb-ns pkill -f ziti-edge-tunnel 2>/dev/null || true
sudo ip netns exec core-ns pkill -f ziti-edge-tunnel 2>/dev/null || true
sudo ip netns exec gnb-ns ip link del ziti0 2>/dev/null || true
sudo ip netns exec core-ns ip link del ziti0 2>/dev/null || true
```

Start N2 gateways over underlay (no `.ziti`):
```bash
sudo ip netns exec core-ns pkill -f n2-sctp-gateway 2>/dev/null || true
sudo ip netns exec gnb-ns  pkill -f n2-sctp-gateway 2>/dev/null || true

sudo ip netns exec core-ns bash -lc 'nohup ./bin/n2-sctp-gateway --mode core --udp-listen 10.10.2.2:38413 --amf-sctp 127.0.0.18:38412 > logs/n2gw-core-underlay.log 2>&1 &'
sudo ip netns exec gnb-ns  bash -lc 'nohup ./bin/n2-sctp-gateway --mode gnb  --sctp-listen 127.0.0.1:38412 --udp-remote 10.10.2.2:38413 > logs/n2gw-gnb-underlay.log 2>&1 &'
```

Start gNB + UE:
```bash
sudo make start-gnb
sudo make start-ue
```

Run ping + iperf from the UE PDU interface:
```bash
UEIP=$(sudo ip netns exec gnb-ns ip -o -4 addr show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
sudo ip netns exec gnb-ns ping -c 5 -I uesimtun0 10.10.5.2
sudo ip netns exec gnb-ns iperf3 -c 10.10.5.2 -t 10 -P 4 -B "$UEIP"
```

### 6.2 Via-Ziti (N3 over OpenZiti)

Re-enable isolation (remove baseline allow rules):
```bash
for spec in \
	"-s 10.10.1.0/24 -d 10.10.2.0/24 -j ACCEPT" \
	"-s 10.10.2.0/24 -d 10.10.1.0/24 -j ACCEPT" \
; do
	while sudo ip netns exec router-ns iptables -C FORWARD $spec 2>/dev/null; do
		sudo ip netns exec router-ns iptables -D FORWARD $spec
	done
done
```

Start tunnelers + Ziti-mode N2 gateway:
```bash
sudo make start-tunnel-core
sudo make start-tunnel-gnb
```

Start gNB + UE and run the same UE-based ping + iperf:
```bash
sudo make start-gnb
sudo make start-ue

UEIP=$(sudo ip netns exec gnb-ns ip -o -4 addr show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
sudo ip netns exec gnb-ns ping -c 5 -I uesimtun0 10.10.5.2
sudo ip netns exec gnb-ns iperf3 -c 10.10.5.2 -t 10 -P 4 -B "$UEIP"
```

Sanity check (optional):
- In via-Ziti mode, you should observe **no** `UDP/2152` on `core-ns` underlay `veth-core` (because N3 is carried over Ziti).

### 6.3 Latency & jitter collection (UE → CN → DN)

Run these commands in **both** baseline and via-Ziti modes (after UE is attached and `uesimtun0` exists). They generate the same artifacts used in section 7.2.

Create an output folder:
```bash
MODE=baseline   # or: via-ziti
OUT="logs/${MODE}-latjit"
mkdir -p "$OUT"
```

Get UE IP (used to bind the client side):
```bash
UEIP=$(sudo ip netns exec gnb-ns ip -o -4 addr show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
echo "$UEIP" | tee "$OUT/ue-ip.txt"
```

**A) ICMP latency (ping RTT)**
```bash
sudo ip netns exec gnb-ns ping -c 50 -I uesimtun0 10.10.5.2 | tee "$OUT/ping_ue_to_dn.txt"

# Alternative (JSON summary):
sudo ip netns exec gnb-ns python3 test/latency.py ping --host 10.10.5.2 --count 50 --iface uesimtun0 \
	| tee "$OUT/ping_ue_to_dn.json"
```

**B) TCP connect latency (100 connects to DN iperf port)**

This measures TCP 3-way handshake completion time to `10.10.5.2:5201` from the UE address, and outputs a JSON summary.

```bash
sudo ip netns exec gnb-ns env UEIP="$UEIP" python3 test/latency.py tcp-connect \
	--host 10.10.5.2 --port 5201 --count 100 --timeout-s 2 --sleep-s 0.05 \
	| tee "$OUT/tcp_connect_stats.json"
```

**C) UDP jitter + loss (iperf3 UDP @ 50 Mbps for 10s)**
```bash
sudo ip netns exec gnb-ns iperf3 -c 10.10.5.2 -p 5201 -u -b 50M -t 10 -B "$UEIP" --json | tee "$OUT/udp_50M_10s.json"
```

Notes:
- The jitter/loss numbers come from the **receiver report** in the iperf3 JSON (`end.sum` / `end.sum_received`).
- Keep `-b` and `-t` identical between baseline and via-Ziti for apples-to-apples comparison.

## 7) Measured Results
Experiment setup: AMD EPYC 7543 processor with 10 virtual CPUs, running Ubuntu 22.04.5 LTS with Linux kernel version 5.15.0-143-generic.
### 7.1 TCP throughput (10s, `-P 4`) — UE → CN → DN

Example logs:
- Baseline (no Ziti): `logs/baseline-latjit/`
- Via-Ziti (N3 over Ziti): `logs/via-ziti-latjit/`

Results:
- **Baseline (no OpenZiti):** sender **~133 Mbits/sec**, receiver **~132 Mbits/sec**
- **Via-Ziti (N3 over OpenZiti):** sender **~68 Mbits/sec**, receiver **~67 Mbits/sec**

### 7.2 Latency & jitter — UE → CN → DN

Example logs:
- Baseline: `logs/baseline-latjit/`
- Via-Ziti: `logs/via-ziti-latjit/`

**ICMP ping (UE → DN)**
- Baseline (50 packets): rtt min/avg/max/mdev = **0.384/0.614/0.822/0.096 ms**
- Via-Ziti (50 packets): rtt min/avg/max/mdev = **0.99/1.376/1.858/0.188 ms**

**TCP connect latency (100 connects to `10.10.5.2:5201`, timeout 2s)**
- Baseline: avg **0.618 ms**, p50 **0.627 ms**, p90 **0.734 ms**, p99 **0.858 ms**, min **0.333 ms**, max **0.862 ms**, failures **0/100**
- Via-Ziti: avg **1.735 ms**, p50 **1.374 ms**, p90 **1.68 ms**, p99 **5.82 ms**, min **0.915 ms**, max **35.975 ms**, failures **0/100**

**UDP iperf3 @ 50M for 10s (UE → DN)**
- Baseline: **~50.00 Mbps**, jitter **0.01 ms**, loss **0%** (0/46361)
- Via-Ziti: **~50.00 Mbps**, jitter **0.012 ms**, loss **0%** (0/46361)

## 8. Cleanup

Stop processes:
```bash
sudo make stop-all
```

Remove namespaces:
```bash
sudo make dn-delete
sudo make ns-delete
```
