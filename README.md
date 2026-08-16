# install-arch

An opinionated, semi-interactive installer for a fresh Arch Linux system. It
creates an encrypted LVM installation, configures GRUB, creates a primary user,
and installs either a CLI environment or a Hyprland workstation.

This project targets one specific setup. It is not a general-purpose Arch
installer.

> [!CAUTION]
> A normal installation erases the entire selected disk. It does not support
> dual boot, preserving existing partitions, or upgrading an existing system.
> The explicit `--resume` path only reopens and validates this installer's
> existing layout; it does not repartition or format the disk.

## Requirements

Run the installer from the Arch Linux live ISO with:

- UEFI boot mode
- Root access
- A working internet connection
- A dedicated target disk of at least 10 GiB (20 GiB or more recommended)
- Nothing mounted at `/mnt`

Confirm that the live ISO was booted in UEFI mode:

```bash
test -d /sys/firmware/efi/efivars && echo "UEFI mode confirmed"
```

Review the available disks before continuing:

```bash
lsblk -d -o NAME,SIZE,MODEL
```

## Run the installer

From the root shell in the live environment:

```bash
curl -fsSL https://git.io/vpvGR | bash
```

At startup, the installer initializes and populates pacman's Arch Linux keyring,
then installs or updates `archlinux-keyring` before installing `dialog` or any
other installer dependency. It stops with an error if the trusted keyring cannot
be prepared; package signature verification remains enabled.

The installer asks for:

1. Install mode
2. Hostname
3. Username and password
4. Target disk
5. Disk encryption password
6. NVIDIA driver, when supported hardware is detected in a desktop mode

Before changing the disk, it shows the selected device and requires
confirmation. Interactive prompts use the controlling terminal directly, so
they work whether the script is piped to Bash, run through process substitution,
or executed from a file. During installation, clear `==> Stage: ...` markers
separate major operations while commands such as `pacstrap`, filesystem tools,
`mkinitcpio`, and GRUB keep their normal stdout/stderr attached to the terminal.

Separately, the installer writes a diagnostic trace from startup to
`/tmp/install-arch-debug.log`. It records high-level installer checkpoints,
named configuration operations and failures, and, for every dialog, its logical
name, widget type, dimensions, option count, entry/exit state, exit status, and
whether captured output was empty. Password and encryption passphrase contents
are never written to this trace. If an interactive run appears stuck, press
`Ctrl+C` and inspect the preserved trace:

```bash
cat /tmp/install-arch-debug.log
```

### Resume after package installation

If target-system configuration fails after `pacstrap`, cleanup leaves the disk
unmounted and closes the installer-owned LVM and LUKS mappings. Retry from the
same Arch ISO environment without repartitioning, formatting, or reinstalling
packages with:

```bash
curl -fsSL https://git.io/vpvGR | bash -s -- --resume
```

Select the same mode and target disk and enter the same encryption passphrase.
Resume mode validates the existing EFI partition, LUKS container, expected
`volgroup0/root` and `volgroup0/swap` volumes, and the pacstrapped Arch base
system before rerunning target configuration. It regenerates `fstab`
atomically, so retrying does not append duplicate entries. If validation does
not match this installer's layout, resume stops without formatting anything.

## Install modes

| Mode | Description | Dotfiles profile |
| --- | --- | --- |
| `1` Minimal | CLI system with development tools, Docker, zsh, and modern terminal utilities | `base` |
| `2` Workstation | Minimal mode plus Hyprland, Wayland utilities, Chromium, PipeWire media support with PulseAudio as the active server, fonts, and optional NVIDIA drivers | `desktop` |
| `3` VirtualBox | Workstation mode plus VirtualBox guest utilities and `vboxservice.service` | `desktop` |

All modes install Arch's current `linux` kernel and matching headers. This
package tracks the latest stable kernel in the Arch repositories; no LTS kernel
is installed. The installer also adds Intel or AMD microcode when it can
identify the CPU vendor.

Package definitions are maintained in the `BASE_PACKAGES`, `GUI_PACKAGES`, and
`VBOX_PACKAGES` arrays in [`install-arch.sh`](install-arch.sh).

## Disk layout

For a disk such as `/dev/sda`, the installer creates:

