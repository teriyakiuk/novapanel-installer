# Cross-distro installer hardening + smart preflight

**Status:** proposed — assess for 1.3.1
**Target:** `install.sh` (this repo). Mirror any preflight/detection changes into `NovaPanel/scripts/bootstrap.sh` (the dev installer) so the two don't drift.
**Effort:** ~half a day for the Debian/Ubuntu scope below.

---

## Why

A user installed on **Debian** and hit package failures that forced a manual install. Root cause is **not** apt-get (Debian uses apt-get too) — it's a handful of Ubuntu-isms in the installer, chiefly the PHP repo. Separately, we want an OpenPanel-style "smart preflight" panel (OS / Arch / Pkg / IP + conflict check). These are the **same feature**: a real detection layer both renders the banner and drives the distro-specific logic.

## Root cause of the Debian crash — the PHP repo

`install.sh` line ~733:

```sh
run add-apt-repository -y ppa:ondrej/php || true
```

**PPAs are Ubuntu-only.** `ppa:ondrej/php` lives on Launchpad and ships **no Debian packages**. On Debian this resolves to nothing, the `|| true` swallows the failure silently, and every later `php8.x-*` install fails "package not found" → the manual-install pain. Debian's equivalent is Ondřej Surý's **sury.org** repo (same maintainer, same builds):

```
deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $CODENAME main
# key: https://packages.sury.org/php/apt.gpg
```

## What's already distro-agnostic (leave alone)

- **PostgreSQL** (~line 511): `$(lsb_release -cs)` + pgdg serves Debian codenames → works.
- **Caddy** (cloudsmith, ~line 572): `debian.deb.txt` repo serves both → works.
- **Node.js** (nodesource, ~line 718): multi-distro → works.
- **MariaDB** (~line 672): Debian ships it natively; existing retry-guard handles the systemd-hook quirk.
- **Arch detection** (~line 580): `dpkg --print-architecture` works on Debian.
- **OS guard** (~line 252): already accepts `ubuntu|debian`.

So this is a **targeted fix, not a rewrite** — the installer is ~90% there.

## Work items

### 1. `detect_platform()` preamble (single source of truth)
Source `/etc/os-release` once, early, and export:
- `OS_ID` — `debian` | `ubuntu`
- `OS_VER` — e.g. `12`, `24.04`
- `CODENAME` — `bookworm` | `bullseye` | `jammy` | `noble` …
- `ARCH` — `dpkg --print-architecture` (`amd64`/`arm64`/`armhf`)
- `PKG` — `apt-get` (room for future)

Everything distro-specific keys off these instead of assuming Ubuntu.

### 2. PHP repo branch (the actual bug fix)
- `OS_ID=ubuntu` → `ppa:ondrej/php` (current behavior)
- `OS_ID=debian` → sury.org repo with signing key + `$CODENAME` templated in
- **Drop the silent `|| true`** — a repo-setup failure must stop loudly with a clear message, not march into broken PHP installs.

### 3. Conflict pre-check (OpenPanel-style "[ OK ]" line)
Detect and refuse/warn on:
- Other panels: cPanel (`/usr/local/cpanel`), Plesk (`/usr/local/psa`), CyberPanel, HestiaCP (`/usr/local/hestia`), Webmin (`/etc/webmin`), ISPConfig
- Web servers already bound to 80/443: existing `nginx` / `apache2` (NovaPanel runs Caddy there — real foot-gun)
- An existing NovaPanel install (re-run guard)

### 4. Banner: add Arch + Pkg rows
The preflight box (~line 278) already shows OS / Server / Memory / Disk / Kernel — render `ARCH` and `PKG` from the detected vars too. Example:

```
  ┌─────────────────────────────────────────────────┐
  │  OS:       Debian GNU/Linux 12 (bookworm)
  │  Arch:     x86_64 (amd64)
  │  Pkg:      apt-get
  │  Server:   203.0.113.10
  │  Memory:   2.0Gi  •  Disk: 38G free
  │  Kernel:   6.1.0-21-amd64
  └─────────────────────────────────────────────────┘

  [ OK ] No conflicting panels or web servers found.
```

## Scope boundary (decide before building)

- **IN: Debian + Ubuntu family** (incl. Mint, Pop!_OS) — same apt/dpkg world, ~all real VPS users. Half-day effort.
- **OUT (separate, ~5–10× bigger): RHEL/Rocky/Fedora/Arch** — different package manager (dnf/pacman), package names, service names, paths. Only if real demand appears. Keep the hard `ubuntu|debian` guard until then — and make it show *why* it's stopping (the new preflight) instead of crashing mid-install.

## Before building
- Get the Debian user's `$INSTALL_LOG` if possible — confirms PHP is the exact crash point and surfaces any second Debian-specific snag not visible from the code.
- Confirm which Debian version (11 bullseye / 12 bookworm).

## Note on competitor reference
OpenPanel's installer screenshot that inspired this *also failed* right after its banner ("Failed to download progress_bar.sh"). Takeaway: the pretty panel is good UX, but the value is the detection **driving** the install and **failing loudly** — not the cosmetics.
