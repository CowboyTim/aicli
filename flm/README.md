# flm: FastFlowLM, the speech recognizer on the NPU

`flm` serves the speech recognition (whisper-v3:turbo) of the AMD Ryzen AI NPU on port 52625,
with an OpenAI compatible endpoint: `/v1/audio/transcriptions`. The agent (`ai.pl`, its `/voice`)
reaches it as `AI_ASR_URL` (docker-compose.yaml sets it to `http://flm:52625/v1/audio/transcriptions`).

## Build

FastFlowLM publishes no container image, so the image installs the release's `.deb`
(`FLM_URL`, pinned by `FLM_SHA256`). The NPU runtime (`libxrt2`, `libxrt-npu2`) comes from the
lemonade-team/stable PPA, the one FastFlowLM's docs name. Its signing key is fetched by the
fingerprint in `XRT_KEY_FPR` (`881CF4B4…50AEC`) and the build stops if the key does not match.

```
docker compose build flm
```

## One process per NPU

The NPU takes one process at a time. A second `flm` (for example one run in a terminal) fails to
load its model with `DRM_IOCTL_AMDXDNA_CREATE_HWCTX ... Invalid argument`. Stop the other one
before the service starts, and do not start `flm` by hand while the service runs.

## Host

- The NPU driver (`amdxdna`, kernel 7.0 or the DKMS module) and the NPU firmware, on the host.
- `/dev/accel/accel0` must exist there; `FLM_NPU` in `.env` names another device.
- `ulimit -l` must be `unlimited` on the host (memlock), and the service sets it for the container.

## Run

`docker compose up -d flm`. The first start downloads the model into the volume `aicli-flm`.
`docker compose logs flm` shows the server. The agent reaches it as `http://flm:52625`.

## Not checked yet

- The PPA's key fetch from keyserver.ubuntu.com, and the PPA's packages at build time (not run here yet).
- `flm serve` binds to localhost by default, so the service passes `--host 0.0.0.0` (every interface of
  the container; the agent reaches it by name). `--host` and `--port` are the options.
- The model download needs network access from the container.
