#!/bin/bash

# Trap Error
set -uo pipefail
trap 'echo "$0: Error on line "$LINENO": $BASH_COMMAND"' ERR

# User Input
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
: "${hostname:?"hostname cannot be empty"}"
user=$(dialog --stdout --inputbox "Enter username" 0 0) || exit 1
: "${user:?"user cannot be empty"}"
password=$(dialog --stdout --passwordbox "Enter password" 0 0) || exit 1
: "${password:?"password cannot be empty"}"
password2=$(dialog --stdout --passwordbox "Enter password again" 0 0) || exit 1
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1

# Logging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# ntp
timedatectl set-ntp true

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

+4096M
t
2
82
n
p
3


w
EOF

# Wipe Disks
wipefs "$device"1
wipefs "$device"2
wipefs "$device"3

# Filesystem
mkfs.ext2 "$device"1
mkswap "$device"2
mkfs.ext4 "$device"3

# Mount Drives
swapon "$device"2
mount "$device"3 /mnt
mkdir /mnt/boot
mount "$device"1 /mnt/boot

# Update Mirrors
curl -s 'https://www.archlinux.org/mirrorlist/?country=US&protocol=http&protocol=https&ip_version=4' > /etc/pacman.d/mirrorlist
sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist

# Yaourt repo
cat >>/etc/pacman.conf <<'EOF'
[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/$arch
EOF

# Pacstrap
pacstrap /mnt base base-devel ctags curl git grub ntp openssh tmux vim wget yaourt zip zsh

# Yaourt repo
cat >>/mnt/etc/pacman.conf <<'EOF'
[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/$arch
EOF

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

# Create User
arch-chroot /mnt useradd -mU -G wheel -s /usr/bin/zsh "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh "$user"
arch-chroot /mnt sed -i '/^# %wheel ALL=(ALL) ALL$/s/^# //g' /etc/sudoers

# Install dotfiles
arch-chroot /mnt su "$user" -c "git clone https://github.com/sneivandt/dotfiles.git /home/$user/src/dotfiles"
arch-chroot /mnt su "$user" -c "/home/$user/src/dotfiles/dotfiles.sh install"

# Install Grub
arch-chroot /mnt grub-install "$device"
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Set Passwords
echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

# Cleanup
umount -R /mnt
swapoff -a
