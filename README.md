<p align="center">
  <img src="https://img.shields.io/badge/shell-blue?logo=bash&style=flat-square" alt="Shell">
</p>

# deb-manuser

**All-in-one Debian user manager** — create, delete, rename users, manage sudo, and fix path permissions — all through a whiptail interactive UI.

## Quick Start

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-manuser/main/renameuser.sh)
```

## Features

| Option | Description |
|--------|-------------|
| **Create user** | Set username, full name, shell, groups, password, home dir |
| **Delete user** | Pick from user list, optionally remove home directory |
| **Rename user** | Change login name, move home, rename group, update mail |
| **Manage sudo** | Grant or remove sudo access for any user |
| **Path permissions** | Fix ownership/permissions on a user's home or any path |

## Requirements

- Debian / Ubuntu (or any apt-based distro)
- `whiptail` (usually pre-installed)
- Run as `root`
