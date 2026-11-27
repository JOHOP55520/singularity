#!/bin/bash
# =============================================================================
#  SINGULARITY-SYSTEMS INSTALLER  -  Artix / dinit edition
# -----------------------------------------------------------------------------
#  Boot an Artix *dinit* live ISO in UEFI mode (Secure Boot OFF), then run this
#  as root.  Result:
#    Artix repos + dinit + elogind     doas (no sudo)       XFS on plain LVM
#    Limine on the ESP (= /boot)       zram + swap LV       no login manager
#    AMD + Intel: both microcodes, Vulkan driver(s) picked by hardware detection
# =============================================================================
set -eE -o pipefail

# ------------------------------- settings ------------------------------------
VG="singularity"      # LVM volume group name
ESP_MIB=1024          # FAT32 ESP, mounted at /boot (Limine can't read XFS)
SWAP_SIZE="8G"        # swap LV
ROOT_SIZE="120G"      # root LV size
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"
USE_CACHYOS=1         # 1 = CachyOS repo (listed LAST) + linux-cachyos-bore, 0 = Artix linux-zen
USE_NEXTDNS=1         # DoT to your NextDNS profile via unbound (no systemd-resolved on Artix)
NEXTDNS_ID="${NEXTDNS_ID:-}"   # not stored in the repo: asked at install time, or run: NEXTDNS_ID=xxxxxx bash install.sh
DOAS_NOPASS=0         # 1 = 'permit nopass' (what your old NOPASSWD sudoers line did)
# -----------------------------------------------------------------------------

say()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
chr()  { artix-chroot /mnt "$@"; }

# shellcheck disable=SC2154  # rc is set inside the trap string
trap 'rc=$?; echo ""; echo "================================================"; echo "  INSTALL FAILED ON LINE $LINENO (exit code $rc)"; echo "  Spawning debug shell. Type \"exit\" when done."; echo "================================================"; /bin/bash' ERR

echo ""
echo "============================================"
echo "   SINGULARITY-SYSTEMS INSTALLER  (dinit)   "
echo "============================================"
warn "Secure Boot must be DISABLED in the BIOS (Limine is unsigned)."
echo ""

[[ $EUID -eq 0 ]]          || die "Run as root."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."

# ------------------------------- live dependencies ---------------------------
# Packages the live session needs before any disk work. Installed up front.
LIVE_PKGS=(
    artix-keyring curl iputils parted dosfstools xfsprogs lvm2 chrony e2fsprogs 
    util-linux coreutils
)
# Commands that must exist. If one is missing after the package install, the
# script asks the package database which package ships /usr/bin/<cmd>.
REQUIRED_CMDS=(
    curl ping lsblk blkid wipefs parted partprobe mkfs.fat mkfs.ext4
    pvcreate vgcreate lvcreate lvs vgs pvs vgchange vgremove
    numfmt basestrap artix-chroot pacman-key
)
# Present on a dinit live ISO by default. Checked, but not installed (they may
# come from a different package than the one a file search would suggest).
CHECK_ONLY_CMDS=(udevadm dinitctl modprobe)

install_live_deps() {
    say "Installing live-environment dependencies..."
    pacman -Sy --noconfirm --needed "${LIVE_PKGS[@]}" \
        || die "Could not install the live dependencies. Check the network and retry."

    local cmd pkg
    pacman -Fy >/dev/null 2>&1 || warn "Could not refresh the file database (pacman -F); fallback search disabled."
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then continue; fi
        warn "'$cmd' still missing - looking for the package that provides it..."
        pkg=$(pacman -Fq "/usr/bin/$cmd" 2>/dev/null | head -n1 | sed 's|^[^/]*/||')
        [[ -n $pkg ]] || die "No package provides '$cmd'. Boot a current Artix dinit ISO."
        pacman -S --noconfirm --needed "$pkg" || die "Failed to install '$pkg' (for $cmd)."
    done

    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}" "${CHECK_ONLY_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        die "Still missing after dependency install: ${missing[*]}"
    fi
    say "All live dependencies present."
}

