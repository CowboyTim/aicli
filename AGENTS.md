# AI-CLI: notes for agents and contributors

## What this is

AI-CLI is a coding agent for the command line, in Perl: an interactive chat
with an LLM that runs tools (file tools, bash, perl, grep, sub-agents) and
feeds the results back to the model in a loop. Same idea as pi, hermes or opencode, but
small and Perl-ish: `fork()`, `exec()`, `eval`/`Safe`, `select()`, libcurl.

## Rules

These are requirements, not suggestions.

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
  hole. `bash` and `perl` are not confined, the container is.
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
  process (`utils::tool_env()`, `@utils::CHILD_INIT`).
- **The chat must survive**: a failing request, tool or command prints an
  error and returns to the prompt. No `die` may escape to the top.
- **Few dependencies**: core Perl plus `JSON::XS`, `Net::Curl` (or
  `WWW::Curl`), `Term::ReadLine::Gnu`. `Data::UUID` is optional. Ask before
  adding a CPAN module.
- **Keep the docs in sync**: README.md, the POD in `ai.pl` and this file
  describe what the code does, not what is planned (that is TODO.md).
- **Tests**: `prove -I. t` must pass. Add tests with every change, the LLM is
  scripted (`t/lib/TestAI.pm`) or faked (`t/lib/FakeLLM.pm`).

## Layout

- **ai.pl** – entry point. Moves `%ENV` to `%::ORIG_ENV` (so nothing leaks to
  children), parses options (`-c` sets `AI_CONTINUE`, `-p` is one request via
  `ai::one_shot()`), drops root privileges, then
  `ai::chat_setup(); ai::setup_commands(); ai::chat_loop();`. Holds the POD.
- **ai.pm** – several packages in one file:
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
- **tui.pm** – `tui`: the status line (named items, spinner, elapsed time),
  drawn from `$loop::on_tick`, wiped by `clear()`.
