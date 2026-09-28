# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [1.3.1] — 2026-09-28

### Fixed
- **`gft doctor` no longer reports *stale link* on a healthy tunnel.** The GRE
  endpoints are now read from the live device the way a real kernel prints them
  (`link/gre <local> peer <remote>`) instead of looking for the wording only the
  test stub used. Both spellings are understood, and the parsed values are shown
  next to the stored ones.
- **A GRE link that contradicts the state file is rebuilt automatically.**
  Creating a device is a no-op while one exists, so an old `local`/`remote`
  could survive a re-install, a `gft restart` or a reboot while the device still
  looked `up` — the classic "nothing changed after the re-install". Everything
  that brings the link up (`restart`, `service-up` on boot, `optimize`, the
  hourly watchdog) now notices the disagreement, prints the reason and rebuilds
  the link from the stored values.
- Only endpoints the kernel positively reports are compared: a device created
  without a local address (NAT mode) or an iproute2 that does not spell the
  encapsulation out is never called stale, so no rebuild loops.

### Tests
- `doctor` covers the real kernel spelling (a matching link must never be called
  stale), an unreadable encapsulation, and the automatic rebuild of a mutated
  link (the old device is deleted, then recreated at the stored peer). The `ip`
  stub can now print both output formats and remembers the device's
  encapsulation.

## [1.3.0] — 2026-09-28

Simplicity release. The kernel relay is now a **plain port forward over the
address the GRE link generated** — the shape of every ordinary iptables
tunnel recipe, with nothing extra anywhere:

```
iran #   iptables -t nat -A PREROUTING -p tcp -j DNAT --to-destination 10.99.99.2
iran #   iptables -t nat -A POSTROUTING -o gft0 -j MASQUERADE
foreign #  (nothing at all)
```

### Added
- **No port list is needed any more.** `sudo gft install` accepts an empty port
  list (and `--ports=`/`GFT_PORTS` may be omitted): the relay then forwards
  **every** port. `gft set ports ""` switches an existing install to that mode.
  The SSH port (and anything in `gft set keep-local <ports>`) is always kept on
  the Iranian relay, so a catch-all forward can never lock the operator out.
- **`gft relay dnat` needs no ports and no frp.** Iran gets one DNAT per
  protocol (port-preserving), one `MASQUERADE` and one `FORWARD` accept; the
  foreign server gets at most a single **port-less** DNAT to the panel address
  and **no frp at all** — it is not downloaded or configured in this mode.
  `gft relay frp` installs frp on demand if it is missing.
- `gft set keep-local <ports>` to pin more ports to the Iranian relay.
- `gft doctor` now reports the GRE device endpoints and **fails on a stale
  link** (a device left over from an earlier configuration keeps the old
  `remote`, which looks up while nothing crosses it) with the exact fix command.

### Changed
- **Kernel mode is the default when no port list is given.** Install with a port
  list and you get the classic frp reverse tunnel; install without one and you
  get the kernel relay. `--relay=frp|dnat` (or `GFT_RELAY_MODE`) picks either
  explicitly, and the choice is now stored in the state file.
- The MSS clamp in kernel mode is one port-agnostic rule on the tunnel device
  instead of one per port, so the TCP path survives without knowing any port.
- `relay dnat|frp` removes the other mode's rules before applying its own, so
  switching back and forth can no longer stack DNAT/SNAT rules from both modes.
- `gft doctor` and `gft test` follow the active mode: in kernel mode they check
  `ip_forward` and the DNAT/MASQUERADE rules and no longer ask for a running frp
  service or a reachable frps control port (there is none).
- `gft status` prints `ALL ports` (and which ports stay local) when there is no
  port list.
- Default MTU is `1476` (1500 − the 24 byte GRE overhead) instead of `1472`,
  matching the documented overhead and the usual tunnel recipe.

### Tests
- `relay_dnat` covers both sub-modes: a configured port list (multiport DNAT +
  MASQUERADE, no per-port SNAT, port-preserving) and **no port list at all**
  (catch-all DNAT that keeps SSH local), plus the port-less rule on the foreign
  side and the clean switch back to frp. `doctor` covers the stale-link case.

