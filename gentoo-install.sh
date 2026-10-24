#!/usr/bin/env bash
# gentoo-install.sh - guided Gentoo installer, fixed stack:
#   systemd + Xorg + XFCE + xdm greeter + power-profiles-daemon + NetworkManager
# Run as root from the Gentoo minimal install ISO. amd64 only.
#
# WARNING: this WIPES the disk you select. Read the script before using it.

set -euo pipefail

MNT=/mnt/gentoo
MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds"
PROFILE_NAME="default/linux/amd64/23.0/desktop/systemd"

# ---------- helpers ----------
c_info()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
c_warn()  { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
c_err()   { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }

ask() {  # ask "prompt" "default"
    local reply
    read -r -p "$1 [${2}]: " reply
    echo "${reply:-$2}"
}

ask_secret() {
    local p1 p2
    while true; do
        read -r -s -p "$1: " p1; echo >&2
        read -r -s -p "Confirm: " p2; echo >&2
        [[ -n "$p1" && "$p1" == "$p2" ]] && { echo "$p1"; return; }
        c_warn "Empty or mismatched, try again." >&2
    done
}

choose() {  # choose "title" opt1 opt2 ...
    local title="$1"; shift
    local opts=("$@") i n
    echo "$title" >&2
    for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i+1)) "${opts[$i]}" >&2; done
    while true; do
        read -r -p "Select [1]: " n
        n=${n:-1}
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#opts[@]} )); then
            echo "${opts[$((n-1))]}"; return
        fi
    done
}

part() {  # part <disk> <num>
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *) echo "${1}${2}" ;;
    esac
}

cleanup() {
    c_info "Unmounting..."
    umount -R "$MNT" 2>/dev/null || true
}

# ---------- preflight ----------
[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == x86_64 ]] || die "Only x86_64 is supported."
for t in sgdisk wipefs mkfs.ext4 mkfs.vfat wget tar lsblk blkid chroot; do
    command -v "$t" >/dev/null || die "Missing required tool: $t"
done

if [[ -d /sys/firmware/efi/efivars ]]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi
c_info "Boot mode: $BOOT_MODE"

c_info "Checking network..."
ping -c1 -W3 distfiles.gentoo.org >/dev/null 2>&1 || die "No network. Configure it first (nmtui / dhcpcd)."

# ---------- guided configuration ----------
echo
lsblk -dpno NAME,SIZE,MODEL | grep -v -E 'loop|sr[0-9]|ram' || true
echo
DISK=$(ask "Target disk (e.g. /dev/sda, /dev/nvme0n1)" "/dev/sda")
[[ -b "$DISK" ]] || die "$DISK is not a block device."

FS=$(choose "Root filesystem:" ext4 xfs btrfs)
SWAP_GB=$(ask "Swap size in GiB (0 for none)" "4")
HOSTNAME_=$(ask "Hostname" "gentoo")
TZ_=$(ask "Timezone (e.g. Asia/Kolkata, UTC)" "Asia/Kolkata")
LOCALE=$(ask "Locale" "en_US.UTF-8")
KEYMAP=$(ask "Keymap (console and X11)" "us")
USERNAME=$(ask "Username" "user")
[[ -n "$USERNAME" ]] || die "A user is required (xdm login)."
ROOT_PW=$(ask_secret "Root password")
USER_PW=$(ask_secret "Password for $USERNAME")

GPU=$(choose "Graphics driver (VIDEO_CARDS):" "intel" "amdgpu radeonsi" "nouveau" "vmware" "virtualbox" "fbdev vesa")
KERNEL=$(choose "Kernel:" "gentoo-kernel-bin (prebuilt, fast)" "gentoo-kernel (compile locally)")
KERNEL=${KERNEL%% *}
BINHOST=$(choose "Use Gentoo official binary package host (much faster)?" yes no)
JOBS=$(ask "Parallel jobs (MAKEOPTS -j)" "$(nproc)")
CPU_FLAGS=$(ask "COMMON_FLAGS" "-O2 -pipe -march=native")

