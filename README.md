# AI-CLI: a coding agent for the command line, in Perl

AI-CLI is an interactive chat with an LLM that can act. The model can run tools
(bash, perl, read/write files, grep), gets the results back and continues, in a
loop, until it has an answer. Think of pi, hermes or opencode, but as a small
Perl program: plain `fork()`, `exec()`, `eval`, `select()` and libcurl, no
framework.

## Features

- **Agent loop**: the answer of the model is scanned for tool calls, they are
  executed, the results go back to the model, until it is done
- **Thinking is shown**: while the model reasons (`reasoning_content`/`reasoning`
  deltas and `<think>` blocks) a spinner runs in the status line, and a line says
  how long it took. `AI_THINKING_VIEW=text` streams it in its own color instead.
  Thinking is not kept in the history
- **Tools the Perl way**: file tools (read, write, numbered lines, exact
  replace, ed-style edit, delete, move, mkdir, list, find) are plain Perl in the
  process; bash and grep are `exec()`ed in a forked child, perl code is
  `eval`ed in a forked child (optionally in a `Safe` compartment)
- **Pictures for vision models** (the server lists the model with the capability `vision`, or `AI_VISION=1`): the `image` tool sends a PNG,
  JPEG, GIF or WebP file from the workspace with the next message, so the model
  can read the text in it or describe it
- **Sub-agents**: the model can hand tasks to sub-agents that work side by
  side. No threads, no process per agent: every request is a curl handle and
  every tool a child in one `select()` loop
- **Status footer**: a two-line footer at the bottom of the terminal, the
  conversation scrolls above it. Line one is what the model, a tool or each
  sub-agent is doing and for how long; line two is the model, the tokens,
  the context used, the speed (pp and tg tokens/s) and the cache. Drawn from
  that same loop, with VT100 escapes and no extra module. On a terminal too
  small for it, or with `AI_STATUS=line`, it is one line at the cursor
- **Markdown**: the answer is drawn with headings, bold, code, lists and tables
  on a terminal (`AI_MARKDOWN`)
- **Readable tool runs**: one line per tool call and the first lines of its
  result instead of the raw call; file changes are shown as a diff, and
  `/undo` takes them back
- **Project instructions**: `AGENTS.md` of the working directory becomes part
  of the system prompt
- **Cache friendly**: the start of a conversation is never rewritten, so the
  prefix cache of the API or a local server keeps hitting
- **Resilient**: retry with exponential backoff, rate limits wait what the API
  says, ctrl-C stops the running turn and nothing else
- **Token usage**: counted per session, shown after each answer, with an
  optional budget
- **Context management**: old tool output is cut and older messages are
  summarized, in pieces that fit a request, when the conversation is over the
  threshold of the context window (right after an answer, or before a request).
  The first request is kept word for word in the summary, every compaction is
  recorded, `/context` shows the state
- **Reasoning control**: `AI_THINKING` or `/thinking` turns the reasoning of the
  model on, off or into a token budget, per session
- **Voice**: `/voice` records from the microphone: Enter starts; while you talk
  the footer shows the words recognized so far (local recognizer, FastFlowLM on
  the NPU, `AI_ASR_URL`); Enter sends now, a pause after speech sends it
  (`AI_VOICE_PAUSE`, 1.2 s), Esc cancels the sentence. A recording with no sound
  is not sent. While it is made, the footer shows a level meter and the words
  recognized so far (a pass every three seconds of new audio; words that two
  passes agree on are final). The text sent at the stop is the whole recording.
  The recording is a child process (`pw-record`) and goes to a private directory
  in the temp dir (`/tmp/aicli-<uid>`), deleted after recognition; the upload is built in Perl
- **Native tool calls**: the tools go in the request and the server returns the
  calls (`tool_calls`); a text protocol is the fallback (`AI_TOOL_CALLS=text`)
  for models and servers without it
- **Providers**: Cerebras, OpenRouter, NVIDIA, OpenAI, Anthropic, Lemonade,
  FastFlowLM, and any OpenAI compatible local server (llama.cpp, ...). Other
  APIs through an OpenAI compatible gateway such as LiteLLM or OpenRouter
- **Sessions**: every conversation is a directory with its history, system
  prompt, model and usage; `-c` continues the last one of the current
  directory
- **Scriptable**: `-p "..."` runs one request and exits with a status code
- **Slash commands** with TAB completion, multi-line input, readline history
- **Confined**: file tools only work in the workspace; `bash`, `perl` and
  `grep` are held there by the kernel (Landlock), no root needed
- **Docker wrapper** to keep what the model does inside a container

## Quick start

### Docker (recommended)

The tools run whatever the model asks for, without confirmation. The container
is the sandbox.

```bash
docker build -t local/ai/aicli:latest .
# or, with docker buildx bake (docker-bake.hcl, same image name)
docker buildx bake
cd ~/my-project
/path/to/aicli.sh
```

`aicli.sh --base` runs the small image (`local/ai/aicli-base`: ai.pl and the basic
unix tools) instead of the dev image (`local/ai/aicli`, the default: python3, the C/C++
toolchain, ImageMagick, ffmpeg, PDL, lame). `DOCKER_IMAGE` overrides both.

`aicli.sh` shares no hardware. The boards, GPUs, radios and power meters are not in these
images: each kind of device is its own image, in its own repository, that runs `ai.pl` as a
remote agent (see PLAN.md, "a thin ai.pl image"). The model server runs on the host, and the
container reaches it over `--network=host`.

`aicli.sh` mounts the current directory, and is set up for a local llama.cpp
server on an AMD ROCm machine: adjust it (`AI_LOCAL_SERVER`, `AI_MODEL`) to your
setup. Every `AI_*` variable of your shell is
passed into the container. The local defaults (`AI_LOCAL_SERVER`,
`AI_PROVIDER=lemonade`, the local `AI_MODEL`) apply only when your shell sets
no `AI_API_KEY`, `AI_LOCAL_SERVER` or other `AI_PROVIDER`; for a cloud provider
set `AI_API_KEY` and `AI_PROVIDER`, and `AI_MODEL` for its model. In there `ai.pl` starts as root and at once becomes
you (`UID`/`GID` of the host, `AI_GROUPS` for device groups), so files in the
mounted project keep their owner; it never runs as root.

### Direct

```bash
# Debian/Ubuntu
apt-get install perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl
# for the web interface over https (--tls-cert): libnet-ssleay-perl

export AI_API_KEY="csk-..."            # provider detected from the key
export AI_PROMPT_TEMPLATE=coder        # the prompt with the tools
perl ai.pl
```