| Device | Purpose |
| --- | --- |
| `/dev/sda1` | 512 MiB FAT32 EFI system partition mounted at `/boot` |
| `/dev/sda2` | LUKS2 encrypted partition opened as `cryptlvm` |
| `volgroup0/swap` | Dynamically sized swap logical volume |
| `volgroup0/root` | Ext4 root logical volume using the remaining space |

NVMe, MMC, and loop devices use partition names such as `/dev/nvme0n1p1`.

Swap is sized from physical memory: twice RAM for systems with up to 2 GiB,
equal to RAM from 2-8 GiB, and capped at 8 GiB above that. On small disks it is
reduced to preserve at least approximately 8 GiB for the root filesystem. This
policy is intended for normal memory pressure, not hibernation.

GRUB is installed for UEFI and configured to unlock the encrypted LVM root
volume during boot.

## System configuration

The installer configures:

- NetworkManager and systemd-resolved
- UFW and fail2ban
- Weekly reflector and filesystem trim timers
- Pacman package-cache cleanup
- Baseline kernel and network hardening
- A primary user in the `wheel` and `docker` groups
- zsh as the user's login shell
- A locked root account

It clones [sneivandt/dotfiles](https://github.com/sneivandt/dotfiles) to
`/home/<user>/src/dotfiles`, validates the profile for the selected mode, and
then applies it as the new user. Passwordless `wheel` sudo is enabled only
during this bootstrap; normal password-required sudo is restored afterward.

On `--resume`, an existing intended user is verified and reconciled instead of
being recreated. The installer restores the expected home path, primary group,
`wheel`/`docker` memberships, zsh login shell, password, and top-level home
ownership without moving or overwriting existing home contents. A matching
dotfiles checkout is reused; an unrelated directory or checkout is left intact
and reported as an error.

## Opinionated defaults

Review [`install-arch.sh`](install-arch.sh) before installing if you want to
change any of these defaults:

| Setting | Default |
| --- | --- |
| Timezone | `US/Pacific` |
| Mirror country | `US` |
| Swap size | RAM-based, 1-8 GiB depending on memory and disk capacity |
| Bootloader | GRUB |
| Encryption | LUKS2 with LVM |
| DNS | Google DNS with Cloudflare fallback |
| Desktop | Hyprland on Wayland |
| Dotfiles | `sneivandt/dotfiles` |

The script also contains the enabled services, firewall policy, sysctl
settings, package lists, and dotfiles profile mapping.

## Dry run and test mode

`--dry-run` skips the installer's disk and target-system changes. Combine it
with `--test-mode` to avoid interactive setup and supply test values.
`--test-mode` requires `--dry-run` by default:

```bash
TEST_MODE_MODE="1" \
TEST_MODE_HOSTNAME="testhost" \
TEST_MODE_USER="testuser" \
TEST_MODE_PASSWORD="testpass123" \
TEST_MODE_DEVICE="/dev/loop0" \
TEST_MODE_LUKS_PASSWORD="lukspass123" \
./install-arch.sh --test-mode --dry-run
```

For workstation and VirtualBox dry runs, set `TEST_MODE_VIDEO_DRIVER` to
`nvidia-open`, `nvidia`, or an empty value.

Destructive test mode is reserved for disposable loop devices. It requires
every `TEST_MODE_*` value plus an explicit opt-in:

```bash
sudo TEST_MODE_MODE="1" \
  TEST_MODE_HOSTNAME="testhost" \
  TEST_MODE_USER="testuser" \
  TEST_MODE_PASSWORD="testpass123" \
  TEST_MODE_DEVICE="/dev/loop0" \
  TEST_MODE_LUKS_PASSWORD="lukspass123" \
  ./install-arch.sh --test-mode --allow-destructive-test-mode
```

Never use that flag with a physical disk. The installer rejects non-loop
devices in destructive test mode.

## Development

Run the local checks with:

```bash
bash -n install-arch.sh test/*.sh
shellcheck install-arch.sh test/*.sh
./test/unit_tests.sh
```

The loop-device integration test requires root:

```bash
sudo ./test/integration_test.sh
```

Unit tests source the production installer helpers and package arrays instead
of maintaining test-only copies. The integration test creates an isolated loop
device, exercises dry-run and test-mode behavior, and cleans up only the loop
device and temporary image it created. It does not run a complete installation
with real `pacstrap` and `arch-chroot` operations.
