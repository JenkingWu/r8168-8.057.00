#!/bin/sh
#
# r8168 installer for CentOS/RHEL 6.10 i686 (kernel 2.6.32-754.el6.i686).
#
# - builds against the running kernel's kernel-devel tree
# - installs to /lib/modules/$(uname -r)/extra/
# - blacklists the in-tree r8169 module
# - adds r8168 to the initramfs and loads it at boot
# - detaches r8169 from the target PCI device(s) without touching other NICs
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)
KDIR=/lib/modules/$KVER/build
MODDIR=/lib/modules/$KVER/extra
BACKUP=/root/r8168-el6-backup
BLACKLIST=/etc/modprobe.d/r8168-blacklist.conf
DRACUT_CONF=/etc/dracut.conf.d/99-r8168.conf
MODULES_SH=/etc/sysconfig/modules/r8168.modules
INITRAMFS=/boot/initramfs-$KVER.img

fail() {
        echo "ERROR: $*" >&2
        exit 1
}

[ "$(id -u)" = 0 ] || fail "run as root"
[ -d "$KDIR" ] || fail "kernel-devel for $KVER not found ($KDIR)"
[ -f "$ROOT/src/Makefile" ] || fail "run from the r8168 source tree"

echo "WARNING: this detaches r8169 from RTL8168/8111 devices."
echo "         Keep a physical or out-of-band console available."


find_bdfs() {
        for d in /sys/bus/pci/devices/*; do
                [ -r "$d/vendor" ] || continue
                v=$(cat "$d/vendor" 2>/dev/null)
                p=$(cat "$d/device" 2>/dev/null)
                case "$v:$p" in
                0x10ec:0x8168|0x10ec:0x8161|0x10ec:0x2502|0x10ec:0x2600)
                        echo "${d##*/}"
                        ;;
                0x1186:0x4300)
                        sv=$(cat "$d/subsystem_vendor" 2>/dev/null)
                        sd=$(cat "$d/subsystem_device" 2>/dev/null)
                        if [ "$sv" = "0x1186" ] && [ "$sd" = "0x4b10" ]; then
                                echo "${d##*/}"
                        fi
                        ;;
                esac
        done
}

BDFS=$(find_bdfs)
[ -n "$BDFS" ] || echo "WARNING: no supported RTL8168/8111 PCI device found"

mkdir -p "$BACKUP" "$MODDIR" /etc/dracut.conf.d

# Keep the first original initramfs and the previously installed module.
if [ -f "$INITRAMFS" ] && [ ! -f "$BACKUP/initramfs-$KVER.img" ]; then
        cp -a "$INITRAMFS" "$BACKUP/initramfs-$KVER.img"
fi
if [ -f "$MODDIR/r8168.ko" ]; then
        cp -a "$MODDIR/r8168.ko" "$BACKUP/r8168.ko.$(date +%Y%m%d%H%M%S)"
fi

echo "Building r8168 for $KVER ..."
make -C "$ROOT/src" clean >/dev/null 2>&1 || true
make -C "$ROOT/src" KERNELDIR="$KDIR" modules || fail "build failed"
make -C "$ROOT/src" KERNELDIR="$KDIR" modules_install INSTALL_MOD_DIR=extra || fail "modules_install failed"

cat > "$BLACKLIST" <<'EOF'
# Installed by the r8168 EL6 installer.
# Keep the in-tree r8169 driver from binding RTL8168/8111 devices.
blacklist r8169
EOF

cat > "$DRACUT_CONF" <<'EOF'
# Installed by the r8168 EL6 installer.
add_drivers+=" r8168 "
install_items+=" /etc/modprobe.d/r8168-blacklist.conf "
EOF

cat > "$MODULES_SH" <<'EOF'
#!/bin/sh
# Loaded by EL6 rc.sysinit.  Detach r8169 (including the built-in case)
# from supported Realtek devices, then load r8168.
case "$1" in
start|"")
        for d in /sys/bus/pci/devices/*; do
                [ -r "$d/vendor" ] || continue
                v=$(cat "$d/vendor" 2>/dev/null)
                p=$(cat "$d/device" 2>/dev/null)
                case "$v:$p" in
                0x10ec:0x8168|0x10ec:0x8161|0x10ec:0x2502|0x10ec:0x2600)
                        bdf=${d##*/}
                        ;;
                0x1186:0x4300)
                        sv=$(cat "$d/subsystem_vendor" 2>/dev/null)
                        sd=$(cat "$d/subsystem_device" 2>/dev/null)
                        if [ "$sv" = "0x1186" ] && [ "$sd" = "0x4b10" ]; then
                                bdf=${d##*/}
                        else
                                continue
                        fi
                        ;;
                *)
                        continue
                        ;;
                esac
                drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)
                if [ "$drv" = "r8169" ]; then
                        echo "$bdf" > /sys/bus/pci/drivers/r8169/unbind 2>/dev/null
                fi
        done
        /sbin/modprobe r8168 >/dev/null 2>&1
        # Load r8169 explicitly for any *other* RTL8169-family NICs.
        # The target devices are already owned by r8168 at this point.
        /sbin/modprobe r8169 >/dev/null 2>&1
        ;;
esac
exit 0
EOF
chmod 755 "$MODULES_SH"

depmod -a "$KVER" || fail "depmod failed"

# Detach r8169 from the target devices only; other r8169 NICs stay bound.
for bdf in $BDFS; do
        link=/sys/bus/pci/devices/$bdf/driver
        [ -e "$link" ] || continue
        drv=$(basename "$(readlink -f "$link" 2>/dev/null)" 2>/dev/null)
        if [ "$drv" = "r8169" ]; then
                echo "Unbinding r8169 from $bdf"
                echo "$bdf" > /sys/bus/pci/drivers/r8169/unbind 2>/dev/null || true
        fi
done

echo "Updating initramfs ..."
if command -v dracut >/dev/null 2>&1; then
        dracut -f --add-drivers "r8168" "$INITRAMFS" "$KVER" || fail "dracut failed"
else
        mkinitrd -f "$INITRAMFS" "$KVER" || fail "mkinitrd failed"
fi

# Best effort SELinux relabeling; ignore if SELinux is disabled.
if command -v restorecon >/dev/null 2>&1; then
        restorecon "$BLACKLIST" "$DRACUT_CONF" "$MODULES_SH" "$MODDIR/r8168.ko" >/dev/null 2>&1 || true
fi

echo "Loading r8168 ..."
modprobe r8168 || fail "modprobe r8168 failed"

# r8169 is blacklisted only for auto-loading.  Load it explicitly so any
# additional RTL8169-family NICs keep working; the target device is already
# bound to r8168 and will not be touched.
modprobe r8169 >/dev/null 2>&1 || true
sleep 1

for bdf in $BDFS; do
        echo "== $bdf"
        readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true
done
ip link 2>/dev/null | grep -E '^[0-9]+:' || true

echo "Done.  Reboot and verify that r8168, not r8169, owns the NIC."
exit 0
