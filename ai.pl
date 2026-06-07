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
        load_cpan("FindBin")->again();
        load_cpan("Pod::Usage")->pod2usage(2);
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

__END__

=head1 NAME

ai.pl - AI Chat CLI

=head1 SYNOPSIS

ai.pl [options]

 Options:
   -help            brief help message
   -debug           enable debug mode

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-debug>

Enable debug mode.

=back

=head1 DESCRIPTION

B<ai.pl> is a command-line interface for interacting with an AI chat model.

=head1 COMMANDS

=over 8

=item B</exit> or B</quit>

Exit the chat.

=item B</clear>

Clear the chat status file.

=item B</history>

Show the chat history.

=item B</help>

Show the list of available commands.

=item B</debug>

Enable debug mode.

=item B</nodebug>

Disable debug mode.

=item B</system>

Send a system message to the chat.

=item B</chdir>

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

=item B</model>

Manage AI models for the current model
  /model              - Show current model
  /model <model_name> - Set model for this model

=back

=head1 SUPPORTED PROVIDERS

The following providers are supported:

=over 8

=item B<Cerebras>

API key prefix: C<csk->

=item B<OpenRouter>

API key prefix: C<sk-or->

=item B<OpenAI>

API key prefix: C<sk-> (standard OpenAI keys)

=item B<Groq>

API key prefix: C<gsk_->

=item B Anthropic>

API key prefix: C<sk-ant->

=item B<AWS Bedrock>

Use AWS credentials for authentication.

=item B<Lemonade (ROCm)>

Local LLM server for AMD ROCm GPUs. Default URL: C<http://localhost:8000/v1>

=back

Providers can be auto-detected from API key prefixes, or explicitly set via the B<AI_PROVIDER>
environment variable.

=head1 ENVIRONMENT VARIABLES

=over 8

=item B<AI_DIR>

Base directory for AI configuration and data files.

=item B<AI_CONFIG>

Path to the AI configuration file.

=item B<DEBUG>

Enable or disable debug mode.

=item B<AI_SESSION>

Prompt string for the AI chat.

=item B<AI_API_KEY>

API key for accessing the AI API.

=item B<AI_MODEL>

Model name for the AI chat.

=item B<AI_TOKENS>

Maximum number of tokens for the AI chat completion.

=item B<AI_TEMPERATURE>

Temperature setting for the AI chat completion.

=item B<AI_CLEAR>

Clear the chat status file if set.

=item B<AI_PROVIDER>

Specify the AI provider to use. Options: cerebras, openrouter, openai, groq, anthropic, bedrock, lemonade.
If not specified, will be auto-detected from API key prefix.

=item B<AI_LOCAL_SERVER>

URL for a local llama.cpp server (overrides provider settings).

=item B<AI_PROXY>

Proxy URL for HTTP/HTTPS requests (e.g., http://proxy:8080).

=item B<HTTPS_PROXY>

Fallback proxy URL if AI_PROXY not set.

=item B<HTTP_PROXY>

Fallback proxy URL if AI_PROXY and HTTPS_PROXY not set.

=back

=cut