# ---------- summary ----------
echo
c_warn "=========== SUMMARY ==========="
cat <<EOF
Disk        : $DISK  (WILL BE ERASED)
Boot mode   : $BOOT_MODE
Filesystem  : $FS
Swap        : ${SWAP_GB} GiB
Init        : systemd
Desktop     : XFCE on Xorg, greeter: xdm
Power       : power-profiles-daemon
Network     : NetworkManager (+ Wi-Fi)
Extras      : Bluetooth (bluez+blueman), CUPS printing, PipeWire audio, udisks/gvfs, Firefox
GPU        : $GPU
Kernel      : $KERNEL
Binhost     : $BINHOST
Hostname    : $HOSTNAME_
Timezone    : $TZ_
Locale      : $LOCALE
Keymap      : $KEYMAP
User        : $USERNAME
Jobs        : $JOBS
EOF
read -r -p "Type YES to continue: " go
[[ "$go" == "YES" ]] || die "Aborted."

trap cleanup EXIT

# ---------- partitioning ----------
c_info "Partitioning $DISK..."
umount -R "$MNT" 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

n=1
if [[ $BOOT_MODE == uefi ]]; then
    sgdisk -n ${n}:0:+1G -t ${n}:ef00 -c ${n}:ESP "$DISK"; ESP=$(part "$DISK" $n); n=$((n+1))
else
    sgdisk -n ${n}:0:+2M -t ${n}:ef02 -c ${n}:biosboot "$DISK"; n=$((n+1))
    sgdisk -n ${n}:0:+1G -t ${n}:8300 -c ${n}:boot "$DISK"; BOOTP=$(part "$DISK" $n); n=$((n+1))
fi
if (( SWAP_GB > 0 )); then
    sgdisk -n ${n}:0:+${SWAP_GB}G -t ${n}:8200 -c ${n}:swap "$DISK"; SWAPP=$(part "$DISK" $n); n=$((n+1))
fi
sgdisk -n ${n}:0:0 -t ${n}:8300 -c ${n}:root "$DISK"; ROOTP=$(part "$DISK" $n)
partprobe "$DISK" 2>/dev/null || true
sleep 2

c_info "Formatting..."
case "$FS" in
    ext4)  mkfs.ext4 -F "$ROOTP" ;;
    xfs)   mkfs.xfs -f "$ROOTP" ;;
    btrfs) mkfs.btrfs -f "$ROOTP" ;;
esac
if [[ $BOOT_MODE == uefi ]]; then mkfs.vfat -F32 "$ESP"; else mkfs.ext4 -F "$BOOTP"; fi
if (( SWAP_GB > 0 )); then mkswap "$SWAPP"; swapon "$SWAPP"; fi

c_info "Mounting..."
mkdir -p "$MNT"
mount "$ROOTP" "$MNT"
if [[ $BOOT_MODE == uefi ]]; then
    mkdir -p "$MNT/efi"; mount "$ESP" "$MNT/efi"
else
    mkdir -p "$MNT/boot"; mount "$BOOTP" "$MNT/boot"
fi

# ---------- stage3 (desktop systemd) ----------
c_info "Fetching latest stage3 (systemd)..."
cd "$MNT"
STAGE_PATH=$(wget -qO- "$MIRROR/latest-stage3-amd64-systemd.txt" | grep -E '\.tar\.xz' | awk '{print $1}' | head -n1)
[[ -n "$STAGE_PATH" ]] || die "Could not determine stage3 tarball."
wget -c "$MIRROR/$STAGE_PATH" -O stage3.tar.xz
wget -q "$MIRROR/$STAGE_PATH.sha256" -O stage3.sha256 2>/dev/null || true
if [[ -s stage3.sha256 ]]; then
    c_info "Verifying checksum..."
    EXPECT=$(grep -E '^[0-9a-f]{64}' stage3.sha256 | awk '{print $1}' | head -n1)
    ACTUAL=$(sha256sum stage3.tar.xz | awk '{print $1}')
    [[ -z "$EXPECT" || "$EXPECT" == "$ACTUAL" ]] || die "Stage3 checksum mismatch!"
fi
c_info "Extracting stage3..."
tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm -f stage3.tar.xz stage3.sha256

# ---------- portage config ----------
c_info "Writing make.conf..."
cat > "$MNT/etc/portage/make.conf" <<EOF
COMMON_FLAGS="${CPU_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${JOBS}"
EMERGE_DEFAULT_OPTS="--jobs=2 --quiet-build=y"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
LC_MESSAGES=C.utf8