or with a local server:

```bash
AI_LOCAL_SERVER=http://localhost:8080 AI_PROMPT_TEMPLATE=coder perl ai.pl
```

Pick up where you left off in this directory:

```bash
perl ai.pl -c
```

Not interactive, one request and an exit code (0 answered, 1 error, 130
interrupted); `-p -` reads the request from stdin, `-c` continues the session
of the directory one request at a time:

```bash
perl ai.pl -p "which files here are bigger than 1MB?"
git diff | perl ai.pl -p - > review.txt
perl ai.pl -c -p "now fix the first one" && make test
```

Without `-p`, piped stdin is read as one request per line.

### Perl modules

| Module | Needed for | Debian/Ubuntu |
|--------|------------|---------------|
| `JSON::XS` | everything | `libjson-xs-perl` |
| `Net::Curl` or `WWW::Curl` | HTTP, streaming | `libwww-curl-perl` or `libnet-curl-perl` |
| `Term::ReadLine::Gnu` | interactive input | `libterm-readline-gnu-perl` |
| `Data::UUID` | optional: session ids | `libdata-uuid-perl` |

The Docker image also has `PDL` (arrays, FFT: `pdl`) and `Audio::Wav` (WAV
files: `libaudio-wav-perl`) for the `perl` tool, so the model can use them, and
the `lame` MP3 encoder (`lame`). aicli itself does not load them.

Everything else is core Perl (`Safe`, `POSIX`, `File::Temp`, `Time::HiRes`,
`Getopt::Long`, `Pod::Usage`; `Test::More` for the tests). To build the XS
modules from CPAN you need a compiler plus the libcurl and readline headers
(`curl-dev readline-dev` / `libcurl4-openssl-dev libreadline-dev`).

## Usage

Answers, tool output and command output are on stdout; errors, retries' error
lines and the debug log (`--debug`) are on stderr.

Type to chat. A line that starts with `/` is a command and is never sent to
the model:

| Command | |
|---------|---|
| `/help` | list the commands |
| `/exit`, `/quit` | leave (also ctrl-D) |
| `/clear` | forget the conversation, keep the system prompt |
| `/session [list]` | list the sessions: when each was last used and what it started with |
| `/session prune [days] [yes]` | remove the sessions not used for that long (default 30 days), after showing them and asking |
| `/session create\|delete\|switch <name>` | manage sessions, `/session <name>` switches too; deleting the current one continues in a new, empty session |
| `/session rename [<old>] <new>` | rename a session, with one name the current one |
| `/session reset` | start the current session over: conversation, archive, token counters, undo journal and agent transcripts go, its name, prompt, model and input history stay |
| `/model [provider/id]` | list the models of every provider of this chat as `provider/id`, or switch the session to one (a bare id works when only one provider has it) |
| `/prompt [name]` | list the prompt templates, or switch the system prompt |
| `/undo [list]` | take back the last file change a tool made, `list` shows them |
| `/usage [reset]` | token usage and context size of this session, and its tool calls with the time they took |
| `/retry` | ask the last request again, its answer and tool runs are dropped |
| `/rewind [n]` | take the last exchange (or n) out of the conversation |
| `/compact` | summarize the older messages now, to free context |
| `/voice [seconds]` | record from the microphone, recognize it (`AI_ASR_URL`) and send it; push to talk: Enter starts, Enter or a pause sends, Esc cancels |
| `/context [summary]` | how full the context is, its compactions and the thinking setting; `summary` shows the last summary of the older messages |
| `/thinking [on\|off\|<tokens>\|default]` | the reasoning of the model for this session |
| `/thinking-view [spin\|text\|off]` | how the thinking is shown, for this run: a spinner, streamed, or hidden |
| `/system <text>` | add a system message |
| `/files [regex]` | add matching files of the current directory to the conversation (`.aiignore` is respected) |
| `/tools` | list the tools |
| `/workspace [dir\|none]` | show or set the directory the file tools are confined to |
| `/chdir <dir>`, `/cd`, `/pwd`, `/ls` | working directory |
| `/history` | input history |
| `/debug`, `/nodebug` | debug logging |

Keys: TAB completes commands, shift-enter starts multi-line input (an empty
line sends it). **Ctrl-C while the model answers or a tool runs stops that
turn** and returns to the prompt; ctrl-C at the prompt leaves. With input from
a pipe it is the same: ctrl-C (SIGINT) stops the turn and the next line is
read, a second one, or one while nothing runs, ends the program (exit 130).

### The web interface

`ai.pl --ui [port]` runs the chat headless and serves it to a browser: the
output streams over server-sent events, the input comes in by POST. The default
port is 8080, on `127.0.0.1`. The address is printed with a token; open that
address once and the browser keeps the token in a cookie (`aicli_token`,
HttpOnly, SameSite=Lax: Strict is not sent after a link from another app, such as the QR code scan on a phone). The API of the page is `GET /events` (the stream),
`POST /message`, `POST /voice` (a WAV recording), `POST /abort`, `GET /state`,
`POST /session` (`{"name": ...}` to switch, `{"new": true}` for a new session;
the session select in the menu lists the sessions of every directory, newest
first). It continues the last session used in this directory, as `-c` does,
unless `--new` or `AI_SESSION` says otherwise. The page shows the conversation
of the session when it connects and after a switch (what was said, not the tool
calls; the last 200 messages). Every session runs in a process of its own
(a worker of the interface): sessions run at the same time, a busy one shows
as busy in the list, and an idle one is stopped after `AI_WORKER_IDLE` seconds
(900 by default). A session's project is the directory it was made in: the
directories of the accounts under the root (where the interface was started) are the
projects. The page's project select switches to the newest session of a project,
or makes one; a new session's prompt carries that project's `AGENTS.md`, and its
worker may only write in the project (and the temp directory and its own
session).
A bearer token (`Authorization: Bearer`) works too; `AI_UI_TOKEN` sets the
token.

| option | |
|--------|---|
| `--ui [port]` | serve the interface (default 8080); continues the last session of this directory |
| `--new` | with `--ui`: a new session instead of the last one of this directory |
| `--root DIR` (`aicli.sh`) | mount `DIR` as a whole: the projects are the directories of its accounts (`DIR/<account>/<project>`), and the container starts in the current directory (which must be inside `DIR`). One container, one web interface for all projects |
| `--ui-bind <address>` | the address to listen on: `127.0.0.1` (default), `::1`, `0.0.0.0` (any IPv4), `::` (any IPv6). The printed phone address is the one of this machine that a phone can reach, with a QR code on the terminal (`qrencode`) |
| `--tls-cert <file> --tls-key <file>` | serve https, with a PEM certificate and key (needs `Net::SSLeay`, Debian `libnet-ssleay-perl`). A self-signed one: `openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj /CN=localhost -keyout key.pem -out cert.pem` |

