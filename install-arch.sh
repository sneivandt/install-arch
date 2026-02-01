#!/usr/bin/env bash
# Arch Linux semi-interactive installer.
#
# Run from Arch live ISO as root. Collects minimal input (mode, disk, hostname,
# user, passwords) then automates: partitioning, LUKS2 encryption + LVM, base
# package install, optional GUI/workstation stack, AUR helper/temp user,
# dotfiles, and bootloader configuration.
#
# WARNING: Destroys selected disk contents completely.
# Modes:
#   1 Minimal (CLI only)
#   2 Workstation (X11 + WM + optional NVIDIA)
#   3 VirtualBox Workstation (adds guest utils)
# Logging starts only after password collection.
set -o errexit
set -o nounset
set -o pipefail

# Preamble ---------------------------------------------------------------- {{{

# Trap errors with line number + failing command.
trap 'echo "$0: Error on line "$LINENO": $BASH_COMMAND"' ERR

# Parse command line arguments
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

# Ensure dialog is present for interactive prompts (skip in test mode).
if [ "$TEST_MODE" = "false" ]; then
  pacman -Sy --noconfirm dialog
fi

# Helper functions for dry-run mode
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

# }}}
# Input ------------------------------------------------------------------- {{{
# Collect required interactive parameters before mutating system state.

# Install mode
if [ "$TEST_MODE" = "true" ]; then
  mode="${TEST_MODE_MODE:-1}"
else
  mode=$(dialog --stdout --clear --menu "Select install mode" 0 0 0 "1" "Minimal" "2" "Workstation" "3" "VirtualBox") || exit 1
fi

# Hostname
if [ "$TEST_MODE" = "true" ]; then
  hostname="${TEST_MODE_HOSTNAME:-testhost}"
else
  hostname=$(dialog --stdout --clear --inputbox "Enter hostname" 0 40) || exit 1
fi
[ -z "$hostname" ] && echo "hostname cannot be empty" && exit 1

# Username
if [ "$TEST_MODE" = "true" ]; then
  user="${TEST_MODE_USER:-testuser}"
else
  user=$(dialog --stdout --clear --inputbox "Enter username" 0 40) || exit 1
fi
[ -z "$user" ] && echo "username cannot be empty" && exit 1

# User password
if [ "$TEST_MODE" = "true" ]; then
  password1="${TEST_MODE_PASSWORD:-testpass123}"
  password2="$password1"
else
  password1=$(dialog --stdout --clear --insecure --passwordbox "Enter password" 0 40) || exit 1
  password2=$(dialog --stdout --clear --insecure --passwordbox "Enter password again" 0 40) || exit 1
fi
[ -z "$password1" ] && echo "password cannot be empty" && exit 1
if [ "$password1" != "$password2" ]; then echo "Passwords did not match"; exit 1; fi

# Installation disk
if [ "$TEST_MODE" = "true" ]; then
  device="${TEST_MODE_DEVICE:-/dev/loop0}"
  # In test mode without dry-run, ensure the device exists and is a block device.
  if [ "$DRY_RUN" = "false" ] && { [ -z "$device" ] || [ ! -b "$device" ]; }; then
    echo "In test mode, device \"$device\" does not exist or is not a block device."
    echo "Set TEST_MODE_DEVICE to a valid block device (for example, a loop device created with losetup)."
    echo "Or use --dry-run mode to skip actual disk operations."
    exit 1
  fi
else
  devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
  # shellcheck disable=SC2086
  device=$(dialog --stdout --clear --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
fi
dpfx=""
case "$device" in
  "/dev/nvme"*) dpfx="p" ;;
esac

# Encryption password
if [ "$TEST_MODE" = "true" ]; then
  password_luks1="${TEST_MODE_LUKS_PASSWORD:-lukspass123}"
  password_luks2="$password_luks1"
else
  password_luks1=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password" 0 40) || exit 1
  password_luks2=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password again" 0 40) || exit 1
fi
[ -z "$password_luks1" ] && echo "disk encryption password cannot be empty" && exit 1
if [ "$password_luks1" != "$password_luks2" ]; then echo "Passwords did not match"; exit 1; fi