## [1.2.1] — 2026-09-27

### Fixed
- **`gft update` now regenerates the frp config.** It used to reinstall the
  systemd units and restart the services but leave `/etc/frp/frpc.toml` (or
  `frps.toml`) untouched — so servers updated from older versions kept running
  with a stale config, missing every option added since (the reported symptom:
  the foreign log still said `With loginFailExit enabled` long after that
  default changed). The update path now rewrites the config and re-applies the
  firewall before restarting.

## [1.2.0] — 2026-09-27

### Added
- **`gft relay dnat|frp|show`** — a second relay mode next to frp: **kernel
  DNAT forwarding over the GRE link**. In `dnat` mode the foreign server runs
  NO frp and learns nothing about the config ports: the Iranian relay rewrites
  user traffic (`DNAT → 10.99.99.2:<port>`) into the tunnel and SNATs the
  replies back; the foreign side only forwards (plus a local DNAT to the
  panel address, loopback targets supported via `route_localnet`). Faster
  (no userspace hop) and the port list only ever lives on the Iranian side.
  The panel's SYN-ACKs are MSS-clamped in the `--sports` direction so
  upstream does not blackhole on the GRE MTU. `gft status` and `gft relay
  show` report the active mode; the mode, the NAT rules and the frp services
  are switched cleanly in both directions (both servers, `relay dnat` on
  Iran + foreign).
- The smoke suite is now ~350 assertions across 20 sections.

## [1.1.2] — 2026-09-27

Field-fix release, driven by a real deployment whose foreign frpc kept dying
with `dial tcp 10.99.99.1:40001: i/o timeout` while the internet path between
the two servers was fine.

### Added
- **`gft doctor`** — deep diagnostics that pinpoint the exact blocker: a
  stored public IP that is not on any interface (with copy-paste fix commands
  for both servers), outer path vs in-tunnel reachability, the GRE device, the
  frp service with its last journal errors, and the frps control port that
  frpc needs.
- **`gft encap fou|none`** — run the tunnel as **GRE over UDP (FOU**, UDP port
  `5555` by default, `GFT_FOU_PORT` to change, must match on both servers**)**.
  Many Iran ⇄ foreign routes silently drop raw IP protocol 47: the outer path
  pings fine but nothing crosses in-tunnel — exactly the timeout signature
  above. FOU wraps the GRE packets in UDP so they pass such filters.
- **Automatic one-shot FOU switch**: when the watchdog finds the outer path
  alive, the tunnel dead, and raw GRE in use, it rebuilds the link with FOU
  once and remembers it (`FOU_AUTOSWITCHED`) so it never flaps.

### Fixed
- **frpc no longer crash-loops systemd.** `loginFailExit = false` keeps the
  client retrying in-process when the relay is unreachable (GRE down, peer
  reinstalling) instead of exiting and triggering restart-after-restart.

### Tests
- New `doctor` section simulating a filtered-GRE route (`STUB_GRE_DEAD`):
  doctor must name the dead in-tunnel path, prescribe the FOU switch, the
  watchdog must perform the one-shot switch, and the tunnel must pass again
  after it. `frpc.toml` must carry `loginFailExit = false`.

## [1.1.1] — 2026-09-27

Hardening release: correct public-IP detection on Iranian servers, boot-order
fixes and port-collision safety.

### Fixed
- **Wrong public-IP detection (the "Iran IP is wrong" bug).** Detection relied
  on IP echo services (ipify, ifconfig.me, …) and only fell back to the route
  source address. On Iranian servers whose egress leaves through a VPN,
  proxy, CGNAT or an ISP portal, the echo services return a *different but
  valid-looking* IPv4 and the installer recorded the wrong address. The
  detection now uses, in order: (1) the source address of the default route —
  exactly the address the GRE tunnel will use as its `local` endpoint, (2) the
  first global interface address that is not loopback and not one of the
  tunnel's own addresses, (3) the echo services as a last resort. When the
  echo services disagree with the interface address the installer now warns
  loudly instead of silently writing the wrong IP.
