# Device images (pods/)

The device images hold what a kind of hardware needs: the boards and their toolchains,
the GPU stack, the USB meters, the radios. Each kind is its own image, and each one is a
remote agent of the broker: it runs `ai.pl --agent` and takes the jobs for its tags (see
PLAN.md, "a thin ai.pl image, device images per kind of hardware"). The main `ai.pl` image
(`local/ai/aicli`, built from the repository root) has no hardware in it.

This directory is the base they are built from. It also holds the device side of the
layout (`run.sh`, `entrypoint.sh`, `usb-meter-nodes.sh`): `run.sh` shares the devices with the
container, and `entrypoint.sh` uses the same list.

| file | what it is |
|------|------------|
| `Dockerfile` | the `base` stage: the basic tools (bash, perl, grep, find), Rust, nodejs, npm and go, and `ai.pl` with its modules |
| `docker-bake.hcl` | the build definition of `base` (`docker buildx bake`) |
| `run.sh`, `entrypoint.sh`, `usb-meter-nodes.sh` | the devices of a container (see their headers) |
| `README.md` | this file |

## ai.pl comes from GitHub

The `base` stage does not copy `ai.pl` from a build context. It downloads the repository
archive of one commit, `AICLI_REF`, from `AICLI_REPO` (GitHub), and installs `ai.pl`, its
modules and `ai/` (the templates and the web page) in the layout of the main image: the
modules at `/`, `ai/` under `/ai`. The commit is pinned in the `Dockerfile` and in
`docker-bake.hcl`, so a build gets the same `ai.pl` until the pin is changed.

To move to a newer `ai.pl`, change `AICLI_REF` to the commit you want (a full commit id of
the repository), and build again. The build checks the modules with `perl -cw /ai.pl`.

The repository is public, so the build needs no login. A commit must be pushed before it can
be pinned.

## Build

```
docker buildx bake                       # base, into the local image store
docker buildx bake --print               # the resolved settings
AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake   # files written into a workspace stay yours
```

`base` is tagged `aicli-pod:base` for local use, and `$REGISTRY/pod-base:latest` (where
`REGISTRY` is `$AICLI_REGISTRY_HOST/aicli`). Push it when the device images are built on
another machine:

```
docker push $AICLI_REGISTRY_HOST/aicli/pod-base:latest
```

## Device images

Each device image is a stage of the `Dockerfile`, built `FROM base`, and an image
of `docker-bake.hcl`:

| image | stage | what it adds |
|-------|-------|--------------|
| `bash` | base | the basic tools, Rust, nodejs, npm, go (the base image, under its own name) |
| `rocm` | rocm | the ROCm image (`ROCM_IMAGE`), a Python venv with torch (TheRock's ROCm wheels for `TORCH_INDEX`), numpy, pyarrow, soundfile, pillow, transformers |
| `arduino` | arduino | arduino-cli with the ESP32 core, usb_logger (usb-multimeter, via pipx), nrfutil with ble-sniffer |
| `android` | android | JDK 17, the Android SDK (platform, build tools, platform-tools), Gradle |

`bake` builds one with `docker buildx bake arduino`, or all with `docker buildx bake local`.
`run.sh --arduino`, `--android`, `--rocm` and `--bash` run them, with the devices of
the flavor passed in.

The entrypoint (`entrypoint.sh`) makes the device nodes that `run.sh` asks for, then runs
`ai.pl` for options (`-x`, `--flag ...`), the command given, or bash with no arguments.
Each image is an `ai.pl` container. The device images as remote agents (`ai.pl --agent`
with their tags) come next: see PLAN.md, "a thin ai.pl image, device images per kind of hardware".
