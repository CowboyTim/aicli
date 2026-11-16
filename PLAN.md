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

- **Tool confirmation or an allow-list.** The container is the sandbox.
- **Sub-agents on FastFlowLM.** The NPU is kept for voice; the `agent` tool is
  not offered with `AI_PROVIDER=flm`.
- **curses or other CPAN UI modules.** The footer is VT100 escapes in
  `tui.pm`. More panes side by side only if they are ever needed.
- **Bedrock and other providers one by one.** Use LiteLLM or OpenRouter as the
  OpenAI compatible endpoint for those.
