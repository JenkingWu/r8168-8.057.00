#!/bin/sh
#
# r8168 uninstaller for CentOS/RHEL 6.10 i686.
#
# - brings down interfaces owned by r8168
# - removes the module and the EL6 integration files
# - restores the original initramfs if it was backed up by install.sh
# - tries to bind the device back to r8169
#
set -u

KVER=$(uname -r)
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

echo "WARNING: this unloads r8168 and may interrupt network access."
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

# Bring down interfaces currently owned by r8168 before unloading it.
for i in /sys/class/net/*; do
        [ -e "$i/device/driver" ] || continue
        drv=$(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$drv" = "r8168" ]; then
                ifname=${i##*/}
                echo "Bringing down $ifname"
                ip link set dev "$ifname" down 2>/dev/null || true
        fi
done

modprobe -r r8168 2>/dev/null || rmmod r8168 2>/dev/null || true
if lsmod 2>/dev/null | grep -q '^r8168[[:space:]]'; then
        echo "WARNING: r8168 is still loaded; reboot to complete the rollback."
fi

rm -f "$BLACKLIST" "$DRACUT_CONF" "$MODULES_SH" "$MODDIR/r8168.ko"
depmod -a "$KVER" || true

if [ -f "$BACKUP/initramfs-$KVER.img" ]; then
        echo "Restoring original initramfs ..."
        cp -a "$BACKUP/initramfs-$KVER.img" "$INITRAMFS" || fail "initramfs restore failed"
elif command -v dracut >/dev/null 2>&1; then
        dracut -f "$INITRAMFS" "$KVER" || fail "dracut failed"
else
        mkinitrd -f "$INITRAMFS" "$KVER" || true
fi

# Reload r8169 and bind the supported devices back to it.
modprobe r8169 2>/dev/null || true
for bdf in $(find_bdfs); do
        [ -d /sys/bus/pci/drivers/r8169 ] || continue
        [ -e "/sys/bus/pci/devices/$bdf/driver" ] && continue
        echo "$bdf" > /sys/bus/pci/drivers/r8169/bind 2>/dev/null || true
done

ip link 2>/dev/null | grep -E '^[0-9]+:' || true

echo "Done.  Verify that r8169 (or the intended driver) owns the NIC."
exit 0