# Xorg + XFCE, no Wayland/GNOME/KDE
USE="X xfce gtk3 dbus policykit udev networkmanager pulseaudio pipewire sound-server bluetooth wifi cups udisks gvfs -wayland -gnome -kde -qt5 -qt6 -elogind"
VIDEO_CARDS="${GPU}"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="$([[ $BOOT_MODE == uefi ]] && echo efi-64 || echo pc)"
EOF
[[ "$BINHOST" == yes ]] && echo 'FEATURES="getbinpkg binpkg-request-signature"' >> "$MNT/etc/portage/make.conf"

mkdir -p "$MNT/etc/portage/repos.conf" "$MNT/etc/portage/package.use"
cp "$MNT/usr/share/portage/config/repos.conf" "$MNT/etc/portage/repos.conf/gentoo.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

cat > "$MNT/etc/portage/package.use/installer" <<EOF
sys-kernel/installkernel grub dracut
sys-boot/grub mount
# PipeWire as the sound server (Gentoo wiki: PipeWire)
media-video/pipewire sound-server
media-sound/pulseaudio -daemon
# Bluetooth permissions handled by systemd ACLs (no plugdev group needed)
net-wireless/bluez acl
# Xfce (Gentoo wiki: Xfce): power management via upower, avoid Qt via poppler
xfce-base/xfce4-meta upower pulseaudio
app-text/poppler -qt5
EOF

# ---------- fstab ----------
c_info "Generating fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOTP")
{
    echo "UUID=$ROOT_UUID  /      $FS  defaults,noatime  0 1"
    if [[ $BOOT_MODE == uefi ]]; then
        echo "UUID=$(blkid -s UUID -o value "$ESP")  /efi  vfat  umask=0077  0 2"
    else
        echo "UUID=$(blkid -s UUID -o value "$BOOTP")  /boot  ext4  defaults,noatime  0 2"
    fi
    if (( SWAP_GB > 0 )); then echo "UUID=$(blkid -s UUID -o value "$SWAPP")  none  swap  sw  0 0"; fi
} > "$MNT/etc/fstab"

# ---------- chroot ----------
c_info "Preparing chroot..."
mount --types proc /proc "$MNT/proc"
mount --rbind /sys "$MNT/sys";  mount --make-rslave "$MNT/sys"
mount --rbind /dev "$MNT/dev";  mount --make-rslave "$MNT/dev"
mount --bind /run  "$MNT/run";  mount --make-slave  "$MNT/run"

umask 077
printf 'root:%s\n%s:%s\n' "$ROOT_PW" "$USERNAME" "$USER_PW" > "$MNT/root/.pw"
umask 022

FS_PKG=""
[[ $FS == xfs ]]   && FS_PKG="sys-fs/xfsprogs"
[[ $FS == btrfs ]] && FS_PKG="sys-fs/btrfs-progs"
BIN_PKG=""
[[ $BOOT_MODE == uefi ]] && BIN_PKG="sys-boot/efibootmgr"
GETUTO=""
[[ "$BINHOST" == yes ]] && GETUTO="getuto || true"

cat > "$MNT/root/chroot-install.sh" <<CHROOT
#!/bin/bash
set -euo pipefail
source /etc/profile

echo "[*] Syncing Portage tree..."
emerge-webrsync
${GETUTO}

echo "[*] Selecting profile ${PROFILE_NAME}..."
eselect profile set "${PROFILE_NAME}"

echo "[*] Updating @world..."
emerge --verbose --update --deep --newuse @world

# timezone / locale
ln -sf "/usr/share/zoneinfo/${TZ_}" /etc/localtime
grep -q "^${LOCALE} " /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
sort -u -o /etc/locale.gen /etc/locale.gen
locale-gen
eselect locale set "${LOCALE}" || eselect locale set C.UTF8
env-update

# hostname, console keymap, machine-id
echo "${HOSTNAME_}" > /etc/hostname
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
systemd-machine-id-setup

echo "[*] Firmware and kernel..."
emerge --verbose sys-kernel/linux-firmware sys-kernel/installkernel
emerge --verbose sys-kernel/${KERNEL}

echo "[*] Base tools..."
emerge --verbose app-admin/sudo sys-apps/mlocate app-shells/bash-completion \\
    sys-fs/e2fsprogs sys-fs/dosfstools ${FS_PKG}

