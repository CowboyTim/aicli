#!/usr/bin/perl
#
#  ↓ root user (possibly)

use strict; use warnings;

use FindBin;
use lib $FindBin::Bin;

# clear $0 asap: clears envp
my $orig_dollar0;
BEGIN {
    $orig_dollar0 = $0;
    my $bd = $ENV{BDIR}    // "session";
    $bd =~ s/^.*\///g;
    $bd =~ s/[^a-zA-Z0-9_-]/_/g;
    my $ln = $ENV{LOGNAME} // "nobody";
    $ln =~ s/[^a-zA-Z0-9_-]/_/g;
    $0 = "aicli:$ln:$bd";
}

# don't leak ENV to other forks, clear $0 asap: clears envp
%::ORIG_ENV = %ENV;
%ENV = ();

# Command-line options
$::DEBUG = $::ORIG_ENV{DEBUG} || 0;
{
    no warnings 'once';
    require Getopt::Long;
    my ($help, $continue);
    if(!Getopt::Long::GetOptions(
        'help|?'     => \$help,
        'debug'      => \$::DEBUG,
        'continue|c' => \$continue,
        'prompt|p=s' => \$::PROMPT,
    ) or $help){
        local $ENV{PAGER} = $::ORIG_ENV{PAGER} // 'less';
        local $0 = $orig_dollar0;
        require Pod::Usage;
        Pod::Usage::pod2usage(-input => "$FindBin::Bin/ai.pl", -verbose => 1, -exitval => 'NOEXIT', -output => \*STDOUT);
        exit 0;
    }
    $::ORIG_ENV{AI_CONTINUE} = 1 if $continue;
}

# init/setup
my $BASE_DIR = $::ORIG_ENV{AI_DIR} // (glob('~/.aicli'))[0];
-d "$BASE_DIR"
    or mkdir $BASE_DIR
    or die "Failed to create $BASE_DIR: $!\n";
if($< == 0){
    my $UID = 1000;
    my $GID = 1000;
    my $target_uid = $ENV{UID} // $UID;

    # we were root, chown the dirs properly, and drop privileges
    chown($UID, $GID, $BASE_DIR)
        or die "Error chown to $UID:$GID for $BASE_DIR: $!\n";

    chown($UID, $GID, $::ORIG_ENV{HOME})
        or die "Error chown to $UID:$GID for $::ORIG_ENV{HOME}: $!\n";

    # now drop privileges
    local $! = 0;
    # drop to GID
    $) = "$GID 983 986 992 109";
    die "[ERROR] setting EGID to $GID: $!\n"
        if $!;
    $( = $);
    die "[ERROR] setting RGID to $): $!\n"
        if $!;
    # drop to UID
    $> = $target_uid;
    die "[ERROR] setting EUID to $target_uid: $!\n"
        if $!;
    $< = $>;
    die "[ERROR] setting RUID to $>: $!\n"
        if $!;
}

# Final safety check: ensure we're not running as root
die "[ERROR] running as root EUID/RUID is not allowed\n"
    if $< == 0 or $> == 0;
die "[ERROR] running as root EGID/RGID is not allowed\n"
    if $( == 0 or $) == 0;

#  ↑ root user (possibly)
#--------------------------------------------------------
#  ↓ user 1000 (node)

# Main execution
require ai;

ai::chat_setup($BASE_DIR);
ai::setup_commands();
if(defined $::PROMPT){
    # one request and out: -p "text", or -p - for all of stdin
    $::PROMPT = do {local $/; <STDIN>} if $::PROMPT eq '-';
    my $rc = ai::one_shot($::PROMPT);
    ai::cleanup_chat();
    exit $rc;
}
ai::chat_loop();
ai::cleanup_chat();

__END__

=head1 NAME

ai.pl - AI chat and coding agent for the command line

=head1 SYNOPSIS

