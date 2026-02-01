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
set -u nounset
set -o pipefail

# Preamble ---------------------------------------------------------------- {{{

# Trap errors with line number + failing command.
trap 'echo "$0: Error on line "$LINENO": $BASH_COMMAND"' ERR

# Ensure dialog is present for interactive prompts.
pacman -Sy --noconfirm dialog

# }}}
# Input ------------------------------------------------------------------- {{{
# Collect required interactive parameters before mutating system state.

# Install mode
mode=$(dialog --stdout --clear --menu "Select install mode" 0 0 0 "1" "Minimal" "2" "Workstation" "3" "VirtualBox") || exit

# Hostname
hostname=$(dialog --stdout --clear --inputbox "Enter hostname" 0 40) || exit 1
[ -z "$hostname" ] && echo "hostname cannot be empty" && exit 1

# Username
user=$(dialog --stdout --clear --inputbox "Enter username" 0 40) || exit 1
[ -z "$user" ] && echo "username cannot be empty" && exit 1

# User password
password1=$(dialog --stdout --clear --insecure --passwordbox "Enter password" 0 40) || exit 1
[ -z "$password1" ] && echo "password cannot be empty" && exit 1
password2=$(dialog --stdout --clear --insecure --passwordbox "Enter password again" 0 40) || exit 1
if [ "$password1" != "$password2" ]; then echo "Passwords did not match"; exit; fi

# Installation disk
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
# shellcheck disable=SC2086
device=$(dialog --stdout --clear --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
dpfx=""
case "$device" in
  "/dev/nvme"*) dpfx="p"
esac

# Encryption password
password_luks1=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password" 0 40) || exit 1
[ -z "$password_luks1" ] && echo "disk encryption password cannot be empty" && exit 1
password_luks2=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password again" 0 40) || exit 1
if [ "$password_luks1" != "$password_luks2" ]; then echo "Passwords did not match"; exit; fi

# Video driver
video_driver=""
if [ "$mode" == 2 ] && lspci | grep -e VGA -e 3D | grep -q NVIDIA
then
  video_drivers=(0 nvidia 1 nvidia-340xx 2 nvidia-390xx 3 xf86-video-nouveau)
  # shellcheck disable=SC2068
  video_driver="${video_drivers[($(dialog --stdout --clear --menu "Select video driver" 0 0 0 ${video_drivers[@]}) + 1) * 2 - 1]}" || exit
fi

# Logging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# }}}
# Disk -------------------------------------------------------------------- {{{
#
# Setup the disk

# Partitioning
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

# Encrypt root drive
echo -n "$password_luks1" | cryptsetup luksFormat --type luks2 "$device$dpfx"2 -

# Open root drive
echo -n "$password_luks1" | cryptsetup open "$device$dpfx"2 cryptlvm -

# Create physical volume
pvcreate /dev/mapper/cryptlvm

# Create volume group
vgcreate volgroup0 /dev/mapper/cryptlvm

# Create logical volumes
lvcreate -L 1G volgroup0 -n swap
lvcreate -l 100%FREE volgroup0 -n root

# Format
mkswap /dev/mapper/volgroup0-swap
mkfs.ext4 /dev/mapper/volgroup0-root
mkfs.vfat -F32 -n EFI "$device$dpfx"1

# Mount
mount /dev/mapper/volgroup0-root /mnt
swapon /dev/mapper/volgroup0-swap
mkdir /mnt/boot
mount "$device$dpfx"1 /mnt/boot

# }}}
# Pacstrap ---------------------------------------------------------------- {{{
#
# Install packages

# Update mirrors
curl -sL 'https://www.archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4' | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

# Base packages
packages=(
  base \
  base-devel \
  bat \
  btop \
  ctags \
  curl \
  dash \
  dhcpcd \
  docker \
  duf \
  efibootmgr \
  eza \
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
  lvm2 \
  man-db \
  man-pages \
  neovim \
  openssh \
  pacman-contrib \
  ripgrep \
  sed \
  shellcheck \
  tmux \
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
pacstrap /mnt "${packages[@]}"

# }}}
# General ----------------------------------------------------------------- {{{
#
# General system config

# Generate filesystem table
genfstab -U /mnt >> /mnt/etc/fstab

# sh -> dash
arch-chroot /mnt ln -sfT dash /usr/bin/sh

# Set hostname
echo "$hostname" > /mnt/etc/hostname
cat >>/mnt/etc/hosts <<'EOF'
127.0.0.1 localhost.localdomain localhost
::1 localhost.localdomain localhost
127.0.0.1 "$hostname".localdomain "$hostname"
EOF

# Set locale
echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen

# Google DNS (static resolv.conf; protected by chattr to prevent overwrite)
cat >>/mnt/etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
chattr +i /mnt/etc/resolv.conf

# Initialize audio volume for GUI modes (store ALSA state)
case "$mode" in
  2|3)
    arch-chroot /mnt amixer -q sset Master 100%
    arch-chroot /mnt alsactl store
    ;;
