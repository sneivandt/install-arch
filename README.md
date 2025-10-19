# install-arch 🚀

Automated, opinionated provisioning of an [Arch Linux](https://archlinux.org) system with encrypted LVM, user creation, dotfiles, and optional desktop packages — driven by a single interactive script: `install-arch.sh`.

## Quick Start 🔧

Boot the Arch Linux live ISO, bring up networking, then:

```bash
curl -sL https://git.io/vpvGR | bash
```

Interactive prompts (via `dialog`) cover: mode, hostname, user/password, disk encryption password, target disk, and (when relevant) NVIDIA driver choice. Output is logged to `stdout.log` and `stderr.log`.

## Modes 🧩

| Mode | Purpose | Extras |
|------|---------|--------|
| Minimal (1) | Fast CLI workstation base | Core tooling only |
| Workstation (2) | Lightweight X11 + tiling WM | Desktop + optional NVIDIA + curated AUR |
| VirtualBox (3) | Workstation for VM guests | Adds guest integrations |

## Flow 🗺️

1. Collect input (dialog)
2. GPT partitioning: EFI (512M) + encrypted LUKS2 container
3. LUKS2 → LVM (swap + root)
4. Format & mount
5. Fresh HTTPS mirrorlist
6. Install base + mode additions
7. System config: fstab, hostname, locale, timezone, DNS, services
8. Pacman candy + hooks (dash, cache clean, xmonad auto‑recompile)
9. Temporary AUR helper to pull notable extras (desktop modes)
10. Create user (zsh, wheel, docker); fetch dotfiles & bootstrap
11. Initramfs + GRUB (encrypted root params)
12. Cleanup (unmount, swapoff)

## Noteworthy Packages 📦

Only highlighting the distinctive ones — the usual Arch base is assumed:
* Encryption & LVM stack: `cryptsetup`, `lvm2`
* Boot: `efibootmgr`, `grub`
* Shell: `zsh` (set as default) & `dash` (symlinked to `/bin/sh` via hook)
* Dev / tooling: `docker`, `neovim`, `tmux`, `shellcheck`
* Desktop modes: `xmonad`, `xmonad-contrib`, `xmobar` (tiling WM & status bar), fonts & minimal utilities
* AUR (desktop modes): `visual-studio-code-insiders-bin`, `chromium-widevine`, `fzf`
* VirtualBox mode: `virtualbox-guest-utils`

## Disk Layout 💽

Example (`/dev/sda`):
* `/dev/sda1` → EFI (FAT32) mounted at `/boot`
* `/dev/sda2` → LUKS2 container → VG `volgroup0` with LV `swap` (1G) + `root` (rest)

GRUB passes `cryptdevice=<partition>:volgroup0` to unlock at boot.

## Dotfiles 🎨

Integrates with [sneivandt/dotfiles](https://github.com/sneivandt/dotfiles):
* Minimal: `dotfiles.sh -Ip`
* Workstation / VirtualBox: `dotfiles.sh -Ipg`

## Customize ✏️

Consider editing before running:
* Timezone (`US/Pacific` hardcoded)
* Mirror country (currently US)
* Swap size (1G)
* AUR list & desktop apps
* DNS (Google resolvers pinned + immutable)

## Security 🔐

* Full disk encryption (root + swap)
* Root locked (`nologin`)
* Sudo briefly passwordless for bootstrap then restored
* Immutable `/etc/resolv.conf` (Google DNS) — change if undesired

## Requirements ✅

* Arch Linux live ISO (UEFI target)
* Stable internet connection
* Entire target disk available (no multi‑boot support yet)

## Troubleshooting 🛠️

* Small terminal → dialog truncation: enlarge window
* Time or key errors → ensure NTP active (`timedatectl set-ntp true`)
* AUR build hiccups → retry inside installed system
* No NVIDIA prompt → device not detected (falls back to generic driver)