ai.pl [options]

 Options:
   -help            brief help message
   -debug           enable debug mode
   -c, -continue    continue the session last used in this directory
   -p, -prompt TEXT one request, then exit ("-" reads it from stdin)

 Examples:
   ai.pl -c
   ai.pl -p "why does the build fail?" && echo answered
   AI_API_KEY=csk-... ai.pl
   AI_LOCAL_SERVER=http://localhost:8080 AI_PROMPT_TEMPLATE=coder ai.pl
   echo "what is in this directory?" | AI_SESSION=demo ai.pl

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-debug>

Enable debug mode.

=item B<-c>, B<-continue>

Continue the session that was last used in the current directory, instead of
starting a new one. A new session is started when there is none. B<AI_SESSION>
wins when it is set.

=item B<-p> I<text>, B<-prompt> I<text>

Not interactive: send I<text> as one request, let the model work on it (tools
included) and exit. C<-> as I<text> reads the request from stdin, all of it.
The exit code is 0 when the model answered, 1 when the request ended with an
error (also: turn limit, token budget) and 130 when it was interrupted.
Together with B<-c> this continues a session one request at a time.

=back

=head1 DESCRIPTION

B<ai.pl> is an interactive chat with an LLM that can act: the model can run
tools (file tools, bash, perl, grep, sub-agents) and gets the results back, in
a loop, until it has an answer. Thinking of the model is shown while it streams in, in
its own color.

One turn works like this: the conversation of the session is sent to the
API, the answer is streamed to the terminal, the tool calls in the answer are
executed, their results are appended to the conversation, and the conversation
is sent again. This repeats until an answer has no tool call (or B<AI_MAX_TURNS>
is reached). Ctrl-C while this is going on stops the turn and returns to the
prompt, ctrl-C or ctrl-D at the prompt leaves the chat.

Input is read with readline when on a terminal (history, completion of
commands with TAB, shift-enter for multi-line input, an empty line sends it).
When stdin is not a terminal every line is one request.

=head1 TOOLS

The model calls a tool by writing a block in its answer, the syntax is part of
the system prompt of the B<coder> template (the B<default> template has no
tools):

  ///BASH_7c48+EO_dfd7
  ls -la
  EO_dfd7
  BASH_7c48

The result is sent back as the next message:

  [BASH_7c48 RESULT_d170
  ...
  RESULT_d170]

or C<[BASH_7c48 ERROR_9a78 ... ERROR_9a78]> on failure. Tool calls inside a
thinking block are ignored. A tool call that cannot be parsed is answered with
an error, so the model can try again.

=over 8

=item B<read>, B<lines>, B<write>

Read a file (B<lines>: with line numbers, all or a range like C<10-40>), write
or overwrite a file.

=item B<replace>

Replace a piece of text in a file. The old text must be in the file exactly
once.

=item B<edit>

Apply an ed script to a file: C<Na>, C<Ni>, C<N,Mc> (followed by text and a
line with only a dot), C<N,Md>, C<N,Ms/regex/replacement/g>. An address is a
line number, C<$> or C</regex/>. As in ed, line numbers are those after the
previous command. Nothing is written when a command fails.

=item B<delete>, B<move>, B<mkdir>, B<list>

Delete a file or an empty directory, move/rename (never overwrites), create a
directory with its parents, list a directory.

=item B<grep>

A forked child exec()s C<grep -rn>, without a shell.

=item B<bash>

The script is written to a temp file, a forked child process exec()s bash on it.

=item B<perl>

The code is eval()ed in a forked child process. With B<AI_PERL_SAFE> it runs
in a L<Safe> compartment instead.

=item B<agent>

Give a task to a sub-agent, see B<SUB-AGENTS>.

=back

The file tools are plain perl in the chat process, they start no process.
Forked tool processes run in their own session with stdin from /dev/null,
stdout and stderr captured, and a minimal environment: none of the B<AI_*>
variables (so not the API key) are passed on. They are stopped at
B<AI_TOOL_TIMEOUT> and on ctrl-C. There is no confirmation before a tool runs:
use the docker wrapper (B<aicli.sh>) as the sandbox.

