# install-arch 🚀

Automated, opinionated provisioning of an [Arch Linux](https://archlinux.org) system with encrypted LVM, user creation, dotfiles, and optional desktop packages — driven by a single interactive script: `install-arch.sh`.

[![CI](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml/badge.svg)](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml)

## Quick Start 🔧

Boot the Arch Linux live ISO, bring up networking, then:

```bash
curl -sL https://git.io/vpvGR | bash
```

Interactive prompts (via `dialog`) cover: mode, hostname, user/password, disk encryption password, target disk, and (when relevant) NVIDIA driver choice. Output is logged to `stdout.log` and `stderr.log`.

## Modes 🧩

| Mode | Purpose | Extras |
|------|---------|--------|
| Minimal (1) | Fast CLI workstation base | Core tooling + modern CLI utilities |
| Workstation (2) | Lightweight X11 + tiling WM | Desktop + optional NVIDIA + paru AUR helper |
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
9. Install paru AUR helper (for user package management)
10. Create user (zsh, wheel, docker); fetch dotfiles & bootstrap
11. Initramfs + GRUB (encrypted root params)
12. Cleanup (unmount, swapoff)

## Noteworthy Packages 📦

Only highlighting the distinctive ones — the usual Arch base is assumed:

**Core System:**
* Encryption & LVM stack: `cryptsetup`, `lvm2`
* Boot: `efibootmgr`, `grub`
* Shell: `zsh` (set as default) & `dash` (symlinked to `/bin/sh` via hook)
* Dev / tooling: `docker`, `neovim`, `tmux`, `shellcheck`

**Modern CLI Utilities (Minimal mode):**
* `bat` - cat with syntax highlighting
* `btop` - modern resource monitor
* `eza` - modern ls replacement
* `fd` - modern find replacement
* `ripgrep` - fast grep alternative
* `fzf` - fuzzy finder
* `git-delta` - better git diffs
* `lazygit` - terminal git UI
* `zoxide` - smarter cd
* `duf` - modern df

**Desktop (Workstation modes):**
* Window Manager: `xmonad`, `xmonad-contrib`
* Terminal: `alacritty`, `rxvt-unicode`
* Browser: `chromium`
* Launcher: `rofi` 
* Compositor: `picom`
* Screenshot: `flameshot`
* Fonts: `adobe-source-code-pro-fonts`, `noto-fonts-cjk`, `noto-fonts-emoji`
* Theme: `papirus-icon-theme`

**AUR Helper:**
* `paru` - Installed for user package management (pinned to specific commit for security)

**VirtualBox mode:**
* `virtualbox-guest-utils`

## Disk Layout 💽

Example (`/dev/sda`):
* `/dev/sda1` → EFI (FAT32) mounted at `/boot`
* `/dev/sda2` → LUKS2 container → VG `volgroup0` with LV `swap` (1G) + `root` (rest)

GRUB passes `cryptdevice=<partition>:volgroup0` to unlock at boot.

## Dotfiles 🎨

Integrates with [sneivandt/dotfiles](https://github.com/sneivandt/dotfiles):
* Minimal: `dotfiles.sh -I --profile arch`
* Workstation / VirtualBox: `dotfiles.sh -I --profile arch-desktop`

The dotfiles repository provides profile-based configuration for shell environments (zsh, bash), editors (neovim, VS Code), window managers (xmonad), and more.

## Customize ✏️

Consider editing before running:
* Timezone (`US/Pacific` hardcoded)
* Mirror country (currently US)
* Swap size (1G)
* Package selections in `packages` and `packages_gui` arrays
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
* Package installation issues → check internet connection and mirrors
* No NVIDIA prompt → device not detected (falls back to generic driver)

## Development 🧪

### CI/CD

This repository uses GitHub Actions for continuous integration:
* **ShellCheck Analysis**: Validates shell script quality and catches common errors
* **Arch Linux Testing**: Verifies script runs in an Arch Linux container
* **Syntax Validation**: Ensures script has no syntax errors

Run checks locally:
```bash
# Check script syntax
bash -n install-arch.sh

# Run shellcheck (requires shellcheck package)
shellcheck install-arch.sh
```

### Contributing

See [.github/copilot-instructions.md](.github/copilot-instructions.md) for detailed shell scripting guidelines and code standards used in this project.