# install-arch

[![CI](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml/badge.svg)](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml)

[`install-arch.sh`](install-arch.sh) is an opinionated, semi-interactive Arch Linux installer for a fresh UEFI machine. It provisions an encrypted LVM system, installs a practical CLI or Hyprland workstation package set, creates the primary user, applies dotfiles, configures boot, and leaves the system ready for first boot.

It is designed for one specific installation style rather than every possible Arch layout: full-disk install, LUKS2 encryption, LVM root/swap, GRUB on UEFI, NetworkManager, systemd-resolved, UFW, fail2ban, Docker, zsh, and the author's dotfiles.

> [!WARNING]
> This installer permanently erases the selected target disk. It does not support preserving existing partitions, dual boot, or in-place upgrades.

## Quick start

Boot the Arch Linux live ISO in UEFI mode, connect to the internet, then run from the root shell:

```bash
curl -sL https://git.io/vpvGR | bash
```

The installer prompts for install mode, hostname, username, user password, target disk, disk encryption password, and NVIDIA driver choice when NVIDIA hardware is detected in a desktop mode. Runtime logs are written to `stdout.log` and `stderr.log` after password collection is complete.

## Install modes

| Mode | Use when | Adds |
| --- | --- | --- |
| `1` Minimal | You want a fast CLI-first system | Base Arch packages, development tools, modern terminal utilities, Docker, zsh, and the `base` dotfiles profile |
| `2` Workstation | You want the full desktop setup | Minimal mode plus Hyprland, Wayland desktop utilities, Chromium, audio tools, fonts, themes, optional NVIDIA driver, and the `desktop` dotfiles profile |
| `3` VirtualBox | You want the workstation setup inside VirtualBox | Workstation mode plus `virtualbox-guest-utils` and `vboxservice.service` |

## What it installs

The base package set includes:

- **System:** `base`, `base-devel`, `linux`, `linux-lts`, headers for both kernels, `linux-firmware`, `grub`, `efibootmgr`, `lvm2`, `sudo`
- **Security and networking:** `networkmanager`, `openssh`, `ufw`, `fail2ban`, `reflector`, `pacman-contrib`
- **Development and CLI tools:** `git`, `curl`, `wget`, `neovim`, `vim`, `tmux`, `shellcheck`, `rustup`, `jq`, `ctags`
- **Modern terminal utilities:** `bat`, `btop`, `duf`, `eza`, `fd`, `fzf`, `git-delta`, `lazygit`, `ripgrep`, `zoxide`
- **Shell:** `zsh`, `zsh-autosuggestions`, `zsh-completions`, `zsh-syntax-highlighting`, with `dash` linked as `/bin/sh`

Desktop modes add Hyprland and the surrounding Wayland stack: `hyprland`, `uwsm`, `waybar`, `alacritty`, `fuzzel`, `mako`, `hyprpaper`, `hyprlock`, `hypridle`, `grim`, `slurp`, `wl-clipboard`, `gammastep`, `playerctl`, `chromium`, `alsa-utils`, `qt5-wayland`, `qt6-wayland`, `xorg-xwayland`, `otf-font-awesome`, and `papirus-icon-theme`.

When CPU vendor detection succeeds, the installer also adds `intel-ucode` or `amd-ucode`.

## Disk layout

For a target such as `/dev/sda`, the installer creates:

| Device | Purpose |
| --- | --- |
| `/dev/sda1` | 512 MiB EFI system partition, FAT32, mounted at `/boot` |
| `/dev/sda2` | LUKS2 container opened as `/dev/mapper/cryptlvm` |
| `volgroup0/swap` | 1 GiB swap logical volume |
| `volgroup0/root` | Ext4 root logical volume using the remaining space |

GRUB is installed for `x86_64-efi` and configured with `cryptdevice=UUID=<luks-partition-uuid>:cryptlvm root=/dev/mapper/volgroup0-root`. Both `linux` and `linux-lts` initramfs images are built with encryption and LVM hooks.

