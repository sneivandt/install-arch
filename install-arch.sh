#!/usr/bin/env bash
# Arch Linux semi-interactive installer.
#
# Run from Arch live ISO as root. Collects minimal input (mode, disk, hostname,
# user, passwords) then automates: partitioning, LUKS2 encryption + LVM, base
# package install, optional GUI/workstation stack, user creation, dotfiles, and
# bootloader configuration.
#
# WARNING: Destroys selected disk contents completely.
# Modes:
#   1 Minimal (CLI only)
#   2 Workstation (Wayland + Hyprland + optional NVIDIA)
#   3 VirtualBox Workstation (adds guest utils)
# Logging starts only after password collection.
set -o errexit
set -o nounset
set -o pipefail

# Runtime setup

DRY_RUN=false
TEST_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --test-mode)
      TEST_MODE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--test-mode]"
      exit 1
      ;;
  esac
done

error_handler() {
  local exit_code=$?
  echo "$0: Error on line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}

cleanup() {
  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  set +o errexit
  swapoff /dev/mapper/volgroup0-swap 2>/dev/null || true
  if mountpoint -q /mnt 2>/dev/null; then
    umount -R /mnt 2>/dev/null || true
  fi
  if [ -e /dev/volgroup0/root ] || [ -e /dev/mapper/volgroup0-root ]; then
    vgchange -an volgroup0 2>/dev/null || true
  fi
  if [ -e /dev/mapper/cryptlvm ]; then
    cryptsetup close cryptlvm 2>/dev/null || true
  fi
}

# Report the failing command and release any partially-mounted target system.
trap error_handler ERR
trap cleanup EXIT

# The interactive path depends on dialog before package installation begins.
if [ "$TEST_MODE" = "false" ]; then
  if [ "$EUID" -ne 0 ]; then
    echo "Error: This installer must be run as root from the Arch Linux live ISO."
    exit 1
  fi
  if [ "$DRY_RUN" = "false" ] && [ ! -d /sys/firmware/efi/efivars ]; then
    echo "Error: UEFI boot mode is required. Reboot the installer media in UEFI mode."
    exit 1
  fi
  if ! pacman -Sy --noconfirm dialog; then
    echo "Error: Failed to install dialog. Cannot proceed with interactive installation."
    echo "Check your internet connection and try again."
    exit 1
  fi
fi

# Command helpers keep dry-run output and chroot execution consistent.
run_cmd() {
  if [ "$DRY_RUN" = "true" ]; then
    # Use %q to show a shell-escaped representation of each argument,
    # preserving spaces and special characters.
    printf '[DRY-RUN] Would execute:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

dry_run_msg() {
  echo "[DRY-RUN] $*"
}

in_target() {
  run_cmd arch-chroot /mnt "$@"
}

as_user() {
  in_target runuser -u "$user" -- env HOME="/home/$user" USER="$user" LOGNAME="$user" "$@"
}

write_file() {
  local path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would write $path"
  else
    mkdir -p "${path%/*}"
    cat > "$path"
  fi
}

append_file() {
  local path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would append to $path"
  else
    mkdir -p "${path%/*}"
    cat >> "$path"
  fi
}

enable_services() {
  local service

  for service in "$@"; do
    in_target systemctl enable "$service"
  done
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: Required command not found: $command_name"
    exit 1
  fi
}

run_preflight_checks() {
  local required_commands=(
    arch-chroot
    awk
    blkid
    blockdev
    cryptsetup
    curl
    findmnt
    genfstab
    lsblk
    lvcreate
    mkfs.ext4
    mkfs.vfat
    mkswap
    mount
    openssl
    pacman
    pacstrap
    partx
    pvcreate
    sfdisk
    swapon
    udevadm
    vgchange
    vgcreate
    vgs
    wipefs
  )
  local command_name

  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ "$EUID" -ne 0 ]; then
    echo "Error: This installer must be run as root."
    exit 1
  fi

  for command_name in "${required_commands[@]}"; do
    require_command "$command_name"
  done

  if command -v timedatectl >/dev/null 2>&1; then
    if ! timedatectl set-ntp true; then
      echo "Warning: Failed to enable NTP; TLS downloads may fail if system time is wrong." >&2
    fi
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 20 https://archlinux.org/ >/dev/null; then
    echo "Error: Network check failed. Connect to the internet before running the installer."
    exit 1
  fi
}

validate_target_device() {
  local target_device="$1"
  local device_type
  local min_bytes=$((10 * 1024 * 1024 * 1024))
  local size_bytes

  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
    echo "Error: Target device '$target_device' does not exist or is not a block device."
    exit 1
  fi

  device_type="$(lsblk -dn -o TYPE "$target_device")"
  if [ "$device_type" != "disk" ] && [ "$device_type" != "loop" ]; then
    echo "Error: Target device '$target_device' is type '$device_type', not a disk."
    exit 1
  fi

  if lsblk -nr -o MOUNTPOINT "$target_device" | grep -q .; then
    echo "Error: Target device '$target_device' or one of its partitions is mounted."
    exit 1
  fi

  size_bytes="$(blockdev --getsize64 "$target_device")"
  if [ "$size_bytes" -lt "$min_bytes" ]; then
    echo "Error: Target device must be at least 10 GiB."
    exit 1
  fi
}

confirm_destructive_action() {
  local target_device="$1"
  local device_summary

  if [ "$TEST_MODE" = "true" ] || [ "$DRY_RUN" = "true" ]; then
    return
  fi

  device_summary="$(lsblk -dno NAME,SIZE,MODEL "$target_device" | sed 's/[[:space:]]\+/ /g')"
  dialog --clear --defaultno --yesno \
    "This will permanently erase all data on:\n\n$device_summary\n\nContinue?" 0 0 || exit 1
}

ensure_install_names_available() {
  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ -e /dev/mapper/cryptlvm ]; then
    echo "Error: /dev/mapper/cryptlvm already exists. Close or rename it before installing."
    exit 1
  fi

  if vgs --noheadings volgroup0 >/dev/null 2>&1; then
    echo "Error: LVM volume group 'volgroup0' already exists. Remove or rename it before installing."
    exit 1
  fi
}