=head1 DISPLAY AND UNDO

The tool calls in an answer are not shown as the model writes them: every
call is one line, followed by the first lines of its result (B<AI_TOOL_LINES>).
B<write>, B<replace> and B<edit> show what they changed as a diff. The model
always gets the complete result. B<AI_TOOL_DISPLAY=full> shows everything.

Every change of the file tools (also of sub-agents) is noted in the session
with a copy of the old content, B</undo> takes back the last one. Changes made
by B<bash> or B<perl> are not covered.

=head1 SYSTEM PROMPT

The system prompt of a session is the prompt template, the tools (template
C<coder>), the project instructions (F<AGENTS.md> of the working directory,
see B<AI_PROJECT_FILE>) and the date (only the month by default, see
B<AI_PROMPT_DATE>). It is built once, when the session starts, and stored with
the conversation; B</clear> and B</prompt> build it again.

The start of a conversation is never rewritten afterwards: each request is the
previous one plus the new messages, byte for byte, so that the prompt (prefix)
cache of the API or of a local server keeps working. Only context management
changes older messages, when the context window is nearly full.

=head1 SUB-AGENTS

With the B<agent> tool the model hands a self-contained task to a sub-agent:
a second conversation with the model, with the system prompt of the session
and all tools except B<agent>, but nothing of the conversation so far. Its
final answer is the result of the tool call. Several B<agent> calls in one
answer work at the same time, at most B<AI_MAX_AGENTS>.

A sub-agent is neither a process nor a thread: its request is one more curl
handle and its tools are forked children in the one select() loop of the
program. What it thinks and does is not printed, the status line shows it. Its
conversation is saved in the F<agents/> directory of the session.

=head1 RETRIES, USAGE, CONTEXT

Failed requests are retried with exponential backoff when that can help (rate
limit, overload, server and network errors); a rate limit waits as long as the
API asks for. See B<AI_RETRIES>, B<AI_RETRY_DELAY>, B<AI_RETRY_MAX_WAIT>.

The tokens of every request are counted per session and shown after each
answer (B<AI_SHOW_USAGE>, B</usage>). B<AI_TOKEN_BUDGET> limits what a session
may use.

When the conversation gets close to the context window of the model
(B<AI_CONTEXT_TOKENS>, B<AI_CONTEXT_THRESHOLD>), the output of old tool calls
is cut, and if needed the older messages are replaced by a summary written by
the model (B<AI_CONTEXT_SUMMARY>). Removed messages are kept in F<chat.archive>.
B</compact> does this on demand.

=head1 COMMANDS

A line that starts with C</> is a command, it is never sent to the model.

=over 8

=item B</exit> or B</quit>

Exit the chat.

=item B</help>

Show the list of available commands.

=item B</clear>

Forget the conversation of the session, the system prompt is kept.

=item B</history>

Show the input history.

=item B</debug>, B</nodebug>

Enable or disable debug mode.

=item B</tools>

List the tools the model can call.

=item B</undo> [list]

Take back the last change a file tool made (write, replace, edit, delete,
move, mkdir), C<list> shows the changes that can be undone.

=item B</usage> [reset]

Show the token usage and the context size of the session, C<reset> starts
counting again.

=item B</compact>

Summarize the older messages now, to free context.

=item B</system> <text>

Add a system message to the conversation.

=item B</files> [regex]

Add the files of the current directory that match to the conversation. Files
listed (as globs) in F<.aiignore> are skipped.

=item B</chdir> <dir> or B</cd> <dir>

Change the current working directory.

=item B</ls>

List files in the current directory.

=item B</pwd>

Print the current working directory.

=item B</session>

Manage chat sessions.
  /session                 - List all sessions
  /session list            - List all sessions
  /session create <name>   - Create a new session and switch to it
  /session delete <name>   - Delete a session
  /session rename <old> <new> - Rename a session
  /session switch <name>   - Switch to a session
  /session <name>          - Switch to a session (shortcut)