## System configuration

After package installation, the script configures:

- Hostname, `/etc/hosts`, `en_US.UTF-8`, and timezone `US/Pacific`
- NetworkManager with DNS delegated to systemd-resolved
- systemd-resolved using Google DNS, Cloudflare fallback DNS, DNSSEC `allow-downgrade`, and opportunistic DNS-over-TLS
- UFW defaults: deny incoming, allow outgoing, then enable firewall
- fail2ban for SSH using the systemd journal backend
- Weekly reflector mirror updates and weekly fstrim
- Pacman color/candy, a package-cache cleanup hook keeping the last five package versions, and a hook that keeps `/bin/sh` linked to `dash`
- Baseline kernel and network hardening in `/etc/sysctl.d/99-security.conf`
- A primary user in the `wheel` and `docker` groups with zsh as the login shell
- Locked root password and `/sbin/nologin` for the root account
- Password-required sudo for `wheel` after dotfiles bootstrap finishes

## Dotfiles

The installer integrates with [sneivandt/dotfiles](https://github.com/sneivandt/dotfiles). It clones the repository to `/home/<user>/src/dotfiles`, validates the selected profile, then applies it as the target user:

| Install mode | Dotfiles profile |
| --- | --- |
| Minimal | `base` |
| Workstation | `desktop` |
| VirtualBox | `desktop` |

The installer temporarily grants passwordless sudo to `wheel` while dotfiles are applied, removes that temporary sudoers file afterward, and replaces it with normal password-required `wheel` sudo.

## Requirements

- Arch Linux live ISO booted in UEFI mode
- Root privileges
- Working internet connection
- One whole target disk of at least 10 GiB, with 20 GiB or more recommended
- No requirement to preserve data on the target disk

Before starting, confirm the live ISO is booted in UEFI mode:

```bash
test -d /sys/firmware/efi/efivars && echo "UEFI mode confirmed"
```

## Customizing before install

This project intentionally bakes in personal defaults. Review and edit `install-arch.sh` before running if you want different values for:

- Timezone: `US/Pacific`
- Mirror country: `US`
- Swap size: `1G`
- DNS servers and DNSSEC/DNS-over-TLS policy
- Package arrays: `packages`, `packages_gui`, `packages_vbox`
- Enabled services and firewall rules
- Sysctl hardening settings
- Dotfiles repository, install path, or profile mapping

## Test and dry-run modes

`--dry-run` prints the commands and file writes that would be performed without mutating the host:

```bash
./install-arch.sh --dry-run --test-mode
```

`--test-mode` bypasses interactive prompts and reads values from environment variables:

```bash
TEST_MODE_MODE="1" \
TEST_MODE_HOSTNAME="testhost" \
TEST_MODE_USER="testuser" \
TEST_MODE_PASSWORD="testpass123" \
TEST_MODE_DEVICE="/dev/loop0" \
TEST_MODE_LUKS_PASSWORD="lukspass123" \
./install-arch.sh --test-mode --dry-run
```

For desktop dry runs, `TEST_MODE_VIDEO_DRIVER` can be set to `nvidia-open`, `nvidia`, or left empty.

## Development

Run the smallest check that covers your change:

```bash
bash -n install-arch.sh test/*.sh
shellcheck install-arch.sh test/*.sh
./test/unit_tests.sh
```

[`test/unit_tests.sh`](test/unit_tests.sh) covers validation helpers, package-list naming, script syntax, executable permissions, and dry-run dotfiles bootstrap output.

The integration test requires root and a system where loop devices are available:

```bash
sudo ./test/integration_test.sh
```

Current CI runs ShellCheck, unit tests, a privileged Arch container integration test, syntax checks, executable permission checks, and dry-run flag coverage. [`test/integration_test.sh`](test/integration_test.sh) creates a loop-backed disk image and exercises dry-run/test-mode behavior; it does not perform a full Arch installation with real `pacstrap` and `arch-chroot` execution.