wait_for_block_device() {
  local block_device="$1"
  local attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if [ -b "$block_device" ]; then
      return
    fi
    sleep 1
  done

  echo "Error: Timed out waiting for block device '$block_device'."
  exit 1
}

run_preflight_checks

# Input and validation
# Collect required interactive parameters before mutating system state.

if [ "$TEST_MODE" = "true" ]; then
  mode="${TEST_MODE_MODE:-1}"
else
  mode=$(dialog --stdout --clear --menu "Select install mode" 0 0 0 "1" "Minimal" "2" "Workstation" "3" "VirtualBox") || exit 1
fi
if [[ ! "$mode" =~ ^[1-3]$ ]]; then
  echo "Error: Invalid mode '$mode'. Must be 1, 2, or 3."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  hostname="${TEST_MODE_HOSTNAME:-testhost}"
else
  hostname=$(dialog --stdout --clear --inputbox "Enter hostname" 0 40) || exit 1
fi
[ -z "$hostname" ] && echo "hostname cannot be empty" && exit 1
hostname="${hostname,,}"
if [[ ! "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Error: Invalid hostname '$hostname'. Must be lowercase alphanumeric with optional hyphens, 1-63 characters."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  user="${TEST_MODE_USER:-testuser}"
else
  user=$(dialog --stdout --clear --inputbox "Enter username" 0 40) || exit 1
fi
[ -z "$user" ] && echo "username cannot be empty" && exit 1
if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Error: Invalid username '$user'. Must start with lowercase letter or underscore, 1-32 characters, lowercase alphanumeric/underscore/hyphen only."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  password1="${TEST_MODE_PASSWORD:-testpass123}"
  password2="$password1"
else
  password1=$(dialog --stdout --clear --insecure --passwordbox "Enter password" 0 40) || exit 1
  password2=$(dialog --stdout --clear --insecure --passwordbox "Enter password again" 0 40) || exit 1
fi
[ -z "$password1" ] && echo "password cannot be empty" && exit 1
if [ "$password1" != "$password2" ]; then echo "Passwords did not match"; exit 1; fi

if [ "$TEST_MODE" = "true" ]; then
  device="${TEST_MODE_DEVICE:-/dev/loop0}"
  if [ "$DRY_RUN" = "false" ] && { [ -z "$device" ] || [ ! -b "$device" ]; }; then
    echo "In test mode, device \"$device\" does not exist or is not a block device."
    echo "Set TEST_MODE_DEVICE to a valid block device (for example, a loop device created with losetup)."
    echo "Or use --dry-run mode to skip actual disk operations."
    exit 1
  fi
else
  device_options=()
  while read -r disk_name disk_size; do
    device_options+=( "$disk_name" "$disk_size" )
  done < <(lsblk -dplnx size -o name,size,type | awk '$3 == "disk" { print $1, $2 }' | tac)

  if [ "${#device_options[@]}" -eq 0 ]; then
    echo "Error: No installable disk devices were found."
    exit 1
  fi

  device=$(dialog --stdout --clear --menu "Select installation disk" 0 0 0 "${device_options[@]}") || exit 1
fi
validate_target_device "$device"
confirm_destructive_action "$device"
ensure_install_names_available

dpfx=""
case "$device" in
  "/dev/nvme"*|"/dev/mmcblk"*|"/dev/loop"*) dpfx="p" ;;
esac
part_efi="${device}${dpfx}1"
part_luks="${device}${dpfx}2"

if [ "$TEST_MODE" = "true" ]; then
  password_luks1="${TEST_MODE_LUKS_PASSWORD:-lukspass123}"
  password_luks2="$password_luks1"
else
  password_luks1=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password" 0 40) || exit 1
  password_luks2=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password again" 0 40) || exit 1
fi
[ -z "$password_luks1" ] && echo "disk encryption password cannot be empty" && exit 1
if [ "$password_luks1" != "$password_luks2" ]; then echo "Passwords did not match"; exit 1; fi

# Only prompt for NVIDIA drivers when hardware is detected in desktop modes.
video_driver=""
if [ "$mode" -eq 2 ] || [ "$mode" -eq 3 ]; then
  if [ "$TEST_MODE" = "true" ]; then
    video_driver="${TEST_MODE_VIDEO_DRIVER:-}"
  elif command -v lspci >/dev/null 2>&1 && lspci | grep -e VGA -e 3D | grep -q NVIDIA; then
    video_driver=$(dialog --stdout --clear --menu "NVIDIA GPU detected. Select driver" 0 0 0 \
      "nvidia-open" "Open kernel modules (Turing+, recommended)" \
      "nvidia" "Proprietary (pre-Turing GPUs)" \
      "none" "Skip (use nouveau/mesa)") || exit 1
    if [ "$video_driver" = "none" ]; then
      video_driver=""
    fi
  fi
fi

# Avoid writing logs during tests so assertions can inspect stdout/stderr directly.
if [ "$TEST_MODE" != "true" ]; then
  exec 1>> "stdout.log"
  exec 2>> "stderr.log"
fi

# Disk provisioning
# Create ESP + LUKS2-on-LVM layout and mount it at /mnt.

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would wipe signatures and create GPT partitions on $device"
else
  wipefs --all --force "$device"
  sfdisk --wipe always --wipe-partitions always "$device" <<'EOF'
label: gpt

size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
type=CA7D7CCB-63ED-4C53-861C-1742536059CC
EOF
  partx --update "$device"
  udevadm settle
  wait_for_block_device "$part_efi"
  wait_for_block_device "$part_luks"
fi

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would encrypt $part_luks with LUKS2"
else
  printf '%s' "$password_luks1" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$part_luks"
fi

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would open LUKS device $part_luks as cryptlvm"
else
  printf '%s' "$password_luks1" | cryptsetup open --key-file - "$part_luks" cryptlvm
  unset password_luks1 password_luks2
fi

run_cmd pvcreate --yes --force /dev/mapper/cryptlvm
run_cmd vgcreate volgroup0 /dev/mapper/cryptlvm

run_cmd lvcreate -L 1G volgroup0 -n swap
run_cmd lvcreate -l 100%FREE volgroup0 -n root

run_cmd mkswap -f /dev/mapper/volgroup0-swap
run_cmd mkfs.ext4 -F /dev/mapper/volgroup0-root
run_cmd mkfs.vfat -F32 -n EFI "$part_efi"

run_cmd mount /dev/mapper/volgroup0-root /mnt
run_cmd swapon /dev/mapper/volgroup0-swap
run_cmd mkdir -p /mnt/boot
run_cmd mount "$part_efi" /mnt/boot

# Package installation
# Refresh package metadata/keyring, select packages for the chosen mode, then pacstrap.

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would update mirrorlist"
else
  mirrorlist_tmp="$(mktemp)"
  curl -fsSL 'https://archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4' \
    | sed 's/^#Server/Server/' > "$mirrorlist_tmp"
  if ! grep -q '^Server = ' "$mirrorlist_tmp"; then
    echo "Error: Downloaded mirrorlist did not contain any enabled HTTPS mirrors."
    rm -f "$mirrorlist_tmp"
    exit 1
  fi
  install -m 0644 "$mirrorlist_tmp" /etc/pacman.d/mirrorlist
  rm -f "$mirrorlist_tmp"
  pacman -Sy --needed --noconfirm archlinux-keyring
fi

cpu_vendor=""
if [ "$DRY_RUN" = "false" ] && [ "$TEST_MODE" = "false" ]; then
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    cpu_vendor="intel"
  elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    cpu_vendor="amd"
  fi
fi

packages=(
  base \
  base-devel \
  bat \
  btop \
  ctags \
  curl \
  dash \
  docker \
  duf \
  efibootmgr \
  eza \
  fail2ban \
  fd \
  fzf \
  git \
  git-delta \
  grub \
  jq \
  lazygit \
  linux \
  linux-firmware \
  linux-headers \
  linux-lts \
  linux-lts-headers \
  lvm2 \
  man-db \
  man-pages \
  networkmanager \
  neovim \
  openssh \
  pacman-contrib \
  reflector \
  ripgrep \
  sed \
  shellcheck \
  rustup \
  sudo \
  tmux \
  ufw \
  util-linux \
  vim \
  wget \
  xdg-user-dirs \
  zip \
  zoxide \
  zsh \
  zsh-autosuggestions \
  zsh-completions \
  zsh-syntax-highlighting
)

packages_gui=(
  alacritty \
  alsa-utils \
  chromium \
  gammastep \
  grim \
  hyprland \
  hypridle \
  hyprlock \
  hyprpaper \
  mako \
  otf-font-awesome \
  papirus-icon-theme \
  playerctl \
  qt5-wayland \
  qt6-wayland \
  slurp \
  uwsm \
  waybar \
  wl-clipboard \
  fuzzel \
  xorg-xwayland
)

# Wayland uses mesa/nouveau by default; add NVIDIA only when explicitly selected.
if [ -n "$video_driver" ]; then
  packages_gui=( "${packages_gui[@]}" "$video_driver" )
fi

packages_vbox=(
  virtualbox-guest-utils
)

if [ -n "$cpu_vendor" ]; then
  if [ "$cpu_vendor" = "intel" ]; then
    packages=( "${packages[@]}" "intel-ucode" )
  elif [ "$cpu_vendor" = "amd" ]; then
    packages=( "${packages[@]}" "amd-ucode" )
  fi
fi

case "$mode" in
  2)
    packages=( "${packages[@]}" "${packages_gui[@]}" )
    ;;
  3)
    packages=( "${packages[@]}" "${packages_gui[@]}" "${packages_vbox[@]}" )
    ;;
