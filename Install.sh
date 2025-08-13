#!/bin/bash
set -euo pipefail

echo "== Arch Linux Auto-Installer =="

# 1. Check boot mode
if [ ! -d /sys/firmware/efi ]; then
  echo "ERROR: System not booted in UEFI mode!"
  exit 1
fi

# 2. Check network
ping -c 3 archlinux.org || { echo "ERROR: No internet connection."; exit 1; }

# 3. Sync system clock
timedatectl set-ntp true

# 4. Disk selection and confirmation
lsblk
read -p "Enter target disk (e.g., nvme0n1): " DISK
echo "WARNING: /dev/$DISK will be completely erased!"
read -p "Type YES to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# 5. Prompt for passwords and username
read -sp "Enter passphrase for LUKS encryption: " LUKS_PASS
echo
read -sp "Enter root password: " ROOT_PASS
echo
read -p "Enter new username: " USERNAME
read -sp "Enter password for $USERNAME: " USER_PASS
echo

# 6. Partitioning
echo "== Partitioning disk =="
parted /dev/$DISK --script mklabel gpt
parted /dev/$DISK --script mkpart ESP fat32 1MiB 513MiB
parted /dev/$DISK --script set 1 boot on
parted /dev/$DISK --script mkpart primary linux-swap 513MiB 33.5GiB
parted /dev/$DISK --script mkpart primary 33.5GiB 65.5GiB
parted /dev/$DISK --script mkpart primary 65.5GiB 100%

# 7. Format partitions
mkfs.fat -F32 /dev/${DISK}p1
mkswap /dev/${DISK}p2
swapon /dev/${DISK}p2

# Encrypt root and home
echo -n "$LUKS_PASS" | cryptsetup luksFormat /dev/${DISK}p3 -
echo -n "$LUKS_PASS" | cryptsetup open /dev/${DISK}p3 cryptroot -
echo -n "$LUKS_PASS" | cryptsetup luksFormat /dev/${DISK}p4 -
echo -n "$LUKS_PASS" | cryptsetup open /dev/${DISK}p4 crypthome -

# 8. Format LUKS volumes
mkfs.btrfs /dev/mapper/cryptroot
mkfs.btrfs /dev/mapper/crypthome

# 9. Mount
mount /dev/mapper/cryptroot /mnt
mkdir /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir /mnt/boot
mount /dev/${DISK}p1 /mnt/boot

# 10. Install base system
pacstrap /mnt base linux linux-firmware btrfs-progs vim sudo networkmanager \
    gdm gnome gnome-extra plasma kde-applications xorg \
    intel-ucode firefox keepassxc syncthing git base-devel

# 11. Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 12. Chroot configuration
arch-chroot /mnt /bin/bash <<EOF
set -e

# 12a. Timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# 12b. Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# 12c. Hostname
echo "archpc" > /etc/hostname
echo "127.0.0.1   localhost" >> /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   archpc.localdomain archpc" >> /etc/hosts

# 12d. Root password
echo "root:$ROOT_PASS" | chpasswd

# 12e. Create user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# 12f. Initramfs
mkinitcpio -P

# 12g. Install GRUB
pacman -Sy --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 12h. Enable services
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable syncthing@$USERNAME

EOF

echo "== Installation complete! Reboot and remove the ISO. =="