# ------------------------------ clock / swap / mounts ------------------------
say "Syncing clock..."
dinitctl start ntpd 2>/dev/null || warn "no ntpd service on this ISO - clock may be off"
sleep 5

swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
udevadm settle

# ------------------------------ network ---------------------------------------
say "Checking network connection..."
if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
    warn "No internet connection detected."
    if command -v nmtui >/dev/null; then
        nmtui
    else
        echo "Connect first (Artix base ISO: connmanctl), then press Enter."
        read -r _
    fi
    ping -c1 -W3 8.8.8.8 &>/dev/null || die "Still offline."
fi

# ------------------------- live-ISO keyring and tools ------------------------
say "Preparing live environment (keyring)..."
pacman-key --init
pacman-key --populate artix
install_live_deps
pacman-key --populate artix

if [[ $USE_CACHYOS == 1 ]]; then
    say "Importing CachyOS signing key..."
    if ! pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com; then
        curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF3B607488DB35A47' | pacman-key --add -
    fi
    pacman-key --lsign-key F3B607488DB35A47
fi

# ------------------------------- CPU level -----------------------------------
# znver4 = Zen 4/5 (AVX-512), v4/v3 = generic x86-64 levels. Picks CachyOS repos.
CPU_VENDOR=$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
CPU_FAMILY=$(awk -F': *' '/^cpu family/{print $2; exit}' /proc/cpuinfo)
CPU_LEVEL="base"
if [[ $CPU_VENDOR == AuthenticAMD ]] && (( CPU_FAMILY >= 25 )) && grep -q avx512f /proc/cpuinfo; then
    CPU_LEVEL="znver4"
elif /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-v4"; then
    CPU_LEVEL="v4"
elif /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-v3"; then
    CPU_LEVEL="v3"
fi
say "CPU level detected: $CPU_LEVEL"

# pacman only installs packages whose arch is listed here; the CachyOS
# v3/v4/znver4 repos ship x86_64_v3 / x86_64_v4 packages.
case $CPU_LEVEL in
    znver4|v4) ARCH_LIST="x86_64 x86_64_v3 x86_64_v4" ;;
    v3)        ARCH_LIST="x86_64 x86_64_v3" ;;
    *)         ARCH_LIST="auto" ;;
esac

# ------------------------------- pacman.conf ---------------------------------
# Artix repos first. [core] must NEVER be enabled on Artix (systemd-dependent).
say "Writing pacman.conf (Artix repos first)..."
cp -n /etc/pacman.conf /etc/pacman.conf.live-bak
cat > /etc/pacman.conf <<'EOF'
[options]
HoldPkg           = pacman glibc
Architecture      = auto
Color
CheckSpace
ParallelDownloads = 5
SigLevel          = Required DatabaseOptional
LocalFileSigLevel = Optional

[system]
Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist

[lib32]
Include = /etc/pacman.d/mirrorlist
EOF
if [[ $USE_CACHYOS == 1 ]]; then
    # Level-specific repos first (they win over the generic [cachyos] below).
    case $CPU_LEVEL in
        znver4) LEVEL_DIR=x86_64_v4; LEVEL_REPOS="cachyos-znver4 cachyos-core-znver4 cachyos-extra-znver4" ;;
        v4)     LEVEL_DIR=x86_64_v4; LEVEL_REPOS="cachyos-v4 cachyos-core-v4 cachyos-extra-v4" ;;
        v3)     LEVEL_DIR=x86_64_v3; LEVEL_REPOS="cachyos-v3 cachyos-core-v3 cachyos-extra-v3" ;;
        *)      LEVEL_DIR=""; LEVEL_REPOS="" ;;
    esac
    for r in $LEVEL_REPOS; do
        printf '\n[%s]\nServer = https://mirror.cachyos.org/repo/%s/%s/\nServer = https://cdn.cachyos.org/repo/%s/%s/\n' \
            "$r" "$LEVEL_DIR" "$r" "$LEVEL_DIR" "$r" >> /etc/pacman.conf
    done
    # Signatures are verified (the key was locally signed above).
    cat >> /etc/pacman.conf <<'EOF'