esac

run_cmd pacstrap -K /mnt "${packages[@]}"

# Target system configuration
# Write base OS configuration and enable services before user bootstrap.

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would generate fstab"
else
  genfstab -U /mnt >> /mnt/etc/fstab
fi

in_target ln -sfT dash /usr/bin/sh

write_file /mnt/etc/hostname <<EOF
$hostname
EOF
append_file /mnt/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
::1 localhost.localdomain localhost
127.0.0.1 $hostname.localdomain $hostname
EOF

write_file /mnt/etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
EOF
in_target locale-gen

# NetworkManager delegates DNS to resolved; allow-downgrade avoids strict DNSSEC
# failures on unsigned or misconfigured zones while still validating when possible.
write_file /mnt/etc/systemd/resolved.conf <<'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
EOF
write_file /mnt/etc/NetworkManager/conf.d/dns.conf <<'EOF'
[main]
dns=systemd-resolved
EOF

# Store an initial ALSA state so desktop sessions start with usable volume.
case "$mode" in
  2|3)
    in_target amixer -q sset Master 100%
    in_target alsactl store
    ;;
esac

# The installer is opinionated; adjust this before running for other regions.
in_target ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime

enable_services \
  NetworkManager.service \
  systemd-resolved.service \
  ufw.service \
  fail2ban.service \
  docker.service \
  systemd-timesyncd.service \
  paccache.timer \
  fstrim.timer \
  reflector.timer

