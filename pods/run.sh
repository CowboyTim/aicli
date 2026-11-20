#!/bin/bash
#
# Run a shell (or a command) in one of the aicli pod images, with a workspace mounted.
#
#   ./run.sh                    bash in the general dev image, in the current directory
#   ./run.sh --rocm             the ROCm image instead (GPU devices passed through)
#   ./run.sh --arduino          the arduino-cli/ESP32 image
#   ./run.sh --android          the Android SDK/Gradle image
#   ./run.sh bash -c 'make'     anything else runs as a command in the container
#   ./run.sh --build            rebuild the selected image first (build cache kept)
#   ./run.sh --update           pull fresh base images, rebuild
#   ./run.sh --no-ssh-agent     don't share your ssh-agent (shared by default)
#   ./run.sh --serial           allow USB serial boards (default for --arduino)
#   ./run.sh --no-serial        don't
#   ./run.sh --usb              allow USB power meters (libusb, /dev/bus/usb)
#   ./run.sh --no-usb           don't (default)
#   ./run.sh --rtlsdr           allow NESDR / RTL-SDR dongles (implies --usb)
#   ./run.sh --no-rtlsdr        don't (default)
#   ./run.sh --nrf-sniffer      allow nRF52840 dongles for flashing/sniffing (implies --usb)
#   ./run.sh --no-nrf-sniffer   don't (default)
#   ./run.sh --bluetooth        host network + Bluetooth HCI access (default for --bash/--arduino)
#   ./run.sh --no-bluetooth     don't
#
# Devices: the ROCm flavor passes /dev/kfd and the GPU nodes through, with the groups
# that own them on this host. Serial and USB are not passed one by one: access to
# every ttyUSB* (major 188), ttyACM* (major 166) and USB (189) device is allowed with
# a device cgroup rule, and the entrypoint mknods the nodes in the container, so
# boards plugged in or re-enumerated after start work without a restart. Nothing
# from the host's /dev is mounted. The agents' containers (built outside this project)
# are configured in the same terms, but without these cgroup rules, which rootless
# Podman cannot apply; see PLAN.md, "Open: remote agents".
#
# USB: the power meters (JT-UM120, FNIRSI) are HID devices that usb_logger reads
# through libusb. The entrypoint mknods /dev/bus/usb/<bus>/<dev> for the meters present
# (usb-meter-nodes.sh), owned by the container's dialout group. A replugged meter needs
# `usb-meter-nodes` run again. Opt-in, because the rule lets the container open any USB
# device on the host.
#
# Bluetooth: HCI adapters (hci0) live in the host's network namespace, so
# --bluetooth runs the container with --network host, which drops the
# container's network isolation. It also adds NET_ADMIN and NET_RAW for the raw
# HCI socket, and seccomp=unconfined in case Docker's default profile blocks
# AF_BLUETOOTH. Keep bluetoothd running on the host. Opt-out with --no-bluetooth.
#
# The flavor and the options (--rocm/--bash/--arduino/--android, --build/--update,
# --[no-]ssh-agent, --[no-]serial, --[no-]usb, --[no-]bluetooth) come first, in any order.
# "docker buildx bake" on its own builds all images.
#
# Environment overrides:
#   WORKSPACE      host directory to work in        (default: $PWD)
#   IMAGE_REPO     image repository                  (default: aicli-pod)
#   IMAGE          full image tag                    (default: $IMAGE_REPO:<bash|rocm|arduino|android>)
#   NAME           container name                    (default: aicli-pod-<flavor>-<workspace>)
#   SSH_AGENT      1 shares $SSH_AUTH_SOCK, 0 doesn't (default: 1)
#   SSH_KNOWN_HOSTS 1 also mounts your ~/.ssh/known_hosts read-only (default: 0)
#   SERIAL         1 allows serial boards, 0 doesn't (default: 1 for arduino, 0 otherwise)
#   SERIAL_MAX     device nodes created per serial type (default: 8)
#   USB            1 allows USB power meters, 0 doesn't (default: 0)
#   RTLSDR         1 allows RTL-SDR dongles, 0 doesn't (default: 0)
#   RTLSDR_IDS     RTL-SDR vid:pid list          (default: "0bda:2838 0bda:2832")
#   NRF_SNIFFER    1 allows nRF52840 dongles, 0 doesn't (default: 0)
#   NRF_IDS        nRF52840 vid:pid list         (default: "1915:521f 1915:522a", the Nordic DFU bootloader and the running sniffer)
#   BLUETOOTH      1 gives Bluetooth access (host network), 0 doesn't (default: 1 for bash/arduino, 0 otherwise)
#   AGENT_USER     user name inside the image        (default: agent)
#   BUILDER        buildx builder to build with      (default: the active one)
#   DOCKER_ARGS    extra "docker run" arguments, word-split
#
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

