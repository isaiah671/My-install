#!/usr/bin/env bash
set -euo pipefail

### ===== Helpers =====
ask_password() {
    local pass1 pass2 prompt="$1"
    while true; do
        read -s -p "$prompt: " pass1 && echo
        read -s -p "Confirm $prompt: " pass2 && echo
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            printf "%s" "$pass1"
            return
        else
            echo "Passwords do not match or are empty. Try again."
        fi
    done
}

wipe_disk() {
    local dev="$1"
    echo "[*] Wiping $dev ..."
    # best: trim the whole device (instant on many NVMe/SSD)
    if command -v blkdiscard >/dev/null 2>&1; then
        blkdiscard -f "$dev" || true
    fi
    # zap GPT & protective MBR
    sgdisk --zap-all "$dev" || true
    # remove any FS signatures
    wipefs -a "$dev" || true
    # zero first/last 16MiB to kill stray headers
    dd if=/dev/zero of="$dev" bs=1M count=16 conv=fsync status=none || true
    # compute last LBA in MiB and zero tail
    if command -v blockdev >/dev/null 2>&1; then
        sz_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        if [[ "$sz_bytes" -gt 0 ]]; then
            seek_mb=$(( sz_bytes/1024/1024 - 16 ))
            if [[ "$seek_mb" -gt 0 ]]; then
                dd if=/dev/zero of="$dev" bs=1M seek="$seek_mb" count=16 conv=fsync status=none || true
            fi
        fi
    fi
}

### ===== 0) Pre-clean any remnants =====
echo "[*] Cleaning up previous mounts, swap, and LUKS..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
for m in cryptroot crypthome; do cryptsetup close "$m" 2>/dev/null || true; done

### ===== 1) Sanity checks =====
if [ ! -d /sys/firmware/efi ]; then
  echo "ERROR: Not booted in UEFI mode."; exit 1
fi
#ping -c 3 archlinux.org >/dev/null || { echo "ERROR: No internet."; exit 1; }
timedatectl set-ntp true

### ===== 2) Pick target disk =====
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
read -rp "Enter **ENTIRE DISK** (e.g., nvme0n1): " DISK_SHORT
DISK="/dev/$DISK_SHORT"

echo "DESTRUCTIVE ACTION: $DISK WILL BE ERASED."
read -rp 'Type YES to confirm: ' really
[[ "$really" == "YES" ]] || { echo "Aborted."; exit 1; }

### ===== 3) Credentials (single encryption pass + user creds) =====
ENC_PASS=$(ask_password "LUKS encryption password (one password for root & home)")
echo
read -rp "Enter username: " USER_NAME
USER_PASS=$(ask_password "Password for user '$USER_NAME'")
echo
ROOT_PASS=$(ask_password "Root account password")
echo

### ===== 4) Full device wipe =====
wipe_disk "$DISK"

### ===== 5) Partition layout =====
# p1 EFI (512MiB) | p2 swap (32GiB) | p3 cryptroot | p4 crypthome (rest)
echo "[*] Creating partitions..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart linux-swap 513MiB 33.5GiB
parted -s "$DISK" mkpart cryptroot 33.5GiB 65.5GiB
parted -s "$DISK" mkpart crypthome 65.5GiB 100%

EFI="${DISK}p1"
SWAP="${DISK}p2"
P_ROOT="${DISK}p3"
P_HOME="${DISK}p4"

### ===== 6) Filesystems & LUKS =====
echo "[*] Making filesystems..."
mkfs.fat -F32 "$EFI"
mkswap "$SWAP"

echo "[*] Setting up LUKS (one pass for both containers)..."
# safer: no passphrase in args list
cryptsetup luksFormat "$P_ROOT" --key-file <(printf "%s" "$ENC_PASS")
cryptsetup open "$P_ROOT" cryptroot --key-file <(printf "%s" "$ENC_PASS")

cryptsetup luksFormat "$P_HOME" --key-file <(printf "%s" "$ENC_PASS")
cryptsetup open "$P_HOME" crypthome --key-file <(printf "%s" "$ENC_PASS")

mkfs.ext4 /dev/mapper/cryptroot
mkfs.ext4 /dev/mapper/crypthome

### ===== 7) Mount target =====
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi
swapon "$SWAP"

### ===== 8) Base install (minimal; add DEs later if you want) =====
pacstrap /mnt base linux linux-firmware grub efibootmgr sudo vim nano networkmanager

### ===== 9) fstab =====
genfstab -U /mnt >> /mnt/etc/fstab

### ===== 10) Configure inside chroot =====
# Export for heredoc (single-quoted EOF prevents premature expansion)
export DISK EFI SWAP P_ROOT P_HOME USER_NAME USER_PASS ROOT_PASS ENC_PASS
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

# Time/locale/host
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname
cat >/etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
H

# Accounts
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# mkinitcpio: ensure encrypt before filesystems; include resume later
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems resume)/' /etc/mkinitcpio.conf

# Gather UUIDs from inside the target system
ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")
HOME_UUID=$(blkid -s UUID -o value "$P_HOME")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP")

# crypttab for home (same passphrase; will prompt at boot)
echo "crypthome UUID=$HOME_UUID none luks" > /etc/crypttab

# Kernel cmdline for root+resume; GRUB crypto enabled
sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot resume=UUID=$SWAP_UUID\"|" /etc/default/grub

# Build initramfs AFTER config is set
mkinitcpio -P

# Install & configure GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Network
systemctl enable NetworkManager

# Backup EFI (handy if Windows overwrites it later)
tar -czf /root/efi-backup.tar.gz -C /boot efi
EOF

### ===== 11) Final tidy =====
echo "[*] Final cleanup..."
umount -R /mnt || true
swapoff -a || true
for m in crypthome cryptroot; do cryptsetup close "$m" 2>/dev/null || true; done

echo "== All done! =="
echo "- EFI backup in /root/efi-backup.tar.gz (inside the installed system)."
echo "- If Windows overwrites bootloader later, you can chroot and run:"
echo "    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"
echo "    grub-mkconfig -o /boot/grub/grub.cfg"