# Video driver
video_driver=""
if [ "$mode" -eq 2 ]; then
  if [ "$TEST_MODE" = "true" ]; then
    video_driver="${TEST_MODE_VIDEO_DRIVER:-}"
  elif lspci | grep -e VGA -e 3D | grep -q NVIDIA; then
    video_drivers=(0 nvidia 1 nvidia-340xx 2 nvidia-390xx 3 xf86-video-nouveau)
    # shellcheck disable=SC2068
    driver_index=$(dialog --stdout --clear --menu "Select video driver" 0 0 0 ${video_drivers[@]}) || exit 1
    # Dialog returns the tag (0, 1, 2, 3), we need to get the value at index (tag * 2 + 1)
    # But we need to convert tag to the actual driver name
    case "$driver_index" in
      0) video_driver="nvidia" ;;
      1) video_driver="nvidia-340xx" ;;
      2) video_driver="nvidia-390xx" ;;
      3) video_driver="xf86-video-nouveau" ;;
    esac
  fi
fi

# Logging
# Only log to files when not in test mode
if [ "$TEST_MODE" != "true" ]; then
  # Simple file redirection without process substitution
  exec 1>> "stdout.log"
  exec 2>> "stderr.log"
fi

# }}}
# Disk -------------------------------------------------------------------- {{{
#
# Setup the disk

# Partitioning
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would partition $device with fdisk"
else
  fdisk "$device" <<'EOF' # p1 make type 1 (UEFI)
g
n
1

+512M
n
2


t
2
8e
w
EOF
fi

# Encrypt root drive
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would encrypt ${device}${dpfx}2 with LUKS2"
else
  echo -n "$password_luks1" | cryptsetup luksFormat --type luks2 "${device}${dpfx}2" -
fi

# Open root drive
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would open LUKS device ${device}${dpfx}2 as cryptlvm"
else
  echo -n "$password_luks1" | cryptsetup open "${device}${dpfx}2" cryptlvm -
fi

# Create physical volume
run_cmd pvcreate /dev/mapper/cryptlvm

# Create volume group
run_cmd vgcreate volgroup0 /dev/mapper/cryptlvm

# Create logical volumes
run_cmd lvcreate -L 1G volgroup0 -n swap
run_cmd lvcreate -l 100%FREE volgroup0 -n root

# Format
run_cmd mkswap /dev/mapper/volgroup0-swap
run_cmd mkfs.ext4 /dev/mapper/volgroup0-root
run_cmd mkfs.vfat -F32 -n EFI "${device}${dpfx}1"

# Mount
run_cmd mount /dev/mapper/volgroup0-root /mnt
run_cmd swapon /dev/mapper/volgroup0-swap
run_cmd mkdir /mnt/boot
run_cmd mount "${device}${dpfx}1" /mnt/boot

# }}}
# Pacstrap ---------------------------------------------------------------- {{{
#
# Install packages

# Update mirrors
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would update mirrorlist"
else
  curl -sL 'https://www.archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4' | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist
fi

# Detect CPU vendor for microcode updates
cpu_vendor=""
if [ "$DRY_RUN" = "false" ] && [ "$TEST_MODE" = "false" ]; then
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    cpu_vendor="intel"
  elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    cpu_vendor="amd"
  fi
fi

# Base packages
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

# Workstation packages
packages_gui=(
  adobe-source-code-pro-fonts \
  alacritty \
  alsa-utils \
  chromium \
  dunst \
  feh \
  flameshot \
  noto-fonts-cjk \
  noto-fonts-emoji \
  papirus-icon-theme \
  picom \
  redshift \
  rofi \
  rxvt-unicode \
  urxvt-perls \
  xclip \
  xmonad \
  xmonad-contrib \
  xorg \
  xorg-server \
  xorg-xinit \
  xterm
)

# Video drivers
if [ -n "$video_driver" ]
then
  packages_gui=( "${packages_gui[@]}" "$video_driver" )
else
  packages_gui=( "${packages_gui[@]}" "xf86-video-vesa" )
fi

# Virtualbox packages
packages_vbox=(
  virtualbox-guest-utils
)

# Add CPU microcode package if detected
if [ -n "$cpu_vendor" ]; then
  if [ "$cpu_vendor" = "intel" ]; then
    packages=( "${packages[@]}" "intel-ucode" )
  elif [ "$cpu_vendor" = "amd" ]; then
    packages=( "${packages[@]}" "amd-ucode" )
  fi
fi

# Select packages
case "$mode" in
  2)
    packages=( "${packages[@]}" "${packages_gui[@]}" )
    ;;
  3)
    packages=( "${packages[@]}" "${packages_gui[@]}" "${packages_vbox[@]}" )
    ;;
esac

# Pacstrap
run_cmd pacstrap /mnt "${packages[@]}"

# }}}
# General ----------------------------------------------------------------- {{{
#
# General system config

# Generate filesystem table
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would generate fstab"
else
  genfstab -U /mnt >> /mnt/etc/fstab
fi

