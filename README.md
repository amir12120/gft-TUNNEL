# gft-TUNNEL

A single bash installer **and** an interactive manager for a
**GRE tunnel + reverse FRP tunnel** between an **Iranian relay server** and a
**foreign server** that hosts the VPN panel.

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
- Everything is driven by one command, **`gft`**, which opens a full-screen
  menu after the install.

---

## Quick start

On **both** servers (order does not matter, run it on each one):

```bash
curl -fsSL https://raw.githubusercontent.com/amir12120/gft-TUNNEL/main/install.sh | sudo bash
```

From a checkout:

```bash
git clone https://github.com/amir12120/gft-TUNNEL.git
cd gft-TUNNEL && sudo ./install.sh
```

The wizard then:

1. installs the prerequisites (iproute2, curl, iptables, iputils, kmod, …) for
   your distribution (apt / dnf / yum / apk / pacman / zypper),
2. asks whether this is the **Iran** or the **foreign** server,
3. detects the public IP and asks *"is this your IP?"* — if not, you type the
   correct one,
4. asks for the **other server's** public IP,
5. shows the **default tunnel (control) port `40001`** and asks whether to keep
   it or change it,
6. asks which **ports** to tunnel — **you type them all at once, comma
   separated** (e.g. `443,8443,2053`) — and opens exactly those TCP + UDP ports,
7. creates the persistent GRE device and computes the best MTU + TTL,
8. installs the latest `frp`, writes both sides' configs, installs the systemd
   services/timers, starts everything, and **drops you into the menu**.

Example of the non-interactive form (handy for an automated install):

```bash
GFT_ROLE=iran    GFT_PORTS="443,2053" sudo -E ./install.sh
GFT_ROLE=foreign GFT_PORTS="443,2053" sudo -E ./install.sh
```

> **Client configs must point at the Iranian IP** — that is the whole idea of
> the setup. The panel itself stays on the foreign server.

---

## The `gft` menu

After the install, running `gft` opens a full-screen menu (arrow keys + Enter,
or type the number when stdin is not a terminal):

```
  Install / reconfigure this server       Status
  Edit tunnel settings                    Update gft-TUNNEL from GitHub
  Change the tunnel port                  Update frp to the latest release
  Manage tunnelled ports                  Restart the tunnel and frp
  Recalculate the best MTU + TTL          Show logs
  Connectivity test                       Show configuration
                                          Firewall rules
                                          Export the peer's frp config
                                          Uninstall
                                          Quit
```

The header always shows the role, both public IPs, both tunnel IPs, the tunnel
port, the link state, MTU/TTL, the tunnelled ports, the frp version and the
service state — read from the state file, so opening the menu costs nothing.

### Changing a setting — including the peer's IP

The tunnel is fully editable after the install, from the menu *or* the command
line. The key use case: **on the foreign server, repoint the tunnel at a new
Iranian IP.**

```bash
sudo gft set                       # interactive picker over every setting
sudo gft edit                      # same picker (menu entry "Edit tunnel settings")
sudo gft set peer-ip 1.2.3.4       # the peer's public IP (rebuilds the link)
sudo gft set local-ip 5.6.7.8      # this server's own public IP
sudo gft set gre-remote 10.99.99.9 # the peer's tunnel IP
sudo gft set tunnel-port 41000     # the tunnel (control) port (default 40001)
sudo gft set ports 443,8443,2053   # replace the tunnelled list (all at once)
sudo gft set target 10.77.0.5      # where the panel listens on this server
sudo gft set mtu 1400              # pin the MTU by hand
sudo gft set ttl 64                # pin the TTL by hand
```

`gft set <key> <value>` validates the value, refuses anything that would break
the tunnel (an unknown key, the peer IP equal to your own, the two tunnel IPs
identical, an SSH port without an explicit override), applies the change to the
host and keeps everything in sync: it rebuilds the GRE link, rewrites the frp
config, re-applies the firewall and the MSS clamp, retunes MTU/TTL and restarts
the services — all in one step.

