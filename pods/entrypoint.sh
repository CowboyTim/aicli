#!/bin/bash
# Container entrypoint: makes the serial and USB device nodes that run.sh asks for, then runs
# ai.pl (the chat, and its options such as --agent), or the command given.
set -e

# Serial device nodes. run.sh sets SERIAL_NODES ("ttyUSB:188 ttyACM:166") and
# allows those majors with a device cgroup rule. Create /dev/<name>0..N-1 so a
# board plugged in (or re-enumerated) later can be opened without a restart.
# A node without a board behind it fails to open with ENXIO.
if [ -n "${SERIAL_NODES:-}" ]; then
    for t in $SERIAL_NODES; do
        name=${t%%:*} major=${t#*:}
        for ((i = 0; i < ${SERIAL_MAX:-8}; i++)); do
            [ -e "/dev/$name$i" ] && continue
            sudo -n mknod -m 0660 "/dev/$name$i" c "$major" "$i" \
                && sudo -n chgrp dialout "/dev/$name$i" \
                || echo "entrypoint: can't create /dev/$name$i" >&2
        done
    done
fi

# USB power meters (run.sh --usb sets USB_METERS=1 and allows USB major 189):
# make /dev/bus/usb nodes for the meters plugged in now. A meter replugged later
# needs usb-meter-nodes run again, since its device number changes.
if [ "${USB_METERS:-0}" = 1 ]; then
    usb-meter-nodes -q || echo "entrypoint: usb-meter-nodes failed" >&2
fi

# the arguments: none is ai.pl (the chat); options (-x, --flag ..., --agent) are ai.pl's;
# anything else is run as a command (bash, bash -c ..., arduino-cli ...)
if [ $# -eq 0 ]; then
    exec /usr/bin/perl /ai.pl
fi
case "$1" in
    -*) exec /usr/bin/perl /ai.pl "$@" ;;
    *)  exec "$@" ;;
esac