Session names consist of letters, digits, C<.>, C<_> and C<->.

=item B</model>

Manage the model of the current session
  /model              - List the models of the API, the current one marked
  /model <model_name> - Set the model for this session

=item B</prompt>

Manage the system prompt of the current session
  /prompt             - List the prompt templates
  /prompt <name>      - Switch the system prompt, the conversation is kept

=back

=head1 SUPPORTED PROVIDERS

All providers are used through their OpenAI compatible streaming chat
completions API.

=over 8

=item B<Cerebras>

API key prefix: C<csk->

=item B<OpenRouter>

API key prefix: C<sk-or->. B<OPENROUTER_PROVIDER> restricts the upstream
providers (space separated).

=item B<NVIDIA>

API key prefix: C<nvapi->

=item B<Lemonade>

Local server, no API key needed. Default URL: C<http://localhost:8000>

=item B<Any local server>

Set B<AI_LOCAL_SERVER> to the URL of an OpenAI compatible server (llama.cpp,
lemonade, ...).

=back

The provider is auto-detected from the API key prefix, or explicitly set via
the B<AI_PROVIDER> environment variable.

=head1 ENVIRONMENT VARIABLES

These can also be set in the config file, a shell fragment with C<AI_...=value>
lines.

=over 8

=item B<AI_DIR>

Base directory for configuration and sessions. Default: F<~/.aicli>

=item B<AI_CONFIG>

Path to the configuration file. Default: F<$AI_DIR/config>

=item B<AI_API_KEY>

API key for accessing the AI API.

=item B<AI_PROVIDER>

The provider to use: cerebras, openrouter, nvidia, lemonade. If not specified
it is auto-detected from the API key prefix.

=item B<AI_LOCAL_SERVER>

URL of a local OpenAI compatible server (overrides the provider URL).

=item B<AI_MODEL>

Model name, the default for sessions without a model of their own.

=item B<AI_SESSION>

Name of the session to use. Default: a new C<session-E<lt>uuidE<gt>>.

=item B<AI_PROMPT_TEMPLATE>

System prompt template for new sessions, a file in F<ai/>: C<default> (plain
chat) or C<coder> (with the tools). Default: C<default>

=item B<AI_PROMPT_TEMPLATE_FILE>

Path to a system prompt file, instead of F<ai/$AI_PROMPT_TEMPLATE>.

=item B<AI_CLEAR>

Start the session with an empty conversation and a fresh system prompt.

=item B<AI_TOKENS>

Maximum number of tokens for a completion. Default: 100000

=item B<AI_TEMPERATURE>, B<AI_TOP_P>, B<AI_TOP_K>, B<AI_MIN_P>

Sampling settings. Defaults: 0.6, 0.95, 20, 0.0

=item B<AI_RAW>

Use the raw F</v1/completions> endpoint with a prompt formatted here (for
servers without a chat template). Only known for qwen models.

=item B<AI_MAX_TURNS>

Maximum number of requests for one user input (tool loop). Default: 50, 0 for
no limit.

=item B<AI_MAX_AGENTS>

Number of sub-agents that work at the same time. Default: 4

=item B<AI_AGENT_MODEL>

Model for the sub-agents. Default: the model of the session.

=item B<AI_RETRIES>

How often a failed request is tried again. Default: 4, 0 for never.

=item B<AI_RETRY_DELAY>

Seconds before the first retry, doubled for every further one (with jitter,
at most 60). Default: 2

=item B<AI_RETRY_MAX_WAIT>

The longest wait in seconds that a rate limit may ask for, a longer one is an
error. Default: 120

=item B<AI_CONTEXT_TOKENS>

Context window of the model in tokens, 0 for no context management. Default:
what the API reports (model list, or F</props> of a llama.cpp server); when
unknown, the conversation is compacted when the API refuses it as too long.

=item B<AI_CONTEXT_THRESHOLD>

