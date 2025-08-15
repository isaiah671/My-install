#!/bin/bash
set -euo pipefail

echo "== Arch Linux Auto-Installer (Arch first, Windows later) =="

# 1. Check boot mode
if [ ! -d /sys/firmware/efi ]; then
  echo "ERROR: System not booted in UEFI mode!"
  exit 1
fi

# 2. Check network
# ping -c 3 archlinux.org || { echo "ERROR: No internet connection."; exit 1; }

# 3. Sync system clock
timedatectl set-ntp true

# 4. Disk selection and confirmation
lsblk
read -p "Enter target disk (e.g., nvme0n1): " DISK
echo "WARNING: /dev/$DISK will be completely erased!"
echo "NOTE: This installer will set up EFI partition for Arch only."
echo "When you install Windows later, it may overwrite the bootloader."
echo "Make sure to backup your EFI partition (/boot/efi) after installation!"
read -p "Type YES to continue: " confirm
if [ "$confirm" != "YES" ]; then
  echo "Aborted."
  exit 1
fi

# 5. Prompt for LUKS passphrase and username
read -sp "Enter passphrase for LUKS encryption: " LUKS_PASS
echo
read -sp "Enter root password: " ROOT_PASS
echo
read -p "Enter new username: " USERNAME

# 6. Partitioning
echo "== Partitioning disk =="
parted /dev/$DISK --script mklabel gpt

# Create EFI partition (512MiB)
parted /dev/$DISK --script mkpart ESP fat32 1MiB 513MiB
parted /dev/$DISK --script set 1 boot on

# Create swap partition (32GiB)
parted /dev/$DISK --script mkpart primary linux-swap 513MiB 33.5GiB

# Create encrypted root (rest of disk minus home)
parted /dev/$DISK --script mkpart primary 33.5GiB 65.5GiB

# Create encrypted home (rest of disk)
parted /dev/$DISK --script mkpart primary 65.5GiB 100%

# 7. Format partitions
mkfs.fat -F32 /dev/${DISK}p1
mkswap /dev/${DISK}p2
swapon /dev/${DISK}p2

# Encrypt root and home (safer passphrase handling)
cryptsetup luksFormat /dev/${DISK}p3 --key-file <(echo -n "$LUKS_PASS")
cryptsetup open /dev/${DISK}p3 cryptroot --key-file <(echo -n "$LUKS_PASS")
cryptsetup luksFormat /dev/${DISK}p4 --key-file <(echo -n "$LUKS_PASS")
cryptsetup open /dev/${DISK}p4 crypthome --key-file <(echo -n "$LUKS_PASS")

# 8. Format LUKS volumes (EXT4)
mkfs.ext4 /dev/mapper/cryptroot
mkfs.ext4 /dev/mapper/crypthome

# 9. Mount
mount /dev/mapper/cryptroot /mnt
mkdir /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir -p /mnt/boot/efi
mount /dev/${DISK}p1 /mnt/boot/efi

# Get UUIDs now (outside chroot to avoid name mismatch issues)
ROOT_UUID=$(blkid -s UUID -o value /dev/${DISK}p3)
SWAP_UUID=$(blkid -s UUID -o value /dev/${DISK}p2)
CRYPT_STRING="cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot resume=UUID=$SWAP_UUID"

# Export variables so chroot can use them
export ROOT_UUID SWAP_UUID CRYPT_STRING ROOT_PASS USERNAME

# 10. Install base system and essential packages
pacstrap /mnt base linux linux-firmware vim sudo networkmanager \
  gdm gnome gnome-extra plasma kde-applications xorg \
  intel-ucode firefox keepassxc syncthing git base-devel grub efibootmgr

# 11. Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 12. Chroot configuration
arch-chroot /mnt /bin/bash <<'EOF'
set -e

# Timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "archpc" > /etc/hostname
cat <<HOSTS >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archpc.localdomain archpc
HOSTS

# Set root password
echo "root:$ROOT_PASS" | chpasswd

# Create user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$ROOT_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Update mkinitcpio hooks for encryption and resume
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems resume)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Enable GRUB crypto disk support (fixes error)
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

# Configure GRUB for encrypted root + resume
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$CRYPT_STRING\"|" /etc/default/grub

# Install GRUB EFI bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Backup EFI partition
tar -czf /root/efi-backup.tar.gz -C /boot efi

# Enable essential services
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable syncthing@$USERNAME
EOF

echo "== Installation complete! =="
echo "IMPORTANT:"
echo "- EFI partition contains Arch bootloader."
echo "- Backup saved in /root/efi-backup.tar.gz"
echo "- If Windows overwrites bootloader, restore with:"
echo "    mount /dev/${DISK}p1 /mnt/boot/efi"
echo "    arch-chroot /mnt"
echo "    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"
echo "    grub-mkconfig -o /boot/grub/grub.cfg"
echo
echo "Reboot and remove the installation media."