flavor=bash
build=0
ssh_agent=${SSH_AGENT:-1}
serial=${SERIAL:-}
usb=${USB:-0}
rtlsdr=${RTLSDR:-0}
rtlsdr_ids=${RTLSDR_IDS:-"0bda:2838 0bda:2832"}   # RTL2832U: NESDR SMArt (2838), NESDR (2832)
nrf_sniffer=${NRF_SNIFFER:-0}
nrf_ids=${NRF_IDS:-"1915:521f 1915:522a"}         # Nordic nRF52840 Dongle: DFU bootloader, sniffer firmware
bluetooth=${BLUETOOTH:-}
refresh=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rocm)    flavor=rocm ;;
        --bash)    flavor=bash ;;
        --arduino) flavor=arduino ;;
        --android) flavor=android ;;
        --build)   build=1 ;;
        --update)  build=1; refresh=(--pull) ;;
        --ssh-agent)    ssh_agent=1 ;;
        --no-ssh-agent) ssh_agent=0 ;;
        --serial)    serial=1 ;;
        --no-serial) serial=0 ;;
        --usb)       usb=1 ;;
        --no-usb)    usb=0 ;;
        --rtlsdr)    rtlsdr=1 ;;
        --no-rtlsdr) rtlsdr=0 ;;
        --nrf-sniffer)    nrf_sniffer=1 ;;
        --no-nrf-sniffer) nrf_sniffer=0 ;;
        --bluetooth)    bluetooth=1 ;;
        --no-bluetooth) bluetooth=0 ;;
        *) break ;;
    esac
    shift
done

IMAGE_REPO=${IMAGE_REPO:-aicli-pod}
IMAGE=${IMAGE:-$IMAGE_REPO:$flavor}
WORKSPACE=$(readlink -f "${WORKSPACE:-$PWD}")
AGENT_USER=${AGENT_USER:-agent}
BUILDER=${BUILDER:-}
SERIAL_MAX=${SERIAL_MAX:-8}
if [ -z "$serial" ]; then
    [ "$flavor" = arduino ] && serial=1 || serial=0
fi
if [ -z "$bluetooth" ]; then
    { [ "$flavor" = bash ] || [ "$flavor" = arduino ]; } && bluetooth=1 || bluetooth=0
fi

# ~/rocm-hip.git -> /work/rocm-hip
ws_name=$(basename "$WORKSPACE")
ws_name=${ws_name%.git}
NAME=${NAME:-aicli-pod-$flavor-$(tr -c 'a-zA-Z0-9_.\n-' '-' <<<"$ws_name")}
container_home=/home/$AGENT_USER
container_ws=/work/$ws_name

# The image user can't be root; fall back to 1000 if run as root.
uid=$(id -u); gid=$(id -g)
[ "$uid" = 0 ] && uid=1000
[ "$gid" = 0 ] && gid=1000

