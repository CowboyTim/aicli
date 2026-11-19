#!/bin/bash
# Make /dev/bus/usb/<bus>/<dev> nodes inside the container for the USB power
# meters that usb_logger supports. Like the serial nodes from entrypoint.sh,
# they are the container's own: owned by the container's dialout group, so the
# host's permissions on the device don't matter and nothing from the host /dev
# is mounted.
#
# A meter's device number changes when it is replugged, so run this again after
# a replug (the entrypoint runs it once at start). Stale nodes are harmless: the
# kernel only opens a node whose device is there.
#
#   usb-meter-nodes                      make nodes for the meters present now
#   USB_METER_IDS="vid:pid ..."          which meters (default: usb_logger's list)
#   USB_EXTRA_IDS="vid:pid ..."         more devices to add (run.sh --rtlsdr sets the RTL-SDR IDs)
#   USB_DEV_ROOT=dir                     where /dev is (tests only; default /dev)
#   -q                                   no "not plugged in" notice (the entrypoint uses this)
set -euo pipefail

quiet=0
if [ "${1:-}" = -q ]; then
    quiet=1
fi

ids="${USB_METER_IDS:-"0483:003a 0483:003b 2e3c:0049 2e3c:5558"} ${USB_EXTRA_IDS:-}"
root=${USB_DEV_ROOT:-/dev}
usb_major=189 # char major of /dev/bus/usb/*

found=0
for dev in /sys/bus/usb/devices/*; do
    if [ ! -r "$dev/idVendor" ] || [ ! -r "$dev/busnum" ]; then
        continue
    fi
    id="$(<"$dev/idVendor"):$(<"$dev/idProduct")"
    case " $ids " in
        *" $id "*) ;;
        *) continue ;;
    esac

    bus=$((10#$(<"$dev/busnum")))
    devnum=$((10#$(<"$dev/devnum")))
    # Same numbering the kernel uses for the usbfs nodes.
    minor=$(((bus - 1) * 128 + (devnum - 1)))
    node=$(printf '%s/bus/usb/%03d/%03d' "$root" "$bus" "$devnum")

    sudo -n mkdir -p "$(dirname "$node")"
    sudo -n rm -f "$node"
    sudo -n mknod -m 0660 "$node" c "$usb_major" "$minor"
    sudo -n chgrp dialout "$node"
    echo "usb-meter-nodes: $node ($id)"
    found=$((found + 1))
done

if [ "$found" -eq 0 ] && [ "$quiet" = 0 ]; then
    echo "usb-meter-nodes: no meter from [$ids] is plugged in" >&2
fi
