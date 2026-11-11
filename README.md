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
- **Tools the Perl way**: bash and grep are `exec()`ed in a forked child, perl
  code is `eval`ed in a forked child (optionally in a `Safe` compartment)
- **Text based tool protocol**: no function-calling API needed, so it works
  with any model, also on raw completion endpoints
- **Providers**: Cerebras, OpenRouter, NVIDIA, Lemonade, and any OpenAI
  compatible local server (llama.cpp, ...)
- **Sessions**: every conversation is a directory with its history, system
  prompt and model
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
apt-get install perl libjson-xs-perl libnet-curl-perl libterm-readline-gnu-perl

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
| `Net::Curl` (or `WWW::Curl`) | HTTP, streaming | `perl-net-curl` | `libnet-curl-perl` |
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
              └── results ◄── fork: exec/eval      done, back to the prompt
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

| Tool | How it runs |
|------|-------------|
| `bash` | script in a temp file, `exec bash` in a forked child |
| `perl` | `eval` in a forked child, or `Safe->reval` with `AI_PERL_SAFE` |
| `grep` | `exec grep -rn` in a forked child, no shell |
| `read`, `write` | in the chat process |

A forked tool process has its own session/process group, stdin from
`/dev/null`, stdout+stderr captured through a pipe, and a minimal environment:
no `AI_*` variable, so no API key. The parent waits in a `select()` loop and
kills the process group on `AI_TOOL_TIMEOUT` or ctrl-C.

The parser is forgiving, because models are sloppy: sentinels may be the ones
of the header or the ones of the tool definition, the `[length]` suffix and the
closing tag are optional. Tool calls inside thinking are ignored. A call that
cannot be parsed is answered with an error, so the model can correct itself.

Adding a tool: add an entry to `$tools::TOOLS` in `ai.pm` (its `syntax` defines
the tag and the sentinels) and a sub named after the lowercased tag
(`sub mytool_1a2b {my ($t_args) = @_; ...}`) that returns the result or dies.

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
- `ai.pm` - chat loop, streaming, commands, sessions, providers, prompt, tools
- `utils.pm` - HTTP (curl multi + `select()`), `fork_run()`, logging
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