if [ "$build" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # docker-bake.hcl holds the build definition. Uses the same builder as a
    # plain "docker buildx bake" (the active one) unless BUILDER is set, so
    # both share one build cache.
    nrfutil_refresh=${NRFUTIL_REFRESH:-0}
    [ ${#refresh[@]} -gt 0 ] && nrfutil_refresh=$(date +%s)
    (
        cd "$here"
        IMAGE_REPO=$IMAGE_REPO AGENT_USER=$AGENT_USER \
        AGENT_UID=$uid AGENT_GID=$gid \
        NRFUTIL_REFRESH=$nrfutil_refresh \
            docker buildx bake ${BUILDER:+--builder "$BUILDER"} "${refresh[@]}" \
                --set "$flavor.tags=$IMAGE" "$flavor"
    )
fi

# shellcheck disable=SC2054  # commas in --tmpfs options are intentional
args=(
    --rm
    --init
    --name "$NAME"
    --hostname "$NAME"
    --tmpfs /tmp:rw,suid,exec,size=1G
    --tmpfs /var/tmp:rw,suid,exec,size=1G
    -v "$WORKSPACE:$container_ws"
    -w "$container_ws"
    -e TERM="${TERM:-xterm-256color}"
)

if [ -t 0 ] && [ -t 1 ]; then
    args+=(-it)
else
    args+=(-i)
fi

# Pass devices through and add whatever groups own them on *this* host
# (replaces the hardcoded --group-add 109/986/992).
declare -A gids=()
add_dev() {
    local dev=$1
    [ -c "$dev" ] || return 0
    args+=(--device="$dev")
    local gid
    gid=$(stat -c %g "$dev")
    [ "$gid" != 0 ] && gids[$gid]=1
    return 0
}

case "$flavor" in
    rocm)
        add_dev /dev/kfd                              # ROCm compute
        for d in /dev/dri/card* /dev/dri/renderD*; do # GPU
            add_dev "$d"
        done
        args+=(
            --security-opt seccomp=unconfined
            --ipc=host
            --ulimit memlock=-1:-1
            --ulimit stack=67108864:67108864
            --ulimit nofile=65536:65536
        )
        ;;
esac

# Serial boards: allow whole device types (name:major), not single devices,
# so boards plugged in later work too. The entrypoint creates the nodes.
# Don't add ttyS (major 4): it shares its major with the virtual consoles.
if [ "$serial" = 1 ]; then
    serial_types=(ttyUSB:188 ttyACM:166)
    for t in "${serial_types[@]}"; do
        args+=(--device-cgroup-rule "c ${t#*:}:* rmw")
    done
    args+=(-e "SERIAL_NODES=${serial_types[*]}" -e "SERIAL_MAX=$SERIAL_MAX")
fi

# RTL-SDR dongles and nRF52840 dongles: same USB nodes as the meters, with their
# IDs added to the list usb-meter-nodes looks for (USB_EXTRA_IDS). The host's
# dvb_usb_rtl28xxu driver may claim an RTL-SDR first; librtlsdr detaches it from
# inside the container. An nRF52840 dongle shows up as ttyACM once its sniffer
# firmware runs (covered by --serial); the bootloader ID is for flashing it.
extra_ids=()
if [ "$rtlsdr" = 1 ]; then
    usb=1
    read -ra rtl_list <<<"$rtlsdr_ids"
    extra_ids+=("${rtl_list[@]}")
fi
if [ "$nrf_sniffer" = 1 ]; then
    usb=1
    read -ra nrf_list <<<"$nrf_ids"
    extra_ids+=("${nrf_list[@]}")
fi
if [ ${#extra_ids[@]} -gt 0 ]; then
    args+=(-e "USB_EXTRA_IDS=${extra_ids[*]}")
fi

# USB power meters: the entrypoint makes their /dev/bus/usb nodes (USB_METERS).
if [ "$usb" = 1 ]; then
    args+=(--device-cgroup-rule "c 189:* rmw" -e USB_METERS=1)
fi

# Bluetooth HCI: host network namespace, raw HCI socket caps, and the bluetooth
# group (109 on this host) for adapter access.
if [ "$bluetooth" = 1 ]; then
    # Host networking copies the host's /etc/hosts, which has no entry for the
    # container hostname, so sudo warns "unable to resolve host". Add one.
    args+=(--network host
        --add-host "$NAME:127.0.0.1"
        --cap-add NET_ADMIN --cap-add NET_RAW
        --security-opt seccomp=unconfined)
    gids[109]=1
fi

# Add the groups that own the passed-through devices (and bluetooth, above).
for g in "${!gids[@]}"; do
    args+=(--group-add "$g")
done

# Optional extras
[ -f "$HOME/.gitconfig" ] && args+=(-v "$HOME/.gitconfig:$container_home/.gitconfig:ro")

# ssh-agent: the socket is mounted, never the keys. The container user has
# your UID, so it can use the socket.
# accept-new trusts unknown hosts on first use (changed keys still fail), so a
# restart never stops at a host key prompt. Your host known_hosts is NOT
# mounted by default: one outdated entry there (e.g. GitHub's old RSA key)
# would turn "unknown, accept" into "changed, refuse". SSH_KNOWN_HOSTS=1
# mounts it read-only as the system-wide file anyway.
if [ "$ssh_agent" = 1 ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
    args+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock
        -e "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}")
    [ "${SSH_KNOWN_HOSTS:-0}" = 1 ] && [ -f "$HOME/.ssh/known_hosts" ] \
        && args+=(-v "$HOME/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro")
fi

# shellcheck disable=SC2206
[ -n "${DOCKER_ARGS:-}" ] && args+=($DOCKER_ARGS)

exec docker run "${args[@]}" "$IMAGE" "$@"