[cachyos]
Server = https://mirror.cachyos.org/repo/x86_64/cachyos
Server = https://cdn.cachyos.org/repo/x86_64/cachyos
EOF
fi
sed -i "s/^Architecture .*/Architecture      = ${ARCH_LIST}/" /etc/pacman.conf
pacman -Sy --noconfirm

# ---------------------------- hardware detection -----------------------------
say "Detecting hardware (AMD / Intel)..."
has_amd=0; has_intel=0; has_nvidia=0
for v in /sys/class/drm/card[0-9]*/device/vendor; do
    [[ -r $v ]] || continue
    case $(<"$v") in
        0x1002) has_amd=1 ;;
        0x8086) has_intel=1 ;;
        0x10de) has_nvidia=1 ;;
    esac
done
GPU_PKGS=(mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader)
unknown=0
if (( ! has_amd && ! has_intel && ! has_nvidia )); then unknown=1; fi
if (( has_amd   || unknown )); then GPU_PKGS+=(vulkan-radeon lib32-vulkan-radeon); fi
if (( has_intel || unknown )); then GPU_PKGS+=(vulkan-intel lib32-vulkan-intel); fi
if (( has_nvidia )); then warn "NVIDIA GPU found: only nouveau/mesa is installed. Proprietary driver + Wayland setup is not automated here."; fi

KERNEL="linux-zen"
if [[ $USE_CACHYOS == 1 ]]; then
    if pacman -Si linux-cachyos-bore linux-cachyos-bore-headers cachyos-keyring &>/dev/null; then
        KERNEL="linux-cachyos-bore"
    else
        warn "linux-cachyos-bore not available in the CachyOS repo - falling back to linux-zen."
        USE_CACHYOS=0
    fi
fi

PKGS=(
    base dinit elogind-dinit dbus dbus-dinit artix-keyring artix-mirrorlist
    "$KERNEL" "${KERNEL}-headers" linux-firmware mkinitcpio lz4
    amd-ucode intel-ucode
    lvm2 xfsprogs dosfstools efibootmgr limine
    opendoas
    networkmanager networkmanager-dinit
    zramen zramen-dinit
    polkit libsecret xorg-xwayland git nano
    # makepkg toolchain = base-devel minus sudo (base-devel would drag sudo back in)
    autoconf automake binutils bison debugedit fakeroot flex gcc groff libtool m4 make patch pkgconf texinfo which
    "${GPU_PKGS[@]}"
)
if [[ $USE_CACHYOS == 1 ]]; then PKGS+=(cachyos-keyring); fi

# nice-to-have packages: installed one by one, skipped if missing
OPT_PKGS=(bluez bluez-utils bluez-dinit chrony chrony-dinit irqbalance irqbalance-dinit
          ananicy-cpp ananicy-cpp-dinit device-mapper-dinit lvm2-dinit)

say "Pre-flight: checking that every package exists BEFORE touching the disk..."
MISSING=()
for p in "${PKGS[@]}"; do
    pacman -Si "$p" &>/dev/null || MISSING+=("$p")