- `net_public_ip_detect` no longer leaks its progress hints into stdout (its
  stdout is the detected address and callers captured the hints as part of it).
- **Boot-order race**: `frps.service`/`frpc.service` `Require=` the GRE unit
  but nothing pulled it in *before* them on boot; systemd could start frp
  first and frps would crash-loop binding a tunnel IP that did not exist yet.
  `gft-tunnel.service` now declares `Before=frps.service frpc.service`.
- **The foreign side no longer opens the tunnelled ports publicly.** When the
  panel target was not `127.0.0.1`, the firewall added public ACCEPT rules for
  every tunnelled port on the foreign server — contradicting the documented
  design and letting clients bypass the tunnel by hitting the foreign IP
  directly. Only the Iranian relay publishes the ports now (TCP+UDP); the
  foreign side stays reachable by the peer alone.
- **Port collision guard on the Iranian relay**: before applying the firewall,
  `gft` checks what is already bound to the tunnelled ports with `ss` and warns
  loudly when another service holds one of them (frp's own listeners are
  recognised and ignored). A held port used to silently starve the frp proxy.
- Every script ships with the executable bit set in the git index, so
  `git clone` + `sudo ./install.sh` cannot die on "Permission denied" on any
  platform, and `install.sh` verifies the `gft` command actually starts,
  falling back to a bash wrapper when the archive lost the exec bit.
- `gft update` sanitises a token-embedded git remote left behind by a piped
  install so later self-updates fetch without credentials.
- The frp configs now spell out that `udpPacketSize` **must stay identical on
  both servers** — it is the TCP/UDP synchronisation key of the tunnel.

### Tests
- New invariants: the foreign side installs **zero** public `--dport` rules
  (also asserted after `set target`), the relay's collision guard runs during
  the install, and public-IP detection prefers the route/interface source over
  IP echo services — including the egress-mismatch, no-default-route and
  no-address-at-all cases. The suite is now ~324 assertions.

## [1.1.0] — 2026-09-26

Rename to **gft-TUNNEL** with the **`gft`** command, a full-screen manager and
after-install editing.

### Changed
- **Renamed the project to `gft-TUNNEL`** — the repository, the state paths
  (`/etc/gft-tunnel`, `/var/log/gft-tunnel`, `99-gft-tunnel.conf`), the units
  (`gft-tunnel*.service`, `gft-tunnel*.timer`) and the GRE device (`gft0`).
- The CLI is now **`gft`** (a `gre-frp-tunnel` compatibility alias is still
  installed). Running `sudo gft` opens the menu.
- **Default tunnel (control) port is now `40001`** everywhere.
- The install wizard now states the default tunnel port and asks whether to keep
  it *before* asking for the tunnelled ports, and asks for the tunnelled ports
  **all at once, comma separated** (e.g. `443,8443,2053`).

### Added
- **Full-screen menu** (`gft`, opened automatically after the install) with
  install/reconfigure, edit, tunnel-port, ports, MTU/TTL, connectivity, status,
  self-update, frp update, restart, logs, config, firewall, export-peer and
  uninstall; it also works scripted (`GFT_NO_TTY=1`, stdin-driven).
- **`gft set <key> <value>` and `gft edit`** — change any tunnel setting after
  the install (peer IP, local IP, both tunnel IPs, tunnel port, ports, panel
  target, MTU, TTL). A change is validated, applied to the host and kept in sync:
  the GRE link is rebuilt, the frp config rewritten, the firewall and MSS clamp
  re-applied, MTU/TTL retuned and the services restarted. This is how a foreign
  server is repointed at a **new Iranian IP**.
- **`gft update [--force]`** — update gft-TUNNEL itself from GitHub, preserving
  (or, with `--force`, discarding) local changes, then reinstall the units and
  restart the services.
- **`gft tunnel-port`** — show or change the tunnel port on its own.
- **Network tuning**: `net.ipv4.tcp_mtu_probing = 1` plus **BBR + fq** when the
  kernel offers them (`GFT_TCP_CC=auto|bbr|cubic|none`, `GFT_TUNE_NETWORK=0|1`).
