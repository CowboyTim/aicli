# AI-CLI: a coding agent for the command line, in Perl

AI-CLI is an interactive chat with an LLM that can act. The model can run tools
(bash, perl, read/write files, grep), gets the results back and continues, in a
loop, until it has an answer. Think of pi, hermes or opencode, but as a small
Perl program: plain `fork()`, `exec()`, `eval`, `select()` and libcurl, no
framework.

## Features

- **Agent loop**: the answer of the model is scanned for tool calls, they are
  executed, the results go back to the model, until it is done
- **Thinking is shown**: reasoning (`reasoning_content`/`reasoning` deltas and
  `<think>` blocks) streams in its own color, and is not kept in the history
- **Tools the Perl way**: file tools (read, write, numbered lines, exact
  replace, ed-style edit, delete, move, mkdir, list) are plain Perl in the
  process; bash and grep are `exec()`ed in a forked child, perl code is
  `eval`ed in a forked child (optionally in a `Safe` compartment)
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
- **Voice**: `/voice` records from the microphone (push to talk: Enter starts,
  Enter stops), recognizes the speech with a local recognizer (FastFlowLM on the
  NPU, `AI_ASR_URL`) and sends the text as the request. A recording with no sound
  is not sent. The recording is a child process (`pw-record`), the upload is built in Perl
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

`aicli.sh` mounts the current directory, and is set up for a local llama.cpp
server on an AMD ROCm machine: adjust it (`AI_LOCAL_SERVER`, `AI_MODEL`, the
`--device` options) to your setup. Every `AI_*` variable of your shell is
passed into the container. In there `ai.pl` starts as root and at once becomes
you (`UID`/`GID` of the host, `AI_GROUPS` for device groups), so files in the
mounted project keep their owner; it never runs as root.

### Direct

```bash
# Debian/Ubuntu
apt-get install perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl

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
| `/model [name]` | list the models of the API, or set the model of this session |
| `/prompt [name]` | list the prompt templates, or switch the system prompt |
| `/undo [list]` | take back the last file change a tool made, `list` shows them |
| `/usage [reset]` | token usage and context size of this session |
| `/retry` | ask the last request again, its answer and tool runs are dropped |
| `/rewind [n]` | take the last exchange (or n) out of the conversation |
| `/compact` | summarize the older messages now, to free context |
| `/voice [seconds]` | record from the microphone, recognize it (`AI_ASR_URL`) and send it as the request |
| `/context [summary]` | how full the context is, its compactions and the thinking setting; `summary` shows the last summary of the older messages |
| `/thinking [on\|off\|<tokens>\|default]` | the reasoning of the model for this session |
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

## How it works

```
 you ──► chat file ──► POST /v1/chat/completions (stream)
              ▲                 │
              │        thinking │ answer      shown as they stream in
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
| `grep` | search files | `exec grep -rn` in a forked child, no shell |
| `bash` | a shell script | temp file, `exec bash` in a forked child |
| `perl` | Perl code | `eval` in a forked child, or `Safe->reval` with `AI_PERL_SAFE` |
| `fetch` | a web page as text, links as `[text](url)` | async HTTP in the event loop |
| `search` | web search through your SearXNG instance | async HTTP, only offered with `AI_SEARXNG_URL` |
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
`mkdir`, `list`, and the path of `grep`) only work inside the workspace: the
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

## Configuration

Environment variables, or `AI_...=value` lines in `~/.aicli/config`:

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_API_KEY` | API key | required, except for local servers |
| `AI_PROVIDER` | `cerebras`, `openrouter`, `nvidia`, `openai`, `anthropic`, `lemonade` | detected from the key prefix |
| `AI_LOCAL_SERVER` | URL of an OpenAI compatible server, instead of a provider | |
| `AI_MODEL` | model for sessions without their own | provider-dependent |
| `AI_SESSION` | session name | new `session-<uuid>` |
| `AI_SESSION_KEEP_DAYS` | at start, remove sessions not used for that many days, without asking; also the default of `/session prune` | never |
| `AI_PROMPT_TEMPLATE` | `default` (chat) or `coder` (with tools), a file in `ai/` | `default` |
| `AI_PROMPT_TEMPLATE_FILE` | a system prompt file of your own | |
| `AI_CONFIG` | the file of `AI_...=value` lines read at start | `~/.aicli/config` |
| `AI_CLEAR` | start with an empty conversation and a fresh system prompt | 0 |
| `AI_TOKENS` | max tokens per answer | 100000 (8192 with `AI_PROVIDER=flm`) |
| `AI_TEMPERATURE`, `AI_TOP_P`, `AI_TOP_K`, `AI_MIN_P` | sampling | 0.6, 0.95, 20, 0.0 |
| `AI_MAX_TURNS` | max requests per input (tool loop), 0 = no limit | 50 |
| `AI_AGENT_MAX_TURNS` | max tool turns of one sub-agent, 0 = no limit | 20 |
| `AI_MAX_AGENTS` | sub-agents working at the same time (1 with `AI_PROVIDER=flm`, the NPU takes one request at a time) | 4 |
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
| `AI_VOICE_SECONDS` | length of a timed `/voice` recording, in seconds (no terminal, or `/voice <seconds>`) | 5 |
| `AI_VOICE_MAX` | longest push-to-talk recording, in seconds | 60 |
| `AI_AUTO_COMPACT` | compact right after an answer when the conversation is over the threshold; 0: only before a request | 1 |
| `AI_THINKING` | the reasoning of the model: `on`, `off` or a token budget; `/thinking` sets it per session | server decides |
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
| `AI_SHOW_THINKING` | 0 hides the thinking | 1 |
| `AI_TOOL_TIMEOUT` | seconds for a bash/perl/grep tool, 0 = no limit | 120 |
| `AI_TOOL_MAX_OUTPUT` | max bytes of a tool result, the middle is cut out | 65536 |
| `AI_TOOL_ENV` | extra environment variables to pass to tools | |
| `AI_PERL_SAFE` | perl tool in a `Safe` compartment: `1`, or extra opcodes like `:filesys_read` | off |
| `AI_MARKDOWN` | draw the markdown of the answer (on a terminal only); 0 keeps it as written | on a terminal |
| `AI_TOOL_CALLS` | `native`: tools sent with the request, calls as the server parses them; `text`: the tool syntax in the prompt | native |
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
- `TODO.md` - roadmap
- `AGENTS.md` - notes and rules for (AI) contributors

## Tests

```bash
prove -I. t
```

CI runs them on every push, with the Debian packages and inside the Debian
slim image. The LLM is scripted in the tests. `t/45_http_e2e.t` runs the real HTTP code
against a small fake server (and `ai.pl` itself as a process), it is skipped
without a curl module.

`t/97_live.t` talks to a real model, when one is given. It is skipped otherwise:

```bash
AI_LIVE_SERVER=http://localhost:8001/v1 AI_LIVE_MODEL=qwen3:4b prove -I. t/97_live.t
AI_API_KEY=... AI_LIVE_MODEL=... prove -I. t/97_live.t      # a cloud provider, by its key
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
