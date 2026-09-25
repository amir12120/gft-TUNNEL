# GRE+FRP-TUNNEL

A single bash installer for a **GRE tunnel + reverse FRP tunnel** between an
**Iranian relay server** and a **foreign server** that hosts the VPN panel.

The point: your VPN clients connect to the **Iranian IP** (low ping, reachable
from every Iranian ISP) while the panel keeps running on the foreign box.

```
  VPN client ──▶  IRAN public IP : 443/tcp+udp
                     │  frps  (listens on the GRE link only)
                     │
        ╔════════════╪═════════════════════════════════════════════╗
        ║        GRE tunnel  (IPv4, survives reboot)                ║
        ║        10.99.99.1  ⇄  10.99.99.2    best MTU/TTL, hourly  ║
        ╚════════════╪═════════════════════════════════════════════╝
                     │  frpc  (reverse tunnel, latest release)
                     ▼
              FOREIGN server ──▶ 127.0.0.1:443  (panel / inbound)
```

- `frps` runs on **Iran** and binds to the tunnel address only, so the control
  channel never touches the public internet.
- `frpc` runs on the **foreign** server and dials the relay through the GRE
  link, exposing each requested port (TCP **and** UDP) on the Iranian public IP.
- `frp` is always the **latest release** from
  [fatedier/frp](https://github.com/fatedier/frp) (SHA-256 verified), with a
  daily auto-update timer.

---

## Quick start

On **both** servers (order does not matter, run it on each one):

```bash
curl -fsSL https://raw.githubusercontent.com/amir12120/GRE-FRP-TUNNEL/main/install.sh | sudo bash
```

From a checkout:

```bash
git clone https://github.com/amir12120/GRE-FRP-TUNNEL.git
cd GRE-FRP-TUNNEL && sudo ./install.sh
```

The wizard then:

1. installs the prerequisites (iproute2, curl, iptables, iputils, kmod, …) for
   your distribution (apt / dnf / yum / apk / pacman / zypper),
2. asks whether this is the **Iran** or the **foreign** server,
3. detects the public IP and asks *"is this your IP?"* — if not, you type the
   correct one,
4. asks for the **other server's** public IP,
5. creates the persistent GRE device and computes the best MTU + TTL,
6. installs the latest `frp` and writes both sides' configs,
7. asks which **ports** to tunnel and opens exactly those TCP + UDP ports,
8. installs the systemd services/timers and starts everything.

Example of the non-interactive form (handy for an automated install):

```bash
GRE_FRP_ROLE=iran    GRE_FRP_PORTS="443,2053" sudo -E ./install.sh
GRE_FRP_ROLE=foreign GRE_FRP_PORTS="443,2053" sudo -E ./install.sh
```

> **Client configs must point at the Iranian IP** — that is the whole idea of
> the setup. The panel itself stays on the foreign server.

---

## What gets installed on each server

| | Iran (relay) | Foreign (panel) |
|---|---|---|
| GRE device | `gre-frp`, `10.99.99.1/30` | `gre-frp`, `10.99.99.2/30` |
| frp role | `frps` (binds `10.99.99.1:7000`) | `frpc` (dials `10.99.99.1:7000`) |
| Public ports opened | the tunnelled ports, TCP+UDP | none (target is `127.0.0.1`) |
| Config | `/etc/frp/frps.toml` | `/etc/frp/frpc.toml` |
| State | `/etc/gre-frp-tunnel/config.env` | same |

Other paths: binaries in `/usr/local/bin`, units in `/etc/systemd/system`,
logs in `/var/log/gre-frp-tunnel`, sysctl drop-in in
`/etc/sysctl.d/99-gre-frp-tunnel.conf`.

---

## Survives reboot, tuned every hour

| systemd unit | What it does |
|---|---|
| `gre-frp-tunnel.service` | recreates the GRE device at boot (oneshot, `RemainAfterExit`) |
| `gre-frp-tunnel-optimize.timer` | runs the optimizer **every hour** and 2 min after boot |
| `gre-frp-tunnel-frpupdate.timer` | once a day: install the latest frp if a new release exists |
| `frps.service` / `frpc.service` | the tunnel itself, `Restart=always`, needs the GRE unit |

### How the best MTU and TTL are found

* **MTU** — the installer probes the real path to the peer with
  `ping -M do -s <size>` (binary search, 548 → interface MTU − 28), subtracts
  the 24 byte GRE overhead (20 IP + 4 GRE), applies the result and then verifies
  it *inside* the tunnel with a full-size DF probe and a 4-packet loss test.
  While the tunnel still loses packets the MTU is stepped down 8 bytes at a time
  (floor 1280) until it is clean. The value is stored and re-applied at boot.
* **TTL** — the hop count to the peer is measured first (it becomes the floor),
  then the standard outer TTLs (64/128/192/255 + the current one) are tried with
  short loss measurements over the tunnel and the value with the lowest packet
  loss wins (ties go to the smaller TTL, which is the conservative choice).
* **UDP fragmentation** — `udpPacketSize` in both frp configs is pinned to a
  value that fits inside the discovered MTU, so UDP traffic never fragments.
  It is fixed at setup time so both sides always agree.

Every run appends a line to `/var/log/gre-frp-tunnel/optimize.log`, and
`gre-frp-tunnel status` shows the current MTU/TTL together with the measured
loss.

---

## Commands

```bash
sudo gre-frp-tunnel                 # interactive menu (also: gft)
sudo gre-frp-tunnel status          # link, MTU/TTL, ports, services, frp version
sudo gre-frp-tunnel test            # tunnel, fragmentation, control port, ports
sudo gre-frp-tunnel optimize        # recalculate MTU + TTL right now
sudo gre-frp-tunnel ports add 8443  # add tunnelled ports (TCP + UDP)
sudo gre-frp-tunnel ports remove 2053
sudo gre-frp-tunnel ports list
sudo gre-frp-tunnel frp update      # install the latest frp release
sudo gre-frp-tunnel frp token       # show the shared auth token
sudo gre-frp-tunnel restart
sudo gre-frp-tunnel logs
sudo gre-frp-tunnel config
sudo gre-frp-tunnel export-peer     # write the peer's frp config to /etc/gre-frp-tunnel
sudo gre-frp-tunnel firewall show   # inspect the rules
sudo gre-frp-tunnel uninstall
```

Useful environment variables:
`GRE_FRP_ROLE`, `GRE_FRP_LOCAL_PUBLIC`, `GRE_FRP_PEER_PUBLIC`,
`GRE_FRP_PORTS`, `GRE_FRP_CTRL_PORT`, `GRE_FRP_GRE_LOCAL`,
`GRE_FRP_GRE_REMOTE`, `GRE_FRP_LOCAL_TARGET_IP`, `GRE_FRP_TOKEN` (your own frp
secret, must be identical on both servers), `GRE_FRP_NONINTERACTIVE=1`,
`GRE_FRP_DRY_RUN=1` (print every change without touching the host).

---

## Safety

* **ACCEPT-only firewall rule engine** — it adds the rules it needs and never
  drops or rejects anything, so it cannot lock you out of SSH. Rules carry the
  comment `gre-frp-tunnel` and are removed again by `uninstall`.
* **SSH guard** — tunnelling the SSH port (from `sshd_config` or 22) is refused
  unless you explicitly set `GRE_FRP_ALLOW_SSH_PORT=1`.
* **Control channel over the tunnel** — `frps` binds to the tunnel address, so
  port 7000 is not exposed publicly.
* **Shared secret** — `auth.token` is derived from the (order-independent)
  pair of public IPs, so both servers compute the same value on their own with
  no copy/paste step. Show it with `gre-frp-tunnel frp token`, or set your own
  with `GRE_FRP_TOKEN=…` on both servers.
* Works alongside `ufw`, plain `iptables` and `firewalld` (direct rules).

---

## Testing

The project ships a hermetic smoke test suite — no root, no network, no
firewall changes: every privileged command is replaced by a logging stub.

```bash
bash test/smoke.sh                 # ~250 assertions, both roles
SECTIONS="mtu_ttl firewall" bash test/smoke.sh   # run a subset
QUIET=1 bash test/smoke.sh         # failures only
```

It covers the full install for both roles, GRE creation and persistence, MTU/TTL
autotuning (including lossy and ICMP-filtered paths), port management, the SSH
guard, frp install/update/checksum failures, the three firewall backends,
idempotency of a second install, dry-run mode, the service helpers and
uninstall. CI runs it on every push (see `.github/workflows/ci.yml`).

---

## Troubleshooting

```bash
sudo gre-frp-tunnel test
ip -d link show gre-frp
ping -M do -s 1448 10.99.99.2        # fragmentation check from Iran
sudo journalctl -u frps -n 50        # or -u frpc on the foreign server
sudo tail -f /var/log/gre-frp-tunnel/optimize.log
```

* **The tunnel is down after configuring only one side** — expected. The GRE
  link comes up as soon as the other server is configured, and the hourly
  optimizer tunes it then.
* **High ping / packet loss** — run `gre-frp-tunnel optimize` and look at the
  loss column. If the path MTU is lower than your provider's, the MTU drops
  automatically.
* **Port not reachable from clients** — `gre-frp-tunnel test` on the Iranian
  server shows whether `frps` is listening; make sure the panel really listens
  on the foreign server at the requested port.
* **Public IP not detected** — set it by hand; the wizard asks for the correct
  IP whenever the detection looks wrong (`GRE_FRP_LOCAL_PUBLIC` in unattended
  mode).
* **Reboot lost the tunnel** — `systemctl status gre-frp-tunnel` and
  `systemctl list-timers | grep gre-frp`.

---

## Requirements

Two Linux servers with public IPv4 addresses, one in Iran and one abroad.
Root access, `systemd`, kernel GRE support (built in or as `ip_gre`), and outbound
access to GitHub for the frp download. Debian/Ubuntu, RHEL/Fedora/Alma/Rocky,
Alpine, Arch and openSUSE are supported.

## License

MIT — see [LICENSE](LICENSE). frp itself is licensed by its own authors.
