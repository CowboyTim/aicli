# AI-CLI: notes for agents and contributors

## What this is

AI-CLI is a coding agent for the command line, in Perl: an interactive chat
with an LLM that runs tools (file tools, bash, perl, grep, sub-agents) and
feeds the results back to the model in a loop. Same idea as pi, hermes or opencode, but
small and Perl-ish: `fork()`, `exec()`, `eval`/`Safe`, `select()`, libcurl.

## Rules

These are requirements, not suggestions.

- **No branches unless explicitly asked.** Work on `main`: commit there and
  push there. Don't create a feature branch, a pull request or a worktree on
  your own, also not "to be safe". When a branch was asked for and is merged,
  delete it, locally and on the remote.
- **No Perl threads.** Never `use threads`, `threads::shared`, `Thread::Queue`
  or anything built on ithreads.
- **Fork only when needed**: to run something that must be isolated from the
  chat process (model-written code, external programs). Don't fork for
  concurrency: a sub-agent is not a process, a file tool is not a process.
- **One event loop, async by design**: everything that waits is registered in
  `package loop` (`loop::http`, `loop::spawn`, `loop::timer`) with a callback,
  and one `select()` drives it all: curl multi (`Net::Curl::Multi` or
  `WWW::Curl::Multi`) for HTTP, pipes for children. Never a blocking read, a
  blocking `perform()` or a `sleep`: a wait is `loop::run(sub {...})`, so other
  transfers, the status line, timeouts and ctrl-C keep working.
- **Callbacks don't block**: code called from the loop (`on_done`, `on_data`,
  timers) must not call `loop::run`, `utils::http` or `utils::fork_run`. It
  registers the next thing and returns (see `package agent`).
- **Children only through the loop**: `loop::spawn()` / `utils::fork_run()`
  give the child its own session, a clean environment, captured output, a
  timeout and abort handling. No backticks, `system()` or piped `open()`.
- **File tools stay in the workspace**: every path a file tool takes from the
  model goes through `tools::_path()` first (`nofollow => 1` when the tool
  acts on the entry itself: delete, move). A new file tool that skips it is a
  hole. Forked tools are confined by the kernel instead (`package sandbox`).
- **File tools are Perl**: reading, writing, editing, deleting, moving,
  listing files is done in-process with Perl, never by shelling out. Only
  what the model explicitly asks a shell for (`bash`, `grep`) is a process.
- **Never rewrite the start of a conversation**: the system prompt is built
  once per session and stored (`system_prompt()` at `init_session`, `/clear`,
  `/prompt`); every request must be the previous one plus new messages, byte
  for byte, or the prefix cache of the API is lost. No timestamps, counters or
  re-read files in the system prompt or in old messages, JSON stays canonical
  (`$::JSON`). The date in the prompt is coarse (`AI_PROMPT_DATE`, month).
  Context compaction is the only exception, and only when it is needed.
  `t/90_prompt_display_undo.t` checks this on the raw request bytes.
- **What the model gets and what the user sees are separate**: display code
  (brief tool lines, diffs, status) never changes the stored messages.
- **Terminal output goes through the status line**: call `$ai::TUI->clear()`
  before printing while the loop may be running, or the line is garbled.
- **A forked child ends with `POSIX::_exit()`**, never `exit`: END blocks and
  destructors of the chat (terminal cleanup) must not run in a child.
