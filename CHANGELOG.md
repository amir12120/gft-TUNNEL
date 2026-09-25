# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-09-26

First release.

### Added
- Guided installer (`install.sh` + `gre-frp-tunnel`) that runs on both the
  Iranian relay and the foreign server, with per-distribution prerequisite
  installation (apt, dnf, yum, apk, pacman, zypper).
- Public IP detection with confirmation and manual override, plus a prompt for
  the peer server's IP; the peer IP is validated against this machine.
- Persistent GRE tunnel over IPv4 (`gre-frp`, default `10.99.99.1 ⇄ 10.99.99.2`,
  `/30`) that is recreated on boot by `gre-frp-tunnel.service`.
- MTU autotuning: path-MTU discovery with `ping -M do` (binary search), GRE
  overhead accounted for, in-tunnel verification and 8-byte step-down while
  packets are still lost.
- TTL autotuning: hop-count floor plus loss measurement over the tunnel for the
  standard outer TTL values.
- Hourly `gre-frp-tunnel-optimize.timer` that re-runs both tuners and a watchdog
  that recreates the link if the peer stops answering.
- Reverse FRP tunnel over the GRE link: `frps` on Iran (bound to the tunnel
  address), `frpc` on the foreign server, one TCP **and** one UDP proxy per
  requested port.
- frp is always installed from the newest `fatedier/frp` release (API with a
  redirect fallback), SHA-256 verified, with rollback of the previous binaries
  and a daily `gre-frp-tunnel-frpupdate.timer`.
- `udpPacketSize` pinned to fit the discovered MTU so UDP never fragments.
- ACCEPT-only firewall engine with a shared rule tag, idempotent application,
  exact-record teardown, and support for plain iptables, ufw and firewalld.
- MSS clamping (`--set-mss MTU-40`, `multiport` on the tunnelled ports) so
  relayed TCP never exceeds the tunnel MTU; the clamp follows the hourly MTU
  without stacking duplicate rules.
- `auth.token` is derived from the order-independent pair of public IPs, so both
  servers agree on it without a manual copy step (`GRE_FRP_TOKEN` overrides it,
  `gre-frp-tunnel frp token` shows it).
- SSH guard that refuses to tunnel SSH ports without an explicit override.
- CLI: `install`, `status`, `test`, `optimize`, `ports`, `frp`, `restart`,
  `logs`, `config`, `export-peer`, `firewall`, `uninstall`, plus a full-screen
  menu and a non-interactive mode (`GRE_FRP_*` environment variables).
- Hermetic smoke test suite (`test/smoke.sh`, ~250 assertions) with stubs for
  every privileged command: both roles, tuning, firewall backends, idempotency,
  dry-run, corruption/checksum failures and uninstall.
- GitHub Actions: `ci.yml` (bash syntax, ShellCheck, smoke suite) and
  `release.yml` (re-runs the smoke suite, verifies `VERSION`, publishes the
  archive and checksum).
- Documentation in English and Persian.