The page shows the conversation with the tool calls and their results, errors
and retries, the thinking of the model (a spinner with the count of characters
while it thinks; a click shows the text), and the stats line. Enter sends,
Shift+Enter starts a new line, Stop ends the turn. Two looks (`simple`, like
the terminal, and `cards`) and a theme (system, light, dark, amber, matrix, solarized, paper, neon) are chosen in the
header and remembered in the browser. The mic records in the browser and sends
the recording to `AI_ASR_URL`; without a recognizer, or when it is not
reachable, the mic is off and the page says why. The model, the look and the theme are in the ☰ menu (phones and desktops alike); the mic, stop and send are small icons under the text. The model is chosen in the menu: one
dropdown with the models of every provider (`provider/id`). Ctrl-C on the terminal ends
the chat as it does without the interface.

A file a tool writes (`write`, `convert`, `generate_image`, `speech`, `generate_audio`), and a picture or a sound that a `bash` call made or changed, is listed under its call in the chat: a picture (PNG, JPEG, GIF, WebP) is shown inline, a sound (WAV, MP3, OGG) plays, and each has a download. Only files of the session's project are sent (`GET /file`); a link or `..` out of the project is refused. A tool line can be opened (a click) to show the whole call, its arguments in full.

The "+" by the message box uploads a file of any kind into the session's project, in its `uploads/` folder (`POST /upload`, 50 MB at most, a name taken gets the next free one, the name is only its last part). The file shows as a chip with a link to it; the next message starts with `Uploaded: uploads/<name>` and the model reads the file from the project (the `read` tool for text, `image` for a picture with `AI_VISION`). A file the model cannot read as text, such as a PDF, needs a tool for it.

Not yet: slash commands in the page.


## How it works

```
 you ──► chat file ──► POST /v1/chat/completions (stream)
              ▲                 │
              │        thinking │ answer      spinner, or streamed; the answer streams in
              │                 ▼
              │        tool calls in the answer?
              │            │ yes                    │ no
              │            ▼                        ▼
              └── results ◄── tools, sub-agents     done, back to the prompt
```

Every step is appended to the `chat` file of the session, and every request is
built from that file, so a session can be continued at any time.

### Tools

The model calls a tool through the API: the request carries the tools and the
server returns the calls (`AI_TOOL_CALLS=native`, the default). The result goes
back as a tool message with the id of the call. With `AI_TOOL_CALLS=text` the
syntax is explained to the model in the system prompt of the `coder` template
(the `default` template is a plain chat without tools), and the model writes a
block like this in its answer:

```
///WRITE_edf5+EO_d068+EO_ecde
hello.pl
EO_d068
print "Hello, World!\n";
EO_ecde
WRITE_edf5
```

In text mode the result goes back as the next message, `[WRITE_edf5 RESULT_d170 ... RESULT_d170]`
or `[WRITE_edf5 ERROR_9a78 ... ERROR_9a78]`. In native mode it is a tool message.

| Tool | What it does | How it runs |
|------|--------------|-------------|
| `read`, `lines` | a file, plain or with line numbers (a range) | Perl, in the chat process |
| `write` | write or overwrite a file | Perl |
| `replace` | swap one exact, unique piece of text | Perl |
| `edit` | apply an ed script: `a`, `i`, `c`, `d`, `s///` with line, `$` and `/regex/` addresses | Perl |
| `delete`, `move`, `mkdir`, `list` | file management | Perl |
| `find` | entries under a directory whose name matches a regex (opendir/readdir, links not followed) | Perl |
| `grep` | search files | `exec grep -rn` in a forked child, no shell |
| `bash` | a shell script | temp file, `exec bash` in a forked child |
| `perl` | Perl code, with the modules of the image (PDL, Audio::Wav) | `eval` in a forked child, or `Safe->reval` with `AI_PERL_SAFE` (no modules there) |
| `fetch` | a web page as text, links as `[text](url)` | async HTTP in the event loop |
| `search` | web search through your SearXNG instance | async HTTP, only offered with `AI_SEARXNG_URL` |
| `theme` | switch the colours of the web interface to one of its names (a look only, for this page); only in the web interface | an event to the page, main chat only |
| `list_sessions` | the sessions of this session's project, newest first, with their age and first message; this one is marked; an optional name filter; only in the web interface | reads the session directories, main chat only |
| `create_session` | make an empty session in this session's project (the given name, or a generated one); it is listed at once; `rename_session` names it, `switch_session` goes to it; only in the web interface. No delete: the model cannot remove a session | an event to the master, which makes it; main chat only |
| `switch_session` | switch the page to another session of this project (one `list_sessions` shows); done when this answer is over, and only if the page is still on this session; only in the web interface | an event to the master, which switches when the turn is over; main chat only |
| `rename_session` | rename this session in the web interface's list; it is done when the answer is over (the page shows it until then, a refresh too); refused for a name in use or a bad one | an event to the master, which renames it when the turn is over; main chat only |
| `models` | the models of every provider of the chat, as `provider/id` (every page of each list), with the context size when known and the current one marked; an optional filter on the ids | HTTP in the chat's flow, main chat only |
| `model` | switch the chat to one of them, `provider/id`, for the next message (this answer finishes with the current model; a bare or partial id works when it is unique, e.g. `qwen3.6`); the provider and the model are kept in the session | the session's files, main chat only |
| `devel` | what a language has installed, with versions: `perl` (modules under @INC), `python` (packages), `lua` (rocks), `c` (pkg-config), `bash` (tools on the PATH); an optional name filter | reads only, in a forked child |
| `image` | a picture (PNG, JPEG, GIF or WebP) in the workspace, sent with the next message; a bigger one is made smaller with ImageMagick; only offered with `AI_VISION=1` | Perl, and ImageMagick in a forked child |
| `convert` | a picture converted with ImageMagick: a smaller size, a crop, a turn, another format by the output name (png, jpg, gif, webp, bmp, tif), the quality, and the colours: `gray` (black and white) or `sepia` (nothing else changes the colours). Metadata is removed. A file of the output name already there is kept: the picture goes to the first free name (`name-2.jpg`, ...). Only offered where ImageMagick is installed | ImageMagick in a forked child, no shell, with `ai/imagemagick/policy.xml` |
| `qr_encode` | a text written as a QR code: a PNG in the workspace (the page shows it). The pixels per square (1 to 32, 8 by default) and the error correction (`L`, `M` (default), `Q`, `H`). Arguments after `--`, so a text starting with `-` is a text. A file of the name already there is kept (`qr-2.png`, ...). Only offered where `qrencode` is installed (the dev image has it) | qrencode in a forked child, no shell; written to a temp file, renamed when whole |
| `qr_decode` | the text of the QR codes in a picture of the workspace (PNG, JPEG, GIF, BMP, TIFF), one per line. No code is an error, said as such. Only offered where `zbarimg` is installed (the `zbar-tools` package in the dev image) | zbarimg in a forked child, no shell; exit 4 (none found) is the answer "no code" |
| `ocr` | the text in a picture of the workspace (PNG, JPEG, GIF, BMP, TIFF) read by Tesseract: printed text such as scans, screenshots and documents. The language is `eng` (the default), `nld`, `deu`, `fra`, or several joined with `+`; the page mode (0 to 13, 3 by default) tells how the page is laid out. Handwriting and poor photos are read badly: a vision model (the `image` tool) does better. Only offered where tesseract is installed (the dev image has it, with the English, Dutch, German and French data) | tesseract in a forked child, no shell; it writes its text to a temp file, which is read and removed |
| `generate_image` | a picture from a text prompt with the image service (`AI_IMAGE_URL`): the PNG is written to the output name in the workspace (default `image_<seed>.png`; a file of that name already there is kept, and the picture goes to the first free name, `name-2.png`, ...); the size, the steps (1 to 50) and the seed. The same prompt, size, steps and seed give the same picture. Only offered where `AI_IMAGE_URL` is set | the image service over HTTP, no process |
| `generate_audio` | a sound from a text prompt with the audio service (`AI_AUDIO_URL`, AudioLDM 2): the WAV is written to the output name (default `audio_<seed>.wav`; a file of that name already there is kept, and the sound goes to the first free name, `name-2.wav`, ...), a clip of 1 to 10 seconds, the steps (1 to 200) and the seed. Only offered where `AI_AUDIO_URL` is set | the audio service over HTTP, no process |
| `speech` | speech from a text with the speech service (`AI_SPEECH_URL`) in a voice the server has: the WAV is written to the output name (default `speech_<voice>.wav`; a file of that name already there is kept, and the sound goes to the first free name, `name-2.wav`, ...), with the language and the seed. Only offered where `AI_SPEECH_URL` is set | the speech service over HTTP, no process |
| `agent` | give a task to a sub-agent | a second conversation in the event loop |