done
(( ${#MISSING[@]} == 0 )) || die "Not found in the enabled repos: ${MISSING[*]}"

# ------------------------------- user input ----------------------------------
echo ""
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -Ev '^/dev/(loop|sr|zram)' || true
read -rp "Target disk (e.g. /dev/nvme0n1): " DRIVE
[[ -b $DRIVE ]] || die "$DRIVE is not a block device."
warn "ALL DATA on $DRIVE will be destroyed!"
read -rp "Type YES to confirm: " CONFIRM
[[ $CONFIRM == YES ]] || die "Aborted."

read -rp "Enter username: " NEW_USER
[[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username."
read -rsp "Enter password: " NEW_PASS; echo
read -rsp "Repeat password: " NEW_PASS2; echo
[[ -n $NEW_PASS && $NEW_PASS == "$NEW_PASS2" ]] || die "Passwords empty or not matching."

if [[ $USE_NEXTDNS == 1 && -z $NEXTDNS_ID ]]; then
    read -rp "NextDNS profile ID (6 characters): " NEXTDNS_ID
fi
if [[ $USE_NEXTDNS == 1 ]]; then
    [[ $NEXTDNS_ID =~ ^[A-Za-z0-9]+$ ]] || die "Missing/invalid NextDNS profile ID (set USE_NEXTDNS=0 to skip NextDNS)."
fi
HOST="${NEW_USER}-pc"

if [[ $DRIVE == *nvme* || $DRIVE == *mmcblk* ]]; then P="p"; else P=""; fi
BOOT_P="${DRIVE}${P}1"
PV_P="${DRIVE}${P}2"

# ------------------------- partition + LVM + XFS -----------------------------
say "Partitioning $DRIVE..."
if vgs --noheadings "$VG" &>/dev/null; then
    if pvs --noheadings -o pv_name -S "vg_name=$VG" | grep -qv "^ *${DRIVE}"; then
        die "A volume group called '$VG' already exists on ANOTHER disk. Rename or remove it first."
    fi
    vgchange -an "$VG"
    vgremove -ff -y "$VG"
fi
wipefs -af "$DRIVE"
parted -s "$DRIVE" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "$((ESP_MIB + 1))MiB" set 1 esp on \
    mkpart lvm "$((ESP_MIB + 1))MiB" 100% set 2 lvm on
partprobe "$DRIVE"
udevadm settle
sleep 2
wipefs -af "$BOOT_P" "$PV_P"


say "Creating LVM physical volume, volume group and logical volumes..."
pvcreate -ff -y "$PV_P"
vgcreate -y "$VG" "$PV_P"
lvcreate -y -L "$SWAP_SIZE" -n swap "$VG"
lvcreate -y -l 60%FREE -n root "$VG"
lvcreate -y -l 100%FREE -n home "$VG"

mkswap -L swap "/dev/$VG/swap"
mkfs.fat -F32 -n BOOT "$BOOT_P"
mkfs.ext4 -F -L SG_ROOT "/dev/$VG/root"
mkfs.ext4 -F -L SG_HOME "/dev/$VG/home"
udevadm settle

mount -o noatime "/dev/$VG/root" /mnt
mkdir -p /mnt/home /mnt/boot
mount -o noatime "/dev/$VG/home" /mnt/home
mount -o fmask=0077,dmask=0077 "$BOOT_P" /mnt/boot
swapon "/dev/$VG/swap"

# initramfs config goes in BEFORE the kernel is installed, so the first build is already LVM-aware
mkdir -p /mnt/etc/mkinitcpio.conf.d
cat > /mnt/etc/mkinitcpio.conf.d/singularity.conf <<'EOF'
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block lvm2 filesystems)
COMPRESSION="lz4"
EOF

# ------------------------------- base system ---------------------------------
say "Installing base system via basestrap..."
basestrap /mnt "${PKGS[@]}"
install -m644 /etc/pacman.conf /mnt/etc/pacman.conf

say "Writing fstab..."
# Device-mapper paths for root/home.
ESP_UUID=$(blkid -s UUID -o value "$BOOT_P")
cat > /mnt/etc/fstab <<EOF
/dev/mapper/${VG}-root   /      ext4    rw,noatime                        0 0
/dev/mapper/${VG}-home   /home  ext4    rw,noatime                        0 0
UUID=${ESP_UUID}         /boot  vfat   rw,noatime,fmask=0077,dmask=0077  0 2
/dev/mapper/${VG}-swap   none   swap   defaults                          0 0
EOF

# ------------------------------ system settings ------------------------------
say "Configuring locale, time, hostname, sysctl, LVM..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
chr hwclock --systohc || warn "hwclock --systohc failed (ignored)"
sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /mnt/etc/locale.gen
chr locale-gen
echo "LANG=${LOCALE}" > /mnt/etc/locale.conf
echo "$HOST" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST}.localdomain ${HOST}
EOF

mkdir -p /mnt/etc/sysctl.d
cat > /mnt/etc/sysctl.d/99-singularity-mem.conf <<'EOF'
# zram + disk swap: swap eagerly, keep RAM free (zram is higher priority than the swap LV)
vm.swappiness = 100
vm.page-cluster = 0
vm.max_map_count = 2147483642
vm.vfs_cache_pressure = 100
EOF


# ------------------------------ doas / makepkg / paru ------------------------
say "Configuring doas (no sudo)..."
if [[ $DOAS_NOPASS == 1 ]]; then echo "permit nopass :wheel" > /mnt/etc/doas.conf
else echo "permit persist :wheel" > /mnt/etc/doas.conf; fi
chmod 0400 /mnt/etc/doas.conf
chr doas -C /etc/doas.conf || warn "doas.conf did not validate!"

mkdir -p /mnt/etc/makepkg.conf.d
cat > /mnt/etc/makepkg.conf.d/singularity.conf <<'EOF'
PACMAN_AUTH=(doas)
MAKEFLAGS="-j$(nproc)"
EOF

# --------------------------------- user --------------------------------------
say "Creating user $NEW_USER..."
USER_GROUPS=""
for g in wheel video audio input render; do
    if chr getent group "$g" >/dev/null; then USER_GROUPS+="${USER_GROUPS:+,}$g"; fi
done
chr useradd -m -G "$USER_GROUPS" -s /bin/bash "$NEW_USER"
printf '%s:%s\n' "$NEW_USER" "$NEW_PASS" | chr chpasswd      # stdin, so $ and ` in passwords survive

UH="/mnt/home/$NEW_USER"
mkdir -p "$UH/.config/paru"
cat > "$UH/.config/paru/paru.conf" <<'EOF'
[options]
BottomUp
RemoveMake
CleanAfter

[bin]
Sudo = doas
EOF

# No login manager: log in on tty1 and MangoWM starts (only if it is installed).
cat > "$UH/.bash_profile" <<'EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z $WAYLAND_DISPLAY && -z $DISPLAY && $(tty) == /dev/tty1 ]] && command -v mango >/dev/null; then
    exec dbus-run-session mango
fi
EOF

cat > "$UH/post-install.sh" <<'EOF'
#!/bin/sh
# Run once after the first login (needs network): AUR parts the installer can't do.
set -e
if ! command -v paru >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
fi
# provides 'sudo' as a wrapper around doas, for tools that hard-code sudo
paru -S --needed --noconfirm doas-sudo-shim
# compositor
paru -S --needed --noconfirm mangowm-git
# TODO: your shell + extras (quickshell, matugen, ...) go here
echo "Done. Log out and log back in on tty1 to start MangoWM."
EOF
chmod +x "$UH/post-install.sh"
chr chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER"

mkdir -p /mnt/etc/pacman.d/hooks

cat > /mnt/etc/pacman.d/hooks/99-limine.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Updating Limine EFI binary on the ESP...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
EOF

# ------------------------------ dinit services -------------------------------
# Every *-dinit package ships its service file(s) in /etc/dinit.d; enabling = a
# symlink in /etc/dinit.d/boot.d.  Enabling by package avoids guessing service names.
enable_pkg_services() {
    local pkg f svc
    mkdir -p /mnt/etc/dinit.d/boot.d
    for pkg in "$@"; do
        while read -r f; do
            svc=${f##*/}
            ln -sfn "../$svc" "/mnt/etc/dinit.d/boot.d/$svc"
            echo "    enabled: $svc  ($pkg)"
        done < <(chr pacman -Qlq "$pkg" 2>/dev/null | grep -E '^/etc/dinit\.d/[^/]+$' | grep -v 'wait-online' || true)
    done
}

say "Installing optional packages..."
OPT_OK=()
for p in "${OPT_PKGS[@]}"; do
    if chr pacman -S --needed --noconfirm "$p" &>/dev/null; then OPT_OK+=("$p"); else warn "optional package unavailable: $p"; fi
done

say "Enabling dinit services..."
enable_pkg_services dbus-dinit elogind-dinit networkmanager-dinit zramen-dinit
for p in "${OPT_OK[@]}"; do
    if [[ $p == *-dinit ]]; then enable_pkg_services "$p"; fi
done

# ---------------------------- NextDNS (DoT, strict) --------------------------
if [[ $USE_NEXTDNS == 1 ]]; then
    say "Configuring NextDNS over TLS (unbound)..."
    if chr pacman -S --needed --noconfirm unbound unbound-dinit &>/dev/null; then
        cat > /mnt/etc/unbound/unbound.conf <<EOF
server:
    interface: 127.0.0.1
    interface: ::1
    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt
    hide-identity: yes
    hide-version: yes

# Strict: ONLY your NextDNS profile (hostname-authenticated). No fallback resolvers.
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 45.90.28.0#${NEXTDNS_ID}.dns.nextdns.io
    forward-addr: 2a07:a8c0::#${NEXTDNS_ID}.dns.nextdns.io
    forward-addr: 45.90.30.0#${NEXTDNS_ID}.dns.nextdns.io
    forward-addr: 2a07:a8c1::#${NEXTDNS_ID}.dns.nextdns.io
EOF
        enable_pkg_services unbound-dinit
        mkdir -p /mnt/etc/NetworkManager/conf.d
        printf '[main]\ndns=none\n' > /mnt/etc/NetworkManager/conf.d/dns.conf
        printf 'nameserver 127.0.0.1\nnameserver ::1\n' > /mnt/etc/resolv.conf
    else
        warn "unbound/unbound-dinit unavailable - NextDNS NOT configured (DNS stays with NetworkManager)."
    fi
fi

# --------------------------- initramfs + Limine ------------------------------
say "Building initramfs..."
chr mkinitcpio -P

say "Installing Limine..."
mkdir -p /mnt/boot/EFI/BOOT
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI
CMDLINE="root=/dev/mapper/${VG}-root rootfstype=ext4 rw loglevel=3 split_lock_detect=off zswap.enabled=0 transparent_hugepage=madvise"
cat > /mnt/boot/EFI/BOOT/limine.conf <<EOF
timeout: 5
remember_last_entry: yes
default_entry: 1

/Singularity OS
    protocol: linux
    kernel_path: boot:///vmlinuz-${KERNEL}
    module_path: boot:///amd-ucode.img
    module_path: boot:///intel-ucode.img
    module_path: boot:///initramfs-${KERNEL}.img
    cmdline: ${CMDLINE}

/Singularity OS (fallback initramfs)
    protocol: linux
    kernel_path: boot:///vmlinuz-${KERNEL}
    module_path: boot:///amd-ucode.img
    module_path: boot:///intel-ucode.img
    module_path: boot:///initramfs-${KERNEL}-fallback.img
    cmdline: ${CMDLINE}
EOF
chr efibootmgr --create --disk "$DRIVE" --part 1 --loader '\EFI\BOOT\BOOTX64.EFI' \
    --label "Singularity OS" --unicode || warn "efibootmgr failed; the fallback path /EFI/BOOT/BOOTX64.EFI should still boot."

# --------------------------------- finish ------------------------------------
sync
swapoff -a || true
umount -R /mnt

echo ""
echo "============================================"
echo "  SINGULARITY SYSTEMS INSTALLED CLEANLY!"
echo "  After reboot: log in on tty1, run ./post-install.sh"
echo "============================================"
read -rp "Press Enter to reboot..." _
reboot
