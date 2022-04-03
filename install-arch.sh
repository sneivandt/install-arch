#!/usr/bin/env bash
set -o errexit
set -u nounset
set -o pipefail

# Preamble ---------------------------------------------------------------- {{{

# Error Trap
trap 'echo "$0: Error on line "$LINENO": $BASH_COMMAND"' ERR

# Install host packages
pacman -Sy --noconfirm dialog

# }}}
# Input ------------------------------------------------------------------- {{{
#
# User input

# Install mode
mode=$(dialog --stdout --clear --menu "Select install mode" 0 0 0 "1" "Minimal" "2" "Worktation" "3" "VirtualBox") || exit

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
  ctags \
  curl \
  dhcpcd \
  dash \
  docker \
  efibootmgr \
  git \
  grub \
  linux \
  linux-firmware \
  linux-headers \
  jq \
  lvm2 \
  mlocate \
  neovim \
  ntp \
  openssh \
  pacman-contrib \
  python-pip \
  python-requests \
  shellcheck \
  tmux \
  vim \
  wget \
  zip \
  zsh
)

# Workastation packages
packages_gui=(
  adobe-source-code-pro-fonts \
  alsa-utils \
  chromium \
  compton \
  dmenu \
  dunst \
  feh \
  noto-fonts-cjk \
  noto-fonts-emoji \
  rxvt-unicode \
  playerctl \
  redshift \
  slock \
  ttf-dejavu \
  ttf-font-awesome-5 \
  xautolock \
  xmobar \
  xmonad \
  xmonad-contrib \
  xclip \
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

# Google DNS
cat >>/mnt/etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
chattr +i /mnt/etc/resolv.conf

# Volume
case "$mode" in
  2|3)
    arch-chroot /mnt amixer -q sset Master 100%
    arch-chroot /mnt alsactl store
    ;;
esac

# Set time zone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime

# Enable dhcpcd
arch-chroot /mnt systemctl enable dhcpcd.service

# Enable docker
arch-chroot /mnt systemctl enable docker.service

# Enable time sync
arch-chroot /mnt systemctl enable systemd-timesyncd.service

# Enable paccache.timer
arch-chroot /mnt systemctl enable paccache.timer

# Enable vboxservice
[ "$mode" -eq 3 ] && arch-chroot /mnt systemctl enable vboxservice.service

# }}}
# Pacman ------------------------------------------------------------------ {{{

# Configure pacman
cat >>/mnt/etc/pacman.conf <<'EOF'
[options]
ILoveCandy
Color
EOF

mkdir -p /mnt/etc/pacman.d/hooks

# sh -> dash
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

# clean package cache
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

# xmonad --recompile
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
# Install AUR packages

# Create trizen user
arch-chroot /mnt useradd -m -d /opt/trizen trizen
echo "trizen ALL=(ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers

# Install trizen
arch-chroot /mnt su trizen -c "git clone https://aur.archlinux.org/trizen-git.git /opt/trizen/trizen-git && cd /opt/trizen/trizen-git && makepkg -si --noconfirm"

# Install packages
case "$mode" in
  2|3)
    arch-chroot /mnt su trizen -c "trizen --noconfirm -S \
      chromium-widevine \
      fzf \
      otf-font-awesome \
      vertex-themes \
      visual-studio-code-insiders-bin"
    ;;
esac

# Cleanup trizen user
arch-chroot /mnt userdel trizen
rm -rf /mnt/opt/trizen
sed -i '/trizen/d' /mnt/etc/sudoers

# }}}
# Users  ------------------------------------------------------------------ {{{
#
# Configure users

# Create user
arch-chroot /mnt useradd -mU -G docker,wheel -s /bin/zsh -p "$(openssl passwd -1 "$password1")" "$user"
arch-chroot /mnt chsh -s /bin/zsh "$user"

# Allow sudo without password
sed -i '/^# %wheel ALL=(ALL) NOPASSWD: ALL$/s/^# //g' /mnt/etc/sudoers

# Lock root
arch-chroot /mnt passwd -l root
arch-chroot /mnt usermod -s /sbin/nologin root

# Install dotfiles
arch-chroot /mnt su "$user" -c "git clone https://github.com/sneivandt/dotfiles.git /home/$user/src/dotfiles"
case "$mode" in
  1)
    arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -Ip"
    ;;
  2|3)
    arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh -Ipg"
    ;;
esac

# Require password for sudo
sed -i '/^%wheel ALL=(ALL) NOPASSWD: ALL$/s/^/# /g' /mnt/etc/sudoers
sed -i '/^# %wheel ALL=(ALL) ALL$/s/^# //g' /mnt/etc/sudoers

# }}}
# Init -------------------------------------------------------------------- {{{
#
# Configure system startup

# Create init ramdisk
sed -i "s/^HOOKS.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# Install grub
arch-chroot /mnt grub-install "$device" --efi-directory=/boot
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
device_esc=$(sed 's/\//\\\//g' <<< "$device")
sed -i "s/.*vmlinuz-linux.*/linux \\/vmlinuz-linux root=\\/dev\\/mapper\\/volgroup0-root rw cryptdevice=${device_esc}${dpfx}2:volgroup0 quiet/" /mnt/boot/grub/grub.cfg

# }}}
# Cleanup ----------------------------------------------------------------- {{{
#
# Complete setup

# Release resources
umount -R /mnt
swapoff -a

# }}}