File tools never start a process. `replace` and `edit` write through a temp
file and rename, and write nothing when they fail; `edit` works like `ed`, so
line numbers are those after the previous command (edit bottom-up).

A forked tool process has its own session/process group, stdin from
`/dev/null`, stdout+stderr captured through a pipe, and a minimal environment:
no `AI_*` variable, so no API key. It is stopped at `AI_TOOL_TIMEOUT` or on
ctrl-C, with its whole process group.

The parser is forgiving, because models are sloppy: sentinels may be the ones
of the header or the ones of the tool definition, the `[length]` suffix and the
closing tag are optional. Tool calls inside thinking are ignored. A call that
cannot be parsed is answered with an error, so the model can correct itself.

There is no confirmation before a tool runs. Run it in the container.

### Workspace

The file tools (`read`, `lines`, `write`, `replace`, `edit`, `delete`, `move`,
`mkdir`, `list`, `find`, and the path of `grep`) only work inside the workspace: the
directory `ai.pl` was started in, or `AI_WORKSPACE`. A path is judged by where
it really ends up: symbolic links and `..` are resolved first, so
`../other/file`, `/etc/passwd` and a link in the workspace that points out of
it are all refused, and the model is told so. `delete` and `move` act on a
link itself, never on what it points to.

`AI_WORKSPACE_ALLOW` names more directories, `/workspace <dir>` moves the
workspace while you chat, `AI_WORKSPACE=none` switches the limit off.

### Sandbox for bash, perl and grep