Part of the context window that may be used before compacting. Default: 0.8

=item B<AI_CONTEXT_SUMMARY>

Set to 0 to drop old messages instead of having the model summarize them.

=item B<AI_TOKEN_BUDGET>

Maximum number of tokens (prompt + completion, all requests) a session may
use. Default: no limit.

=item B<AI_USAGE>

Set to 0 to not ask the API for token usage (C<stream_options>), for servers
that refuse it. Usage is estimated then.

=item B<AI_SHOW_USAGE>

Set to 0 to hide the usage line after each answer. Default: 1

=item B<AI_STATUS>

Set to 0 to switch the status line off. Default: 1

=item B<AI_TOOL_DISPLAY>

C<brief> (default): one line per tool call and the first lines of its result.
C<full>: the tool calls as the model writes them and the complete results.

=item B<AI_TOOL_LINES>

Number of result lines shown with the brief display. Default: 8

=item B<AI_SHOW_DIFF>, B<AI_DIFF_LINES>

Set B<AI_SHOW_DIFF> to 0 for no diff after a file change. B<AI_DIFF_LINES> is
the maximum number of lines of a diff. Default: 1, 40

=item B<AI_UNDO_MAX_SIZE>

Files bigger than this many bytes are changed without a copy for B</undo>.
Default: 8000000

=item B<AI_PROJECT_FILE>

Files with project instructions, looked for in the working directory and
added to the system prompt (space or comma separated). Empty for none.
Default: C<AGENTS.md>

=item B<AI_PROJECT_FILE_MAX>

Maximum number of bytes taken from a project instruction file. Default: 32768

=item B<AI_PROMPT_DATE>

How precise the date in the system prompt is: C<none>, C<year>, C<month>,
C<day>, or a strftime(3) format. Coarse on purpose: the system prompt starts
every request, a date that changes often defeats caching. Default: C<month>

=item B<AI_SHOW_THINKING>

Set to 0 to hide the thinking of the model. Default: 1

=item B<AI_TOOL_TIMEOUT>

Seconds a bash/perl/grep tool may run. Default: 120, 0 for no limit.

=item B<AI_TOOL_MAX_OUTPUT>

Maximum size of a tool result, the middle of bigger ones is cut out.
Default: 65536, 0 for no limit.

=item B<AI_TOOL_ENV>

Names of extra environment variables to pass to tools (space or comma
separated). Always passed: PATH HOME LOGNAME USER SHELL TERM LANG LC_ALL TZ
TMPDIR SSH_AUTH_SOCK and GIT_*.

=item B<AI_PERL_SAFE>

Run the perl tool in a L<Safe> compartment: C<1> for the default opcode set,
or a list of extra opcodes/opcode tags to permit, e.g. C<:filesys_read>.

=item B<AI_PS1>, B<AI_PS2>

Prompt and continuation prompt of the input line.

=item B<AI_LOG>

File for log output. Default: stdout

=item B<DEBUG>

Enable or disable debug mode.

=item B<AI_PROXY>

Proxy URL for HTTP/HTTPS requests (e.g., http://proxy:8080).

=item B<HTTPS_PROXY>

Fallback proxy URL if AI_PROXY not set.

=item B<HTTP_PROXY>

Fallback proxy URL if AI_PROXY and HTTPS_PROXY not set.

=back

=head1 FILES

=over 8

=item F<~/.aicli/config>

Configuration (see B<ENVIRONMENT VARIABLES>).

=item F<~/.aicli/inputrc>

Readline init file.

=item F<~/.aicli/sessions/E<lt>nameE<gt>/>

One directory per session: C<chat> (the conversation, one JSON message per
line), C<chat.archive> (messages removed by context management), C<prompt> and
C<template> (system prompt), C<model>, C<usage> (token counters), C<cwd> (the directory it was last used in, for
B<-continue>), C<history>
(input history), C<agents/> (conversations of sub-agents), C<undo/> (journal
and copies for B</undo>).

=back

=cut