echo "[*] Bootloader (GRUB, ${BOOT_MODE})..."
emerge --verbose sys-boot/grub ${BIN_PKG}
if [[ "${BOOT_MODE}" == uefi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo
else
    grub-install --target=i386-pc ${DISK}
fi
grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Xorg..."
emerge --verbose x11-base/xorg-server x11-base/xorg-drivers x11-apps/xinit

echo "[*] XFCE (long build without binhost)..."
# Gentoo wiki: install xfce4-notifyd first so it replaces GNOME's notification-daemon
emerge --verbose --oneshot xfce-extra/xfce4-notifyd
emerge --verbose xfce-base/xfce4-meta \\
    xfce-extra/xfce4-pulseaudio-plugin xfce-extra/xfce4-power-manager \\
    xfce-extra/xfce4-terminal x11-themes/gnome-themes-standard \\
    media-fonts/dejavu media-fonts/noto media-sound/pavucontrol \\
    media-video/pipewire media-video/wireplumber

echo "[*] xdm greeter..."
emerge --verbose x11-apps/xdm
# xdm does not read .desktop session files; it runs the user's ~/.xsession.
# Put one in /etc/skel so every new user starts Xfce (dbus-aware launch).
cat > /etc/skel/.xsession <<XS
#!/bin/sh
exec startxfce4
XS
chmod 755 /etc/skel/.xsession
# xdm's systemd unit is not confirmed by the wiki: use the packaged one if present,
# otherwise provide a minimal unit.
if [[ ! -e /usr/lib/systemd/system/xdm.service && ! -e /lib/systemd/system/xdm.service ]]; then
    cat > /etc/systemd/system/xdm.service <<UNIT
[Unit]
Description=X Display Manager (xdm)
After=systemd-user-sessions.service systemd-logind.service
Conflicts=getty@tty7.service
After=getty@tty7.service

[Service]
ExecStart=/usr/bin/xdm -nodaemon
Restart=always

[Install]
Alias=display-manager.service
WantedBy=graphical.target
UNIT
fi

echo "[*] power-profiles-daemon + NetworkManager..."
emerge --verbose sys-power/power-profiles-daemon sys-power/upower \\
    net-misc/networkmanager gnome-extra/nm-applet

echo "[*] Bluetooth, Wi-Fi, printing, removable media..."
emerge --verbose net-wireless/bluez net-wireless/blueman \\
    net-wireless/iw net-wireless/wireless-regdb net-wireless/wpa_supplicant \\
    net-print/cups net-print/cups-filters net-print/system-config-printer \\
    net-dns/avahi sys-apps/udisks xfce-base/thunar-volman xfce-base/tumbler \\
    gnome-base/gvfs sys-process/procps sys-apps/usbutils sys-apps/pciutils \\
    x11-misc/xdg-user-dirs www-client/firefox-bin app-arch/unzip app-arch/zip

# X11 keyboard layout
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB
Section "InputClass"
    Identifier "keyboard-layout"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYMAP}"
EndSection
XKB

echo "[*] Enabling systemd services..."
systemctl enable NetworkManager.service
systemctl enable power-profiles-daemon.service
systemctl enable upower.service
systemctl enable systemd-timesyncd.service
systemctl enable bluetooth.service
systemctl enable cups.service
systemctl enable avahi-daemon.service
systemctl enable udisks2.service
systemctl enable fstrim.timer
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
systemctl enable xdm.service
systemctl set-default graphical.target

echo "[*] Users..."
useradd -m -G wheel,audio,video,usb,users,lp,lpadmin -s /bin/bash "${USERNAME}" || \\
    useradd -m -G wheel,audio,video,usb,users -s /bin/bash "${USERNAME}"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
chpasswd < /root/.pw
shred -u /root/.pw 2>/dev/null || rm -f /root/.pw

echo "[*] Chroot stage complete."
CHROOT
chmod +x "$MNT/root/chroot-install.sh"

c_info "Entering chroot (this is the long part)..."
chroot "$MNT" /bin/bash /root/chroot-install.sh
rm -f "$MNT/root/chroot-install.sh" "$MNT/root/.pw"

c_info "Installation finished."
echo "Remove the install media and run:  umount -R $MNT && reboot"
echo "After boot: xdm login screen -> XFCE. Switch power mode with: powerprofilesctl set <power-saver|balanced|performance>"
