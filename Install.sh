#!/usr/bin/env bash
set -euo pipefail

### ===== Function: Ask for password with confirmation ===== ###
ask_password() {
    local pass1 pass2 prompt="$1"
    while true; do
        read -s -p "$prompt: " pass1 && echo
        read -s -p "Confirm $prompt: " pass2 && echo
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            echo "$pass1"
            return
        else
            echo "Passwords do not match or are empty. Try again."
        fi
    done
}

### ===== Step 0: Cleanup previous mounts/mappings ===== ###
echo "[*] Cleaning up old mounts and encrypted devices..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
cryptsetup close crypthome 2>/dev/null || true

### ===== Step 1: Select disk ===== ###
lsblk
read -rp "Enter target NVMe device (e.g., nvme0n1): " DISK
DISK="/dev/$DISK"

### ===== Step 2: Ask passwords ===== ###
ROOT_PASS=$(ask_password "Root encryption password")
HOME_PASS=$(ask_password "Home encryption password")
USER_NAME=""
while [[ -z "$USER_NAME" ]]; do
    read -rp "Enter username: " USER_NAME
done
USER_PASS=$(ask_password "Password for user '$USER_NAME'")

### ===== Step 3: Partition ===== ###
echo "[*] Partitioning disk..."
sgdisk --zap-all "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB 512MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart cryptroot 512MiB 50%
parted -s "$DISK" mkpart crypthome 50% 95%
parted -s "$DISK" mkpart linux-swap 95% 100%

### ===== Step 4: Encryption & formatting ===== ###
# Root
echo "[*] Setting up root encryption..."
echo -n "$ROOT_PASS" | cryptsetup luksFormat "${DISK}p2" -
echo -n "$ROOT_PASS" | cryptsetup open "${DISK}p2" cryptroot -
mkfs.ext4 /dev/mapper/cryptroot

# Home
echo "[*] Setting up home encryption..."
echo -n "$HOME_PASS" | cryptsetup luksFormat "${DISK}p3" -
echo -n "$HOME_PASS" | cryptsetup open "${DISK}p3" crypthome -
mkfs.ext4 /dev/mapper/crypthome

# Swap
mkswap "${DISK}p4"

# EFI
mkfs.fat -F32 "${DISK}p1"

### ===== Step 5: Mount ===== ###
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot
swapon "${DISK}p4"

### ===== Step 6: Install base system ===== ###
pacstrap /mnt base linux linux-firmware grub efibootmgr sudo nano vim networkmanager

### ===== Step 7: Generate fstab ===== ###
genfstab -U /mnt >> /mnt/etc/fstab

### ===== Step 8: Configure system ===== ###
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "[*] Timezone & clock..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo "[*] Locale..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[*] Hostname..."
echo "archlinux" > /etc/hostname

echo "[*] Set root password..."
echo "root:$ROOT_PASS" | chpasswd

echo "[*] Create user..."
useradd -m -G wheel "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

echo "[*] Configure mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "[*] Configure GRUB..."
ROOT_UUID=\$(blkid -s UUID -o value ${DISK}p2)
HOME_UUID=\$(blkid -s UUID -o value ${DISK}p3)
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$ROOT_UUID:cryptroot cryptdevice=UUID=\$HOME_UUID:crypthome root=/dev/mapper/cryptroot\"|" /etc/default/grub
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

### ===== Step 9: Final cleanup ===== ###
echo "[*] Cleaning up..."
umount -R /mnt
swapoff -a
cryptsetup close cryptroot
cryptsetup close crypthome

echo "[✓] Installation complete!"