in_target ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

in_target ufw default deny incoming
in_target ufw default allow outgoing
in_target ufw --force enable

if [ "$mode" -eq 3 ]; then
  enable_services vboxservice.service
fi

# Pacman policy

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would configure pacman options"
else
  sed -i '/^\[options\]/a Color\nILoveCandy' /mnt/etc/pacman.conf
fi

# Keep /bin/sh pointed at dash even after bash package transactions.
write_file /mnt/etc/pacman.d/hooks/dash.hook <<'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = bash
[Action]
Description = Re-pointing /bin/sh symlink to dash...
When = PostTransaction
Exec = /usr/bin/ln -sfT dash /usr/bin/sh
Depends = dash
EOF

# Retain a small rollback window without letting the package cache grow forever.
write_file /mnt/etc/pacman.d/hooks/paccache.hook <<'EOF'
[Trigger]
Operation = Remove
Operation = Install
Operation = Upgrade
Type = Package
Target = *
[Action]
Description = Clean package cache
When = PostTransaction
Exec = /usr/bin/paccache -rk5
Depends = pacman-contrib
EOF

# Hardening and maintenance
# Apply baseline kernel/network hardening plus maintenance service config.

write_file /mnt/etc/sysctl.d/99-security.conf <<'EOF'
# Kernel hardening settings for improved security

