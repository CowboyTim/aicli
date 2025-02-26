#!/usr/bin/perl
#
use strict;
use warnings;

use FindBin;

# don't leak ENV to other forks, clear $0 asap: clears envp
my $orig_dollar0;
my %ORIG_ENV;
BEGIN {
    %ORIG_ENV = %ENV;
    %ENV = ();
    $orig_dollar0 = $0;
    $0 = "aicli";
}

use JSON;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use Fatal qw(open close rename mkdir);
use Getopt::Long;

# Constants
my $DEBUG = $ORIG_ENV{DEBUG} // 0;
my $BASE_DIR = $ORIG_ENV{AI_DIR} // (glob('~/.aicli'))[0];
mkdir $BASE_DIR
    unless -d $BASE_DIR;
my $CONFIG_FILE = $ORIG_ENV{AI_CONFIG} // "$BASE_DIR/config";
my $AI_PROMPT = $ORIG_ENV{AI_PROMPT} // $ORIG_ENV{AI_PROMPT_DEFAULT} // 'default';
mkdir "$BASE_DIR/$AI_PROMPT"
    unless -d "$BASE_DIR/$AI_PROMPT";
my $HISTORY_FILE = "$BASE_DIR/$AI_PROMPT/history";
my $PROMPT_FILE = "$BASE_DIR/$AI_PROMPT/prompt";
my $STATUS_FILE = "$BASE_DIR/$AI_PROMPT/chat";

# Variables
my ($json, $cerebras_api_key);

# Command-line options
my $help;
GetOptions(
    'help|?' => \$help,
    'debug'  => \$DEBUG,
) or show_usage();

show_usage() if $help;

# Main execution
ai_setup();
ai_chat();
exit 0;

sub show_usage {
    local $ENV{PAGER} = $ENV{PAGER} // 'less';
    local $0 = $orig_dollar0;
    load_cpan("FindBin")->again();
    load_cpan("Pod::Usage")->pod2usage(2);
    exit 0;
}

sub load_cpan {
    my ($module) = @_;
    eval "require $module";
    die $@ if $@;
    return $module;
}

