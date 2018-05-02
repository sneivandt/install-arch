#!/bin/bash

# Preamble ---------------------------------------------------------------- {{{
#
# Prepare for execution

# Error Trap
set -uo pipefail
trap 'echo "$0: Error on line "$LINENO": $BASH_COMMAND"' ERR

# User Input
mode=$(dialog --stdout --clear --menu "Select install mode" 0 0 0 "1" "Minimal" "2" "Worktation" "3" "VirtualBox") || exit
hostname=$(dialog --stdout --clear --inputbox "Enter hostname" 0 40) || exit 1
[ -z "$hostname" ] && echo "hostname cannot be empty" && exit 1
user=$(dialog --stdout --clear --inputbox "Enter username" 0 40) || exit 1
[ -z "$user" ] && echo "username cannot be empty" && exit 1
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --clear --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
password_luks1=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password" 0 40) || exit 1
[ -z "$password_luks1" ] && echo "disk encryption password cannot be empty" && exit 1
password_luks2=$(dialog --stdout --clear --insecure --passwordbox "Enter disk encryption password again" 0 40) || exit 1
if [ "$password_luks1" != "$password_luks2" ]; then echo "Passwords did not match"; exit; fi

# Logging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# }}}
# Disks ------------------------------------------------------------------- {{{
#
# Setup the disks

# Partitioning
fdisk "$device" <<'EOF'
n
p
1

+512M
a
n
p
2


t
2
8e
w
EOF

# Encrypt Root Drive
echo -n "$password_luks1" | cryptsetup luksFormat --type luks2 "$device"2 -

# Open Root Drive
echo -n "$password_luks1" | cryptsetup open "$device"2 cryptlvm -

# Create Physical Volume
pvcreate /dev/mapper/cryptlvm

# Create Volume Group
vgcreate volgroup0 /dev/mapper/cryptlvm

# Create Logical Volumes
lvcreate -L 1G volgroup0 -n swap
lvcreate -l 100%FREE volgroup0 -n root

# Fromat Filesystems
mkswap /dev/mapper/volgroup0-swap
mkfs.ext4 /dev/mapper/volgroup0-root
mkfs.ext2 "$device"1

# Mount Filesystems
mount /dev/mapper/volgroup0-root /mnt
swapon /dev/mapper/volgroup0-swap
mkdir /mnt/boot
mount "$device"1 /mnt/boot

# }}}
# Pacstrap ---------------------------------------------------------------- {{{
#
# Install packages

# Update Mirrors
curl -s 'https://www.archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4' > /etc/pacman.d/mirrorlist.new
sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist.new
rankmirrors /etc/pacman.d/mirrorlist.new > /etc/pacman.d/mirrorlist

# Base packages
packages=(
  base \
  base-devel \
  ctags \
  curl \
  git \
  grub \
  neovim \
  ntp \
  openssh \
  python-requests \
  tmux \
  vim \
  wget \
  zip \
  zsh
)

# Workastation Packages
packages_gui=(
  adobe-source-code-pro-fonts \
  alsa-utils \
  compton \
  dmenu \
  dunst \
  feh \
  i3lock \
  i3-gaps \
  imagemagick \
  noto-fonts-cjk \
  rxvt-unicode \
  playerctl \
  scrot \
  redshift \
  thunar \
  ttf-font-awesome \
  xautolock \
  xf86-video-vesa \
  xorg \
  xorg-server \
  xorg-xinit \
  xterm
)

# Virtualbox Packages
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

# Generate Filesystem Table
genfstab -U /mnt >> /mnt/etc/fstab

# Set Hostname
echo "$hostname" > /mnt/etc/hostname
cat >>/mnt/etc/hosts <<'EOF'
127.0.0.1 localhost.localdomain localhost
::1 localhost.localdomain localhost
127.0.0.1 "$hostname".localdomain "$hostname"
EOF

# Set Locale
echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen

# Enable dhcpcd
arch-chroot /mnt systemctl enable dhcpcd

# Enable ntpd
arch-chroot /mnt systemctl enable ntpd

# Set Time Zone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime

# }}}
# AUR --------------------------------------------------------------------- {{{
#
# Install AUR packages

# Create User
arch-chroot /mnt useradd -m -d /opt/trizen trizen
echo "trizen ALL=(ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers

# Install trizen
arch-chroot /mnt su trizen -c "git clone https://aur.archlinux.org/trizen-git.git /opt/trizen/trizen-git && cd /opt/trizen/trizen-git && makepkg -si --noconfirm"

# Install packages
case "$mode" in
  2|3)
    arch-chroot /mnt su trizen -c "trizen --noconfirm -S \
      google-chrome-beta \
      otf-font-awesome-5-free \
      polybar \
      spotify \
      vertex-themes \
      visual-studio-code-insiders"
    ;;
esac

# }}}
# Users  ------------------------------------------------------------------ {{{
#
# Configure users

# Create User
arch-chroot /mnt useradd -mU -G wheel -s /usr/bin/zsh "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh "$user"
arch-chroot /mnt sed -i '/^# %wheel ALL=(ALL) ALL$/s/^# //g' /etc/sudoers

# Install sneivandt/dotfiles
arch-chroot /mnt su "$user" -c "git clone https://github.com/sneivandt/dotfiles.git /home/$user/src/dotfiles"
arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh install --gui"

# }}}
# Init -------------------------------------------------------------------- {{{
#
# Configure system startup

# Create init ramdisk
sed -i "s/^HOOKS.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# Install Grub
arch-chroot /mnt grub-install "$device"
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
device_esc=$(sed 's/\//\\\//g' <<< "$device")
sed -i "s/.*vmlinuz-linux.*/linux \\/vmlinuz-linux root=\\/dev\\/mapper\\/volgroup0-root rw cryptdevice=${device_esc}2:volgroup0 quiet/" /mnt/boot/grub/grub.cfg

# }}}
# Cleanup ----------------------------------------------------------------- {{{
#
# Complete setup

# Release Resources
umount -R /mnt
swapoff -a

# }}}
