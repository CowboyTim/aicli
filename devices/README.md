# Device images

The device images hold what a kind of hardware needs: the boards and their toolchains,
the GPU stack, the USB meters, the radios. Each kind is its own image, and each one is a
remote agent of the broker: it runs `ai.pl --agent` and takes the jobs for its tags (see
PLAN.md, "a thin ai.pl image, device images per kind of hardware"). The main `ai.pl` image
(`local/ai/aicli`, built from the repository root) has no hardware in it.

This directory is the base they are built from:

| file | what it is |
|------|------------|
| `Dockerfile` | the `base` stage: the basic tools (bash, perl, grep, find), Rust, nodejs, npm and go, and `ai.pl` with its modules |
| `docker-bake.hcl` | the build definition of `base` (`docker buildx bake`) |
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

`base` is tagged `aicli-device:base` for local use, and `$REGISTRY/device-base:latest` (where
`REGISTRY` is `$AICLI_REGISTRY_HOST/aicli`). Push it when the device images are built on
another machine:

```
docker push $AICLI_REGISTRY_HOST/aicli/device-base:latest
```

## Device images

Not built yet. Each kind will be a `FROM` of `base` with its own programs, and an entrypoint
that starts `ai.pl --agent` with the kind's tags (`arduino`, `rocm`, `android`, `usb-meter`,
`rtl-sdr`, `nrf`). The devices are not in the image: they are passed in at run time by the
host, with the options of each kind.

The files `pods/entrypoint.sh`, `pods/run.sh` and `pods/usb-meter-nodes.sh` in the repository
are the device side of an earlier layout. They stay where they are until the device images
take them over.
