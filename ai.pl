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
    my $help;
    if(!Getopt::Long::GetOptions(
        'help|?' => \$help,
        'debug'  => \$::DEBUG,
    ) or $help){
        local $ENV{PAGER} = $::ORIG_ENV{PAGER} // 'less';
        local $0 = $orig_dollar0;
        require Pod::Usage;
        Pod::Usage::pod2usage(-input => "$FindBin::Bin/ai.pl", -verbose => 1, -exitval => 'NOEXIT', -output => \*STDOUT);
        exit 0;
    }
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

 Examples:
   AI_API_KEY=csk-... ai.pl
   AI_LOCAL_SERVER=http://localhost:8080 AI_PROMPT_TEMPLATE=coder ai.pl
   echo "what is in this directory?" | AI_SESSION=demo ai.pl

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-debug>

Enable debug mode.

=back

=head1 DESCRIPTION

B<ai.pl> is an interactive chat with an LLM that can act: the model can run
tools (bash, perl, read, write, grep) and gets the results back, in a loop,
until it has an answer. Thinking of the model is shown while it streams in, in
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

=item B<bash>

The script is written to a temp file, a forked child process exec()s bash on it.

=item B<perl>

The code is eval()ed in a forked child process. With B<AI_PERL_SAFE> it runs
in a L<Safe> compartment instead.

=item B<read>, B<write>

Read a file, write or overwrite a file.

=item B<grep>

A forked child exec()s C<grep -rn>, without a shell.

=back

Forked tool processes run in their own session with stdin from /dev/null,
stdout and stderr captured, and a minimal environment: none of the B<AI_*>
variables (so not the API key) are passed on. They are stopped at
B<AI_TOOL_TIMEOUT> and on ctrl-C. There is no confirmation before a tool runs:
use the docker wrapper (B<aicli.sh>) as the sandbox.

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
line), C<prompt> and C<template> (system prompt), C<model>, C<history> (input
history).

=back

=cut
