# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

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