What the model runs through `bash`, `perl` and `grep` is a forked process, and
that process is confined by the kernel with
[Landlock](https://docs.kernel.org/userspace-api/landlock.html) before the
tool starts. It, and everything it starts, can

- **write** only in the workspace (and `AI_WORKSPACE_ALLOW`), in the temp
  directory (`TMPDIR`, else `/tmp`), to `/dev/null` and a few such devices,
  and where `AI_SANDBOX_WRITE` says,
- **read and execute** everything. With `AI_SANDBOX_READ=system` only the
  system directories (`/usr`, `/bin`, `/lib*`, `/etc`, `/opt`, `/proc`, `/sys`,
  `/dev`, `/run`), the workspace and the temp directory; more paths can be
  listed in that variable.

```bash
# flashing a board, poking at the kernel, a package cache
AI_SANDBOX_WRITE="/dev/ttyACM0 /sys /proc $HOME/.cache" perl ai.pl
```

Landlock is not a container: nothing is mounted, no root is needed, the
process sees the same filesystem and gets "Permission denied" where it may not
go. It needs Linux 5.13 or newer and works inside docker too. `/workspace`
shows whether it is active and what is allowed. Where the kernel does not have
it the tools run unconfined; `AI_SANDBOX=on` refuses to run them instead,
`AI_SANDBOX=off` switches it off. The chat process itself is never confined.

Good to know: a confined process cannot gain privileges, so `sudo` and other
setuid programs do not work in tools. Programs that write outside of the
workspace (caches and config in `$HOME`: pip, npm, cpan) need their directory
in `AI_SANDBOX_WRITE`. Network access is not restricted. On kernels before
5.19 a file cannot be renamed into another directory.

### What you see, and taking it back

The tool call blocks the model writes are not shown. Each call is one line,
followed by the first lines of its result (`AI_TOOL_LINES`), errors in red:

```
● bash prove -I. t (+1 lines)
  t/10_sessions.t ................ ok
  ... +12 more lines
● edit ai.pm
  ai.pm: +2 -1
  @@ line 118 @@
      $SESSIONS_DIR = "$BASE_DIR/sessions";
  -   -d $SESSIONS_DIR or mkdir $SESSIONS_DIR;
  +   -d $SESSIONS_DIR
  +       or mkdir $SESSIONS_DIR
```

`write`, `replace` and `edit` show what they changed as a diff
(`AI_SHOW_DIFF`, `AI_DIFF_LINES`). The model always gets the complete result.
`AI_TOOL_DISPLAY=full` shows the calls and results as they are.

A result that is not text (a binary file: NUL bytes, or bytes that are not UTF-8)
is not shown as its bytes; the line says its size instead (`not text, 17 bytes:
not shown here`). The model still gets all of it. A change to a binary file
shows as `a binary file`, not as a diff.

Every change the file tools make (also `delete`, `move`, `mkdir`, also by
sub-agents) is noted in the session, with a copy of the old content. `/undo`
takes back the last one, again and again; `/undo list` shows them. What `bash`
or `perl` do to files is not covered.

### System prompt and caching

The system prompt of a session is: the prompt template, the tools (`coder`),
the project instructions and the date, in that order, the most stable parts
first. Project instructions are the `AGENTS.md` of the working directory
(`AI_PROJECT_FILE` for other names, empty for none). The date is only the
month by default (`AI_PROMPT_DATE`: `none`, `year`, `month`, `day` or a
`strftime` format).

It is built once, when the session starts, and stored. Later requests are that
same text plus what was said since, byte for byte (JSON is written with sorted
keys): nothing at the start of the conversation changes, so prompt/prefix
caches keep working. A changed `AGENTS.md` or a new month only show up in a
new session, or after `/clear` or `/prompt`. The one thing that rewrites
history is context compaction, and only when the window is nearly full.

### Web and proxies

`fetch` gets a URL (http/https only) and turns HTML into text. `search` asks a
SearXNG instance and returns titles, URLs and snippets; set
`AI_SEARXNG_URL=http://your-searxng:8888` and allow the JSON format in its
settings (`search: formats: [html, json]`). Without that variable the model is
not told about `search`. Both are plain requests in the event loop: several
can be in flight at once (sub-agents), they have a timeout and a size limit,
and ctrl-C ends them.

There are separate proxies, each takes anything curl understands
(`http://host:3128`, `socks5h://host:1080`, `http://user:pass@host:3128`):

| For | Variable | Falls back to |
|-----|----------|---------------|
| the LLM API | `AI_PROXY` | `HTTPS_PROXY`, `HTTP_PROXY` |
| `fetch` | `AI_WEB_PROXY` | `HTTPS_PROXY`, `HTTP_PROXY` |
| `search` (SearXNG) | `AI_SEARXNG_PROXY` | none: it is asked directly |

`none` as a value means no proxy even when the environment has one, e.g.
`AI_PROXY=none` for a local model server next to `AI_WEB_PROXY=http://...`.
`NO_PROXY` is honoured. The API key is never sent with web requests.

### Sessions that are not kept

A start without `AI_SESSION` or `-c` makes up a session (`session-<id>`). When
nothing was said in it, it is removed again at the end, so trying a command or
`-p` with a typo leaves nothing behind. A session you named is always kept.
What a crash leaves (empty made-up sessions older than a day) is removed at
the next start. Sessions with a conversation are only removed when you say so:
`/session delete`, `/session prune`, or `AI_SESSION_KEEP_DAYS=90` to drop
everything unused for 90 days at each start, without asking.

### Sub-agents

With the `agent` tool the model delegates a self-contained task. A sub-agent
has the system prompt of the session and all tools except `agent`, but nothing
of the conversation; its final answer is the tool result. Several `agent`
calls in one answer run at the same time (`AI_MAX_AGENTS`, default 4):

```
///AGENT_f2a8+EO_9d31
List the public subs of utils.pm with one line on what each does.
EO_9d31
AGENT_f2a8
```

With `AI_PROVIDER=flm` there is no `agent` tool: the NPU is kept for voice.

A sub-agent is not a process and not a thread. It is a small state machine:
its request is a curl handle, its bash/perl/grep tools are forked children,
and all of them sit in the same `select()` loop as everything else. Its
thinking is not printed. The status line shows what each agent is doing and how
many tokens it used, and a line per start and tool call is printed
(`AI_AGENT_VIEW`). Transcripts are kept in
`sessions/<name>/agents/`, rewritten after every message, so a stuck agent can be read. A sub-agent stops after `AI_AGENT_MAX_TURNS` tool turns. Sub-agents retry API errors like the main loop,
count for the token usage of the session, and stop on ctrl-C. They watch
their own context window: the output of their older tool calls is cut, then
their oldest steps are dropped; the task always stays.

### Errors, retries, rate limits

A request that fails with a rate limit (429), an overload or server error
(408, 425, 500, 502, 503, 504, 529) or without any HTTP status (network) is
tried again, `AI_RETRIES` times, waiting 2s, 4s, 8s, ... with jitter
(`AI_RETRY_DELAY`). For a rate limit the wait is what the API asks for
(`Retry-After`, `x-ratelimit-reset-*`), up to `AI_RETRY_MAX_WAIT`. Other
errors, and errors after part of an answer arrived, are shown and the chat goes
on. Ctrl-C ends a wait.

In the web interface the retries and the request lines are not on the page:
they are in the server's log (`docker compose logs agent`). Every request to the
model has a `REQUEST` line with its stamp: the UTC time, the user (the account
of the session's project, `local` in the terminal chat) and a checksum (the first
16 hex digits of the SHA-256 of the request body). The same body has the same
checksum, so the time tells the tries apart. When a request fails for good, the
page's error ends with the stamp of its last try, to quote when asking about it.

### Token usage and context

After each answer a line shows the tokens of the request, the total of the
session, how full the context window is and the speed:

```
[tokens: 5210 in + 187 out, session 48213 | context 16% of 32768 | 4.1s, 52.3 tok/s]
```

The numbers come from the API (`stream_options.include_usage`); when it does
not report them they are estimated and marked with `~`. `AI_TOKEN_BUDGET`
stops a session that used that many tokens (`/usage reset` to go on).

When the conversation is over 80% of the context window (`AI_CONTEXT_THRESHOLD`)
after an answer, it is compacted right then, between the turns (`AI_AUTO_COMPACT=0`
to wait until the next request needs it). The same happens before a request that
would be over it. The compaction:

1. the output of old tool calls is cut to its first and last lines,
2. if that is not enough, the older messages are replaced by a summary the
   model writes (or just dropped with `AI_CONTEXT_SUMMARY=0`).

The recent messages stay as they are, everything removed is appended to
`chat.archive` in the session directory. The window size is `AI_CONTEXT_TOKENS`,
else what the API reports (`context_length` in the model list, `/props` of a
llama.cpp server). When it is unknown, compaction starts when the API refuses a
request as too long. `/compact` does it on demand.

### Adding a tool

Add an entry to `$tools::TOOLS` in `ai.pm` (its `syntax` defines the tag and
the sentinels) and a sub named after the lowercased tag
(`sub mytool_1a2b {my ($t_args) = @_; ...}`) that returns the result or dies.
A tool that needs a child process returns `_run(sub {exec ...})`: that waits
for the main agent and becomes a job in the event loop for a sub-agent.

## The broker

`docker compose up -d --build` runs the broker (`docker-compose.yaml`). The broker is the
control plane of the remote agents: it keeps the agents of the users (their enrollment, tags
and token hashes), gives a job to an agent of the job's account that has the job's tags, and
sends the answer back. It runs no program and holds no project.

Every `ai.pl` runs its tools in its own container, the local one of the web interface and a
remote agent alike. A remote agent's project is on its machine, under its `--work` directory,
and the job runs there. The files never pass through the broker.

The broker's Unix socket (`/run/aicli-broker/broker.sock`, in the volume `aicli-broker`) takes
one JSON line per request:

- `exec`: a job for an agent: `project` (`account/project`), `tags` (the agent must have all
  of them), `argv` (a program and its arguments, no shell) and `timeout` (seconds, at most 120).
  The answer comes when the agent has run it: `exit` and `output` (base64).
- `enroll_token`, `agents` and `agent_revoke`: a user's enrollment token, the user's agents, a
  revocation. The web interface's agents page uses them through `aicli.sh --broker`.

Anything else is refused. The broker checks the shape of a request; the agent checks the program
against its own `--programs`.

Host setup: set `AI_PROJECTS` (the root of the local ai.pl's projects), `BROKER_UID` and
`BROKER_GID` (the owner of the broker's socket).

## Remote agents

A remote agent is a machine with devices (a Raspberry Pi with a Zigbee stick, an
Arduino bench, a GPU box) that runs `ai.pl --agent` and calls the broker for jobs. The
broker never starts an agent: it has no devices, so the agent is started on its machine,
with the devices it needs, and it connects back.

```
ai.pl --agent --broker https://PUBLIC_DOMAIN/ --name strix --programs arduino-cli,python3 \
      --work ~/aicli-work --token TOKEN        # or AI_AGENT_TOKEN in the environment
```

- `--name`: the name the broker knows the agent by (`agents` in `broker.json`).
- `--programs`: the only programs this agent runs, whatever the broker sends.
- `--work`: the directory of the projects on the agent (`--work/<project>`). The agent runs
  the job's program there, with no shell. Nothing is checked out for it yet: the directory
  must hold the project.
- `--token`: the agent's own credential (`AI_AGENT_TOKEN`), sent with each request as
  `Authorization: Bearer`. The broker keeps only its SHA-256 (`token_sha256`).
- `--pin sha256//BASE64` (optional): the broker's public key must be this one, on top of the
  normal check of the certificate. A renewal with a new key then needs a new pin.

The broker side is in `broker.json` (`token_sha256` is `sha256sum` of the token):

```json
"agents": {"strix": {"tags": ["arduino", "gfx1151"], "token_sha256": "..."}}
```

A job names the tags it needs: an agent of the job's account with all of them runs it. The
agent's own `--programs` decide what it runs. The broker listens for agents on `AI_BROKER_AGENT_LISTEN`
(host:port) when there are agents. Its requests come through nginx over HTTPS, with the public
certificate; the token is the agent's whole credential.

**Enrollment.** On the web page, "new enrollment token" shows a token once. On the agent's machine:

```
ai.pl --enroll TOKEN --broker https://PUBLIC_DOMAIN/ --name strix --tags arduino,gfx1151 --programs arduino-cli,python3 \
  --work /home/agent/work
```

Without `--name` the agent is named by a random UUID; without `--tags` its tags are the names of its
`--programs` (short lower-case words only).

With `--programs` the agent runs at once after the enrollment (one command). Without it, the run ends
after the enrollment. The broker keeps the agent's name, its tags and the hash of its own token (not the token); the
agent keeps its token in `$AI_DIR/agent.json` (mode 0600). After that, `ai.pl --agent --programs ...`
needs no token on its command line. An enrollment token is used once: it enrolls one agent, and a new token (the page) is needed for the
next. Revoking an agent does not make its token usable again. Enrolling again on the same machine (the same volume or the same `$AI_DIR`) reuses the
agent in `agent.json` and makes no second one; a different name or broker is refused. The page lists the agents of the user, with a revoke
for each: a revoked agent's token stops working.

The broker's state file (`AI_BROKER_STATE`, in its own volume) keeps the enrollments over a restart.
nginx sends `/agents/` to the broker without a login: the agent's token is its login, and the
connection is TLS with the public certificate (`--pin` is optional, on top of that).

Not built yet: the checks of a job against its project's owner, and the checkout of the project on
the agent.

## The public address (nginx, TLS)

`docker-compose.yaml` runs `broker`, `agent`, `searxng`, `proxy`, and `nginx`. nginx has the
public IPv6 address of `PUBLIC_DOMAIN` on the network `dmz-aicli`, and serves TLS on port
443 with the certificate of certbot. Steps, once:

1. A routed IPv6 prefix for the containers, and its gateway (see `deploy.sh`). The router or
   the host must route that prefix to this host.
2. An `AAAA` record for `PUBLIC_DOMAIN` with the IPv6 address this host uses in that prefix,
   set by hand at the DNS provider.
3. Port 80 and 443 on that address must reach the host (ufw rules for the prefix).
4. `PUBLIC_DOMAIN=… CERTBOT_EMAIL=… AI_PROJECTS=… ./deploy.sh`. It writes `.env` and
   `.agent.env`, looks up the `AAAA` record, creates `dmz-aicli`, gets the
   certificate (certbot runs on the domain's address and answers the HTTP challenge on port
   80, with nginx stopped meanwhile), and starts the stack.
5. The page is at `https://PUBLIC_DOMAIN/?token=...`; the token is in
   `docker compose logs agent` (or `AI_UI_TOKEN` in `.agent.env`).

The certificate lasts about 90 days. `DO_CERTBOT=1 ./deploy.sh` renews it when it is due
(run it from cron every few weeks, or by hand).

Only nginx is on the public network `dmz-aicli`. The agent, the broker, searxng, and the proxy
are on `aicli-net` and have no public address. The agent listens in its container only (nothing is
published); nginx sends the event stream without buffering, and accepts recordings up to 25 MB.
Searxng for other tools is at `https://PUBLIC_DOMAIN/searxng/` with `SEARXNG_API_TOKEN` as
`Authorization: Bearer`.

The FastFlowLM API (the NPU: the model list, chat and speech recognition, `flm` in docker-compose.yaml)
is at `https://PUBLIC_DOMAIN/api/flm/`, e.g. `/api/flm/v1/models`, `/api/flm/v1/chat/completions`,
`/api/flm/v1/audio/transcriptions`. It takes a token of the user's, made on the page ("new API token",
a week) or with `POST /auth/api/token?aud=flm` after a login, sent as `Authorization: Bearer`.
The token is not the login cookie and no login cookie works there.

A model server on the host (for example `AI_LOCAL_SERVER`) is reached by its address on
the host, and the host's firewall must allow the agent's network to reach its port (ufw).

## Configuration

Environment variables, or `AI_...=value` lines in `~/.aicli/config`:

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_API_KEY` | API key | required, except for local servers |
| `AI_API_KEY_<NAME>` | a key of another provider, e.g. `AI_API_KEY_OPENAI`, `AI_API_KEY_OPENROUTER`: its models join the one list (`provider/id`) and the chat can switch to them | none |
| `AI_PROVIDER` | `cerebras`, `openrouter`, `nvidia`, `openai`, `anthropic`, `lemonade` | detected from the key prefix |
| `AI_LOCAL_SERVER` | URL of an OpenAI compatible server, instead of a provider | |
| `AI_MODEL` | model for sessions without their own; when none is set, the first model of the provider's list is used (not saved) | the first of the list |
| `AI_SESSION` | session name | new `session-<uuid>` |
| `AI_SESSION_KEEP_DAYS` | at start, remove sessions not used for that many days, without asking; also the default of `/session prune` | never |
| `AI_PROMPT_TEMPLATE` | `default` (chat), `coder` (with tools) or `perl` (a Perl developer with the tools), a file in `ai/` | `default` |
| `AI_PROMPT_TEMPLATE_FILE` | a system prompt file of your own | |
| `AI_CONFIG` | the file of `AI_...=value` lines read at start | `~/.aicli/config` |
| `AI_CLEAR` | start with an empty conversation and a fresh system prompt | 0 |
| `AI_TOKENS` | max tokens per answer | 100000 (8192 with `AI_PROVIDER=flm`) |
| `AI_TEMPERATURE`, `AI_TOP_P`, `AI_TOP_K`, `AI_MIN_P` | sampling | 0.6, 0.95, 20, 0.0 |
| `AI_MAX_TURNS` | max requests per input (tool loop), 0 = no limit | 50 |
| `AI_LOOP_LIMIT` | stop an input after this many turns in a row whose results are the same errors (a stuck model), 0 = never | 4 |
| `AI_AGENT_MAX_TURNS` | max tool turns of one sub-agent, 0 = no limit | 20 |
| `AI_MAX_AGENTS` | sub-agents working at the same time (no sub-agents with `AI_PROVIDER=flm`) | 4 |
| `AI_AGENT_VIEW` | 0: no line per sub-agent start and tool call | 1 |
| `AI_AGENT_MODEL` | model for sub-agents | the session model |
| `AI_RETRIES` | retries of a failed request | 4 |
| `AI_RETRY_DELAY` | first backoff delay in seconds, doubles every retry | 2 |
| `AI_RETRY_MAX_WAIT` | longest wait a rate limit may ask for, in seconds | 120 |
| `AI_CONTEXT_TOKENS` | context window of the model, 0 = no context management | from the API |
| `AI_CONTEXT_THRESHOLD` | compact when the conversation is over this part of the window | 0.8 |
| `AI_CONTEXT_SUMMARY` | 0: drop old messages instead of summarizing them | 1 |
| `AI_SUMMARY_CHUNKS` | most pieces the older part is summarized in, one request each | 8 |
| `AI_RECORDER` | recorder program for `/voice` (pw-record, PipeWire) | pw-record |
| `AI_ASR_URL` | OpenAI compatible transcription endpoint for `/voice` (FastFlowLM: `http://localhost:52625/v1/audio/transcriptions`) | none: no voice |
| `AI_ASR_MODEL` | model name sent to the transcription endpoint | whisper-large-v3-turbo |
| `AI_ASR_PROMPT` | words for the recognizer to spell as given, e.g. `Code me, Perl` (sent with every recognition) | none |
| `AI_VOICE_SECONDS` | length of a timed `/voice` recording, in seconds (no terminal, or `/voice <seconds>`) | 5 |
| `AI_VOICE_PAUSE` | silence after speech that ends a push-to-talk recording, in seconds | 1.2 |
| `AI_VOICE_MAX` | longest push-to-talk recording, in seconds | 60 |
| `AI_AUTO_COMPACT` | compact right after an answer when the conversation is over the threshold; 0: only before a request | 1 |
| `AI_THINKING` | the reasoning of the model: `on`, `off` or a token budget; `/thinking` sets it per session | a local server: a budget of 2048 tokens; others: their default |
| `AI_TOKEN_BUDGET` | max tokens a session may use | no limit |
| `AI_USAGE` | 0: don't ask the API for token usage | 1 |
| `AI_SHOW_USAGE` | 1 shows the usage line after each answer, 0 hides it | shown, except while the footer is on |
| `AI_STATUS` | `bar`: footer at the bottom; `line`: one line at the cursor; 0 switches the status off | `bar` |
| `AI_GLYPHS` | `unicode` (spinner, `│`, `…`, `↑↓`, `Σ`) or `ascii` (`\|`, `...`, `in:`, `out:`, `sum:`); default from the locale: UTF-8 gets unicode | from the locale |
| `AI_TOOL_DISPLAY` | `brief`: a line per tool call and the start of its result; `full`: everything | `brief` |
| `AI_TOOL_LINES` | lines of a tool result shown with `brief` | 8 |
| `AI_SHOW_DIFF` | 0: no diff after a file change | 1 |
| `AI_DIFF_LINES` | max lines of a diff | 40 |
| `AI_UNDO_MAX_SIZE` | files bigger than this (bytes) are changed without an undo copy | 8000000 |
| `AI_WORKSPACE` | directory the file tools are confined to, `none` for no limit | start directory |
| `AI_WORKSPACE_ALLOW` | more directories the file tools may use | |
| `AI_SANDBOX` | kernel sandbox (Landlock) for bash/perl/grep: `auto` (when the kernel has it), `on` (or no tool runs), `off` | `auto` |
| `AI_SANDBOX_WRITE` | more paths those tools may write to, e.g. `/dev/ttyACM0 /sys /proc` | |
| `AI_SANDBOX_READ` | limit what they read: `system`, or more paths besides the system | read everything |
| `AI_PROJECT_FILE` | project instruction files to add to the system prompt, empty for none | `AGENTS.md` |
| `AI_PROJECT_FILE_MAX` | max bytes taken from such a file | 32768 |
| `AI_PROMPT_DATE` | date in the system prompt: `none`, `year`, `month`, `day` or a `strftime` format | `month` |
| `AI_THINKING_VIEW` | how the thinking is shown: `spin` (a spinner in the status line, and how long it took), `text` (streamed in its color), `off`; `/thinking-view` changes it for the run | spin |
| `AI_SHOW_THINKING` | 0 hides the thinking (the same as `AI_THINKING_VIEW=off`) | 1 |
| `AI_TOOL_TIMEOUT` | seconds for a bash/perl/grep tool, 0 = no limit | 120 |
| `AI_TOOL_MAX_OUTPUT` | max bytes of a tool result, the middle is cut out | 65536 |
| `AI_TOOL_ENV` | extra environment variables to pass to tools | |
| `AI_PERL_SAFE` | perl tool in a `Safe` compartment: `1`, or extra opcodes like `:filesys_read` | off |
| `AI_MARKDOWN` | draw the markdown of the answer (on a terminal only); 0 keeps it as written | on a terminal |
| `AI_TOOL_CALLS` | `native`: tools sent with the request, calls as the server parses them; `text`: the tool syntax in the prompt | native |
| `AI_VISION` | offer the `image` tool, so the model gets pictures: `1` always, `0` never; unset, when the server's model list has a model with the capability `vision`. Only with a model that takes pictures | unset |
| `AI_IMAGE` | offer `generate_image` (with `AI_IMAGE_URL`): `1` always, `0` never; unset, when the server's model list has a model with the capability `image` | unset |
| `AI_AUDIO` | offer `generate_audio` (with `AI_AUDIO_URL`): `1` always, `0` never; unset, when the server's model list has a model with the capability `audio` | unset |
| `AI_IMAGE_MAX` | largest picture the `image` tool sends, in bytes; a bigger one is made smaller (0 for no limit) | 5242880 |
| `AI_CONVERT_MAX` | largest input of the `convert` tool, in bytes (0 for no limit) | 52428800 |
| `AI_IMAGE_URL` | base address of the image service for `generate_image`, as the agent reaches it (e.g. `http://host:8000`); empty: no tool | none |
| `AI_IMAGE_TIMEOUT` | seconds to wait for a picture (the service makes one at a time) | 3600 |
| `AI_IMAGE_PROXY` | proxy for the image service; `none` or empty: none | none |
| `AI_SPEECH_URL` | base address of the speech service for `speech`, as the agent reaches it (e.g. `http://host:8000`); empty: no tool | none |
| `AI_SPEECH_TIMEOUT` | seconds to wait for speech | 3600 |
| `AI_SPEECH_PROXY` | proxy for the speech service; `none` or empty: none | none |
| `AI_AUDIO_URL` | base address of the audio service for `generate_audio`, as the agent reaches it (e.g. `http://host:8000`); empty: no tool | none |
| `AI_AUDIO_TIMEOUT` | seconds to wait for a clip (about 50 seconds for 5 seconds of sound) | 3600 |
| `AI_AUDIO_PROXY` | proxy for the audio service; `none` or empty: none | none |
| `AI_RAW` | use `/v1/completions` with a prompt built here (qwen only) | off |
| `AI_DIR` | base directory | `~/.aicli` |
| `AI_PS1`, `AI_PS2` | input prompts | |
| `AI_PROXY` | proxy for the LLM API, `none` for no proxy | `HTTPS_PROXY`, `HTTP_PROXY` |
| `AI_WEB_PROXY` | proxy for `fetch`, `none` for no proxy | `HTTPS_PROXY`, `HTTP_PROXY` |
| `NO_PROXY` | hosts that are reached without proxy | |
| `AI_SEARXNG_URL` | SearXNG instance for the `search` tool | no search |
| `AI_SEARXNG_PROXY` | proxy to reach the SearXNG instance | direct |
| `AI_SEARCH_RESULTS` | results per search | 8 |
| `AI_WEB_TIMEOUT` | seconds for a web request | 30 |
| `AI_WEB_MAX_SIZE` | max bytes of a fetched page, the rest is cut | 2000000 |
| `AI_WEB_USER_AGENT`, `AI_WEB_LANGUAGE` | User-Agent and Accept-Language of `fetch` | |
| `DEBUG`, `AI_LOG` | debug logging, and a file for it | 0, stderr |
| `AI_UID`, `AI_GID`, `AI_GROUPS` | started as root (docker): the user, group and supplementary groups to become | `UID`/`GID`, else 1000; the groups of the process |

`perl ai.pl --help` and `ai.pl -man` have the full reference.

## Project structure

- `ai.pl` - entry point: options, drop privileges, POD
- `ai.pm` - chat loop, streaming, retry, usage, context, commands, sessions, sub-agents, providers, prompt, tools, speech
- `utils.pm` - the event loop (curl multi, child pipes, keyboard watch, timers in one `select()`), `fork_run()`, logging
- `tui.pm` - the screen: the status footer (scroll region) or the status line
- `md.pm` - markdown of the answer, drawn line by line
- `ai/` - system prompt templates (`default`, `coder`)
- `aicli.sh`, `Dockerfile`, `docker-bake.hcl` - docker wrapper, image, and the bake file for it
- `t/` - tests
- `PLAN.md` - open work and ideas
- `AGENTS.md` - notes and rules for (AI) contributors

## Tests

```bash
prove -I. t
```

Run them with `prove -I. t`. The LLM is scripted in the tests. `t/45_http_e2e.t` runs the real HTTP code
against a small fake server (and `ai.pl` itself as a process), it is skipped
without a curl module.

`t/97_live.t` talks to a real model, when one is given. It is skipped otherwise:

```bash
AI_LIVE_SERVER=http://localhost:8001/v1 AI_LIVE_MODEL=qwen3:4b prove -I. t/97_live.t
AI_API_KEY=... AI_LIVE_MODEL=... prove -I. t/97_live.t      # a cloud provider, by its key
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