# Prevent kernel pointer leaks
kernel.kptr_restrict = 2

# Restrict dmesg access to root only
kernel.dmesg_restrict = 1

# Restrict access to kernel logs
kernel.printk = 3 3 3 3

# Protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1

# Disable IP forwarding (unless this machine is a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Disable ICMP redirect acceptance
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable secure ICMP redirect acceptance
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Disable ICMP redirect sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable source address verification without breaking common VPN/multihomed setups
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore ICMP ping requests (optional, uncomment to enable)
# net.ipv4.icmp_echo_ignore_all = 1

# Protect against time-wait assassination
net.ipv4.tcp_rfc1337 = 1

# Increase system file descriptor limit
fs.file-max = 2097152

# Restrict core dumps (potential information leak)
kernel.core_uses_pid = 1
fs.suid_dumpable = 0

# Enable ASLR (Address Space Layout Randomization)
kernel.randomize_va_space = 2
EOF

write_file /mnt/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# Ban hosts for 1 hour (3600 seconds)
bantime = 3600
# Check for attacks within 10 minutes
findtime = 600
# Ban after 5 failed attempts
maxretry = 5
# Use systemd backend for journal-based logging
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
EOF

write_file /mnt/etc/xdg/reflector/reflector.conf <<'EOF'
# Reflector configuration for automatic mirror updates
--save /etc/pacman.d/mirrorlist
--protocol https
--country US
--latest 20
--sort rate
EOF

