# install-arch 🚀

Automated, opinionated provisioning of an [Arch Linux](https://archlinux.org) system with encrypted LVM, user creation, dotfiles, and optional desktop packages — driven by a single interactive script: `install-arch.sh`.

[![CI](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml/badge.svg)](https://github.com/sneivandt/install-arch/actions/workflows/ci.yml)

## Table of Contents

- [Quick Start](#quick-start)
- [Modes](#modes)
- [Installation Flow](#installation-flow)
- [Noteworthy Packages](#noteworthy-packages)
- [Disk Layout](#disk-layout)
- [Dotfiles Integration](#dotfiles-integration)
- [Customization](#customization)
- [Security](#security)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
  - [Testing](#testing)
  - [CI/CD](#cicd)
  - [Contributing](#contributing)

## Quick Start

Boot the Arch Linux live ISO, bring up networking, then:

```bash
curl -sL https://git.io/vpvGR | bash
```

Interactive prompts (via `dialog`) cover: mode, hostname, user/password, disk encryption password, target disk, and (when relevant) NVIDIA driver choice. Output is logged to `stdout.log` and `stderr.log`.

> **⚠️ WARNING**: This script will **ERASE THE ENTIRE TARGET DISK**. Only run on a system where data loss is acceptable or on a fresh installation target.

## Modes

| Mode | Purpose | Extras |
|------|---------|--------|
| Minimal (1) | Fast CLI workstation base | Core tooling + modern CLI utilities |
| Workstation (2) | Lightweight X11 + tiling WM | Desktop + optional NVIDIA + paru AUR helper |
| VirtualBox (3) | Workstation for VM guests | Adds guest integrations |

**Minimal mode** provides a lean, fast command-line system perfect for servers, development machines, or users who prefer terminal-based workflows.

**Workstation mode** adds a complete desktop environment with XMonad tiling window manager, perfect for power users who want efficiency and customization.

**VirtualBox mode** is identical to Workstation but includes VirtualBox Guest Additions for seamless VM integration.

## Installation Flow

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

## Noteworthy Packages

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

## Disk Layout

Example (`/dev/sda`):
* `/dev/sda1` → EFI (FAT32) mounted at `/boot`
* `/dev/sda2` → LUKS2 container → VG `volgroup0` with LV `swap` (1G) + `root` (rest)

GRUB passes `cryptdevice=<partition>:volgroup0` to unlock at boot.

## Dotfiles Integration

Integrates with [sneivandt/dotfiles](https://github.com/sneivandt/dotfiles):
* Minimal: `dotfiles.sh -I --profile arch`
* Workstation / VirtualBox: `dotfiles.sh -I --profile arch-desktop`

The dotfiles repository provides profile-based configuration for shell environments (zsh, bash), editors (neovim, VS Code), window managers (xmonad), and more. This separation allows you to maintain your personal configurations separately from the installation script.

## Customization

Consider editing before running:
* Timezone (`US/Pacific` hardcoded)
* Mirror country (currently US)
* Swap size (1G)
* Package selections in `packages` and `packages_gui` arrays
* DNS (Google resolvers pinned + immutable)

## Security

This installation prioritizes security with multiple layers of protection:

* **Full disk encryption** (root + swap) using LUKS2
* **Root account locked** (`nologin`) - preventing direct root login
* **Sudo briefly passwordless** for bootstrap, then restored to require password
* **Immutable `/etc/resolv.conf`** (Google DNS) — change if undesired
* **User isolation** - regular user account with sudo access via wheel group
* **Modern encryption** - LUKS2 with strong defaults

> **Note**: The immutable DNS configuration uses Google's public DNS servers (8.8.8.8, 8.8.4.4). To change DNS servers after installation:
> 1. Remove immutable attribute: `chattr -i /etc/resolv.conf`
> 2. Edit the file with your preferred DNS: `echo "nameserver 1.1.1.1" > /etc/resolv.conf`
> 3. Optionally restore immutability: `chattr +i /etc/resolv.conf`

## Requirements

* **Arch Linux live ISO** (UEFI target required)
* **Stable internet connection** for package downloads
* **Entire target disk available** (no multi‑boot support yet)
* **Minimum disk space**: 20GB recommended (10GB absolute minimum)
* **UEFI firmware** (Legacy BIOS not supported)

> **Important**: Ensure your system supports UEFI boot mode. Most modern systems (2012+) support UEFI, but older hardware may not.
> 
> **Verify UEFI mode**: Before starting installation, confirm you're booted in UEFI mode by checking if the directory exists:
> ```bash
> ls /sys/firmware/efi && echo "UEFI mode confirmed" || echo "Not in UEFI mode"
> ```

## Troubleshooting

### Common Issues

* **Small terminal → dialog truncation**: Enlarge window or use larger virtual console
* **Time or key errors**: Ensure NTP active: `timedatectl set-ntp true`
* **Package installation issues**: 
  - Check internet connection: `ping archlinux.org`
  - Verify mirror list: `cat /etc/pacman.d/mirrorlist`
  - Update keyring: `pacman -Sy archlinux-keyring`
* **No NVIDIA prompt**: Device not detected (falls back to generic driver)
* **Boot fails after installation**: 
  - Verify GRUB installation completed
  - Check BIOS/UEFI settings for boot order
  - Ensure LUKS password is correct
* **Dialog crashes or doesn't display**: Terminal too small, resize to at least 80x24

### Getting Help

1. Check the logs: `stdout.log` and `stderr.log` in the current directory
2. Review error messages carefully - they usually indicate the specific issue
3. Open an issue on GitHub with:
   - Full error message
   - Contents of log files
   - Hardware details (especially for disk/NVIDIA issues)
   - Mode selected and any customizations made

## Development

### Testing

This project includes comprehensive testing to ensure reliability:

#### Unit Tests
Unit tests validate individual functions and logic without requiring actual system operations:

```bash
# Run unit tests
./tests/unit_tests.sh
```

Tests cover:
- Input validation (hostname, username, password)
- Device detection and naming (NVMe vs SATA/SSD)
- Partition naming logic
- Package name validation
- Configuration file syntax

#### Integration Tests
Integration tests simulate a real installation using loop devices:

```bash
# Run integration test (requires root)
sudo ./tests/integration_test.sh
```

The integration test:
- Creates a virtual disk using a loop device
- Runs `install-arch.sh` in dry-run and test modes against the loop device
- Validates script syntax, option parsing, and flag acceptance (including partitioning, encryption, and LVM flags) without modifying real disks
- Runs in a safe, isolated environment without performing destructive changes

#### Test Modes

The `install-arch.sh` script supports special modes for testing:

**Dry-Run Mode**: Simulates operations without making changes
```bash
./install-arch.sh --dry-run --test-mode
```

**Test Mode**: Uses environment variables instead of interactive prompts
```bash
export TEST_MODE_MODE="1"
export TEST_MODE_HOSTNAME="testhost"
export TEST_MODE_USER="testuser"
export TEST_MODE_PASSWORD="testpass"
export TEST_MODE_DEVICE="/dev/loop0"
export TEST_MODE_LUKS_PASSWORD="lukspass"
./install-arch.sh --test-mode
```

### CI/CD

This repository uses GitHub Actions for continuous integration:
* **ShellCheck Analysis**: Validates shell script quality and catches common errors
* **Unit Tests**: Runs the full unit test suite on every push/PR
* **Integration Test**: Simulates installation in a Docker container with loop devices
* **Arch Linux Testing**: Verifies script runs in an Arch Linux container
* **Syntax Validation**: Ensures script has no syntax errors

Run checks locally:
```bash
# Check script syntax
bash -n install-arch.sh

# Run shellcheck (requires shellcheck package)
shellcheck install-arch.sh

# Run all tests
./tests/unit_tests.sh
sudo ./tests/integration_test.sh  # Requires root
```

### Contributing

Contributions are welcome! Please:

1. **Read the guidelines**: See [.github/copilot-instructions.md](.github/copilot-instructions.md) for detailed shell scripting guidelines and code standards
2. **Fork and branch**: Create a feature branch from `main`
3. **Follow conventions**: 
   - Shell script best practices (quote variables, use set options)
   - ShellCheck must pass with no warnings
   - Follow existing code style
4. **Test thoroughly**:
   - Run unit tests: `./tests/unit_tests.sh`
   - Run integration tests: `sudo ./tests/integration_test.sh`
   - Test in a VM for destructive changes
5. **Submit a PR**: Use the pull request template and fill out all sections
6. **Be patient**: Reviews may take time, especially for security-critical changes

### Code Standards

- All shell scripts must pass ShellCheck analysis
- Quote all variables to prevent word splitting
- Use `set -o errexit`, `set -o nounset`, `set -o pipefail`
- Add error traps with line numbers
- Validate all user input
- Test in isolated environments (never on production systems)
- Document complex logic with comments
- Keep changes minimal and focused

### Development Workflow

```bash
# Clone the repository
git clone https://github.com/sneivandt/install-arch.git
cd install-arch

# Create a feature branch
git checkout -b feature/my-feature

# Make changes and test
./tests/unit_tests.sh                    # Unit tests
sudo ./tests/integration_test.sh         # Integration tests
shellcheck install-arch.sh               # ShellCheck analysis
bash -n install-arch.sh                  # Syntax check

# Test in a VM
# (Use VirtualBox, QEMU, or your preferred virtualization)

# Commit and push
git add .
git commit -m "feat: Add new feature"
git push origin feature/my-feature

# Open a pull request on GitHub
```

## License

See [LICENSE](LICENSE) file for details.

## Acknowledgments

- Arch Linux community for excellent documentation
- All contributors who have helped improve this script
- Dialog utility for the interactive TUI interface