- **ai/** – prompt templates: `default` (chat), `coder` (adds the tools).
- **aicli.sh**, **Dockerfile** – docker wrapper and Alpine image.
- **t/** – tests, **TODO.md** – roadmap.

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
7. `handle_llm_response()`: `parse_tool_calls()`, then `execute_tool()` for
   each, `agent` calls are started together and waited for at the end; the
   results are appended as user messages,
8. back to 2 while there were tool calls (max `AI_MAX_TURNS`).

The request is always rebuilt from the chat file: nothing about the
conversation lives only in memory.

`$::ABORT` is set by ctrl-C while a turn runs (`$ai::BUSY`). `loop::step()`
sees it and stops everything that is registered: transfers end with error
"interrupted", children are killed (process group), timers fire with a true
argument. `$::LOOP = 0` ends the chat.

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
`AI_MAX_AGENTS` are running), `agent::wait(@agents)` runs the loop until they
are done, then `{result}` / `{error}` are set. A sub-agent has its own message
list (system prompt from `ai::subagent_prompt()`: session prompt + tools
without `agent`), retries like the main loop, counts into the usage of the
session, writes its transcript to `agents/` in the session directory, and
shows up in the status line. It has no context management, and cannot start
agents.

## System prompt

`system_prompt()` = prompt file of the session + `prompt::<template>::prompt()`
(tools) + `prompt_context()`: `project_instructions()` (`AGENTS.md` of the
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
by `estimate_tokens()`). `context_limit()`: `AI_CONTEXT_TOKENS`, else
`%MODEL_CONTEXT` (model list) or `$SERVER_CONTEXT` (llama.cpp `/props`), else
0 = unknown. `compact_context()`: prune old tool results, then summarize the
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
| grep | `_run` → `exec grep -rn -e <pattern> -- <path>` |
| bash | temp file, `_run` → `exec bash <file>` |
| perl | `_run` → `eval` in package `aicli::tool`, or `Safe->reval` (`AI_PERL_SAFE`) |
| fetch, search | `tools::_http` → `loop::http` (web proxy, timeout, size limit, redirects) |
| agent | `agent::launch` + `agent::wait` |

There is no confirmation step, by choice. The file tools are confined to the
workspace (`$ai::WORKSPACE`, set by `ai::set_workspace()` at start from
`AI_WORKSPACE` or the current directory; `@ai::WORKSPACE_ALLOW`).
`tools::_path()` resolves the part of a path that exists with `realpath`
(symlinks, `..`), requires plain names for the rest, and dies with "outside of
the workspace" unless the result is under an allowed root. The docker
container is still the sandbox for `bash` and `perl`.

## Commands

One table, `@ai::COMMANDS` (`run`, `help`, `usage`, `complete`), drives
execution (`handle_command()`), `/help` and TAB completion
(`setup_commands()` builds `$ai::cmds` from it). Add a command there and
nowhere else. `handle_command()` returns undef for chat text, 0 for a handled
command, 1 to leave; a command line never reaches the LLM. `/retry` and
`/rewind` use `rewind_chat()`: it only cuts the end of the conversation (to
`chat.archive`), the start stays as it is.

## Sessions

`$AI_DIR/sessions/<name>/` with `chat` (conversation), `prompt` + `template`
(system prompt and the template it came from), `model`, `history` (readline).
Names match `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`, checked by
`valid_session_name()` everywhere a name comes in. `use_session()` notes the
working directory in `cwd`; `last_session()` finds the most recent session of
a directory for `-c`. `chat_completion()` returns true when the turn ended
with an answer, `one_shot()` makes the exit code of `-p` out of that.

## Providers

`%ai::PROVIDERS` (URL, key prefix) and a `provider::<name>` package with
`req()` (chat request) and `raw()` (raw completion request). All are OpenAI
compatible streaming APIs: cerebras, openrouter, nvidia, lemonade, and `local`
for `AI_LOCAL_SERVER`. OpenAI, Groq, Anthropic and Bedrock are not
implemented.

## Tests

| file | covers |
|------|--------|
| `t/10_sessions.t` | `ai.pl` as a process: sessions, startup checks, `--help` |
| `t/20_response_tool_handling.t` | tool call parsing on real model output |
| `t/30_prompt.t` | generated tools prompt, examples parse |
| `t/40_chat_loop.t` | agent loop, streaming, thinking, errors, abort (scripted LLM) |
| `t/45_http_e2e.t` | real curl against a fake server: loop, rate limit headers, usage, parallel sub-agents, `ai.pl` end to end |
| `t/50_commands.t` | slash commands, input readers, completion |
| `t/60_tools.t` | `fork_run`, environment, bash/perl/Safe/read/write/grep |
| `t/65_file_tools.t` | lines, replace, the ed engine, edit, delete, move, mkdir, list |
| `t/66_workspace.t` | workspace confinement: `..`, absolute paths, symlinks, every file tool, `/workspace` |
| `t/70_retry_usage_context.t` | retry/backoff, rate limits, usage, budget, context management |
| `t/80_agents.t` | sub-agents (parallel, limits, errors, abort), the status line |
| `t/95_cli.t` | `-p` (one request, exit codes, stdin) and `-c` (continue per directory), as a process |
| `t/85_web.t` | proxy selection, HTML to text, fetch, search (mocked HTTP layer), a real fetch, `/retry`, `/rewind` |
| `t/90_prompt_display_undo.t` | project file and date in the prompt, byte-stable request prefix, brief display, diffs, `/undo` |

`TestAI::mock_http` scripts the main agent (`utils::http`),
`TestAI::mock_agent_http` answers the sub-agents (`loop::http`).

## Known gaps

See TODO.md. The proxies and the SearXNG search have only been tested with a
mocked HTTP layer, never against a real proxy or instance. The bigger ones: `Net::Curl` is the preferred curl module but the
tests have only run with `WWW::Curl` since the event loop exists; sub-agents
have no context management; no tool confirmation or allow-list (by choice);
the privilege drop in `ai.pl` uses a fixed uid/gid (1000).