- A cheap `gft_summary` header (state-file only, no pings) so the menu opens
  instantly and stays light on RAM/CPU.

### Fixed
- `set` rebuilt the GRE link through the wrong (pre-rename) function names.
- `set mtu`/`set ttl` did not apply the new value to the device, and the MSS
  clamp record (`MSS_CLAMPED`) was not refreshed after a manual MTU change.
- `set local-ip` accepted the peer's own IP; it is now refused like `set peer-ip`.
- `update --force` now also restores a dirty checkout when it is already on the
  newest revision.
- The scripted menu now propagates menu mode out of the `menu` sub-shell, so the
  prompts opened by "Edit tunnel settings" / "Change the tunnel port" work.

### Tests
- Three new smoke sections: **`set`** (every setting changed after the install),
  the **full-screen menu** (scripted, including the submenus) and the **GitHub
  self-update** flow, plus a **speed/lightness** guard (BBR drop-in, header cost).
  The suite is now ~300 assertions.
- The `sysctl` stub answers capability queries, the iptables stub is
  table-aware (filter/mangle) and the self-update test builds its own bare origin.

## [1.0.0] — 2026-09-26

First release.

### Added
- Guided installer (`install.sh` + `gft-tunnel`) that runs on both the
  Iranian relay and the foreign server, with per-distribution prerequisite
  installation (apt, dnf, yum, apk, pacman, zypper).
- Public IP detection with confirmation and manual override, plus a prompt for
  the peer server's IP; the peer IP is validated against this machine.
- Persistent GRE tunnel over IPv4 (`gft0`, default `10.99.99.1 ⇄ 10.99.99.2`,
  `/30`) that is recreated on boot by `gft-tunnel.service`.
- MTU autotuning: path-MTU discovery with `ping -M do` (binary search), GRE
  overhead accounted for, in-tunnel verification and 8-byte step-down while
  packets are still lost.
- TTL autotuning: hop-count floor plus loss measurement over the tunnel for the
  standard outer TTL values.
- Hourly `gft-tunnel-optimize.timer` that re-runs both tuners and a watchdog
  that recreates the link if the peer stops answering.
- Reverse FRP tunnel over the GRE link: `frps` on Iran (bound to the tunnel
  address), `frpc` on the foreign server, one TCP **and** one UDP proxy per
  requested port.
- frp is always installed from the newest `fatedier/frp` release (API with a
  redirect fallback), SHA-256 verified, with rollback of the previous binaries
  and a daily `gft-tunnel-frpupdate.timer`.
- `udpPacketSize` pinned to fit the discovered MTU so UDP never fragments.
- ACCEPT-only firewall engine with a shared rule tag, idempotent application,
  exact-record teardown, and support for plain iptables, ufw and firewalld.
- MSS clamping (`--set-mss MTU-40`, `multiport` on the tunnelled ports) so
  relayed TCP never exceeds the tunnel MTU; the clamp follows the hourly MTU
  without stacking duplicate rules.
- `auth.token` is derived from the order-independent pair of public IPs, so both
  servers agree on it without a manual copy step (`GFT_TOKEN` overrides it,
  `gft-tunnel frp token` shows it).
- SSH guard that refuses to tunnel SSH ports without an explicit override.
- CLI: `install`, `status`, `test`, `optimize`, `ports`, `frp`, `restart`,
  `logs`, `config`, `export-peer`, `firewall`, `uninstall`, plus a full-screen
  menu and a non-interactive mode (`GFT_*` environment variables).
- Hermetic smoke test suite (`test/smoke.sh`, ~250 assertions) with stubs for
  every privileged command: both roles, tuning, firewall backends, idempotency,
  dry-run, corruption/checksum failures and uninstall.
- GitHub Actions: `ci.yml` (bash syntax, ShellCheck, smoke suite) and
  `release.yml` (re-runs the smoke suite, verifies `VERSION`, publishes the
  archive and checksum).
- Documentation in English and Persian.
