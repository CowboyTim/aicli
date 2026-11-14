#!/bin/bash
# The device nodes of the serial boards and the USB devices, made in the container
# as root before ai.pl drops to the user (as claude-agent's entrypoint and
# usb-meter-nodes do). aicli.sh sets these variables:
#   SERIAL_NODES   "ttyUSB:188 ttyACM:166" for --arduino/--serial, empty otherwise
#   SERIAL_MAX     nodes per serial type (default 8)
#   USB_METERS     1 for --usb, --rtlsdr, --nrf-sniffer: make the /dev/bus/usb nodes
#                  of the devices in USB_METER_IDS and USB_EXTRA_IDS that are plugged in
#   USB_METER_IDS  the power meters (vid:pid), default: usb_logger's list
#   USB_EXTRA_IDS  more vid:pid (the RTL-SDR and nRF52840 dongles)
#   DEVICE_GID     the dialout group of the host: the group of these nodes
max=${SERIAL_MAX:-8}
gid=${DEVICE_GID:-0}

# serial: ttyUSB0..N-1 and ttyACM0..N-1, minor = index (see /sys/class/tty), so a
# board plugged in later finds its node already there
for t in ${SERIAL_NODES:-}; do
    name=${t%%:*}
    major=${t#*:}
    for ((i = 0; i < max; i++)); do
        node=/dev/$name$i
        [ -e "$node" ] && continue
        if mknod -m 0660 "$node" c "$major" "$i"; then
            chown "0:$gid" "$node"
        else
            echo "aicli-devices: can't create $node" >&2
        fi
    done
done

# USB: /dev/bus/usb/<bus>/<dev> for the devices plugged in now, with the number the
# kernel uses for the usbfs node. A device replugged later gets a new number, so
# that needs the container started again.
if [ "${USB_METERS:-0}" = 1 ]; then
    ids=" ${USB_METER_IDS:-0483:003a 0483:003b 2e3c:0049 2e3c:5558} ${USB_EXTRA_IDS:-} "
    for dev in /sys/bus/usb/devices/*; do
        [ -r "$dev/idVendor" ] && [ -r "$dev/busnum" ] || continue
        id="$(<"$dev/idVendor"):$(<"$dev/idProduct")"
        case "$ids" in
            *" $id "*) ;;
            *) continue ;;
        esac
        bus=$((10#$(<"$dev/busnum")))
        devnum=$((10#$(<"$dev/devnum")))
        minor=$(((bus - 1) * 128 + (devnum - 1)))
        node=$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$devnum")
        mkdir -p "$(dirname "$node")"
        rm -f "$node"
        if mknod -m 0660 "$node" c 189 "$minor"; then
            chown "0:$gid" "$node"
            echo "aicli-devices: $node ($id)" >&2
        fi
    done
fi

exec /usr/bin/perl /ai.pl "$@"
