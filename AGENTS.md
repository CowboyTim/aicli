# AI-CLI: notes for agents and contributors

## What this is

AI-CLI is a coding agent for the command line, in Perl: an interactive chat
with an LLM that runs tools (bash, perl, read, write, grep) and feeds the
results back to the model in a loop. Same idea as pi, hermes or opencode, but
small and Perl-ish: `fork()`, `exec()`, `eval`/`Safe`, `select()`, libcurl.

## Rules

These are requirements, not suggestions.

- **No Perl threads.** Never `use threads`, `threads::shared`, `Thread::Queue`
  or anything built on ithreads.
- **Fork only when needed**: to run something that must be isolated from the
  chat process (model-written code, external programs). Don't fork for
  concurrency that I/O multiplexing can do.
- **Prefer async I/O**: curl multi (`Net::Curl::Multi` or `WWW::Curl::Multi`) for HTTP and
  `select()` on file handles for everything that waits. A wait must be a
  `select()` with a timeout in a loop that also checks `$::ABORT`, never a
  blocking read or a `sleep`, so ctrl-C and timeouts keep working.
- **Everything through `utils::fork_run()`** when a child is needed: it gives
  the child its own session, a clean environment, captured output, a timeout
  and abort handling. Don't use backticks, `system()` or piped `open()` for
  tools.
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
  children), parses options, drops root privileges, then
  `ai::chat_setup(); ai::setup_commands(); ai::chat_loop();`. Holds the POD.
- **ai.pm** – several packages in one file:
  - `ai` – setup/providers, chat state, agent loop, streaming, sessions,
    commands, readline input
  - `model`, `provider`, `provider::<name>` – request building per provider
  - `prompt::<template>` – generated part of the system prompt (tools section)
  - `tools` – tool table, parser regex, tool implementations
  - `colors`
- **utils.pm** – `utils::http()` (curl), `utils::fork_run()`,
  `utils::tool_env()`, packages `curl` (Net::Curl/WWW::Curl shim) and `log`.
- **ai/** – prompt templates: `default` (chat), `coder` (adds the tools).
- **aicli.sh**, **Dockerfile** – docker wrapper and Alpine image.
- **t/** – tests, **TODO.md** – roadmap.

## How a turn works

`ai::chat_completion($input)`:

1. append the user message to the session `chat` file (one JSON message per
   line),
2. `load_messages()` and `request_completion()`: POST to
   `/v1/chat/completions` with `stream => true`,
3. `new_stream()` parses the SSE chunks, `new_printer()` shows thinking
   (`reasoning_content`/`reasoning` deltas, `<think>` blocks) and answer in
   their colors,
4. the answer without thinking is appended as assistant message,
5. `handle_llm_response()` finds the tool calls, `execute_tool()` runs them,
   the results are appended as user messages,
6. back to 2 while there were tool calls (max `AI_MAX_TURNS`).

The request is always rebuilt from the chat file: nothing about the
conversation lives only in memory.

`$::ABORT` is set by ctrl-C while a turn runs (`$ai::BUSY`); the curl loop, the
stream callback, `fork_run()` and the tool loop all check it
(`utils::aborted()`). `$::LOOP = 0` ends the chat.

Strings: messages are text (decoded) in memory and in JSON. The terminal,
files and tools work with bytes: `ai::to_text()` / `ai::to_bytes()` at the
border.

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
| bash | temp file, `fork_run` → `exec bash <file>` |
| perl | `fork_run` → `eval` in package `aicli::tool`, or `Safe->reval` (`AI_PERL_SAFE`) |
| grep | `fork_run` → `exec grep -rn -e <pattern> -- <path>` |
| read, write | in-process |

There is no confirmation step and no path restriction: the docker container
is the sandbox.

## Commands

One table, `@ai::COMMANDS` (`run`, `help`, `usage`, `complete`), drives
execution (`handle_command()`), `/help` and TAB completion
(`setup_commands()` builds `$ai::cmds` from it). Add a command there and
nowhere else. `handle_command()` returns undef for chat text, 0 for a handled
command, 1 to leave; a command line never reaches the LLM.

## Sessions

`$AI_DIR/sessions/<name>/` with `chat` (conversation), `prompt` + `template`
(system prompt and the template it came from), `model`, `history` (readline).
Names match `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`, checked by
`valid_session_name()` everywhere a name comes in.

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
| `t/45_http_e2e.t` | real curl against a fake server, `ai.pl` end to end |
| `t/50_commands.t` | slash commands, input readers, completion |
| `t/60_tools.t` | `fork_run`, environment, bash/perl/Safe/read/write/grep |

## Known gaps

See TODO.md. The bigger ones: no retry/backoff on API errors, no token usage
statistics, no tool confirmation or allow-list, no edit/patch tool, the
privilege drop in `ai.pl` uses a fixed uid/gid (1000).
