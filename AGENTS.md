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
  process (`utils::tool_env()`, `@utils::CHILD_INIT`).
- **The chat must survive**: a failing request, tool or command prints an
  error and returns to the prompt. No `die` may escape to the top.
- **Few dependencies**: core Perl plus `JSON::XS`, `Net::Curl` (or
  `WWW::Curl`), `Term::ReadLine::Gnu`. `Data::UUID` is optional. Ask before
  adding a CPAN module.
- **Keep the docs in sync**: README.md, the POD in `ai.pl` and this file
  describe what the code does, not what is planned (that is TODO.md). Notes
  for whoever works on this next go here, in "Status", not in a file of their
  own (there was a MEMORY.md, it is part of this file now).
- **stdout is the conversation**: messages, errors and the debug log go to
  stderr through `log::error` / `log::info` (`AI_LOG` for a file), never
  `print`. `ai.pl -p` in a pipe must give the answer and nothing else.
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
  Real models have been used with llama.cpp and FastFlowLM on the NPU. The cloud APIs
(NVIDIA, Cerebras, OpenRouter, Anthropic) have only scripted tests so far. Not yet done by anyone: the
tests with `Net::Curl` (the preferred module; the image has `WWW::Curl`), a real
proxy, the privilege drop as root in docker with a user other than 1000, and voice
with a real microphone.
- What is open is in TODO.md ("Open, found while fixing the agent loop"),
  what is settled in its "Completed Items".

## Layout

- **ai.pl** – entry point. Moves `%ENV` to `%::ORIG_ENV` (so nothing leaks to
  children), parses options (`-c` sets `AI_CONTINUE`, `-p` is one request via
  `ai::one_shot()`), drops root privileges (to `utils::privilege_plan()`:
  `AI_UID`/`UID`, `AI_GID`/`GID`, `AI_GROUPS` or the groups it has; the base
  directory is chowned, with its content when the owner changes), then
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
- **md.pm** – `md`: markdown of the answer, line by line as it streams (`new_printer()` uses it on a terminal)
- **/voice** (in `ai.pm`, section "Speech"): `voice_record()` runs the recorder as a child (`loop::spawn`), stopped with SIGINT by a timer; `transcribe()` sends the recording as multipart/form-data (`multipart_body()`) to AI_ASR_URL.
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
- **ai/** – prompt templates: `default` (chat), `coder` (adds the tools).
- **aicli.sh**, **Dockerfile** – docker wrapper and the Debian slim image.
  **docker-bake.hcl** builds that image (`docker buildx bake`; `image-ci`
  adds the GitHub Actions cache). CI still uses `docker build`.
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
7. `handle_llm_response()`: the calls the server made (`tool_calls`, see
`native_call()`), or else `parse_tool_calls()`, then `execute_tool()` for
   each, `agent` calls are started together and waited for at the end; the
   results are appended as user messages,
8. back to 2 while there were tool calls (max `AI_MAX_TURNS`).

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
`AI_MAX_AGENTS` are running), `agent::wait(@agents)` runs the loop until they
are done, then `{result}` / `{error}` are set. A sub-agent has its own message
list (system prompt from `ai::subagent_prompt()`: session prompt + tools
without `agent`), retries like the main loop, counts into the usage of the
session, writes its transcript to `agents/` in the session directory, and
shows up in the status line with its tokens (`agent::status`), and each start and
tool call is printed as one line (`ai::agent_view`, `AI_AGENT_VIEW`). It keeps its
own messages within the context window (`agent::compact`, before every
request and once after a "context too long" error): old tool output is
pruned, then the oldest steps are dropped with a note; system prompt, task
and the last two messages stay. No summary request, so it never has to wait.
It cannot start agents.

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
by `estimate_tokens()`). `context_limit()`: `AI_CONTEXT_TOKENS`, else
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
| grep | `_run` → `exec grep -rn -e <pattern> -- <path>` |
| bash | temp file, `_run` → `exec bash <file>` |
| perl | `_run` → `eval` in package `aicli::tool`, or `Safe->reval` (`AI_PERL_SAFE`) |
| fetch, search | `tools::_http` → `loop::http` (web proxy, timeout, size limit, redirects) |
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
only ever run in a forked child, never in the chat process. The policy is
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
| `t/65_file_tools.t` | lines, replace, the ed engine, edit, delete, move, mkdir, list |
| `t/67_sandbox.t` | Landlock for forked tools: writes, reads, child processes, extra paths, fallbacks (skipped without kernel support) |
| `t/66_workspace.t` | workspace confinement: `..`, absolute paths, symlinks, every file tool, `/workspace` |
| `t/70_retry_usage_context.t` | retry/backoff, rate limits, usage, budget, context management |
| `t/80_agents.t` | sub-agents (parallel, limits, errors, abort), the status line |
| `t/82_footer.t` | the footer (`tui.pm` bar mode, line fallback, resize, close), `fmt_k`, speeds, cached tokens, the info line from a mocked request |
| `t/84_providers.t` | providers: detection by key, OpenAI and Anthropic requests and stream, the curl shim, tool calls in the text, the logging of server calls |
| `t/86_native_tools.t` | native tool calls: tools in the request, calls and results, pieces of arguments, errors, the text fallback, sub-agents |
| `t/88_markdown.t` | markdown of the answer: headings, emphasis, code, lists, tables, streaming, the printer |
| `t/89_context_thinking.t` | the reasoning setting, what the request says, the first request through compactions, `/context` |
| `t/97_live.t` | a real model, only when `AI_LIVE_SERVER` is set (`AI_LIVE_MODEL`, optional `AI_LIVE_SEARXNG`): one answer, a native tool call, the thinking setting, search. Skipped otherwise |
| `t/98_voice.t` | speech: the multipart upload, the recorder child stopped by SIGINT, the text of the recognizer, `/voice` |
| `t/95_cli.t` | `-p` (one request, exit codes, stdin) and `-c` (continue per directory), as a process |
| `t/85_web.t` | proxy selection, HTML to text, fetch, search (mocked HTTP layer), a real fetch, `/retry`, `/rewind` |
| `t/90_prompt_display_undo.t` | project file and date in the prompt, byte-stable request prefix, brief display, diffs, `/undo` |

CI (`.github/workflows/tests.yml`) runs them twice on every push to `main`:
with the Debian packages (`WWW::Curl`) and inside the image of the Dockerfile
(Debian slim, `WWW::Curl`), there as a normal user.

`TestAI::mock_http` scripts the main agent (`utils::http`),
`TestAI::mock_agent_http` answers the sub-agents (`loop::http`).

## Known gaps

See TODO.md. The proxies and the SearXNG search have only been tested with a
mocked HTTP layer, never against a real proxy or instance. The bigger ones: `Net::Curl` is the preferred curl module, but the
tests have only run with `WWW::Curl` since the event loop exists, the image included; no tool
confirmation or allow-list (by choice);
the privilege drop itself (as root) is not covered by a test, only the plan.
