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

## Decided: no pods; the ai.pl container holds the tools

Built (code and docs; tests t/107, t/110, t/124, t/127, t/129, t/131, t/135): the pod kinds, the
engine and the pod tools are gone; the broker is the control plane of the remote agents only; the page
has no pods panel; `aicli.sh --broker` mounts the broker's socket and needs no `--root`.
The `pods/` directory is the image of the tools: a slim Debian base with ai.pl and what it needs
(perl and its modules, bash, grep, find, sudo for the device nodes, CA certificates), built by
`docker buildx bake` from `pods/`, with ai.pl fetched from GitHub at a pinned commit. The device
images (arduino, android, rocm) are built on it. A session's job reaches a remote agent through the
page (`POST /agent/job`, for a project of the login) or the broker's `exec`; the agent runs it in its
own work directory, with no checkout yet.

There are no pods. The unit that holds the tools is an `ai.pl` container (the agent of
the web interface, or a remote agent). The minimal image has the standard tools
(bash, perl, grep, find, and the basic unix tools); a toolchain is added to an image of
its own when it is needed, not as a pod. A tool is a fork/exec in that container, as
`_run` does now, confined by landlock, with no key in the child.

- **Projects are where they are now.** An `ai.pl` that is not remote works on the
  projects under its root (`account/project`). A remote `ai.pl` is user-specific (one
  per user, from the agent's enrollment), and holds that user's projects on its own
  machine, in the same `account/project` layout. The structure stays: the account is
  the user, the project is a directory under it.
- **The broker stays.** Remote agents connect in to it (`/agents/` through nginx, the
  polls, the results), and it routes a job to the agent of the job's account and tags.
  Without remote agents, the broker has nothing to do; the local `ai.pl` needs none.
- **What is removed:** the pod kinds and their `broker.json` entries, the per-project
  pods, the model's pod tools (`pods`, `pod_open`, `pod_close`, `pod_run`), the pods
  panel of the page, `_pod_run` and `AI_POD_ROOT` for bash, perl and grep, the reaper
  and the open-pod cap. The `pods/` directory is the image of the minimal `ai.pl`
  container (the tools), not pod images.
- **Every `ai.pl` is a container with its tools in it.** The local `ai.pl` of the web
  interface (the compose `agent` service) runs its tools in its own container, not on
  the host. The projects it works on are the ones under its root, as now.
- **A remote job stays on the remote.** The project's files are on the remote agent's
  machine, in its container, and the job's work is done there. The broker sends a job
  (the project, the program, the arguments, the timeout) and gets the result back; the
  files do not pass through the broker.

## Decided: a thin ai.pl image, device images per kind of hardware

The `ai.pl` image (the `dev` stage) keeps only what every session needs: some dev tools
(python3, make, cmake, pkg-config, the C/C++ toolchain), image conversion (ImageMagick, and
its `convert` tool), ffmpeg, the perl tool's modules (PDL, Audio::Wav), lame, qrencode and
the pipewire recorder for voice. lua, strace and the device programs are out. It is kept
as thin as possible. Hardware tools do not go in it.

Each kind of hardware has its own image, built from this project or next to it, and that
image is also a remote agent: it installs `ai.pl` as a library and runs `ai.pl --agent`
with the enrollment's tags (`arduino`, `rocm`, `android`, `usb-meter`, `rtl-sdr`, `nrf`).
Its programs are the ones of the image (`--programs`), so the jobs it takes are the
programs it can run. The device images are: arduino (arduino-cli), rocm (the GPU stack),
android (adb and the SDK), usb-meter (usb_logger), rtl-sdr (rtl-sdr tools), nrf (nrfutil,
the BLE sniffer).

- An agent image starts from the thin image or from its own base, whichever keeps it
  smaller. It holds ai.pl's agent code and no model key.
- The devices of a device image come from its host through its own run options, not from
  the image. `aicli.sh` shares no hardware any more: its device flags are gone.
- Enrollment and tags are as now (`ai.pl --enroll ... --tags`). A job for a tag goes only
  to an agent with it.

Built: the thin `dev` stage and the wrapper without device flags (`aicli.sh` has no
--rocm, --arduino, --usb, --rtlsdr, --nrf-sniffer or --bluetooth; `aicli-devices.sh` is gone).
Built, not yet run on hardware: the device images are in `pods/` (not a separate repository), each a
stage on the slim base (`rocm` on the ROCm image, with the same ai.pl layer): arduino (arduino-cli,
usb_logger, nrfutil with ble-sniffer), android (JDK 21, the SDK, Gradle), rocm (a Python venv with
torch and the ROCm wheels). rtl-sdr and nrf are not images yet. Their run options per device are in
`pods/run.sh`, which still has the pods-era device flags (see the open list below).

## Open: the stack (pods, registry, auth, deploy)

- **First real run on the host.** Not tested here (no Docker, Podman or PAM in
  the sandbox): the auth login through the page, `user add` and `user passwd`
  with the terminal prompts, the `chpasswd -e` step inside the auth container,
  and the agent images' first pull from `AICLI_REGISTRY_HOST` with its login.
- **Brute-force protection for logins.** `auth/aicli-auth.pam` has only
  `pam_unix`. A `pam_faillock` sketch needs a test in the auth container before
  it is committed. The `metrics_api` PAM file (a copy kept out of the repo) was
  compared: its `pam_selinux`, `pam_permit` fall-through and listfile rules do
  not fit.
- **Git history** still has the domain and the public IPv6 prefix in older
  commits (removed from the tree). Rewriting `main` is undecided.
- **Flaky test:** `t/100_ui.t` ("the slow turn starts") failed once in a full
  run and passed on its own and on the next run. Not investigated.

## Open: web interface

- **Projects and `--root`** are built and tested with a fake docker and the
  socket tests, and the page's project and session controls were checked in a
  headless Chromium against a local `ai.pl --ui` (create, switch, delete of a project,
  the last one included; new session with a name; rename; the menu's layout at 360 and
  1000 px). Not yet: a real `aicli.sh --root` run with the image, and the login path
  (nginx, auth, the account of a request) in a browser.
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
- **Not run in a real browser:** the replayed history (only tested with the socket pairs, the
  child process and curl), the page in both looks, the microphone and the speech warnings, the TLS
  trust prompt for a self-signed. (The dark theme's fields, the menu's layout and the session select
  were checked in a headless Chromium; not the looks in a real desktop browser.)
  certificate. The QR code and the page on a phone work (checked); the desktop
  browser cookie with `SameSite=Lax` is not checked on its own.
- **TLS:** tested with a generated certificate and `openssl s_client`. Not
  yet: a certificate from a real CA, the key read after the privilege drop.

## Open: remote agents (hardware attached to a project)

Built so far: the polls, the jobs for the tags, the answers, the times, the agent's program list,
the agent's working directory, the bearer token (the broker keeps its SHA-256), the optional
public key pin, the enrollment (a user's token from the page, `ai.pl --enroll`, the state file,
the revocation). Also built: an enrollment token is used once; an enrollment on a machine that
has its agent (`agent.json` in `$AI_DIR`, in a volume) reuses it; `--enroll` with `--programs`
runs the agent at once; `--name` defaults to a random UUID and `--tags` to the programs' names;
the page shows each agent online or offline (a poll held or lately) and sends a job of one of
the login's projects (`POST /agent/job`, the output back as text). Tests t/123 to t/128, t/126,
t/127, t/137. Not built: the checkout of the project on the agent (see the parts below), and the
job's owner check beyond the account of the project.

Decided: the hardware is reached through agents that call in. The broker never starts
an agent (it has no /dev); the user starts it on the machine that has the devices, and it
calls back. The device images are built in `pods/` (see "Decided: a thin ai.pl image"), and
their run is outside this project. An agent is the
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
  a copy button. `ai.pl --enroll TOKEN --broker URL --programs P` on a machine gets its agent
  its own token (the broker stores its SHA-256), kept in `agent.json` in `$AI_DIR`. The token is not the session cookie and is kept as a hash. Roles
  (admins of projects and users) are not designed yet, so every logged-in user has one.
  The token is revocable and can be rotated on the page; rotating or revoking it stops
  new enrollments and leaves the enrolled agents as they are. Each agent can be revoked
  on its own (its token's hash is removed from the broker). The page lists the enrolled agents and when
  each enrolled. The token is used once: the enrollment deletes it, so a new one is needed for
  each agent, and a used or revoked one enrolls nothing. It is shown only to its user, and it is
  not logged.
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
- **Jobs decide where they run:** a job runs by fork/exec on the agent that has its tags
  (the agent's container has the tools). No agent connected: the job is refused with the
  reason; it does not fall back to a local pod.
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

## Open: accounts and ownership (one broker, a subtree per account)

Decided: one broker. The projects live in subdirectories per account:
`AI_PROJECTS/<account>/<project>`. An account is the login's account ID: a UUID (without its
dashes) kept in the passwd comment (GECOS), in its fifth subfield as `aicli=<uuid>`; auth.pl makes
it with the user, and the token and nginx's X-Aicli-Account carry it. A project belongs to the
account in its path. Renaming a login does not move its projects.

- **The broker's requests** carry the account and the project; the broker resolves the host
  path as `<root>/<account>/<project>` and refuses links and paths outside it.
- **Pod engine names** carry the account: `aicli-<kind>-<account>-<project>`, so two accounts
  with the same project name do not collide.
- **Owner check:** a job for a kind with tags goes only to an agent enrolled by the same
  account as the project. The hub keeps the account of each agent (`user`).
- **Static agents of broker.json** have no account: they get no jobs for a project until they
  are given an owner.
- **Built:** the broker takes `account/project` and checks both parts, the pod names carry the
  account, the hub gives a job only to an agent of the job's account, `project_dirs()` and the
  pods panel list account/project. The tools need no account setting: a project's path holds it.
  Tests updated to the new layout (t/104 to t/128); the full suite passes.
- **Built, the page:** the account of a request is the login's name (nginx's gate); the local
  operator (no nginx) sees all. The lists (sessions, projects, pods, busy) are made per account,
  events go only to the accounts they are about, every route that switches, messages, deletes,
  renames or opens checks the project's account (403, or 404 where a session must not be shown).
  One active session is shared by the page: an account that switches takes it over, the other
  account's page sees no session until it switches back.
- **Built, projects on the page:** create (in the login's account), rename (without sessions),
  delete (with its sessions and files on confirmation). The page has the controls next to the
  project select. Rename with sessions is refused on purpose: their conversations name the old
  path, and a conversation's start is not rewritten. Renaming those would need the sessions
  to be moved or ended first, which is a choice for later.
- **Open:** several active sessions at once (one per account) would need the active session per
  page connection instead of one for the master; moving the existing flat projects of the host
  into `AI_PROJECTS/<account>/` (a host step, done by the user).

## Open: devel and hardware

- **Devel probe counts:** `devel` reports `lua: 0` and `python: 1` on the
  test machine. Check what the probes count and whether they are right.
- **Hardware:** the device images in `pods/` build with `docker buildx bake` (the base and
  arduino, android and rocm were built on the slim base; the rocm stage was not run on a GPU).
  Not run: the devices themselves (the serial and USB nodes of `pods/run.sh` and
  `entrypoint.sh`, the `pods/run.sh` device flags `--usb`, `--rtlsdr`, `--nrf-sniffer`,
  `--bluetooth`, `--serial`, which still belong to the pods era), rtl-sdr and nrf images, and
  an agent started from a device image with its tags.
- **Images:** the base's Rust, nodejs, go and rtl-sdr were removed from the base image;
  a device image that needs one adds it itself. The android stage uses JDK 21 (Debian trixie has no
  JDK 17); not yet checked against the Android Gradle Plugin it would build with.

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
- **A base pod for the session's tools.** The agent container is the toolchain and
  the sandbox; a pod per project for bash, perl and grep only added a registry pull, a
  network path to the engine and a second place to keep the tools in step.
- **Tool confirmation or an allow-list.** The container is the sandbox.
- **Sub-agents on FastFlowLM.** The NPU is kept for voice; the `agent` tool is
  not offered with `AI_PROVIDER=flm`.
- **curses or other CPAN UI modules.** The footer is VT100 escapes in
  `tui.pm`. More panes side by side only if they are ever needed.
- **Bedrock and other providers one by one.** Use LiteLLM or OpenRouter as the
  OpenAI compatible endpoint for those.