### Updating

```bash
sudo gft update            # git pull the newest gft-TUNNEL and reinstall the units
sudo gft update --force    # overwrite local edits (they are protected by default)
sudo gft frp update        # install the latest frp release
```

---

## What gets installed on each server

| | Iran (relay) | Foreign (panel) |
|---|---|---|
| GRE device | `gft0`, `10.99.99.1/30` | `gft0`, `10.99.99.2/30` |
| frp role | `frps` (binds `10.99.99.1:40001`) | `frpc` (dials `10.99.99.1:40001`) |
| Public ports opened | the tunnelled ports, TCP+UDP | none (target is `127.0.0.1`) |
| Config | `/etc/frp/frps.toml` | `/etc/frp/frpc.toml` |
| State | `/etc/gft-tunnel/config.env` | same |

The **default tunnel (control) port is `40001`** and can be changed during the
install or any time with `gft set tunnel-port` / `gft tunnel-port`.

Other paths: binaries in `/usr/local/bin`, units in `/etc/systemd/system`,
logs in `/var/log/gft-tunnel`, sysctl drop-in in
`/etc/sysctl.d/99-gft-tunnel.conf`.

---

## Survives reboot, tuned every hour

| systemd unit | What it does |
|---|---|
| `gft-tunnel.service` | recreates the GRE device at boot (oneshot, `RemainAfterExit`) |
| `gft-tunnel-optimize.timer` | runs the optimizer **every hour** and 2 min after boot |
| `gft-tunnel-frpupdate.timer` | once a day: install the latest frp if a new release exists |
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

Every run appends a line to `/var/log/gft-tunnel/optimize.log`, and
`gft status` shows the current MTU/TTL together with the measured loss.

### Speed, low loss, low footprint

* **MSS clamping** (`--set-mss MTU-40` on the tunnelled ports) keeps relayed TCP
  inside the tunnel MTU, so large downloads do not fragment and stall. The clamp
  follows the hourly MTU without stacking duplicate rules.
* **BBR + fq** are enabled when the kernel offers them (`net.ipv4.tcp_congestion_control = bbr`,
  `net.core.default_qdisc = fq`), plus
  `net.ipv4.tcp_mtu_probing = 1` to survive PMTU black holes. Set
  `GFT_TCP_CC=cubic|none` to opt out, or `GFT_TUNE_NETWORK=0` to skip the tuning.
* **Lightweight by design** — no userspace tunnel process, no proxy daemon and no
  Python: it is bash + kernel GRE + one frp pair. The hourly optimizer is a
  short-lived oneshot, and the menu header reads only the small state file (no
  pings), so it stays cheap on RAM and CPU.

---

## Commands

```bash
sudo gft                        # interactive menu
sudo gft status                 # link, MTU/TTL, ports, services, frp version
sudo gft test                   # tunnel, fragmentation, control port, ports
sudo gft optimize               # recalculate MTU + TTL right now
sudo gft edit                   # interactive editor for every tunnel setting
sudo gft set <key> <value>      # change one setting non-interactively
sudo gft tunnel-port            # show / change the tunnel (control) port
sudo gft ports add 8443         # add tunnelled ports (TCP + UDP)
sudo gft ports remove 2053
sudo gft ports list
sudo gft frp update             # install the latest frp release
sudo gft frp token              # show the shared auth token
sudo gft update                 # update gft-TUNNEL itself from GitHub
sudo gft restart
sudo gft logs
sudo gft config
sudo gft export-peer            # write the peer's frp config to /etc/gft-tunnel
sudo gft firewall show          # inspect the rules
sudo gft uninstall
```

The `set` keys are:
`peer-ip`, `local-ip`, `gre-local`, `gre-remote`, `tunnel-port`, `ports`,
`target`, `mtu`, `ttl`.

