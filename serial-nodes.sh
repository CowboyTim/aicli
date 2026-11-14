#!/bin/sh
# The serial nodes of the boards, made in the container as claude-agent's entrypoint
# does: ttyUSB0..N (major 188) and ttyACM0..N (major 166), N = SERIAL_MAX (default 8).
# The minor number of each is its index (/sys/class/tty shows ttyACM0 as 166:0), so
# a board plugged in later finds its node already there, and the device cgroup rule
# that aicli.sh adds lets the container open it. Runs as root, before ai.pl drops
# to the user (SERIAL_GID is the dialout group of the host).
max=${SERIAL_MAX:-8}
gid=${SERIAL_GID:-0}
for t in ttyUSB:188 ttyACM:166; do
    name=${t%%:*}
    major=${t#*:}
    i=0
    while [ "$i" -lt "$max" ]; do
        node=/dev/$name$i
        if [ ! -e "$node" ]; then
            mknod -m 660 "$node" c "$major" "$i" 2>/dev/null
            chown "0:$gid" "$node" 2>/dev/null
        fi
        i=$((i + 1))
    done
done
exec /usr/bin/perl /ai.pl "$@"