sub ai_setup {
    $json //= JSON->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;
    if(!defined $ORIG_ENV{AI_CEREBRAS_API_KEY}) {
        if (!-f $CONFIG_FILE) {
            print "Please set AI_DIR/AI_CONFIG/AI_CEREBRAS_API_KEY environment variable or set $BASE_DIR/config\n";
            exit 1;
        } else {
            open(my $fh, ". $CONFIG_FILE; set|");
            my %envs = map { chomp; split m/=/, $_, 2 } grep m/^AI_/, <$fh>;
            while (my ($key, $value) = each %envs) {
                $ORIG_ENV{$key} = $value =~ s/^['"]//r =~ s/['"]$//r;
            }
            close $fh;
        }
    }
    $cerebras_api_key = $ORIG_ENV{AI_CEREBRAS_API_KEY};
    if (!$cerebras_api_key) {
        print "Please set AI_CEREBRAS_API_KEY environment variable or set $BASE_DIR/config\n";
        exit 1;
    }
    my $prompt;
    if(!-s $PROMPT_FILE and open(my $fh, '<', "$FindBin::Bin/ai/$AI_PROMPT")){
        local $/;
        $prompt = <$fh>;
        close($fh);
        open(my $pfh, '>', $PROMPT_FILE);
        print {$pfh} $prompt;
        close $pfh;
    }
    if(!-s $STATUS_FILE or ($ORIG_ENV{AI_CLEAR}//0)){
        if(not defined $prompt and open(my $fh, '<', $PROMPT_FILE)){
            local $/;
            $prompt = <$fh>;
            close($fh);
        }
        open(my $fh, '>', $STATUS_FILE);
        print {$fh} $json->encode({ role => 'system', content => $prompt }) . "\n";
        close $fh;
    }
    return;
}

sub ai_log {
    my ($message) = @_;
    return unless $DEBUG;
    my $LOG_FILE = $ORIG_ENV{AI_LOG} // "&STDOUT";
    open(my $lfh, ">>$LOG_FILE");
    print {$lfh} "INFO: [$$]: ".scalar(localtime()) . ": $message\n";
    close $lfh;
    return;
}

sub ai_chat_completion {
    my ($input) = @_;
    ai_log("User input: $input");
    open(my $sfh, '>>', $STATUS_FILE);
    print {$sfh} $json->encode({ role => 'user', content => $input }) . "\n";
    close $sfh;
    my @jstr = do { open(my $fh, '<', $STATUS_FILE); map { chomp; JSON::decode_json($_) } <$fh> };
    my $req = {
        model       => $ORIG_ENV{AI_MODEL}  // 'llama-3.3-70b',
        max_tokens  => $ORIG_ENV{AI_TOKENS} // 8192,
        stream      => JSON::false(),
        messages    => \@jstr,
        temperature => $ORIG_ENV{AI_TEMPERATURE} // 0,
        top_p       => 1
    };
    print $json->encode($req) . "\n" if $DEBUG;
    my $ua = LWP::UserAgent->new();
    print "Requesting completion from Cerebras AI API... $cerebras_api_key\n" if $DEBUG;
    my $http_req = POST('https://api.cerebras.ai/v1/chat/completions',
        'User-Agent'    => 'Cerebras AI Chat/0.1',
        'Accept'        => 'application/json',
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer $cerebras_api_key",
        'Content'       => $json->encode($req),
    );
    print $http_req->as_string() if $DEBUG;
    my $response = $ua->request($http_req);
    if (!$response->is_success()) {
        ai_log("Error: " . $response->status_line());
        print $response->status_line() . "\n";
        return;
    }
    print $response->decoded_content() if $DEBUG;
    my $resp = JSON::decode_json($response->decoded_content())->{choices}[0]{message}{content};
    if (!$resp) {
        print "Error: Failed to parse response\n";
        return;
    }
    print "$resp\n";
    ai_log("AI response: $resp");
    open($sfh, '>>', $STATUS_FILE);
    print {$sfh} $json->encode({ role => 'assistant', content => $resp }) . "\n";
    close $sfh;
    return;
}

sub ai_chat_word_completions_cli {
    my ($text, $line, $start, $end) = @_;
    $line =~ s/ +$//g;
    my @rcs = ();
    my @wrd = split m/\s+/, $line, -1;
    print STDERR "W: >" . join(", ", @wrd) . "<\n" if $DEBUG;
    foreach my $w (@wrd) {
        next unless $w =~ m|^/|;
        foreach my $k (qw(/exit /quit /clear /history /help /debug /nodebug /system)) {
            push @rcs, $k if !index($k, $w) or $k eq $w;
        }
    }
    print STDERR "R: >" . join(", ", @rcs) . "<\n" if $DEBUG;
    return '', @rcs;
}

sub ai_setup_readline {
    local $ENV{PERL_RL} = 'Gnu';
    local $ENV{TERM}    = $ORIG_ENV{TERM} // 'vt220';
    eval {require Term::ReadLine};
    die $@ if $@;
    my $term = Term::ReadLine->new("aicli");
    $term->ReadLine('Term::ReadLine::Gnu') eq 'Term::ReadLine::Gnu'
        or die "Term::ReadLine::Gnu is required\n";
    $term->enableUTF8();
    $term->using_history();
    $term->ReadHistory($HISTORY_FILE);
    $term->clear_signals();
    my $attribs = $term->Attribs();
    $attribs->{attempted_completion_function} = \&ai_chat_word_completions_cli;
    $attribs->{ignore_completion_duplicates}  = 1;
    return ($term, $attribs);
}

sub ai_chat {
    my ($term, $attribs) = ai_setup_readline();
    while (1) {
        my $line = $term->readline("|$AI_PROMPT|> ");
        last unless defined $line;
        next if $line =~ m/^\s*$/;
        ai_log("Command: $line");
        if ($line =~ m|^/system|) {
            $line =~ s|^/system||;
            rename($PROMPT_FILE, $PROMPT_FILE . '.bak.' . time()) if -f $PROMPT_FILE;
            open(my $pfh, '>', $PROMPT_FILE);
            print {$pfh} $line;
            close $pfh;
            open(my $sfh, '>', $STATUS_FILE);
            print {$sfh} $json->encode({ role => 'system', content => $line }) . "\n";
            close $sfh;
            next;
        }
        if ($line =~ m|^/exit| or $line =~ m|^/quit|) {
            last;
        }
        if ($line =~ m|^/clear|) {
            my $prompt = -f $PROMPT_FILE ? do { open(my $fh, '<', $PROMPT_FILE); local $/; <$fh> } : '';
            open(my $fh, '>', $STATUS_FILE);
            print {$fh} $json->encode({ role => 'system', content => $prompt }) . "\n";
            close $fh;
            next;
        }
        if ($line =~ m|^/history|) {
            print do { open(my $_hfh, '<', $HISTORY_FILE); local $/; <$_hfh> };
            next;
        }
        if ($line =~ m|^/debug|) {
            $DEBUG = 1;
            next;
        }
        if ($line =~ m|^/nodebug|) {
            $DEBUG = 0;
            next;
        }
        if ($line =~ m|^/help|) {
            print "/exit, /quit, /clear, /history, /help, /debug, /nodebug, /system\n";
            next;
        }
        ai_chat_completion($line);
    }
    $term->WriteHistory($HISTORY_FILE);
    return;
}

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

=head1 ENVIRONMENT VARIABLES

=over 8

=item B<AI_DIR>

Base directory for AI configuration and data files.

=item B<AI_CONFIG>

Path to the AI configuration file.

=item B<DEBUG>

Enable or disable debug mode.

=item B<AI_PROMPT>

Prompt string for the AI chat.

=item B<AI_CEREBRAS_API_KEY>

API key for accessing the Cerebras AI API.

=item B<AI_MODEL>

Model name for the AI chat.

=item B<AI_TOKENS>

Maximum number of tokens for the AI chat completion.

=item B<AI_TEMPERATURE>

Temperature setting for the AI chat completion.

=item B<AI_CLEAR>

Clear the chat status file if set.

=back

=cut
