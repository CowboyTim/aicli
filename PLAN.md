# PLAN

Open work and ideas for aicli. What is built is described in README.md (the
user's view) and AGENTS.md (the code, and "Status" for the history), not here.

## Open: needs a real run

- **Voice with a real microphone.** Checked: a 16 s recording of real speech
  was recognized correctly with `AI_ASR_PROMPT`, and the pause send and the
  footer words ran in a pseudo-terminal. Not checked: Esc cancel and the level
  meter in a real terminal. The thresholds (speech and silence at peak 100,
  about -50 dBFS) were lowered after a quiet test recording; the same mic at
  full source gain then gave a clear one (peak -7 dBFS).
- **First CI runs** (`.github/workflows/tests.yml`). The image job is the
  first run of the tests with `Net::Curl`.
- **Privilege drop as a user other than 1000** (`AI_UID`, `AI_GID`,
  `AI_GROUPS`) in the docker wrapper. Only the plan is tested.
- **Proxies and search against the real thing:** `AI_PROXY`, `AI_WEB_PROXY`,
  and `search` with a real SearXNG. So far only with a mocked HTTP layer.
- **Cloud providers live** (NVIDIA, Cerebras, OpenRouter, Anthropic). NVIDIA
  works in real use. The others have only scripted tests so far.
- **Pictures with a real vision model.** The `image` tool (`AI_VISION=1`) is
  tested with scripted requests only. No real model that reads pictures has
  been run yet, nor a picture of text to check the reading.
- **ImageMagick.** Tested here with ImageMagick 6 (`convert`, Debian's package):
  the formats, the policy (`ai/imagemagick/policy.xml`: PostScript and PDF
  refused), the crop, the turn, the shrinking. The Docker image builds with it
  and `convert` is there. Not yet: ImageMagick 7 (`magick`).
- **The environment whitelist.** `utils::tool_env()` is a guess of what the
  programs of the tools need. Check each one: the voice recorder needs its
  runtime variables (XDG_RUNTIME_DIR, PIPEWIRE_REMOTE are in the list), a
  future program may need more. Every child gets the list (AGENTS.md).
- **Terminals other than tmux 3.4** for the footer (kitty and others). Emoji
  and wide-character widths may differ.

## Open: the stack (pods, registry, auth, deploy)

- **First real run on the host.** Not tested here (no Docker, Podman or PAM in
  the sandbox): the auth login through the page, `user add` and `user passwd`
  with the terminal prompts, the `chpasswd -e` step inside the auth container,
  and the broker's first pull from `AICLI_REGISTRY_HOST` with its login.
- **Podman's field names.** The broker's create request uses libpod's
  `devices`, `groups`, `seccomp_profile_path` and `ipc`. Check them against the
  running Podman: `podman container inspect` of a `-dev` container after its
  first open.
- **Devices for rootless Podman.** Serial, USB and the ROCm GPU nodes are owned
  by groups (`dialout`, `render`, `video`) that a rootless container with
  `keep-id` cannot use. Undecided: a udev rule on the host that gives the user
  access (`TAG+="uaccess"` or a mode), or a rootful Podman for the broker's pods.
- **Pod images.** Built by `pods/docker-bake.hcl` (bash, arduino, rocm, android,
  node), not yet built or pushed. The `rocm` kind's `seccomp` and `ipc` settings
  are taken from the Docker side of the old launcher; not checked on a GPU.
- **Brute-force protection for logins.** `auth/aicli-auth.pam` has only
  `pam_unix`. A `pam_faillock` sketch needs a test in the auth container before
  it is committed. The `metrics_api` PAM file (a copy kept out of the repo) was
  compared: its `pam_selinux`, `pam_permit` fall-through and listfile rules do
  not fit.
- **The pods panel** in the web page shows the base pods only, and it is not
  refreshed by the model's own pod calls.
- **Git history** still has the domain and the public IPv6 prefix in older
  commits (removed from the tree). Rewriting `main` is undecided.
- **Flaky test:** `t/100_ui.t` ("the slow turn starts") failed once in a full
  run and passed on its own and on the next run. Not investigated.

## Open: web interface

- **Projects and `--root`** are built and tested with a fake docker and the
  socket tests. Not yet: a real `aicli.sh --root` run with the image, and a
  browser check of the project select.
- **Not started:** file downloads and inline pictures for what the model
  generates (`GET /files`, `tools::_path()`, `Content-Disposition: attachment`
  for downloads, `file` events from `tools::_changing`).
- **Not started:** uploads into `./uploads/` (`POST /upload`, a multipart
  parser, `AI_UPLOAD_MAX`, names sanitized, pictures into the next message with
  `AI_VISION=1`).
- **Not started:** slash commands over `POST /command` (refused with 400 now).
- **The sync/flow issue** the user saw in the page: not investigated yet.
- **Thinking not shown in the page** for the user's model: the server emits
  `think` events for both forms (`reasoning_content` and `<think>` tags) in
  tests, and the page has a thinking block now. Not reproduced in a browser.
  Check: `/thinking` (a session setting can turn it off), the browser console.
- **Not run in a real browser:** the session select and the replayed history
  (only tested with the socket pairs, the child process and curl), the page in both looks and both themes, the
  microphone and the speech warnings, the TLS trust prompt for a self-signed
  certificate. The QR code and the page on a phone work (checked); the desktop
  browser cookie with `SameSite=Lax` is not checked on its own.
- **TLS:** tested with a generated certificate and `openssl s_client`. Not
  yet: a certificate from a real CA, the key read after the privilege drop.

## Open: remote agents (hardware attached to a project)

Built so far: the polls, the jobs for the tags, the answers, the times, the agent's program list,
the agent's working directory, the bearer token (the broker keeps its SHA-256), the optional
public key pin, the enrollment (a user's token from the page, `ai.pl --enroll`, the state file,
the revocation). Tests t/123 to t/128. Not built: the owner check of a job, and the checkout of
the project on the agent (see the parts below).

Decided: the hardware is reached through agents that call in. The broker never starts
an agent (it has no /dev); the user starts it on the machine that has the devices, and it
calls back. The agent images rocm, arduino and android are built and run outside this
project. `base` is a pod, started by the broker, built here. An agent is the
unit that does the work: `ai.pl --agent`, a mode of ai.pl that loads no chat and
holds no model key, on a machine (a Raspberry Pi with a Zigbee stick, a DGX Spark,
a Strix Halo box, a laptop, or the broker's own host). It runs jobs in its own
containers with its own devices, and it can be run by hand for a test. The broker is only the
control plane: it sends small job specs and gets small results back. Project
files, images and build output never pass through the broker. The connection goes
through nginx over the public TLS (the certificate of PUBLIC_DOMAIN, checked by the agent
as any client does; no client certificate). The agent's credential is its token.

- **Transport:** a `/agents/` location in nginx that proxies to the broker's agent
  listener. The public certificate is checked by the agent, as usual; an optional pin
  of the server's public key (`--pin sha256//BASE64`) is on top of that. A pin breaks at
  a renewal with a new key, so it is for when that is wanted. No client CA.
- **Agent credential:** the token of each agent (`Authorization: Bearer`). The broker
  keeps only the SHA-256 (`token_sha256` in `broker.json`).
- **Enrollment:** each logged-in user has an enrollment token on the main page, with
  a copy button. Any number of agents can enroll with it: `ai.pl --agent --enroll TOKEN
  --name NAME` on each machine gets that agent its own token (the broker stores its
  SHA-256), kept locally. The token is not the session cookie and is kept as a hash. Roles
  (admins of projects and users) are not designed yet, so every logged-in user has one.
  The token is revocable and can be rotated on the page; rotating or revoking it stops
  new enrollments and leaves the enrolled agents as they are. Each agent can be revoked
  on its own (its token's hash is removed from the broker). The page lists the enrolled agents and when
  each enrolled. The token is reusable, so it is a secret that can add machines: it is
  shown only to its user, and it is not logged.
- **Long poll, not a WebSocket:** the agent asks for work (`GET /agents/poll`),
  the broker answers with a job or with a timeout, the agent posts the result
  (`POST /agents/result/<id>`). Plain HTTP through nginx, no Upgrade handling, and
  the connection drops cleanly. Same shape as a gitlab runner.
- **Tags are set at enrollment:** `ai.pl --agent --enroll TOKEN --name NAME --tags
  arduino,usb-meter` (as `gitlab-runner register --tag-list`). The broker stores them with
  the agent's token hash, and the agent cannot change them. Tags describe the hardware
  and the platform (for example `zigbee`, `gfx1151`, `dgx-spark`, `arduino`, `arm64`,
  `armv6`). A kind names the tags it needs. An agent without a tag never gets that
  kind's jobs.
- **A tag is only usable by its owner:** an agent receives jobs only for projects of
  the user who enrolled it. Without this, one user's token could claim another user's
  tags. Projects can later be shared with other users, which is a role question not
  designed yet.
- **Kinds decide where they run:** a kind without tags runs in a local pod (Podman,
  as now); a kind with tags runs on a connected agent that has all of them. No agent
  connected: `pod_run` says so and does not fall back to a local pod.
- **What a job carries:** the project's name, a commit the agent must check out, the
  program and its arguments (no shell), the timeout, and the output cap. Nothing else.
  The broker checks the program against the kind's allowlist before it sends the job.
- **What a result carries:** the exit code, the log (capped), and the small results
  the job names. Larger output (a firmware image, a capture) stays on the agent; someone
  who needs it fetches it from the agent, not through the broker. This is a later step.
- **The agent keeps its own state:** its checkouts of the projects (a cache it can
  lose), its images (pulled from the registry itself, for its own platform), its own
  devices. The agent refuses any program not in its own allowlist for its tags, as the
  second check.
- **Private repos:** each agent has its own read-only git credential on its machine.
  The broker never holds it.
- **Limits:** a concurrency limit per agent (default 1), output and time capped as for
  pods. A disconnect ends the running job with an error.
- **Platforms:** the bake file builds amd64 only today. An arm64 agent needs its own
  images (a second build for its platform), chosen by its platform tag. A Pi Zero W
  (armv6, 512 MB) can run the agent but not a rocm or android job, so those tags keep
  such jobs off it.
- **Revocation:** an agent's token hash is removed from the broker; a removed agent is
  detached at its next poll.
- **The agent itself:** `ai.pl --agent`, run as a container on its own machine (rootful
  Docker where serial and USB need cgroup rules) or directly on the
  host. It holds only its token and its git credential, no model key, and it
  loads the chat's libraries only where they are needed. An agent on the broker's own
  host is the same program, just local.
- **Open:** where `pods/entrypoint.sh`, `pods/run.sh` and `pods/usb-meter-nodes.sh` go
  (they serve the agent images, built outside this project); how an agent's token is made and kept on the broker side (enrollment, the hash in
  the agents file); how the agent is updated and how its version is
  checked against the broker; how the arduino build output comes back, and whether
  the first step is the log only.

## Open: devel and hardware

- **Devel probe counts:** `devel` reports `lua: 0` and `python: 1` on the
  test machine. Check what the probes count and whether they are right.
- **Hardware tests:** `--usb`, `--rtlsdr`, `--nrf-sniffer`, `--bluetooth` have
  not been run against real devices in a while.

## Ideas, not started

- **Sub-agent roles:** a config file with endpoints and models, a `role`
  argument on `agent`, limits per endpoint.
- **Config file** (JSON or YAML) beside the environment variables, per session
  and global.
- **Sessions:** tagging and search, a generated title, export and import
  (history and context).
- **Git:** AI-assisted commit messages, branch suggestions.
- **Questions and plans:** the model asks a clarifying question when unsure,
  and can outline a plan before it acts.
- **Tools:** a side-by-side diff.
- **Answers:** syntax highlighting of code blocks.
- **Live voice.** The footer preview re-sends the audio every few seconds and
  shows the words that two passes agree on (LocalAgreement), so it is not word
  by word as you speak. A recognizer with real streaming would do that;
  FastFlowLM only does batch transcription.
- **Anthropic native tool calls.** Anthropic uses the text protocol for now.
- **Performance:** cache model listings; faster session I/O for long histories.

## Decided against

- **Pods chosen by the model by image.** The model names a pod kind; the image,
  programs and devices come from `broker.json`, and a registry must be listed there.
- **A registry run by the stack**, or a LAN nginx for it. The images are on
  `registry.aardbeiplantje.link`; the stack only pulls from it.
- **Passwords through the system `passwd`.** `auth.pl` sets them (its rules, its
  hash) and stores the hash with `chpasswd -e`.
- **A domain or a public address in the repo.** They are settings in `.env`.
- **Pods with bluetooth or host networking.** Not offered to pods.
- **Tool confirmation or an allow-list.** The container is the sandbox.
- **Sub-agents on FastFlowLM.** The NPU is kept for voice; the `agent` tool is
  not offered with `AI_PROVIDER=flm`.
- **curses or other CPAN UI modules.** The footer is VT100 escapes in
  `tui.pm`. More panes side by side only if they are ever needed.
- **Bedrock and other providers one by one.** Use LiteLLM or OpenRouter as the
  OpenAI compatible endpoint for those.