- **No secrets to children**: `AI_*` variables and the API key stay in the chat
  process (`utils::tool_env()`, `@utils::CHILD_INIT`). The exception is a session
  worker (`worker.pm`, forked by the master of the web interface): it is a chat
  and holds the key to make requests, so it is marked as one. Tool children
  (`bash`, `perl`, `grep`, sub-agents' tools) never get the key, and no process
  of the chat is readable through `/proc` by them: the chat and its workers are
  `sandbox::not_dumpable()` (`/proc/<pid>/environ` is root's), since `%ENV` is
  cleared but the process's own environment still holds the key.
- **Children get a curated environment, every time**: `utils::fork_child()` is
  the only `fork()`, and it sets `%ENV` to `utils::tool_env()`, an allow-list
  (PATH, HOME, TMPDIR, LANG, the runtime variables of the recorder, `GIT_*`,
  `AI_TOOL_ENV`), before the worker runs. A new child goes through it and never
  inherits the parent's `%ENV`. What one program needs beyond the list is set in
  its own worker, after the fork (ImageMagick: `MAGICK_CONFIGURE_PATH`,
  `MAGICK_TEMPORARY_PATH`), and never in the parent. The list is a guess of
  what the programs need, see PLAN.md.
- **The chat must survive**: a failing request, tool or command prints an
  error and returns to the prompt. No `die` may escape to the top.
- **Few dependencies**: core Perl plus `JSON::XS`, `Net::Curl` (or
  `WWW::Curl`), `Term::ReadLine::Gnu`. `Data::UUID` is optional. Ask before
  adding a CPAN module. `Net::SSLeay` (Debian `libnet-ssleay-perl`) is loaded
  only for the web interface over https (`--tls-cert`). The image also has `PDL` and `Audio::Wav` (Debian
  packages) for the `perl` tool, and the `lame` MP3 encoder; aicli itself does
  not load them.
- **Keep the docs in sync**: README.md, the POD in `ai.pl` and this file
  describe what the code does, not what is planned (that is PLAN.md). Notes
  for whoever works on this next go here, in "Status", not in a file of their
  own (there was a MEMORY.md, it is part of this file now).
- **stdout is the conversation**: messages, errors and the debug log go to
  stderr through `log::error` / `log::info` (`AI_LOG` for a file), never
  `print`. `log::notice` is for facts about the running process that help when
  it hangs or misbehaves (the provider and endpoint, the model request before it
  is sent, the model count, the listener's address): written by the web
  interface (`--ui`) and with `DEBUG`, not by the terminal chat at its start
  (`t/15_logging_privileges.t` keeps that stderr quiet). `log::info` is only
  with `DEBUG` or `--debug`. Every model request is stamped (`ai::request_stamp()`:
  UTC time, the user, a checksum of the body) in its `REQUEST` lines, and the
  retries of a web turn are in that log, not on the page (`ai::chat_completion`);
  the page's error for a failed request ends with the stamp of its last try.
  `ai.pl -p` in a pipe must give the answer
  and nothing else.
- **Tests**: `prove -I. t` must pass. Add tests with every change, the LLM is
  scripted (`t/lib/TestAI.pm`) or faked (`t/lib/FakeLLM.pm`).

## Status

What this file replaces: MEMORY.md, the notes of an earlier session (September
2025) that described a single-file `ai.pl`. That is long gone:

- November 2026: the chat loop was rebuilt (tool results reach the model, one
  command table), then grown into what is described below: event loop,
  sub-agents, status line, retries, token usage, context management, file
  tools in Perl, web tools, workspace and kernel sandbox, `-c`/`-p`.
- Everything has tests (`prove -I. t`), but against a scripted or fake LLM.
  Real models have been used with llama.cpp and FastFlowLM on the NPU, and
  NVIDIA's cloud API works in real use. Cerebras, OpenRouter and Anthropic have
  only scripted tests so far. Not yet done by anyone: the tests with
  `Net::Curl` (the preferred module; the image has `WWW::Curl`), a real proxy,
  the privilege drop as root in docker with a user other than 1000, and voice
  in a real terminal (a recording of real speech has been recognized; Esc
  cancel and the level meter have not been seen in a real terminal).
- November 2026, the web interface (`ai.pl --ui`): SSE, routes, token, IPv4 and
  IPv6, Ctrl-C, tool and error blocks, speech input, the thinking block, theme
  and look choice, TLS with `Net::SSLeay`. Tested with socket pairs, a forked
  client, `ai.pl --ui` as a child, and `openssl s_client`. Checked on a phone:
  the QR code opens the page and the token cookie holds (`SameSite=Lax`, after
  a link from another app `Strict` was not sent and the page answered 401).
  Sessions in the web interface: `ai.pl --ui` continues the last session of
  the directory (`--new` for a fresh one); the page has a session select
  (`POST /session`, a switch goes through the chat's queue like a model
  switch) and gets the conversation on connect and after a switch (`history`
  event: what was said (`load_messages()`), the answers, and the tool calls of the chat with their
  results, drawn as the live lines are (`_history_data`, `_tool_item`: a tool call's line from its
  arguments, its result clipped; a summary is not shown)). Tested with the socket pairs, `ai.pl --ui` as a child, and
  curl, and since then in a headless Firefox (Playwright, see "Testing the page in a
  browser"): the revert buttons, the session and project menu (rename, delete with "sure?"
  and "cancel", create), the dark theme's fields, the menu's layout, the session select.
  Not yet in a real desktop browser: both looks and themes, the microphone, the
  thinking block, the TLS trust prompt. Uploads: the "+" of the page (`POST /upload`)
  keeps any file in the active session's project under `uploads/` (`_upload_name`,
  `tools::free_name` for a taken name; a link named `uploads` is refused; the page names
  the files in the next message, `Uploaded: uploads/...`; `t/151_upload.t`,
  `tools/ui-check/upload.js`). Not built yet: slash commands over `POST /command` (refused with 400 for now). The files a tool
  writes are on the page: a picture inline and a download, live and after a reload
  (`GET /file`, the `file` event, the history's `files`; `tools/ui-check/files.js`).
- What is open is in PLAN.md. What is built is in README.md and in this
  "Status", not in PLAN.md.

## Layout

- **ai.pl** – entry point. Moves `%ENV` to `%::ORIG_ENV` (so nothing leaks to
  children), parses options (`-c` sets `AI_CONTINUE`, `-p` is one request via
  `ai::one_shot()`), drops root privileges (to `utils::privilege_plan()`:
  `AI_UID`/`UID`, `AI_GID`/`GID`, `AI_GROUPS` or the groups it has; the base
  directory is chowned, with its content when the owner changes), then
  `ai::chat_setup(); ai::setup_commands(); ai::chat_loop();`. Holds the POD.
- **ai.pm** – several packages in one file. Projects (`$ROOT`, the workspace at
  start): `project_dirs()` (the projects: account/project, the directories of the accounts under the root, not hidden, not links),
  `session_project($name)` (the `cwd` file of a session, relative to the root),
  `project_path($rel)`, `in_project($dir, $code)` (the process and the workspace
  are the project for the time of the call: a new session's prompt names it).
  `use_session()` records the process directory in `cwd` only for the terminal
  chat (`!$::UI`); the web master records the project of a new session itself.
  - `ai` – setup/providers, chat state, agent loop, streaming, retry, token
    usage, context management, sessions, commands, readline input
  - `agent` – sub-agents: a state machine per agent on the event loop
  - `model`, `provider`, `provider::<name>` – request building per provider
  - `prompt::<template>` – generated part of the system prompt (tools section)
  - `tools` – tool table, parser regex, tool implementations
  - `colors`
- **utils.pm** – `package loop` (the event loop: `http`, `spawn`, `timer`,
  `step`, `run`), the waits on top of it (`utils::http()`,
  `utils::fork_run()`, `utils::wait_abortable()`), `utils::fork_child()`,
  `utils::tool_env()`, packages `curl` (Net::Curl/WWW::Curl shim) and `log`.
- **md.pm** – `md`: markdown of the answer, line by line as it streams (`new_printer()` uses it on a terminal)
- **/voice** (in `ai.pm`, section "Speech"): `voice_record()` runs the recorder as a child (`loop::spawn`), stopped with SIGINT by a timer; `transcribe()` sends the recording as multipart/form-data (`multipart_body()`) to AI_ASR_URL; `voice_quiet()` skips a recording with no sound (the recognizer answers silence with "you"). The recording goes to `voice_dir()` (`/tmp/aicli-<uid>`, the sandbox lets the recorder write there, not in the session directory). While it is made: `voice_meter_start()` samples the level for the footer, `voice_preview_start()` sends the audio since the last final words every three seconds (verbose JSON segments), `heard_agree()` (LocalAgreement) makes the segments that two passes agree on final and drops their audio.
- **FastFlowLM** is used for voice (`flm serve -a whisper-v3:turbo`, port 52625, the `flm` service in docker-compose.yaml, flm/), not for chat work. Its chat defaults (8192 tokens) stay as they are; there is no `agent` tool with it.
- **worker.pm** – `worker`: one session as a chat in a process of its own,
  served over a socket (`worker::serve($fh, session => ...)`): input lines
  (`{"text"}`, `{"model"}`, `{"models"}`, `{"abort"}`) into the web interface's
  queue, the events of `ui::publish` back out (`ui::$RELAY`), as JSON lines. Ends
  when the socket closes. Used by the master (phase 2 of the session workers);
  landlock and projects come with it.
- **ui.pm** – `ui`: the web interface (`ai.pl --ui`), headless: an HTTP/1.1 server
  that is the master of the sessions: it runs no chat itself. `_worker_for($name)`
  forks a worker per session (`worker::serve`, the child first calls
  `loop::forget()` so it holds none of the master's sockets, timers or
  transfers); `_worker_read` reads its events (JSON lines, `_worker_event`:
  what the page shows of the active session, every failure, and `busy`, `state`,
  `models` kept by the master); `_project($rel)` (the page's project: its newest
  session, or a new one in it), `_project_dir($name)` (the directory a worker starts
  in); `_to_active($msg)` sends a message to the active
  session's worker; `_activate` switches the page (state, conversation and list
  are sent); `_idle_check` stops idle workers (`AI_WORKER_IDLE`); `_stop_all` ends
  them with the interface. The worker side keeps the queue, `input()` and the
  model switch (see worker.pm). `$OUTBOX` is for the tests: the messages go into
  an array instead of the workers. Routes, the SSE stream (`publish()`, the
  `$ai::EVENT_SINK` hook of the chat), the token (`_authed()`). The files of a
  session: `GET /file` (`_file`, `_query`: only what lies in the session's project,
  `tools::_resolve` for where a path leads; a picture or a sound inline, the rest an
  attachment, sandboxed); a tool's file goes to the page as a `file` event
  (`handle_llm_response` through `tools::offered_file`, the master adds the session
  in `_worker_event`), and the history lists it in the call's `files` (`_tool_item`). A tool line carries the whole call as `full` (`ai::call_full`: the name, then each argument in full), and the page opens it on a click (`toolLine()`). The worker side
  has the input queue that `chat_loop` reads (`input()`; a recording is recognized
  there, in the main flow, never in a request). `check_voice()` asks the recognizer (AI_ASR_URL)
  for a GET at start and after a failed recognition: the state's `voice` (`ok`,
  `none`, `unreachable`) disables the mic on the page, and stderr says why.
  The listener is `IO::Socket::IP` with `ReuseAddr`, so a stop and a start on
  the same port work. TLS (`--tls-cert`, `--tls-key`): `_tls_context()` loads
  the certificate once; each client gets a `Net::SSLeay` object on its
  non-blocking socket. `_handshake()` runs on the loop (a 10 s limit),
  `_read_socket()`, `_flush()` and `_close()` branch on `$cn->{ssl}`, and
  `_close()` sends close_notify before the socket closes (without it a client
  drops the answer). The cookie is `HttpOnly; SameSite=Lax` and gets `Secure`
  over https. Page:
  `ai/ui/index.html`: answers and thinking are drawn as markdown (its own
  renderer, DOM nodes only, never innerHTML); the system prompt says so in web
  mode only (`prompt_context()`, when `$::UI` is set; a session keeps the prompt it
  was made with). The look (`simple`/`cards`), the theme (system, light,
  dark; `data-theme` on `<html>`), the thinking block (a spinner and the
  character count while it comes, a click shows the text; `think` events), the
  waiting line above the message box (a spinner and the seconds while a request
  has no answer yet; `wait` event before each request, hidden at the first
  text, thinking or tool line, or at the turn's end), the
  mic (16 kHz WAV via `/voice`), the session select (`sessions` event,
  `ai::session_choices()`) and the conversation of the session (`history`
  event, `_history_data()`, on connect and after a switch; the master does the
  switch in `_activate()`, the model switch goes to the worker's queue like
  `_switch_model()`, which runs there).
- **tui.pm** – `tui`: the screen. Two modes: `bar` (default when the terminal
  is big enough, at least 7 rows and 20 columns): a footer of two lines at
  the bottom, activity (`set`/`unset` items with spinner and elapsed time)
  and info (`info` pieces: model, context, tokens, speed, cache), fenced off
  with a scroll region (`ESC[1;Nr`), drawn with the cursor saved and put
  back; `line` (`AI_STATUS=line`, or no size known): one line at the cursor,
  wiped by `clear()`. Both are animated by `tick()` from `$loop::on_tick`.
  `open()`/`close()`/`resize()` handle the footer; `set_screen_size` of
  readline is set to the rows above it (`ai::fit_readline()`). Only VT100
  escapes, no curses. `ai::status_info()` fills the info pieces. Glyphs come
  from `tui::glyph()` (unicode or ASCII set, by `AI_GLYPHS` or the locale),
  never a literal `chr(0x...)` in the status: `_cols()` measures columns
  (wide characters two, combining none), `_fit()` cuts by columns, emoji are
  `?`. Tests run with the unicode set (`TestAI::setup`).
- **ai/** – prompt templates: `default` (chat), `coder` (adds the tools),
  `perl` (a Perl developer with the tools; it names no project module, those
  go in the project's own AGENTS.md).
  `ai/imagemagick/policy.xml` is the ImageMagick policy of the `convert` tool
  (`MAGICK_CONFIGURE_PATH` points at its directory in the child).
- **aicli.sh**, **Dockerfile** – docker wrapper and the Ubuntu image.
  Builds: `./build-watch.sh` runs `docker buildx bake --pull` each time
  `.build-trigger` appears (`touch .build-trigger` starts one). The output goes
  to the terminal and to `build-watch.log`; `tail build-watch.log` shows the
  result (`== ... done, exit N`). Both files are git-ignored.
  **docker-bake.hcl** builds that image (`docker buildx bake`).
  The Dockerfile has three stages: `system` (the apt installs both images
  share), `base` (ai.pl and the basic unix tools) and `dev` (the default
  target: python3, the C/C++ toolchain, ImageMagick, ffmpeg, PDL, lame, the devel lists;
  no hardware tools, those are device images in their own repository). The
  package installs come before the `COPY` of the code in each stage, so a code
  change keeps the build cache; keep it that way when adding a package.
- **broker.pl** – the control plane of the remote agents (no pods, no engine, no project
  files): a Unix socket of JSON lines (`exec`: a job for an agent of the project's account
  with the job's tags, answered when the agent is done; `enroll_token`, `agents`,
  `agent_revoke` for the page; anything else refused), and the agents' listener
  (`AI_BROKER_AGENT_LISTEN`, through `remote_hub.pm`). `_exec` checks the shape of a request:
  the project as `account/project` by name, the tags as short lower-case words, argv as a list
  of strings (no shell), the timeout at most 120 s. The program is checked by the agent. Runs
  in `Dockerfile.broker`: no engine socket, no projects mounted; `broker.json` has the socket
  and the agents (`AI_BROKER_STATE` for the enrolled ones).
- **Remote agents** (`remote_hub.pm`, the broker's side; `remote_agent.pm` and `ai.pl --agent`,
  the agent's side; PLAN.md "remote agents"): a machine with devices runs `ai.pl --agent`,
  which polls the broker (`GET /agents/poll`, held up to 30 s) and posts each job's answer
  (`POST /agents/result/<id>`). The broker never starts an agent. `remote_hub` keeps the
  agents of `broker.json` (`agents`: name and fixed tags), the queue, one job per agent, and
  the times (a poll ends, a job waits 120 s for an agent, an agent has its timeout + 10 s).
  The agent's credential is its token, sent as a Bearer token in the request's authorization header, and the broker keeps
  only the SHA-256 of each agent's token (`agents` in `broker.json`: `tags`, `token_sha256`).
  The transport is HTTPS through nginx with the public certificate (no client certificate);
  `ai.pl --agent --pin sha256//BASE64` adds a pin of the server's key (optional). The broker's
  listener is `AI_BROKER_AGENT_LISTEN` (host:port), behind nginx's `/agents/` route (no login
  there: the agent's token is its login). Enrollment: the web page asks for a user's enrollment
  token (`POST /agent/token`, through the login: nginx's `X-Aicli-User`), shown once; the broker
  keeps its hash (`enroll`, in the state file `AI_BROKER_STATE`). `ai.pl --enroll TOKEN --broker URL
  [--name NAME] [--tags T] --programs P` (name: a UUID by default; tags: the programs' names by default); an enrollment on a machine that has its agent
  already (agent.json) reuses it, a different name or broker is refused posts it to `/agents/enroll`, gets the agent's own token and
  keeps it in `$AI_DIR/agent.json` (0600); with `--programs` it runs at once, else `--agent` reads that file when no token is given.
  The page's accounts (ui.pm, `_account`, `_visible`, `_owns`, `publish_each`): a request's account
  is the account ID nginx sends (X-Aicli-Account, 32 hex digits: the login's UUID without its dashes),
  behind the gate; undef for the local operator; the lists are made per account,
  an event goes to the clients that may see its project (publish's `session`/`project` options, the
  active session by default), and each route that uses a session or project checks `_owns`.
  Projects on the page: `POST /project/new` (made in the login's account, then switched to; the
  local operator names account/project), `/project/rename` (the project's sessions come along:
  their workers are ended first, a busy one refuses; the directory moves and each session's `cwd`
  follows; a session's stored prompt keeps the old path, a conversation's start is not rewritten),
  `/project/delete` (its sessions and files only with `force`, which the page asks for; a busy
  session refuses; when the page is on one of its sessions, the page moves to another project of
  the login first, or to none). `_delete_session` keeps the replacement session in the same project.
  The icon: `ai/ui/favicon.svg` is the drawing (plain shapes, made for aicli: no emoji artwork, which
  belongs to its makers), `ai/ui/favicon.ico` is the same at 16, 32, 48, 64 and 256 pixels (rendered with
  rsvg-convert, packed with PIL). nginx serves both publicly; the local interface serves them too.
  `/agent/list`, `/agent/revoke` and `/agent/job` (a job: exec for a project of the login, its output as text) are the page's (through the broker's `agents`, `agent_revoke`
  socket operations). A name or a token of the config and the state can not be the same. A job names
  tags, and an agent of its account with all of them runs it: `exec` waits for the answer (through the
  same Unix socket). The agent runs only the programs of its own
  `--programs`, in `--work/<project>`, with no shell. Not built yet: the owner check of a job
  (the agents are the user's, the jobs are not yet checked against the project's owner), the
  checkout of the project on the agent (it runs in a directory it has, empty by default), and
  the agents' page asks again every 10 s while its menu is open, and shows online or offline (a poll held or lately).
- **The tools run in the `ai.pl` container.** There are no pods. `bash`, `perl`, `grep`
  and the file tools run in the container of the `ai.pl` that holds the session (the local
  one of the web interface, or a remote agent's), as fork/exec, confined by landlock. The
  broker is not on the path of a local session. The projects are the directories
  `root/account/project` (the local root, or the agent's `--work`).
- **docker-compose.yaml** – (nginx and proxy/squid are built from `nginx/Dockerfile` and `proxy/Dockerfile`: the upstream image with `iproute2` added, so `ip` works inside them; searxng is the upstream image as it is) the services: `broker` (broker.pl), `agent` (the web
  interface, `ai.pl --ui`, on `aicli-net`, listens in its container on `AGENT_PORT`,
  nothing published), `searxng`, `proxy` (squid), `nginx` (`nginx/nginx.conf.template`:
  TLS on
  443 on the public IPv6 network `dmz-aicli` (the address of the `AAAA` record of
  `PUBLIC_DOMAIN`), proxy to `agent` on `aicli-net`, SSE unbuffered). `deploy.sh` looks up
  the `AAAA` record, creates `dmz-aicli` (routed, IPv6 only, like the qr deployment), and
  runs compose. The origin check of the agent accepts the https origin of the same host
  (behind nginx).
- **auth.pl** – the auth service (`Dockerfile.auth`, container `auth`, not published, on
  `aicli-net`): `POST /auth/login` checks the local account with PAM (`/etc/pam.d/aicli-auth`,
  `auth/aicli-auth.pam`) and sets the cookie `aicli_jwt`, an RS256 JWT (`Crypt::OpenSSL::RSA`,
  key in the volume `aicli-auth`, made at the first start) with `sub`, `roles` (the groups
  `aicli-*` of the account), `iat`, `exp`. `GET /auth/verify[?role=R]` is nginx's `auth_request`:
  200 with `X-User` and `X-Roles`, 401 without a valid token, 403 without the role.
  Sessions: a token lasts a day (AI_AUTH_LIFETIME, so a day idle logs out); a request in its second half gets a new
  token (`Set-Cookie`, the roles read again); a session (`sid`, every token of one login) ends a
  month after its login (AI_AUTH_SESSION_MAX). Logout revokes the session; `user del` and
  `user passwd` revoke the user's sessions. The revocation list is `revoked.json` in the volume.
  Another device: `POST /auth/qr/new` (a live session) makes a ticket, 256 bits, 120 s, once, at most
  3 open per user (kept as hashes, in memory); the menu shows it as a QR code (qrencode, SVG) of
  `.../login.html#qr=TICKET` (a fragment: not sent to a server, not in a log). The phone
  `POST /auth/qr/peek` (the user, nothing used), then `POST /auth/qr/redeem` after the user's
  confirmation: a new session of its own.
  nginx serves the login page (`ai/ui/login.html`, public, with `ai/ui/theme.css`, mounted read-only
  at `/etc/nginx/ui`) and sends every other page through `auth_request` (`/_gate`): the agent gets
  `X-Aicli-Gate` (AI_GATE_SECRET, made by deploy.sh, shared with nginx) and `X-Aicli-User`. The
  agent accepts the gate secret, or its own page token without nginx. The theme block of the chat
  is `ai/ui/theme.css`, inlined by the agent (`/*theme.css*/` in index.html).
  Passwords are set by auth.pl itself (`set_password`, asked twice on the terminal): its rules
  (AI_AUTH_MINLEN, default 10; printable; not the account name), a SHA-512 crypt hash with
  AI_AUTH_ROUNDS rounds (default 100000), stored with `chpasswd -e` (the hash on its standard input). The system passwd command is
  not used, so its rules do not apply.   The accounts: `auth.pl user add|passwd|del|list`, `role add|remove`. Each has an account ID: a UUID
  in the passwd comment's fifth subfield (`aicli=<uuid>`, made by `user add` or at the first login by
  `ensure_account_id`, kept with `usermod -c`), in the token as `acct` and sent to nginx as X-Account. PAM reads `/etc`, so the
  four account files are copied to the volume after a change and back at a start (a bind mount
  over them fails: useradd renames over them).
  API tokens (for the services behind nginx): `POST /auth/api/token?aud=flm`, from a live login
  (never from an API token), gives a JWT with `aud: flm`, the login's `sub`, `acct`, `sid` and `ses`
  (so logout and a revoked session end it), a week by default (AI_AUTH_API_LIFETIME). nginx's
  `/api/flm/` checks it with `/auth/verify?aud=flm` (`/_gate_flm`), sends the user and account as
  X-Aicli-User and X-Aicli-Account to flm, and strips the token and the cookie. `/auth/verify`
  refuses an API token for the page (no aud) and a login for an API (aud mismatch); no renewal for
  an API token. The page's agents panel has the "new API token" button.
- **t/** – tests, **PLAN.md** – open work and ideas.

## How a turn works

`ai::chat_completion($input)`:

1. append the user message to the session `chat` file (one JSON message per
   line), unless `AI_TOKEN_BUDGET` is used up,
2. `manage_context()`: compact the conversation if it is over the threshold,
3. `load_messages()` and `request_completion()`: POST to
   `/v1/chat/completions` with `stream => true`,
4. `new_stream()` parses the SSE chunks, `new_printer()` shows thinking
   (`reasoning_content`/`reasoning` deltas, `<think>` blocks) and answer in
   their colors,
5. on an error: `classify_error()` says whether to retry (`retry_delay()`,
   backoff or what the rate limit headers ask), to compact (context too long)
   or to give up,
6. the answer without thinking is appended as assistant message,
   `record_usage()` counts the tokens,
7. `handle_llm_response()`: the calls the server made (`tool_calls`, see
`native_call()`), or else `parse_tool_calls()`, then `execute_tool()` for
   each, `agent` calls are started together and waited for at the end; the
   results are appended as user messages,
8. back to 2 while there were tool calls (max `AI_MAX_TURNS`). `stuck_check()`
   stops the input when `AI_LOOP_LIMIT` turns in a row had the same errors only.

The request is always rebuilt from the chat file: nothing about the
conversation lives only in memory.

`$::ABORT` is set by ctrl-C while a turn runs (`$ai::BUSY`). `loop::step()`
sees it and stops everything that is registered: transfers end with error
"interrupted", children are killed (process group), timers fire with a true
argument. `$::LOOP = 0` ends the chat. Without a terminal (`chat_loop` with
piped input) the same is done by a plain signal handler: INT stops the turn,
a second INT or one while idle exits 130, TERM stops the turn and exits.

Strings: messages are text (decoded) in memory and in JSON. The terminal,
files and tools work with bytes: `ai::to_text()` / `ai::to_bytes()` at the
border.

## The event loop

`loop::step()` does one round: draw the status line (`$on_tick`), `select()`
on the curl sockets and the pipes of the children until the next timer or
deadline (at most 0.2s), then `multi->perform()`, finished transfers
(`on_done`), child output and exits (`on_done`), due timers.
`loop::run($until)` repeats that until `$until->()` is true.

- `loop::http(method, url, data, api_key, on_data, on_done)` returns the
  request hash: `{code}`, `{headers}`, `{error}`, `{body}` when done.
- `loop::spawn($worker, timeout, on_done)`: `on_done->($out, $exit, $sig, $why)`.
- `loop::timer($seconds, $cb)`: `$cb->($aborted)`.

The main agent waits (`utils::http`, `utils::fork_run`: register + `run`), so
its code reads top to bottom. Sub-agents never wait: `agent::request` →
`on_done` → `agent::response` → `agent::next_tool` → `execute_tool_async` →
callback → ... Forking tools support both through `tools::_run()`: it runs and
waits, or with `$tools::ASYNC` returns a `tools::job` for `loop::spawn`.

A callback can start a child whose pipe gets the fd number of a socket closed
in the same round: `step()` only reads what it selected on, and pipes are
non-blocking. Keep it that way.

## Web tools and proxies

`tools::_http($finish, %request)` is to HTTP what `_run` is to children: it
waits for the main agent, and with `$tools::ASYNC` returns a `tools::job`
whose `start` registers the request in the loop. `execute_tool_async()` runs
either kind of job. `fetch` turns HTML into text with `ai::html_to_text()`;
`search` asks SearXNG (`AI_SEARXNG_URL`, `format=json`) and is only
`tools::available()` (and in the prompt) when that is set.

Proxies: `utils::proxy_for('ai')` (`AI_PROXY`) is what `loop::http` uses
unless a request names its own `proxy`; web tools pass
`utils::proxy_for('web')` (`AI_WEB_PROXY`), search passes `AI_SEARXNG_PROXY` or
none. `loop::http` always sets the proxy option, also to empty, so libcurl
never reads the environment on its own. Web requests carry no API key.

## Sub-agents

`package agent`. `agent::launch($task)` creates one (queued when
`AI_MAX_AGENTS` are running; the `agent` tool is not available with FastFlowLM), `agent::wait(@agents)` runs the loop until they
are done, then `{result}` / `{error}` are set. A sub-agent has its own message
list (system prompt from `ai::subagent_prompt()`: session prompt + tools
without `agent`), retries like the main loop, counts into the usage of the
session, writes its transcript to `agents/` in the session directory after every
message, and
shows up in the status line with its tokens (`agent::status`), and each start and
tool call is printed as one line (`ai::agent_view`, `AI_AGENT_VIEW`). It keeps its
own messages within the context window (`agent::compact`, before every
request and once after a "context too long" error): old tool output is
pruned, then the oldest steps are dropped with a note; system prompt, task
and the last two messages stay. No summary request, so it never has to wait.
It cannot start agents. It stops after `AI_AGENT_MAX_TURNS` tool turns (default 20).

## System prompt

`system_prompt()` = prompt file of the session + `prompt::<template>::prompt()`
(tools, not with native calls: the API has them) + `prompt_context()`: `project_instructions()` (`AGENTS.md` of the
working directory, `AI_PROJECT_FILE`) and `prompt_date()`. Most stable first.
Sub-agents: `subagent_prompt()`, same parts without the `agent` tool.

## Display, diffs, undo

`tool_display()` is `brief` or `full`. Brief: `new_printer(hide_tools => 1)`
drops the tool call blocks from the streamed answer (a line is held back until
it is clear that it is no tool header), `handle_llm_response()` prints one
line per call (`tool_summary()`) and the first lines of the result
(`clip_lines()`). A printer passed to `handle_llm_response()` always gets the
full texts.

The file tools push what they change to `@tools::CHANGES` (shown by
`show_changes()` with `format_diff()`/`diff_lines()`, an LCS line diff) and
write an entry to the undo journal of the session (`tools::_journal()`:
`undo/journal`, JSON lines, plus a copy of the old content). `ai::undo_last()`
pops and reverts one entry. A new tool that changes files must call
`_changing()` or `_journal()` before it does.

## Usage and context

`usage` file per session (`load_usage`/`save_usage`): requests, prompt and
completion tokens, `chars_per_token` (learned from what the API reports, used
by `estimate_tokens()`). Also `tools`: per tool its calls, errors and seconds
(`tool_stat()`, for the chat's calls and the sub-agents' ones; an agent's time runs
from its start to its end). Each call shows its time after its result (`took`), the
header of the page has the session's totals (the `stats` event and the state's
`tools`, `_tool_totals()`), and `/usage` lists them. `context_limit()`: `AI_CONTEXT_TOKENS`, else
`%MODEL_CONTEXT` (model list) or `$SERVER_CONTEXT` (llama.cpp `/props`), else
0 = unknown. `compact_context()` summarizes the older part in pieces that fit a request (`summarize_messages()`, each piece updates the summary so far; a piece that fails keeps what there is). It keeps the first request of the conversation (the file
`first_request`) word for word in its summary, and records every compaction in
`compactions` (`/context` shows them). `compact_context()`: prune old tool results, then summarize the
older messages with a quiet request (or drop them); removed messages are
appended to `chat.archive`.

## Tools

A tool is an entry in `$tools::TOOLS` plus a sub in package `tools` named
after the lowercased tag of its `syntax` (`bash_7c48`, `write_edf5`, ...). The
sub gets an arrayref of arguments (bytes), returns the result or dies with the
error. Tag and argument sentinels are derived from `syntax` in the `BEGIN`
block.

```
///BASH_7c48+EO_dfd7        header: tag + one sentinel per argument
ls -la                      argument
EO_dfd7[6]                  sentinel, the [length] is optional
BASH_7c48                   closing tag, optional
```

Result for the model: `[BASH_7c48 RESULT_d170\n...\nRESULT_d170]` or
`[BASH_7c48 ERROR_9a78\n...\nERROR_9a78]`. The hex suffixes make accidental
matches in normal text unlikely, keep them when adding tools.

How they run:

| tool | execution |
|------|-----------|
| read, lines, write | in-process Perl |
| replace | in-process: one exact, unique match; temp file + rename |
| edit | in-process: `tools::ed_apply()`, an ed subset (a, i, c, d, s; line, `$`, `/regex/` addresses); all or nothing |
| delete, move, mkdir, list | in-process Perl (`unlink`/`rmdir`, `rename`, `File::Path`, `readdir`) |
| find | in-process Perl: `walk_tree()`, opendir/readdir/closedir, a filter and a prune sub; `-l` before descending, so links are not followed |
| image | in-process Perl: `_image_type()` checks the format; a picture bigger than `AI_IMAGE_MAX` is made smaller by `_shrink()` (ImageMagick, forked); the picture waits in `@tools::IMAGES`, and `handle_llm_response()` sends it in a user message after the results, as `wire_message()` makes it (OpenAI form) or `provider::anthropic::message_content()` (Anthropic). Only with `AI_VISION=1`, never for a sub-agent |
| theme | `theme_5c2e` sends `theme` with a name of `@ai::THEMES` (the page's `THEMES` list must match: `t/100_ui.t` checks it); no code and no CSS come from the model. Only where `$EVENT_SINK` is set (web), not for sub-agents |
| list_sessions | `list_sessions_3b7d` lists `ai::session_choices()` of the session's project (an empty one left out, except this one), with a name filter. Only where `$EVENT_SINK` is set, not for sub-agents |
| create_session | `create_session_9d4e` takes an optional name (checked: a valid name, not taken, also not one made in this answer), else makes one (`session-` and an id), and emits `create`; the master's `_create_session` makes the session in the project of the session that asked (`init_session`, its `cwd`), checks the name, and lists it. `%tools::CREATED` lets `switch_session` name a session made in the same answer. No delete tool, on purpose. Only where `$EVENT_SINK` is set, not for sub-agents |
| switch_session | `switch_session_5a1f` checks the name (exists, not this one, same project) and emits `switch`; the master keeps it in `%pending_switch` and `_apply_pending` switches the page when the turn is over, if the page is still on that session (then the pending rename, if any). The state carries `switch` for a refresh. Only where `$EVENT_SINK` is set, not for sub-agents |
| rename_session | `rename_session_8f2c` checks the name and emits `rename`; the master (`ui::_worker_event`) keeps it in `%pending_rename` and calls `_apply_rename` when the session's turn is over with nothing queued (`_rename_session` ends the worker, moves the directory, the page follows); the state carries `rename` until then, so a refresh shows it. Only where `$EVENT_SINK` is set, not for sub-agents |
| models, model | `models`: `all_models()` (`fetch_models()` of every provider: Anthropic pages its list, `after_id`), the filter as a regex on the ids, the context from `MODEL_CONTEXT`; `model`: a choice must be in the list (`resolve_model()`, which also takes a unique part of the id), then it waits in `$PENDING_MODEL` and `apply_pending_model()` (at the start of `chat_completion()`) calls `set_model()`, which writes the session's model and provider files and emits a `model` event. Both are main chat only (`available` is false for sub-agents): a sub-agent cannot wait for the list, and does not switch the model |
| devel | a probe per language in `%DEVEL_PROFILE`: `perl` reads the `$VERSION` of each `.pm` under `@INC` (nothing is loaded), `bash` looks at the PATH, the others run their list tool (`python3`, `luarocks`, `pkg-config`) through `_run`; the list is cached per process in `%DEVEL_CACHE`, and a missing program is an answer, not an error. The system prompt does not carry it, the model asks |
| convert | ImageMagick (`magick` or `convert`, `_magick()`) in a forked child through `_run` (`_magick_run`, `_magick_args`): the colour (`gray`, `sepia`) is `-colorspace Gray` or `-sepia-tone 80%`, given only when asked for; the output goes to `free_name()`'s next name when that one is taken, and the result is `wrote NAME: converted ...`; a list, no shell, the input checked by its first bytes (`_picture_ok()`), the output written to a temp name and renamed when it worked, `_changing(..., binary => 1)` for the journal. Works for sub-agents too (a job) |
| grep | `_run` → `exec grep -rn -e <pattern> -- <path>` |
| bash | temp file, `_run` → `exec bash <file>`; on the web page the workspace's pictures and sounds (`workspace_pictures()`) are looked at before and after the call, and the new or changed ones (`picture_changes()`) are added to the result as `[aicli file] NAME` lines (the model sees them; `result_files()`, `without_result_files()`), offered like the other files with their `file_version()` |
| perl | `_run` → `eval` in package `aicli::tool`, or `Safe->reval` (`AI_PERL_SAFE`) |
| fetch, search | `tools::_http` → `loop::http` (web proxy, timeout, size limit, redirects) |
| generate_image | `tools::_http` → `loop::http` to `AI_IMAGE_URL`; the PNG is written by `_write_whole` (the old file goes to the undo journal through `_changing`, the bytes to a temp name, renamed when whole). `image_output()` names the file (the default too); `free_name()` gives the first free name when that one is taken (a picture is never replaced), and `offered_file()` reads the name from the result line (`wrote NAME: ...`). Only with `AI_IMAGE_URL` |
| speech | the same for the speech service (`AI_SPEECH_URL`): the WAV, named by `speech_output()` (a taken name gets `free_name()`'s next one), written by `_write_whole`; the answer must start with RIFF; `offered_file()` reads the name from the result. Only with `AI_SPEECH_URL` |
| generate_audio | the same for the audio service (`AI_AUDIO_URL`, AudioLDM 2): the WAV, named by `audio_output()`, written by `_write_whole`; the answer must start with RIFF; `offered_file()` reads the name from the result. Only with `AI_AUDIO_URL` |
| agent | `agent::launch` + `agent::wait` |

Tools are called natively by default: the request has their JSON schemas (from
the same table: the names and the properties in the order of the syntax), and
the server returns the calls as tool_calls. The result of such a call is a
message with role "tool" and the id of the call. The text syntax above is the
fallback (AI_TOOL_CALLS=text, or a model that writes it): calls are parsed from
the answer, the /// header and a code fence before it are optional.

There is no confirmation step, by choice. The file tools are confined to the
workspace (`$ai::WORKSPACE`, set by `ai::set_workspace()` at start from
`AI_WORKSPACE` or the current directory; `@ai::WORKSPACE_ALLOW`).
`tools::_resolve()` finds where a path really leads, name by name: a symbolic
link is read with `readlink` and replaced by its target, `..` drops the name
before it, a name that does not exist is kept as it is (so new files and
links to nowhere resolve too). `tools::_path()` dies with "outside of the
workspace" unless that place is under an allowed root. Never judge a path by
a pattern over its text: a regex cannot see symlinks (`new/../link_out/x`),
`t/66_workspace.t` has the cases. 
Forked tools (`bash`, `perl`, `grep`) are confined by the kernel:
`ai::sandbox_child()` is a `@utils::CHILD_INIT` hook, it runs in the child of
`utils::fork_child()` after the output is redirected and before the settings
are wiped, and calls `sandbox::confine(ai::sandbox_policy())`. `package
sandbox` (utils.pm) is Landlock through `syscall()`: create a ruleset for the
write rights (and read rights with `AI_SANDBOX_READ`), allow each path (opened
with `O_PATH`, file rules get only file rights), `prctl(NO_NEW_PRIVS)`,
restrict. It is per process, inherited, and cannot be taken back, so it must
only ever run in a forked child, or in a session worker (`worker::confine()`, the
worker's own process: the chat of a session, with its tools' children inheriting
the limit: the workspace, the temp directory, the sandbox devices and the
session's own directory; reads everywhere). Never in the master. The policy is
empty (no sandbox) for `AI_SANDBOX=off`, no workspace, or the workspace `/`.

## Commands

One table, `@ai::COMMANDS` (`run`, `help`, `usage`, `complete`), drives
execution (`handle_command()`), `/help` and TAB completion
(`setup_commands()` builds `$ai::cmds` from it). Add a command there and
nowhere else. `handle_command()` returns undef for chat text, 0 for a handled
command, 1 to leave; a command line never reaches the LLM. `/retry` and
`/rewind` use `rewind_chat()`: it only cuts the end of the conversation (to
`chat.archive`), the start stays as it is.

## Sessions

`meta` (JSON lines, `record_meta()`, `meta_of()`): the thinking and the usage line of each kept
answer, for the web page's history. Never in the chat messages (the model would get them). A line
matches its message by index and by a hash of the answer, so a rewind or a compaction makes it
unused without any clean-up.

`$AI_DIR/sessions/<name>/` with `chat` (conversation), `prompt` + `template`
(system prompt and the template it came from), `model`, `history` (readline,
saved and loaded by `use_session()` when the session changes).
Names match `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`, checked by
`valid_session_name()` everywhere a name comes in. There is always a current
session: `delete_session()` of the current one moves on to a new, empty one,
`reset_session()` empties it in place.

Sessions must not pile up, and conversations must not vanish:
`%AUTO_SESSION` has the sessions this process made up a name for, at `END`
`drop_empty_sessions()` removes those in which nothing happened
(`session_info()->{empty}`: only the system prompt, no model, usage, archive,
undo or agents). `tidy_sessions()` at start removes empty made-up sessions
older than a day (crash leftovers; a younger one may belong to a running
process). A session with a conversation, or one the user named, is only
removed on request: `/session delete`, `/session prune` (asks via
`ai::confirm()`), `AI_SESSION_KEEP_DAYS`. `use_session()` notes the
working directory in `cwd`; `last_session()` finds the most recent session of
a directory for `-c`. `chat_completion()` returns true when the turn ended
with an answer, `one_shot()` makes the exit code of `-p` out of that.

## Providers

The chat has one main provider (`chat_setup`: `AI_PROVIDER`, the key's prefix,
or `AI_LOCAL_SERVER`), kept in `$MAIN_PROVIDER`, `$MAIN_ENDPOINT`, `$MAIN_KEY`.
Every other provider with a key of its own (`AI_API_KEY_<NAME>`, from
`provider_keys()`) is reached too: `provider_names()` lists them, `use_provider()`
makes one the chat's (endpoint, key, `$AI_URL` from `ai_url()`), `with_provider()`
does it for the time of a call. `all_models()` lists every provider as
`[provider, id]` pairs (`@ALL_MODELS`), and the label is `provider/id`
(`model_label()`, `current_label()`). `resolve_model()` and `choice_pair()` read a
choice: a label of the list, a bare id (the chat's provider first, else the one
provider that has it), or a label of a provider the list does not have. `set_model()`
writes the session's `model` and `provider` files, `read_session_provider()` reads
the second on `use_session()`. The context is keyed `"provider/id"` in `%MODEL_CONTEXT`.
The web page gets the list as `models` events (`ui::_send_models`); its choices
come as `POST /model` and are switched in the chat's flow (`ui::input()`).

`%ai::PROVIDERS` (URL, key prefix) and a `provider::<name>` package with
`req()` (chat request) and `raw()` (raw completion request). All are OpenAI
compatible streaming APIs: cerebras, openrouter, nvidia, openai, lemonade, and `local`
for `AI_LOCAL_SERVER`. `anthropic` is the Messages API: `provider::anthropic`
has its own `req()` and `headers()` (the `x-api-key` header, see
`provider_headers()`), and `ai::new_stream()` reads its events (`message_start`,
`content_block_delta`, `message_delta` for the usage).
Other APIs are reached through an OpenAI compatible gateway, such as LiteLLM or OpenRouter.

## Tests

| file | covers |
|------|--------|
| `t/10_sessions.t` | `ai.pl` as a process: sessions, startup checks, `--help` |
| `t/15_logging_privileges.t` | stdout/stderr/`AI_LOG`, who to become when started as root |
| `t/20_response_tool_handling.t` | tool call parsing on real model output |
| `t/30_prompt.t` | generated tools prompt, examples parse |
| `t/40_chat_loop.t` | agent loop, streaming, thinking, errors, abort (scripted LLM) |
| `t/45_http_e2e.t` | real curl against a fake server: loop, rate limit headers, usage, parallel sub-agents, `ai.pl` end to end |
| `t/50_commands.t` | slash commands, input readers, completion |
| `t/55_session_cleanup.t` | empty sessions removed at exit and start, `/session prune`, `AI_SESSION_KEEP_DAYS`, the session list |
| `t/60_tools.t` | `fork_run`, environment, bash/perl/Safe/read/write/grep |
| `t/65_file_tools.t` | lines, replace, the ed engine, edit, delete, move, mkdir, list, find (`walk_tree` options) |
| `t/67_sandbox.t` | Landlock for forked tools: writes, reads, child processes, extra paths, fallbacks (skipped without kernel support) |
| `t/66_workspace.t` | workspace confinement: `..`, absolute paths, symlinks, every file tool, `/workspace` |
| `t/70_retry_usage_context.t` | retry/backoff, rate limits, usage, budget, context management |
| `t/80_agents.t` | sub-agents (parallel, limits, errors, abort), the status line |
| `t/82_footer.t` | the footer (`tui.pm` bar mode, line fallback, resize, close), `fmt_k`, speeds, cached tokens, the info line from a mocked request |
| `t/84_providers.t` | providers: detection by key, OpenAI and Anthropic requests and stream, the curl shim, tool calls in the text, the logging of server calls |
| `t/86_native_tools.t` | native tool calls: tools in the request, calls and results, pieces of arguments, errors, the text fallback, sub-agents |
| `t/87_images.t` | pictures: the formats, the `image` tool (workspace, refusals, size), the picture message in a turn, its form for OpenAI and Anthropic, the estimate |
| `t/92_convert.t` | ImageMagick: the `convert` tool (its colours, gray and sepia, given only when asked for; another one refused) and the shrinking of `image`, with a stand-in program (arguments, environment, refusals, failures, sub-agent) and the real one when it is installed (formats, crop, turn, quality, the policy) |
| `t/93_thinking_view.t` | the thinking view: spin, text or off (AI_THINKING_VIEW, AI_SHOW_THINKING, `/thinking-view`), the printer in each, a whole turn without the thinking in the chat |
| `t/94_perl_prompt.t` | the `perl` template: what it asks of the agent for Perl, that it names no project module, that a session built from it has it |
| `t/96_grounding_loop.t` | the `devel` tool (profiles, filter, cache, a missing program, the system prompt without a module list) and loop control (`stuck_check()`: the same errors stop, different errors and successes do not) |
| `t/88_markdown.t` | markdown of the answer: headings, emphasis, code, lists, tables, streaming, the printer |
| `t/89_context_thinking.t` | the reasoning setting, what the request says, the first request through compactions, `/context` |
| `t/97_live.t` | a real model, only when `AI_LIVE_SERVER` is set (`AI_LIVE_MODEL`, optional `AI_LIVE_SEARXNG`): one answer, a native tool call, the thinking setting, search. Skipped otherwise |
| `t/100_ui.t` | the web interface: routes, the token, origin check, body limits, the input queue, the event stream on socket pairs; the listen addresses (IPv4, IPv6, `::`), stop and start on the same port, TLS with a generated certificate (a https request, the Secure cookie), the state of the speech recognizer; then `ai.pl --ui` as a child, a message in and the streamed answer out, Ctrl-C |
| `t/122_auth_password.t` | the password rules of auth.pl (length, printable, not the name, AI_AUTH_MINLEN), the SHA-512 crypt hash (rounds, salt, it checks), set_password asked twice (no echo on a terminal, refused when they differ or break the rules), the hash given to chpasswd -e on standard input and not the password |
| `t/124_remote_agents.t` | a remote agent end to end: a broker process (its listener and its Unix socket) and an `ai.pl --agent` process; a job with the agent's tags runs in the agent's project directory and its output and exit code come back; the agent's own program list refuses a program (126); a job with no tags, a bad tag, a timeout over the limit, another account's project, and an operation the broker does not have are refused |
| `t/128_agent_routes.t` | the web interface's agent routes with a stand-in broker: a token for the login's user (no login: refused, nothing asked), the list, a revocation (a name needed), a refusal of the broker (502 with its reason) |
| `t/127_enroll_e2e.t` | the enrollment end to end: a broker with its state file, the user's token and list over the socket, `ai.pl --enroll` (a wrong token refused, the right one keeps agent.json 0600, the token not printed), `ai.pl --agent` with that file and no token on its command line runs a job, a revocation stops it |
| `t/126_enrollment.t` | the enrollment without sockets: a user's token (only its hash kept, a new one replaces it, used once: a second use is refused), agents enrolled with it (own token, hash only), the names and tags checked, the list of a user, revocation (owner only, the token stops), the state file over a restart |
| `t/135_error_display.t` | the errors of a tool read whole on the page (a line is not cut at the terminal width there; an error has up to 40 lines, a result 8) |
| `t/134_history_tools.t` | the whole call of a tool line (`full`: each argument in full, a multi-line value indented), a result is the one of its own answer (an id may come again), the history of a session on the page: the tool calls of the chat with their results, in their place between what was said and the answers, a call without a result yet has none |
| `t/133_favicon.t` | the icon of the pages: favicon.ico (16, 32, 48, 64, 256 pixels) and favicon.svg, a strawberry drawn for aicli (not emoji artwork); both pages link it; nginx serves it publicly; the local interface answers it without a login |
| `t/136_api_token.t` | the API tokens of the services (`/auth/api/token`, aud=flm): issued from a login only, verified with `?aud=flm` (a login refused for it, an API token refused for the page), no renewal, a user that is not an account, a token past its time, the end at logout |
| `t/137_agent_defaults.t` | the enrollment defaults: the name is a random UUID version 4 (each new), the tags are the programs' names (a path's last part, short lower-case words, each once) |
| `t/144_web_files.t` | the files of a session on the page: `GET /file` (a picture or a sound inline, the rest an attachment, sandboxed; a login sees the projects of its own account only; a link or `..` out of the project, an absolute path, a bad session name and a folder refused; the size limit; only GET), the history's `files` (a call that wrote a file still there, not a failed call, not one without its result), the master's `file` event (the active session only, with its session) |
| `t/151_upload.t` | the "+" upload (`POST /upload`): a file kept in the active session's project under `uploads/` (any kind, the bytes as they were), a name taken gets the next free one, a name is only its last part (no folders, no hidden names, nothing with no name left), another account's session refused (403), `uploads` as a link refused, no session refused, a body over `$MAX_UPLOAD` refused by the reader (413) |
| `t/150_request_stamp.t` | the request stamp (UTC time, the user: the project's account or `local`, the checksum: SHA-256 of the body, the same body the same checksum); in web mode the retries are in the log stamped and not events for the page; the page's error for a failed request names the request by its stamp |
| `t/149_model_timeout.t` | the start with a model server that takes the connection and never answers: the model list and the context time out (`ai::LIST_TIMEOUT`), the error says so, the start goes on with no models |
| `t/147_bash_pictures.t` | a bash call on the web page: the pictures and sounds it made or changed are offered (a file event with a version, the model's result lists them, the history has them), a change to anything else and a failed call offer nothing |
| `t/146_generate_audio.t` | the generate_audio tool: the WAV written whole and journaled, a name taken goes to the next free one, the request (the seconds, steps and seed, the defaults), the refusals (no request made), a non-WAV answer leaves no file, the file offered |
| `t/143_speech.t` | the speech tool: the WAV written whole (a temp name renamed when whole), a name taken goes to the next free one and the file there stays, the request, the default name, the refusals (no request made), an answer that is not a WAV leaves no file, the file offered |
| `t/142_generate_image.t` | the generate_image tool: the PNG written whole and journaled, a name taken (a folder too) goes to the next free one and the file there stays, the request (the URL's slash, the size, steps and seed), the default names, refusals (no request made), the service's errors leave no file, the file offered, a chat turn sends the `file` event, a failed call none |
| `t/145_multi_calls.t` | several tool calls in one answer: the same index for all of them, none, or one each, and interleaved argument pieces, are separate calls (`stream_call()`), each answered with its own id, in order; a failing call leaves the others to run; the calls are kept in one assistant message; each call's time and the totals in the usage (also the sub-agent's calls), `/usage` lists them |
| `t/141_create_session.t` | the model makes a session: the name made by the worker, the master makes it in the asking session's project and lists it, a switch to it in the same answer is accepted, the same name or a bad one is refused, not for a sub-agent or the terminal |
| `t/140_switch_session.t` | the model lists its project's sessions (this one marked, the empty ones and other projects left out, a filter) and switches the page: checked (same project, exists, not this one), kept by the master, the page's state has it, done when the turn is over only if the page is still on this session, refused as a failure when the target is gone |
| `t/139_rename_session.t` | the model's session rename: the tool (web only, not for a sub-agent; the name checked, its own name and a taken one refused), the master keeps the request, the page's state has it (a refresh too), it is done when the turn is over and nothing is queued, a name taken by then is refused and the page is told |
| `t/138_login_home.t` | a login's page starts in its own work: the stream's connect makes the account's newest session active (or a new one in its first project) when the active one is not its own; the local operator and an account with no project keep what they had |
| `t/132_account_id.t` | the account ID of a login in the passwd comment: the fifth subfield, the other subfields kept, made once, read back without the dashes, the UUID's form and version, a login not in the passwd refused |
| `t/129_page_accounts.t` | the page's accounts: the login's name (none, a bad one, the local operator), what an account sees (its sessions, projects, busy list, the page's state), the events (each to its account, the models to all, a failure of a session to its account), the routes an account may not use (message, switch, delete, rename, pod, a session in another's project) |
| `t/130_project_admin.t` | the page's projects: created in the login's account and switched to (names checked, a taken name, a login with no account), renamed with their sessions (same account; a busy session refuses), deleted with its sessions and files only on force, the page moves off a project it is on first, nothing of another account touched; the local operator's account/project |
| `t/125_agent_pin.t` | the agent's arguments: a pin of the form sha256//BASE64 (others refused), the token (a short one, none refused) |
| `t/123_remote_hub.t` | the hub without sockets: the config of the agents (names, tags, token hashes), the bearer tokens that get in (403, a token of no agent, no token, not a bearer token), a held poll and a job for its tags, the answer (from the right agent only, once), busy polls (409), bad answers (400, 404), no agent for the tags, no agent connected, held polls ending (204), a job no agent takes, an agent that does not answer, an output over the cap |
| `t/107_broker.t` | the broker without sockets (its dispatch): not JSON and unknown operations refused (the pod ones are gone), a job's checks (tags, argv, timeout, project names), a job for an agent that is not connected or of another account refused, the user's enrollment token and agents |
| `t/104_projects.t` | the projects under the root (hidden and files left out), a session made in one with its AGENTS.md and its workspace in its prompt, the switch to a project (the newest session, or a new one), the root |
| `t/105_wrapper.t` | `aicli.sh --root`: the root mounted, the container started in the current project and named for the root; a directory outside the root refused; `--broker` mounts the broker's socket volume with no root needed and no pod root; without `--root` as before (a fake docker records the arguments) |
| `t/102_sessions.t` | `ai.pl --ui` with two sessions: a worker each, two turns at the same time, a switch while one is busy, the abort of the active one only, ctrl-C ends the interface and its workers |
| `t/103_worker_sandbox.t` | a session worker confined by landlock: writes in its workspace and session only, reads everywhere, a tool's child inherits the limit (the probe file is outside the test's temp directory) |
| `t/101_worker.t` | a session worker over a socket pair: the state and the events of a turn, the message in the session's chat file, the models, a slash command refused, the end when the socket closes |
| `t/99_models.t` | the models: every page of the list (Anthropic), one list for the others, several providers in one list (`provider/id`, the keys of each), resolving a choice, the session's provider, the context per provider, the `models` tool (a filter, the current model, the context), the `model` tool (switch, an unknown id refused), the sub-agents without them |
| `t/98_voice.t` | speech: the multipart upload, the recorder child stopped by SIGINT, the text of the recognizer, its errors (endpoint not reachable, HTTP status, no text), `/voice` |
| `t/95_cli.t` | `-p` (one request, exit codes, stdin) and `-c` (continue per directory), as a process |
| `t/85_web.t` | proxy selection, HTML to text, fetch, search (mocked HTTP layer), a real fetch, `/retry`, `/rewind` |
| `t/90_prompt_display_undo.t` | project file and date in the prompt, byte-stable request prefix, brief display, diffs, `/undo` |

The tests are run by hand, twice: with the Debian packages (`prove -I. t`,
`WWW::Curl`), and inside the image of the Dockerfile (Ubuntu 24.04, dev stage,
`WWW::Curl`) as a normal user. There is no CI (no GitHub Actions workflow).

`TestAI::mock_http` scripts the main agent (`utils::http`),
`TestAI::mock_agent_http` answers the sub-agents (`loop::http`).

## Testing the page in a browser

There is a headless browser here: Firefox, through Playwright. Chromium is not installed
here (its install did not finish in this sandbox), so use Firefox. Playwright is installed globally
(`/usr/local/lib/node_modules/playwright`); its Firefox is in `/opt/ms-playwright/firefox-*`.
Check it with `node -e "require('playwright').firefox.launch().then(b => b.close())"` from
any directory with `NODE_PATH=$(npm root -g)`.

The checks are in `tools/ui-check/`:

- `start-server.sh`: starts `ai.pl --ui` on port 8770 (`AICLI_CHECK_PORT` changes it) with
  the session `s1` (two exchanges, no model needed) and a project root with the account
  `acme`. It prints the address, the token (`abc123`), the state dir and the log. It saves the
  server's PID in the state dir, so stop it with `kill -INT $(cat <state>/server.pid)`.
- `revert.js`: the revert button of the chat. Only the last exchange's is enabled (on its answer, or on its question when no answer follows it); the first
  click shows "sure?", the second reverts it. Prints the buttons, the chat file and the page errors.
- `menu.js`: the session menu (rename from the name box, delete with "sure?" and "cancel")
  and the project menu (create, rename, delete). It changes the state dir.
- `common.js`: the shared part (the address, the token, Firefox, the page errors).
- `fake-services.py`: a fake chat (it asks for `generate_image` for each new message of the user, and answers in text after a tool result; "sound" in the message asks for `generate_audio`, "copy" for a bash call that copies a picture), a fake image service (a 256 pixel PNG) and a fake audio service (a WAV clip), so a turn runs without a model.
- `audio.js`: a clip a tool made plays (the audio element) and downloads, live and after a reload. It needs the fake services with the audio service (`AICLI_CHECK_AUDIO`).
- `files.js`: a picture a tool wrote is shown inline and downloads, live and after a reload; a tool line opens to the whole call; a follow-up picture goes to a new name and each entry keeps its own.
- `cancel.js`: a cancelled exchange can be reverted: a question cancelled before its first word or while the model is thinking ("slow think"), an answer cut short, and a stopped tool call ("sleep": a bash call that takes 25 s), each with its revert at the end of its exchange, which takes the exchange out of the chat file and the page; a stop leaves no empty answer. It needs the fake services ("slow", "late", "think", "sleep"; "bigpicture" is a slow picture) and a fresh fixture.
- `upload.js`: the "+" picks files (any kind): they go to the project's `uploads/` (a chip with a link each), and the next message names them; the chat file has the message. Needs a fresh fixture (the session runs in the root).
- `revert-scroll.js`: reverting the last answer of a long chat keeps the page at its end, on a desktop and a phone-sized view (needs a fresh fixture: it adds long exchanges to the chat before the page opens). The history is built off the page and put in place in one step, then the page scrolls once to its end.
- `bashfiles.js`: "copy the picture" makes the fake model ask for a bash call (`cp live.png copy.png`): the copy is shown inline with its download, live and after a reload, and the result on the page has no list of files.
- `multi.js`: "draw two cubes" makes the fake model answer with two calls at index 0: two tool lines, two pictures, each result's time, the header's totals (the times are live, not kept with the chat). It needs the fake services and a server started with `AICLI_CHECK_LLM` and `AICLI_CHECK_IMAGE` (the first lines of the file say how).

Run them from `tools/ui-check/` with the server's settings:

```
AICLI_CHECK_STATE=$(mktemp -d) sh tools/ui-check/start-server.sh
# the script prints the state dir; then, from tools/ui-check:
AICLI_URL=http://127.0.0.1:8770 AICLI_STATE=<state dir> NODE_PATH=$(npm root -g) node revert.js
AICLI_URL=http://127.0.0.1:8770 AICLI_STATE=<state dir> NODE_PATH=$(npm root -g) node menu.js
```

A new state dir for each run: `menu.js` renames and deletes the fixture. What they do not
cover: a turn with a real model (`fake-services.py` stands in for one, so `files.js` checks the page's part only), the login through nginx, the looks in a desktop browser, and the microphone. To check the model's own tools (rename, list,
switch, create a session), the server needs a model: `AI_LOCAL_SERVER` or a cloud key. The
tool calls and the sub-agents then show in the page's chat as usual.

Writing a new check: `common.js` opens the page (`open()`) and gives the page's errors, the
state dir's sessions and projects, and the chat file. Use `waitForFunction` for what the page
draws, not fixed waits, and look at the element with `document.elementFromPoint` when a click
does nothing: that tells whether something covers the button.

## Known gaps

See PLAN.md. The proxies and the SearXNG search have only been tested with a
mocked HTTP layer, never against a real proxy or instance. The bigger ones: `Net::Curl` is the preferred curl module, but the
tests have only run with `WWW::Curl` since the event loop exists, the image included; no tool
confirmation or allow-list (by choice);
the privilege drop itself (as root) is not covered by a test, only the plan.
