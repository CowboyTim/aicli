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
    my ($help, $man, $continue);
    my $ok = Getopt::Long::GetOptions(
        'help|h|?'    => \$help,
        'man'         => \$man,
        'debug'      => \$::DEBUG,
        'continue|c' => \$continue,
        'prompt|p=s' => \$::PROMPT,
    );
    if(!$ok or $help or $man){
        # usage (-h, -help) or the whole manual (-man) from the POD of this file;
        # a wrong option gets the usage on stderr and exit 2
        local $0 = $orig_dollar0;
        require Pod::Usage;
        my $input = "$FindBin::Bin/ai.pl";
        if($man){
            # the manual through the pager, when there is a terminal
            my $pager;
            if(-t STDOUT and length(my $p = $::ORIG_ENV{PAGER} // 'less')){
                open($pager, '|-', $p) or undef $pager;
            }
            Pod::Usage::pod2usage(-input => $input, -verbose => 2, -noperldoc => 1, -exitval => 'NOEXIT',
                -output => ($pager // \*STDOUT));
            close($pager) if $pager;
            exit 0;
        }
        Pod::Usage::pod2usage(-input => $input, -verbose => 1, -exitval => 'NOEXIT',
            -output => ($ok ? \*STDOUT : \*STDERR));
        exit($ok ? 0 : 2);
    }
    $::ORIG_ENV{AI_CONTINUE} = 1 if $continue;
}

# init/setup
my $BASE_DIR = $::ORIG_ENV{AI_DIR} // (glob('~/.aicli'))[0];
-d "$BASE_DIR"
    or mkdir $BASE_DIR
    or die "Failed to create $BASE_DIR: $!\n";
if($< == 0){
    # we are root (docker): become the user the environment names, see
    # utils::privilege_plan: AI_UID/UID, AI_GID/GID, AI_GROUPS
    require utils;
    my $plan = utils::privilege_plan(\%::ORIG_ENV, [split m/ /, $)]);
    my ($UID, $GID) = @{$plan}{qw(uid gid)};

    # chown the dirs properly. The base dir is ours, all of it changes hands
    # when it belonged to someone else (a volume from an earlier run as
    # another user); of the home directory only the directory itself.
    my @owner = (stat($BASE_DIR))[4, 5];
    chown($UID, $GID, $BASE_DIR)
        or die "Error chown to $UID:$GID for $BASE_DIR: $!\n";
    utils::chown_tree($BASE_DIR, $UID, $GID)
        if $owner[0] != $UID or $owner[1] != $GID;
    if(length($::ORIG_ENV{HOME} // '') and -d $::ORIG_ENV{HOME}){
        chown($UID, $GID, $::ORIG_ENV{HOME})
            or die "Error chown to $UID:$GID for $::ORIG_ENV{HOME}: $!\n";
    }

    # now drop privileges
    local $! = 0;
    # drop to GID, and to the supplementary groups: always a list, or root's
    # own groups would stay
    $) = join(' ', $GID, (@{$plan->{groups}} ? @{$plan->{groups}} : $GID));
    die "[ERROR] setting EGID to $GID: $!\n"
        if $!;
    $( = $GID;
    die "[ERROR] setting RGID to $GID: $!\n"
        if $!;
    # drop to UID
    $> = $UID;
    die "[ERROR] setting EUID to $UID: $!\n"
        if $!;
    $< = $UID;
    die "[ERROR] setting RUID to $UID: $!\n"
        if $!;
    die "[ERROR] still not $UID:$GID after dropping privileges\n"
        unless $< == $UID and $> == $UID and $( + 0 == $GID and $) + 0 == $GID;
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
   -h, -help        brief help message
   -man             the whole manual
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

=item B<-h>, B<-help>

Print a brief help message and exit. A wrong option prints it on stderr and exits 2.

=item B<-man>

The whole manual (this text) and exit: through the pager on a terminal.

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
prompt, ctrl-C or ctrl-D at the prompt leaves the chat. With input from a pipe
SIGINT does the same: it stops the turn and the next line is read; a second
one, or one while nothing runs, ends the program with exit code 130. SIGTERM
stops the turn and ends the program.

Input is read with readline when on a terminal (history, completion of
commands with TAB, shift-enter for multi-line input, an empty line sends it).
When stdin is not a terminal every line is one request.

=head1 TOOLS

The model calls a tool through the API: the request carries the tools (with
their arguments as JSON schemas), and the server returns the calls as
B<tool_calls>. The result goes back as a message of its own, with the id of
the call. This is B<AI_TOOL_CALLS=native>, the default. With B<AI_TOOL_CALLS=text>
the tools are described in the system prompt of the B<coder> template (the
B<default> template has no tools) and the model writes a block in its answer:

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

=item B<delete>, B<move>, B<mkdir>, B<list>, B<find>

Delete a file or an empty directory, move/rename (never overwrites), create a
directory with its parents, list a directory.

=item B<find>

The entries under a directory whose name matches a Perl regular expression
(all of them for an empty one), sorted, up to 1000. Walks the tree with
opendir/readdir in the chat process. Symbolic links are listed, never followed.

=item B<grep>

A forked child exec()s C<grep -rn>, without a shell.

=item B<bash>

The script is written to a temp file, a forked child process exec()s bash on it.

=item B<perl>

The code is eval()ed in a forked child process. With B<AI_PERL_SAFE> it runs
in a L<Safe> compartment instead.

=item B<fetch>

Get a web page or file by its URL (http and https). HTML is turned into text,
links are kept as C<[text](url)>. See B<WEB AND PROXIES>.

=item B<search>

Search the web through a SearXNG instance (B<AI_SEARXNG_URL>), the result is a
list of titles, URLs and snippets. The model is only told about this tool
when the variable is set.

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

=head1 WEB AND PROXIES

B<fetch> and B<search> are HTTP requests in the event loop of the program,
like the requests to the model: they don't block anything, several can run at
once, they end at B<AI_WEB_TIMEOUT> or on ctrl-C, and a page is cut at
B<AI_WEB_MAX_SIZE>. The API key is never sent with them.

Each kind of request has its own proxy: B<AI_PROXY> for the LLM API,
B<AI_WEB_PROXY> for B<fetch> (both fall back to B<HTTPS_PROXY> and
B<HTTP_PROXY>), B<AI_SEARXNG_PROXY> for B<search> (no fallback, the instance
is asked directly). A proxy is anything curl takes, e.g.
C<http://host:3128>, C<socks5h://host:1080>, C<http://user:pass@host:3128>.
The value C<none> means no proxy, whatever the environment says. B<NO_PROXY>
is honoured.

The SearXNG instance has to allow the JSON format (settings.yml:
C<search: formats: [html, json]>).

=head1 WORKSPACE

The file tools (B<read>, B<lines>, B<write>, B<replace>, B<edit>, B<delete>,
B<move>, B<mkdir>, B<list>, B<find> and the path of B<grep>) are confined to the
workspace: the directory B<ai.pl> is started in, or B<AI_WORKSPACE>. A path
counts by where it really leads: C<..> and symbolic links are resolved before
the check, a path that ends up outside is refused. B<delete> and B<move> work
on a link itself, not on its target. B<AI_WORKSPACE_ALLOW> adds directories,
B</workspace> changes it while chatting.

=head1 SANDBOX

B<bash>, B<perl> and B<grep> run in a forked process. Before the tool starts,
that process confines itself with Landlock, a feature of the Linux kernel
(5.13 or newer): it and everything it starts can only write in the workspace,
B<AI_WORKSPACE_ALLOW>, the temp directory, a few devices like F</dev/null>,
and the paths of B<AI_SANDBOX_WRITE>. Reading is not limited, unless
B<AI_SANDBOX_READ> is set.

No root is needed and nothing is mounted: this is not a container, the process
sees the whole filesystem and gets "Permission denied" where it may not go. A
confined process cannot gain privileges (no sudo). The network is not
restricted. The chat process itself is never confined. B</workspace> shows
the state.

Without Landlock in the kernel the tools run unconfined (B<AI_SANDBOX=on>
makes that an error).

=head1 SUB-AGENTS

With the B<agent> tool the model hands a self-contained task to a sub-agent:
a second conversation with the model, with the system prompt of the session
and all tools except B<agent>, but nothing of the conversation so far. Its
final answer is the result of the tool call. Several B<agent> calls in one
answer work at the same time, at most B<AI_MAX_AGENTS>. With B<AI_PROVIDER>=flm
there is no B<agent> tool at all (the NPU is kept for voice).

A sub-agent is neither a process nor a thread: its request is one more curl
handle and its tools are forked children in the one select() loop of the
program. What it thinks is not printed. The status line shows what it does, with the
tokens it used, and a line per start and tool call is printed (B<AI_AGENT_VIEW>).
Its conversation is saved in the F<agents/> directory of the session, after every
message, so a stuck agent can be read. It stops after B<AI_AGENT_MAX_TURNS> tool
turns (default 20). An agent keeps its own conversation within the context
window: the output of older tool calls is cut, then its oldest steps are
dropped, the task stays.

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

=item B</retry>

Ask the last request again: its answer and what the tools did for it are taken
out of the conversation first (and kept in F<chat.archive>).

=item B</rewind> [n]

Take the last exchange, or the last n, out of the conversation: what you said
and everything that followed.

=item B</compact>

Summarize the older messages now, to free context.

=item B</voice> [seconds]

Record from the microphone, recognize the speech with the recognizer of B<AI_ASR_URL>
and send the text as the request. At a terminal, Enter starts the recording and
Enter again stops it (B<AI_VOICE_MAX> seconds at most, 60). With a number of
seconds it records that long; without a terminal, B<AI_VOICE_SECONDS> (5). The
recording is made by B<AI_RECORDER> (pw-record), as a child process. A recording
with no sound in it is not sent (the recognizer makes up a word for silence):
"[nothing heard]" is shown instead.

=item B</context> [summary]

How full the context is (tokens against the window), the number of archived
messages, the compactions of this session and the thinking setting.
B<summary> shows the last summary the model wrote for the older messages.

=item B</thinking> [on|off|<tokens>|default]

The reasoning of the model for this session: on, off, a token budget, or the
default (B<AI_THINKING>). Without an argument it shows the setting.

=item B</system> <text>

Add a system message to the conversation.

=item B</files> [regex]

Add the files of the current directory that match to the conversation. Files
listed (as globs) in F<.aiignore> are skipped.

=item B</workspace> [dir|none]

Show the workspace, or set it to a directory; C<none> lifts the limit.

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
  /session delete <name>   - Delete a session; when it is the current one,
                             a new, empty session takes its place
  /session reset           - Start the current session over: conversation,
                             archive, token counters, undo journal and agent
                             transcripts are removed, its name, system
                             prompt, model and input history stay
  /session rename <old> <new> - Rename a session
  /session rename <new>    - Rename the current session
  /session prune [days] [yes] - Remove the sessions that were not used for
                             that many days (default 30): they are listed
                             and you are asked, unless "yes" is given

The list shows for every session when it was last used and the first thing
that was said in it. A session ai.pl made up a name for and in which nothing
was said is removed when ai.pl ends.
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

Most providers are used through their OpenAI compatible streaming chat
completions API; Anthropic has its own Messages API, which is spoken directly.

=over 8

=item B<Cerebras>

API key prefix: C<csk->

=item B<OpenRouter>

API key prefix: C<sk-or->. B<OPENROUTER_PROVIDER> restricts the upstream
providers (space separated).

=item B<NVIDIA>

API key prefix: C<nvapi->

=item B<OpenAI>

API key prefix: C<sk-> (the longer prefixes win, so C<sk-or-> is OpenRouter).
The newer models get C<max_completion_tokens>; no C<top_k> or C<min_p>. The
model is needed: set B<AI_MODEL>.

=item B<Anthropic>

API key prefix: C<sk-ant->. Default model C<claude-sonnet-5-5> (B<AI_MODEL>
overrides it). B<AI_TOKENS> is the maximum answer length (default 8192, the
API requires one). Tool calls are written in the text as with every provider;
no extended thinking yet. No raw completion (B<AI_RAW>).

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

The provider to use: cerebras, openrouter, nvidia, openai, anthropic, lemonade. If not specified
it is auto-detected from the API key prefix.

=item B<AI_LOCAL_SERVER>

URL of a local OpenAI compatible server (overrides the provider URL).

=item B<AI_MODEL>

Model name, the default for sessions without a model of their own.

=item B<AI_SESSION>

Name of the session to use. Default: a new C<session-E<lt>uuidE<gt>>.

=item B<AI_SESSION_KEEP_DAYS>

At every start, remove the sessions that were not used for this many days,
conversation or not, without asking. Also the default number of days of
B</session prune>. Default: sessions are kept forever.

=item B<AI_PROMPT_TEMPLATE>

System prompt template for new sessions, a file in F<ai/>: C<default> (plain
chat) or C<coder> (with the tools). Default: C<default>

=item B<AI_PROMPT_TEMPLATE_FILE>

Path to a system prompt file, instead of F<ai/$AI_PROMPT_TEMPLATE>.

=item B<AI_CLEAR>

Start the session with an empty conversation and a fresh system prompt.

=item B<AI_TOKENS>

Maximum number of tokens for a completion. Default: 100000, 8192 with FastFlowLM
(a model that loops on the NPU would otherwise stream for minutes).

=item B<AI_TEMPERATURE>, B<AI_TOP_P>, B<AI_TOP_K>, B<AI_MIN_P>

Sampling settings. Defaults: 0.6, 0.95, 20, 0.0

=item B<AI_MARKDOWN>

Draw the markdown of the answer for the terminal: headings, bold, italic,
code, lists, quotes, links and tables. Only when the output is a terminal;
0 keeps the text as the model wrote it, 1 draws it anyway. Default: 1 on a
terminal

=item B<AI_TOOL_CALLS>

C<native> (default): the tools are sent with the request (the API's C<tools>),
and the calls come back as the server parses them (C<tool_calls>). The tool
syntax is not in the system prompt then. C<text>: the tool syntax is in the
system prompt and the calls are written in the answer. Anthropic and B<AI_RAW>
always use the text. Calls written in the text are run in both modes.

=item B<AI_RAW>

Use the raw F</v1/completions> endpoint with a prompt formatted here (for
servers without a chat template). Only known for qwen models.

=item B<AI_MAX_TURNS>

Maximum number of requests for one user input (tool loop). Default: 50, 0 for
no limit.

=item B<AI_AGENT_MAX_TURNS>

Maximum number of tool turns of one sub-agent (its requests that make tool calls).
Default: 20. The main loop has its own limit, B<AI_MAX_TURNS>.

=item B<AI_MAX_AGENTS>

Number of sub-agents that work at the same time. Default: 4. Not used with
FastFlowLM, which has no sub-agents.

=item B<AI_AGENT_VIEW>

Sub-agents show what they do as it happens: a line when one starts and one for
each tool call, prefixed with its number. Set to 0 to hide these lines (their
thinking is never shown). Default: 1

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

=item B<AI_THINKING>

The reasoning of the model: C<on>, C<off>, or a token budget (for servers that
take one, C<reasoning_budget>). Set per session with B</thinking>, which wins
over this. Not set: the server decides. Sent to OpenAI-compatible servers only.

=item B<AI_AUTO_COMPACT>

Compact the conversation right after an answer when it is over the threshold
(B<AI_CONTEXT_THRESHOLD>), so that the work happens between the turns. Not with
B<-p>. Set to 0 to compact only before a request that needs it. Default: 1

=item B<AI_RECORDER>, B<AI_ASR_URL>, B<AI_ASR_MODEL>, B<AI_VOICE_SECONDS>

Speech for B</voice>: the recorder program (C<pw-record>: PipeWire, its socket is
shared with the container), the OpenAI compatible transcription endpoint (for
FastFlowLM on the NPU: C<http://localhost:52625/v1/audio/transcriptions>, no
default), the model name it expects (C<whisper-large-v3-turbo>), and the default
length of a recording in seconds (5).

=item B<AI_SUMMARY_CHUNKS>

The older part of a long conversation is summarized in pieces that fit a request,
each one updating the summary so far. At most this many pieces (the newest),
default 8; the oldest are left out of the summary (they stay in the archive).

=item B<AI_CONTEXT_SUMMARY>

Set to 0 to drop old messages instead of having the model summarize them.

=item B<AI_TOKEN_BUDGET>

Maximum number of tokens (prompt + completion, all requests) a session may
use. Default: no limit.

=item B<AI_USAGE>

Set to 0 to not ask the API for token usage (C<stream_options>), for servers
that refuse it. Usage is estimated then.

=item B<AI_SHOW_USAGE>

Set to 1 to show the usage line after each answer, 0 to hide it. Default:
shown, except while the footer is on (then it is shown only with 1), because
the footer shows the same numbers.

=item B<AI_GLYPHS>

C<unicode> or C<ascii>: the characters of the status (spinner, separators,
arrows, sum). The default follows the locale: a UTF-8 locale gets unicode,
any other gets ASCII. The footer measures what it prints in columns (wide
East Asian characters count two, combining marks none), and shows emoji as
C<?>, because terminals disagree on how wide they are.

=item B<AI_STATUS>

C<bar> (default): a two-line footer at the bottom of the terminal. Line one
is what is going on (waiting for the model, a tool, each sub-agent with its
tokens), line two the model, tokens, context, speed and cache. The
conversation scrolls above it. C<line>: one status line at the cursor, no
footer. A terminal too small for the footer gets the line too. Set to 0 to
switch the status off.
Default: bar

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

=item B<AI_WORKSPACE>

The directory the file tools are confined to. Default: the directory ai.pl is
started in. C<none> for no limit.

=item B<AI_WORKSPACE_ALLOW>

More directories the file tools may use (space, comma or colon separated).

=item B<AI_SANDBOX>

The kernel sandbox for bash, perl and grep. C<auto> (default): used when the
kernel has Landlock. C<on>: those tools fail when it has not. C<off>: not
used.

=item B<AI_SANDBOX_WRITE>

More paths, files or directories, the sandboxed tools may write to, e.g.
C</dev/ttyACM0 /sys /proc>.

=item B<AI_SANDBOX_READ>

Limit what the sandboxed tools can read and execute: C<system> for the system
directories, the workspace and the temp directory, or a list of more paths on
top of those. Default: everything can be read.

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

File for the debug log. Without it debug messages go to stderr. Errors always
go to stderr (and to this file): stdout is only the conversation.

=item B<AI_UID>, B<AI_GID>, B<AI_GROUPS>

Only when started as root (in a container): the user id, group id and
supplementary group ids to run as. B<UID> and B<GID> are used when B<AI_UID>
and B<AI_GID> are not set, 1000 when nothing is. Without B<AI_GROUPS> the
supplementary groups of the process are kept (docker C<--group-add>). ai.pl
never runs as root: 0 is not accepted. The base directory is given to that
user.

=item B<DEBUG>

Enable or disable debug mode.

=item B<AI_PROXY>

Proxy for the requests to the LLM API (e.g. http://proxy:8080,
socks5h://proxy:1080). C<none> for no proxy.

=item B<AI_WEB_PROXY>

Proxy for the B<fetch> tool. C<none> for no proxy.

=item B<HTTPS_PROXY>, B<HTTP_PROXY>

Used for both when B<AI_PROXY> or B<AI_WEB_PROXY> is not set.

=item B<NO_PROXY>

Hosts that are reached without a proxy.

=item B<AI_SEARXNG_URL>

URL of the SearXNG instance for the B<search> tool, e.g. http://searx:8888

=item B<AI_SEARXNG_PROXY>

Proxy to reach the SearXNG instance. Default: none.

=item B<AI_SEARCH_RESULTS>

Number of results of a search. Default: 8

=item B<AI_WEB_TIMEOUT>, B<AI_WEB_MAX_SIZE>

Seconds a web request may take, and the number of bytes after which a page is
cut. Default: 30, 2000000

=item B<AI_WEB_USER_AGENT>, B<AI_WEB_LANGUAGE>

User-Agent and Accept-Language headers of B<fetch>.

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