Useful environment variables:
`GFT_ROLE`, `GFT_LOCAL_PUBLIC`, `GFT_PEER_PUBLIC`,
`GFT_PORTS`, `GFT_CTRL_PORT`, `GFT_GRE_LOCAL`,
`GFT_GRE_REMOTE`, `GFT_LOCAL_TARGET_IP`, `GFT_TOKEN` (your own frp
secret, must be identical on both servers), `GFT_TCP_CC`, `GFT_TUNE_NETWORK`,
`GFT_UPDATE_REF`, `GFT_NONINTERACTIVE=1`,
`GFT_DRY_RUN=1` (print every change without touching the host).

---

## Safety

* **ACCEPT-only firewall rule engine** — it adds the rules it needs and never
  drops or rejects anything, so it cannot lock you out of SSH. Rules carry the
  comment `gft-tunnel` and are removed again by `uninstall`.
* **SSH guard** — tunnelling the SSH port (from `sshd_config` or 22) is refused
  unless you explicitly set `GFT_ALLOW_SSH_PORT=1`.
* **Control channel over the tunnel** — `frps` binds to the tunnel address, so
  the control port is not exposed publicly.
* **Shared secret** — `auth.token` is derived from the (order-independent)
  pair of public IPs, so both servers compute the same value on their own with
  no copy/paste step. Show it with `gft frp token`, or set your own
  with `GFT_TOKEN=…` on both servers.
* Works alongside `ufw`, plain `iptables` and `firewalld` (direct rules).

---

## Testing

The project ships a hermetic smoke test suite — no root, no network, no
firewall changes: every privileged command is replaced by a logging stub.

```bash
bash test/smoke.sh                 # both roles + the CLI, ~300 assertions
SECTIONS="set tui update perf" bash test/smoke.sh   # run a subset
QUIET=1 bash test/smoke.sh         # failures only
```

It covers the full install for both roles, GRE creation and persistence, MTU/TTL
autotuning (including lossy and ICMP-filtered paths), port management, the SSH
guard, frp install/update/checksum failures, the three firewall backends,
idempotency of a second install, dry-run mode, the service helpers, uninstall,
**`set`**-ing every setting after the install, the **full-screen menu**
(scripted, including the submenus), the **GitHub self-update** flow and the
**performance/lightness** guards (BBR drop-in, header cost). CI runs it on every
push (see `.github/workflows/ci.yml`).

---

## Troubleshooting

```bash
sudo gft test
ip -d link show gft0
ping -M do -s 1448 10.99.99.2        # fragmentation check from Iran
sudo journalctl -u frps -n 50        # or -u frpc on the foreign server
sudo tail -f /var/log/gft-tunnel/optimize.log
```

* **The tunnel is down after configuring only one side** — expected. The GRE
  link comes up as soon as the other server is configured, and the hourly
  optimizer tunes it then.
* **High ping / packet loss** — run `gft optimize` and look at the loss column.
  If the path MTU is lower than your provider's, the MTU drops automatically.
* **Port not reachable from clients** — `gft test` on the Iranian server shows
  whether `frps` is listening; make sure the panel really listens on the foreign
  server at the requested port.
* **Iranian IP changed / the foreign server must follow it** — on the foreign
  server run `sudo gft set peer-ip <new Iran IP>`; the link, the firewall and the
  tunnel IPs are rebuilt in one step.
* **Public IP not detected** — set it by hand; the wizard asks for the correct
  IP whenever the detection looks wrong (`GFT_LOCAL_PUBLIC` in unattended mode).
* **Reboot lost the tunnel** — `systemctl status gft-tunnel` and
  `systemctl list-timers | grep gft-tunnel`.

---

## Requirements

Two Linux servers with public IPv4 addresses, one in Iran and one abroad.
Root access, `systemd`, kernel GRE support (built in or as `ip_gre`), and outbound
access to GitHub for the frp download. Debian/Ubuntu, RHEL/Fedora/Alma/Rocky,
Alpine, Arch and openSUSE are supported.

## License

MIT — see [LICENSE](LICENSE). frp itself is licensed by its own authors.
