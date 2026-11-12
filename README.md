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
- **Status line**: what the model, a tool or each sub-agent is doing, and for
  how long, drawn from that same loop
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
  summarized before the conversation outgrows the context window
- **Text based tool protocol**: no function-calling API needed, so it works
  with any model, also on raw completion endpoints
- **Providers**: Cerebras, OpenRouter, NVIDIA, Lemonade, and any OpenAI
  compatible local server (llama.cpp, ...)
- **Sessions**: every conversation is a directory with its history, system
  prompt, model and usage
- **Slash commands** with TAB completion, multi-line input, readline history
- **Docker wrapper** to keep what the model does inside a container

## Quick start

### Docker (recommended)

The tools run whatever the model asks for, without confirmation. The container
is the sandbox.

```bash
docker build -t local/ai/aicli:latest .
cd ~/my-project
/path/to/aicli.sh
```

`aicli.sh` mounts the current directory, and is set up for a local llama.cpp
server on an AMD ROCm machine: adjust it (`AI_LOCAL_SERVER`, `AI_MODEL`, the
`--device` options) to your setup.

### Direct

```bash
# Alpine
apk add perl perl-json-xs perl-net-curl perl-term-readline-gnu bash grep
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

Not interactive, one request per line of stdin:

```bash
echo "which files here are bigger than 1MB?" | AI_SESSION=demo perl ai.pl
```

### Perl modules

| Module | Needed for | Alpine | Debian/Ubuntu |
|--------|------------|--------|---------------|
| `JSON::XS` | everything | `perl-json-xs` | `libjson-xs-perl` |
| `Net::Curl` or `WWW::Curl` | HTTP, streaming | `perl-net-curl` | `libwww-curl-perl` |
| `Term::ReadLine::Gnu` | interactive input | `perl-term-readline-gnu` | `libterm-readline-gnu-perl` |
| `Data::UUID` | optional: session ids | `perl-data-uuid` | `libdata-uuid-perl` |

Everything else is core Perl (`Safe`, `POSIX`, `File::Temp`, `Time::HiRes`,
`Getopt::Long`, `Pod::Usage`; `Test::More` for the tests). To build the XS
modules from CPAN you need a compiler plus the libcurl and readline headers
(`curl-dev readline-dev` / `libcurl4-openssl-dev libreadline-dev`).

## Usage

Type to chat. A line that starts with `/` is a command and is never sent to
the model:

| Command | |
|---------|---|
| `/help` | list the commands |
| `/exit`, `/quit` | leave (also ctrl-D) |
| `/clear` | forget the conversation, keep the system prompt |
| `/session [list]` | list the sessions |
| `/session create\|delete\|switch <name>`, `/session rename <old> <new>` | manage sessions, `/session <name>` switches too |
| `/model [name]` | list the models of the API, or set the model of this session |
| `/prompt [name]` | list the prompt templates, or switch the system prompt |
| `/undo [list]` | take back the last file change a tool made, `list` shows them |
| `/usage [reset]` | token usage and context size of this session |
| `/compact` | summarize the older messages now, to free context |
| `/system <text>` | add a system message |
| `/files [regex]` | add matching files of the current directory to the conversation (`.aiignore` is respected) |
| `/tools` | list the tools |
| `/chdir <dir>`, `/cd`, `/pwd`, `/ls` | working directory |
| `/history` | input history |
| `/debug`, `/nodebug` | debug logging |

Keys: TAB completes commands, shift-enter starts multi-line input (an empty
line sends it). **Ctrl-C while the model answers or a tool runs stops that
turn** and returns to the prompt; ctrl-C at the prompt leaves.

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

The model calls a tool by writing a block in its answer. The syntax is
explained to the model in the system prompt of the `coder` template (the
`default` template is a plain chat without tools):

```
///WRITE_edf5+EO_d068+EO_ecde
hello.pl
EO_d068
print "Hello, World!\n";
EO_ecde
WRITE_edf5
```

The result goes back as the next message, `[WRITE_edf5 RESULT_d170 ... RESULT_d170]`
or `[WRITE_edf5 ERROR_9a78 ... ERROR_9a78]`.

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
thinking and tool calls are not printed, the status line shows what each agent
is doing. Transcripts are kept in `sessions/<name>/agents/`. Sub-agents retry
API errors like the main loop, count for the token usage of the session, and
stop on ctrl-C. They have no context management of their own: give them tasks
that fit.

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

Before a request that would use more than 80% of the context window
(`AI_CONTEXT_THRESHOLD`), the conversation is compacted:

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
| `AI_PROVIDER` | `cerebras`, `openrouter`, `nvidia`, `lemonade` | detected from the key prefix |
| `AI_LOCAL_SERVER` | URL of an OpenAI compatible server, instead of a provider | |
| `AI_MODEL` | model for sessions without their own | provider-dependent |
| `AI_SESSION` | session name | new `session-<uuid>` |
| `AI_PROMPT_TEMPLATE` | `default` (chat) or `coder` (with tools), a file in `ai/` | `default` |
| `AI_PROMPT_TEMPLATE_FILE` | a system prompt file of your own | |
| `AI_CLEAR` | start with an empty conversation and a fresh system prompt | 0 |
| `AI_TOKENS` | max tokens per answer | 100000 |
| `AI_TEMPERATURE`, `AI_TOP_P`, `AI_TOP_K`, `AI_MIN_P` | sampling | 0.6, 0.95, 20, 0.0 |
| `AI_MAX_TURNS` | max requests per input (tool loop), 0 = no limit | 50 |
| `AI_MAX_AGENTS` | sub-agents working at the same time | 4 |
| `AI_AGENT_MODEL` | model for sub-agents | the session model |
| `AI_RETRIES` | retries of a failed request | 4 |
| `AI_RETRY_DELAY` | first backoff delay in seconds, doubles every retry | 2 |
| `AI_RETRY_MAX_WAIT` | longest wait a rate limit may ask for, in seconds | 120 |
| `AI_CONTEXT_TOKENS` | context window of the model, 0 = no context management | from the API |
| `AI_CONTEXT_THRESHOLD` | compact when the conversation is over this part of the window | 0.8 |
| `AI_CONTEXT_SUMMARY` | 0: drop old messages instead of summarizing them | 1 |
| `AI_TOKEN_BUDGET` | max tokens a session may use | no limit |
| `AI_USAGE` | 0: don't ask the API for token usage | 1 |
| `AI_SHOW_USAGE` | 0 hides the usage line | 1 |
| `AI_STATUS` | 0 switches the status line off | 1 |
| `AI_TOOL_DISPLAY` | `brief`: a line per tool call and the start of its result; `full`: everything | `brief` |
| `AI_TOOL_LINES` | lines of a tool result shown with `brief` | 8 |
| `AI_SHOW_DIFF` | 0: no diff after a file change | 1 |
| `AI_DIFF_LINES` | max lines of a diff | 40 |
| `AI_UNDO_MAX_SIZE` | files bigger than this (bytes) are changed without an undo copy | 8000000 |
| `AI_PROJECT_FILE` | project instruction files to add to the system prompt, empty for none | `AGENTS.md` |
| `AI_PROJECT_FILE_MAX` | max bytes taken from such a file | 32768 |
| `AI_PROMPT_DATE` | date in the system prompt: `none`, `year`, `month`, `day` or a `strftime` format | `month` |
| `AI_SHOW_THINKING` | 0 hides the thinking | 1 |
| `AI_TOOL_TIMEOUT` | seconds for a bash/perl/grep tool, 0 = no limit | 120 |
| `AI_TOOL_MAX_OUTPUT` | max bytes of a tool result, the middle is cut out | 65536 |
| `AI_TOOL_ENV` | extra environment variables to pass to tools | |
| `AI_PERL_SAFE` | perl tool in a `Safe` compartment: `1`, or extra opcodes like `:filesys_read` | off |
| `AI_RAW` | use `/v1/completions` with a prompt built here (qwen only) | off |
| `AI_DIR` | base directory | `~/.aicli` |
| `AI_PS1`, `AI_PS2` | input prompts | |
| `AI_PROXY` / `HTTPS_PROXY` / `HTTP_PROXY`, `NO_PROXY` | proxy | |
| `DEBUG`, `AI_LOG` | debug logging, and where to | 0, stdout |

`perl ai.pl --help` and `perldoc ai.pl` have the full reference.

## Project structure

- `ai.pl` - entry point: options, drop privileges, POD
- `ai.pm` - chat loop, streaming, retry, usage, context, commands, sessions, sub-agents, providers, prompt, tools
- `utils.pm` - the event loop (curl multi, child pipes, timers in one `select()`), `fork_run()`, logging
- `tui.pm` - the status line
- `ai/` - system prompt templates (`default`, `coder`)
- `aicli.sh`, `Dockerfile` - docker wrapper and image
- `t/` - tests
- `TODO.md` - roadmap
- `AGENTS.md` - notes and rules for (AI) contributors

## Tests

```bash
prove -I. t
```

The LLM is scripted in the tests. `t/45_http_e2e.t` runs the real HTTP code
against a small fake server (and `ai.pl` itself as a process), it is skipped
without a curl module.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