esac

# Set system time zone (adjust if deploying outside US/Pacific)
arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime

# Enable DHCP client service
arch-chroot /mnt systemctl enable dhcpcd.service

# Enable Docker daemon
arch-chroot /mnt systemctl enable docker.service

# Enable systemd time synchronization service
arch-chroot /mnt systemctl enable systemd-timesyncd.service

# Enable pacman cache cleanup timer
arch-chroot /mnt systemctl enable paccache.timer

# Enable VirtualBox guest services (mode 3 only)
[ "$mode" -eq 3 ] && arch-chroot /mnt systemctl enable vboxservice.service

# }}}
# Pacman ------------------------------------------------------------------ {{{

# Basic pacman cosmetic options (color + candy progress)
cat >>/mnt/etc/pacman.conf <<'EOF'
[options]
ILoveCandy
Color
EOF

mkdir -p /mnt/etc/pacman.d/hooks

# Hook to keep /bin/sh pointing to dash after bash transactions
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
cat >>/mnt/etc/pacman.d/hooks/paccache.hook <<EOF
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

# }}}
# AUR --------------------------------------------------------------------- {{{
#
# Install paru AUR helper using temporary build user

# Create temporary AUR build user
arch-chroot /mnt useradd -m -d /opt/aurbuilder aurbuilder

# Grant restricted sudo for package installation only
cat >> /mnt/etc/sudoers.d/aurbuilder <<'EOF'
aurbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman
EOF
chmod 0440 /mnt/etc/sudoers.d/aurbuilder

# Clone paru-bin at specific commit and build
# Using latest stable release commit as of 2024
arch-chroot /mnt su aurbuilder -c "git clone https://aur.archlinux.org/paru-bin.git /opt/aurbuilder/paru-bin && cd /opt/aurbuilder/paru-bin && git checkout 0313c65 && makepkg -si --noconfirm"

# Remove temporary build user and its sudo privileges
arch-chroot /mnt userdel aurbuilder
rm -rf /mnt/opt/aurbuilder
rm -f /mnt/etc/sudoers.d/aurbuilder

# }}}
# Users  ------------------------------------------------------------------ {{{
#
# Create main user, apply dotfiles, lock root, adjust sudo policy

# Create user (groups: docker,wheel) with hashed password and zsh shell
arch-chroot /mnt useradd -mU -G docker,wheel -s /bin/zsh -p "$(openssl passwd -1 "$password1")" "$user"
arch-chroot /mnt chsh -s /bin/zsh "$user"

# Temporarily allow passwordless sudo for bootstrapping
sed -i '/^# %wheel ALL=(ALL) NOPASSWD: ALL$/s/^# //g' /mnt/etc/sudoers

# Lock and disable interactive root login
arch-chroot /mnt passwd -l root
arch-chroot /mnt usermod -s /sbin/nologin root

# Clone dotfiles repo and run installer (mode controls profile)
arch-chroot /mnt su "$user" -c "git clone https://github.com/sneivandt/dotfiles.git /home/$user/src/dotfiles"
case "$mode" in
  1)
    arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -I --profile arch"
    ;;
  2|3)
    arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -I --profile arch-desktop"
    ;;
esac

# Reinstate sudo password requirement
sed -i '/^%wheel ALL=(ALL) NOPASSWD: ALL$/s/^/# /g' /mnt/etc/sudoers
sed -i '/^# %wheel ALL=(ALL) ALL$/s/^# //g' /mnt/etc/sudoers

# }}}
# Init -------------------------------------------------------------------- {{{
#
# Initramfs generation + GRUB installation/config for encrypted root

# Ensure required hooks present then build initramfs
sed -i "s/^HOOKS.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# Install GRUB to EFI and patch kernel line with cryptdevice parameter
arch-chroot /mnt grub-install "$device" --efi-directory=/boot
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
device_esc=$(sed 's/\//\\\//g' <<< "$device")
sed -i "s/.*vmlinuz-linux.*/linux \\/vmlinuz-linux root=\\/dev\\/mapper\\/volgroup0-root rw cryptdevice=${device_esc}${dpfx}2:volgroup0 quiet/" /mnt/boot/grub/grub.cfg

# }}}
# Cleanup ----------------------------------------------------------------- {{{
#
# Final unmounts and swap deactivation

# Release resources
umount -R /mnt
swapoff -a

# }}}
