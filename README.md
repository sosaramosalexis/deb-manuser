# deb-renameuser

**Interactive Debian username changer** — rename a user account, move home, update permissions, all through a whiptail interface.

## Quick Start

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sosramalex/deb-renameuser/main/renameuser.sh)
```

## What it does

- Changes login name (`usermod -l`)
- Renames matching group (`groupmod -n`)
- Moves home directory (`usermod -d -m`)
- Fixes file ownership
- Updates mail spool
- Preserves UID/GID (file permissions stay intact)

## Requirements

- Debian / Ubuntu (or any apt-based distro)
- `whiptail` (usually pre-installed)
- Run as `root`
