<p align="center">
  <img src="https://placehold.co/120x179" width="90" alt="deb-manuser logo">
  <!-- Replace src with your 784×1168 logo image (displayed at 90px wide) -->
</p>

[![GitHub](https://img.shields.io/badge/GitHub-sosaramosalexis/deb-manuser-181717?logo=github)](https://github.com/sosaramosalexis/deb-manuser)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-blue?logo=gnu-bash)]()
[![Platform](https://img.shields.io/badge/platform-Linux-blue)]()

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