# sh -> dash
run_cmd arch-chroot /mnt ln -sfT dash /usr/bin/sh

# Set hostname
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would set hostname to $hostname"
else
  echo "$hostname" > /mnt/etc/hostname
  cat >>/mnt/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
::1 localhost.localdomain localhost
127.0.0.1 $hostname.localdomain $hostname
EOF
fi

# Set locale
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would set locale to en_US.UTF-8"
else
  echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
fi
run_cmd arch-chroot /mnt locale-gen

# Configure DNS with systemd-resolved (modern, supports DNSSEC)
# Note: NetworkManager will manage /etc/resolv.conf via systemd-resolved
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure systemd-resolved"
else
  # Create resolved configuration for Google DNS with DNSSEC
  cat >>/mnt/etc/systemd/resolved.conf <<'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
DNSSEC=yes
DNSOverTLS=opportunistic
EOF
fi

# Initialize audio volume for GUI modes (store ALSA state)
case "$mode" in
  2|3)
    run_cmd arch-chroot /mnt amixer -q sset Master 100%
    run_cmd arch-chroot /mnt alsactl store
    ;;
esac

# Set system time zone (adjust if deploying outside US/Pacific)
run_cmd arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime

# Enable NetworkManager for network management
run_cmd arch-chroot /mnt systemctl enable NetworkManager.service

# Enable systemd-resolved for DNS with DNSSEC support
run_cmd arch-chroot /mnt systemctl enable systemd-resolved.service

# Enable firewall for basic security hardening
run_cmd arch-chroot /mnt systemctl enable ufw.service

# Configure firewall: deny incoming by default, allow outgoing
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure ufw firewall defaults"
else
  arch-chroot /mnt ufw --force enable
  arch-chroot /mnt ufw default deny incoming
  arch-chroot /mnt ufw default allow outgoing
fi

# Enable fail2ban for SSH brute-force protection
run_cmd arch-chroot /mnt systemctl enable fail2ban.service

# Enable Docker daemon
run_cmd arch-chroot /mnt systemctl enable docker.service

# Enable systemd time synchronization service
run_cmd arch-chroot /mnt systemctl enable systemd-timesyncd.service

# Enable pacman cache cleanup timer
run_cmd arch-chroot /mnt systemctl enable paccache.timer

# Enable periodic SSD TRIM for better SSD health and performance
run_cmd arch-chroot /mnt systemctl enable fstrim.timer

# Enable reflector timer for automatic mirrorlist updates
run_cmd arch-chroot /mnt systemctl enable reflector.timer

# Enable VirtualBox guest services (mode 3 only)
if [ "$mode" -eq 3 ]; then
  run_cmd arch-chroot /mnt systemctl enable vboxservice.service
fi

# }}}
# Pacman ------------------------------------------------------------------ {{{

# Basic pacman cosmetic options (color + candy progress)
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure pacman options"
else
  sed -i '/^\[options\]/a Color\nILoveCandy' /mnt/etc/pacman.conf
fi

run_cmd mkdir -p /mnt/etc/pacman.d/hooks

# Hook to keep /bin/sh pointing to dash after bash transactions
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would create pacman hooks"
else
  cat >>/mnt/etc/pacman.d/hooks/dash.hook <<'EOF'
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

# Hook to clean old package cache entries (retain 5)
cat >>/mnt/etc/pacman.d/hooks/paccache.hook <<'EOF'
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

# Hook to auto recompile xmonad after install/upgrade
cat >>/mnt/etc/pacman.d/hooks/xmonad.hook <<EOF
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = xmonad
[Action]
Description = Recompile xmonad
When = PostTransaction
Exec = /usr/bin/sudo XMONAD_CONFIG_DIR=/home/$user/.config/xmonad -u $user /usr/bin/xmonad --recompile
Depends = xmonad
EOF
fi

# }}}
# Security Hardening ------------------------------------------------------ {{{
#
# Apply security-focused system hardening configurations

# Create sysctl configuration for kernel hardening
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would create security hardening sysctl configuration"
else
  cat >>/mnt/etc/sysctl.d/99-security.conf <<'EOF'
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

# Enable source address verification (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP ping requests (optional, uncomment to enable)
# net.ipv4.icmp_echo_ignore_all = 1

# Protect against time-wait assassination
net.ipv4.tcp_rfc1337 = 1

# Disable IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Increase system file descriptor limit
fs.file-max = 2097152

# Restrict core dumps (potential information leak)
kernel.core_uses_pid = 1
fs.suid_dumpable = 0