# User and dotfiles
# Create the primary user, temporarily allow sudo for dotfiles, then require sudo passwords.

in_target useradd -mU -G docker,wheel -s /bin/zsh -p "$(openssl passwd -6 "$password1")" "$user"
in_target chsh -s /bin/zsh "$user"
unset password1 password2

write_file /mnt/etc/sudoers.d/00-installer-wheel-nopasswd <<'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
if [ "$DRY_RUN" = "false" ]; then
  chmod 0440 /mnt/etc/sudoers.d/00-installer-wheel-nopasswd
  in_target visudo -cf /etc/sudoers
fi

in_target passwd -l root
in_target usermod -s /sbin/nologin root

dotfiles_repo="https://github.com/sneivandt/dotfiles.git"
dotfiles_dir="/home/$user/src/dotfiles"
case "$mode" in
  1)
    dotfiles_profile="base"
    ;;
  2|3)
    dotfiles_profile="desktop"
    ;;
esac
echo "Preparing dotfiles bootstrap directory for $user"
in_target install -d -o "$user" -g "$user" "/home/$user/src"
echo "Cloning dotfiles repository for $user"
as_user git clone "$dotfiles_repo" "$dotfiles_dir"
echo "Validating dotfiles profile '$dotfiles_profile' for $user"
as_user "$dotfiles_dir/dotfiles.sh" test -p "$dotfiles_profile"
echo "Applying dotfiles profile '$dotfiles_profile' for $user"
as_user "$dotfiles_dir/dotfiles.sh" install -p "$dotfiles_profile" -v

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would remove /mnt/etc/sudoers.d/00-installer-wheel-nopasswd"
else
  rm -f /mnt/etc/sudoers.d/00-installer-wheel-nopasswd
fi
write_file /mnt/etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
if [ "$DRY_RUN" = "false" ]; then
  chmod 0440 /mnt/etc/sudoers.d/10-wheel
  in_target visudo -cf /etc/sudoers
fi

# Boot configuration
# Build initramfs images with encryption/LVM hooks and install GRUB for UEFI boot.

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would configure mkinitcpio hooks"
else
  mkinitcpio_hooks="HOOKS=(base udev keyboard keymap consolefont autodetect microcode modconf kms block encrypt lvm2 filesystems fsck)"
  if ! sed -i "s/^HOOKS=.*/$mkinitcpio_hooks/" /mnt/etc/mkinitcpio.conf; then
    echo "Warning: Failed to update mkinitcpio hooks"
  fi
  if ! grep -Fxq "$mkinitcpio_hooks" /mnt/etc/mkinitcpio.conf; then
    echo "Error: mkinitcpio hooks not properly configured. System may not boot with encryption."
    exit 1
  fi
fi
in_target mkinitcpio -p linux
in_target mkinitcpio -p linux-lts

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would configure GRUB cryptdevice parameter from $part_luks UUID"
else
  crypt_uuid="$(blkid -s UUID -o value "$part_luks")"
  if [ -z "$crypt_uuid" ]; then
    echo "Error: Failed to resolve LUKS partition UUID for GRUB configuration."
    exit 1
  fi
  grub_cmdline="GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$crypt_uuid:cryptlvm root=/dev/mapper/volgroup0-root\""
  if grep -q '^GRUB_CMDLINE_LINUX=' /mnt/etc/default/grub; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|$grub_cmdline|" /mnt/etc/default/grub
  else
    echo "$grub_cmdline" >> /mnt/etc/default/grub
  fi
fi
in_target grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck "$device"
in_target grub-mkconfig -o /boot/grub/grub.cfg

# Cleanup
# Release resources explicitly; the EXIT trap handles failures before this point.
run_cmd swapoff /dev/mapper/volgroup0-swap
run_cmd umount -R /mnt
run_cmd vgchange -an volgroup0
run_cmd cryptsetup close cryptlvm