# Enable ASLR (Address Space Layout Randomization)
kernel.randomize_va_space = 2
EOF
fi

# Configure fail2ban for SSH protection
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure fail2ban for SSH protection"
else
  cat >>/mnt/etc/fail2ban/jail.local <<'EOF'
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
fi

# Configure reflector for automatic mirror updates
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure reflector"
else
  cat >>/mnt/etc/xdg/reflector/reflector.conf <<'EOF'
# Reflector configuration for automatic mirror updates
--save /etc/pacman.d/mirrorlist
--protocol https
--country US
--latest 20
--sort rate
EOF
fi

# }}}
# AUR --------------------------------------------------------------------- {{{
#
# Install paru AUR helper using temporary build user

# Create temporary AUR build user
run_cmd arch-chroot /mnt useradd -m -d /opt/aurbuilder aurbuilder

# Grant restricted sudo for package installation only
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would create sudoers file for aurbuilder"
else
  cat >> /mnt/etc/sudoers.d/aurbuilder <<'EOF'
aurbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman
EOF
  chmod 0440 /mnt/etc/sudoers.d/aurbuilder
fi

# Clone paru-bin at specific commit and build
# Using latest stable release commit as of 2024
run_cmd arch-chroot /mnt su aurbuilder -c "git clone https://aur.archlinux.org/paru-bin.git /opt/aurbuilder/paru-bin && cd /opt/aurbuilder/paru-bin && git checkout 0313c65 && makepkg -si --noconfirm"

# Remove temporary build user and its sudo privileges
run_cmd arch-chroot /mnt userdel aurbuilder
run_cmd rm -rf /mnt/opt/aurbuilder
run_cmd rm -f /mnt/etc/sudoers.d/aurbuilder

# }}}
# Users  ------------------------------------------------------------------ {{{
#
# Create main user, apply dotfiles, lock root, adjust sudo policy

# Create user (groups: docker,wheel) with hashed password and zsh shell
run_cmd arch-chroot /mnt useradd -mU -G docker,wheel -s /bin/zsh -p "$(openssl passwd -6 "$password1")" "$user"
run_cmd arch-chroot /mnt chsh -s /bin/zsh "$user"

# Temporarily allow passwordless sudo for bootstrapping
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would modify sudoers for passwordless sudo"
else
  sed -i '/^# %wheel ALL=(ALL) NOPASSWD: ALL$/s/^# //g' /mnt/etc/sudoers
fi

# Lock and disable interactive root login
run_cmd arch-chroot /mnt passwd -l root
run_cmd arch-chroot /mnt usermod -s /sbin/nologin root

# Clone dotfiles repo and run installer (mode controls profile)
run_cmd arch-chroot /mnt su "$user" -c "git clone https://github.com/sneivandt/dotfiles.git /home/$user/src/dotfiles"
case "$mode" in
  1)
    run_cmd arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -I --profile arch"
    ;;
  2|3)
    run_cmd arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -I --profile arch-desktop"
    ;;
esac

# Reinstate sudo password requirement
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would restore sudo password requirement"
else
  sed -i '/^%wheel ALL=(ALL) NOPASSWD: ALL$/s/^/# /g' /mnt/etc/sudoers
  sed -i '/^# %wheel ALL=(ALL) ALL$/s/^# //g' /mnt/etc/sudoers
fi

# }}}
# Init -------------------------------------------------------------------- {{{
#
# Initramfs generation + GRUB installation/config for encrypted root

# Ensure required hooks present then build initramfs
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure mkinitcpio hooks"
else
  sed -i "s/^HOOKS.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/" /mnt/etc/mkinitcpio.conf
fi
# Build initramfs for both mainline and LTS kernels
run_cmd arch-chroot /mnt mkinitcpio -p linux
run_cmd arch-chroot /mnt mkinitcpio -p linux-lts

# Install GRUB to EFI and patch kernel line with cryptdevice parameter
run_cmd arch-chroot /mnt grub-install "$device" --efi-directory=/boot
run_cmd arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would configure GRUB cryptdevice parameter"
else
  device_esc=$(sed 's/\//\\\//g' <<< "$device")
  sed -i "s/.*vmlinuz-linux.*/linux \\/vmlinuz-linux root=\\/dev\\/mapper\\/volgroup0-root rw cryptdevice=${device_esc}${dpfx}2:volgroup0 quiet/" /mnt/boot/grub/grub.cfg
fi

# }}}
# Cleanup ----------------------------------------------------------------- {{{
#
# Final unmounts and swap deactivation

# Release resources
run_cmd umount -R /mnt
run_cmd swapoff -a

# }}}
