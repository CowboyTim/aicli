#!/usr/bin/perl

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

use Getopt::Long;
use Socket;
use Cwd qw();
use Encode qw(_utf8_on _utf8_off);

# Constants
my $DEBUG = $ORIG_ENV{DEBUG} // 0;
my $BASE_DIR = $ORIG_ENV{AI_DIR} // (glob('~/.aicli'))[0];
-d "$BASE_DIR"
    or mkdir $BASE_DIR
    or die "Failed to create $BASE_DIR: $!\n";
my $CONFIG_FILE = $ORIG_ENV{AI_CONFIG} // "$BASE_DIR/config";
my $AI_PROMPT = $ORIG_ENV{AI_SESSION} // $ORIG_ENV{AI_PROMPT} // $ORIG_ENV{AI_PROMPT_DEFAULT};
if (!$AI_PROMPT) {
    # Generate a UUID for default session
    eval 'use Data::UUID';
    if ($@) {
        print STDERR "Please install Data::UUID module to generate UUIDs\n";
        exit 1;
    }
    my $ug = new Data::UUID;
    $AI_PROMPT = "session-" . $ug->create_str();
}
-d "$BASE_DIR/$AI_PROMPT"
    or mkdir "$BASE_DIR/$AI_PROMPT"
    or die "Failed to create $BASE_DIR/$AI_PROMPT: $!\n";
my $HISTORY_FILE = "$BASE_DIR/$AI_PROMPT/history";
my $PROMPT_FILE = "$BASE_DIR/$AI_PROMPT/prompt";
my $STATUS_FILE = "$BASE_DIR/$AI_PROMPT/chat";

# Variables
my ($json, $api_key, $curl_handle, $ai_endpoint_url);

# Command-line options
my $help;
GetOptions(
    'help|?' => \$help,
    'debug'  => \$DEBUG,
) or show_usage();

show_usage() if $help;

our @cmds = qw(/exit /quit /clear /history /help /debug /nodebug /system /files /chdir /ls /pwd /session);

# Main execution
chat_setup();
chat_loop();
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

sub chat_setup {
    $json //= eval {require JSON::XS; JSON::XS->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed};
    $json // die "Please install the JSON cpan module:\n\nE.g.:\n  sudo apt install libjson-xs-perl\n\n";
    if(!defined $ORIG_ENV{AI_API_KEY}) {
        if (!-f $CONFIG_FILE) {
            print STDERR "Please set AI_DIR/AI_CONFIG/AI_API_KEY environment variable or set $BASE_DIR/config\n";
            exit 1;
        } else {
            open(my $fh, ". $CONFIG_FILE; set|")
                or die "Failed to read $CONFIG_FILE: $!\n";
            my %envs = map { chomp; split m/=/, $_, 2 } grep m/^AI_/, <$fh>;
            while (my ($key, $value) = each %envs) {
                $ORIG_ENV{$key} = $value =~ s/^['"]//r =~ s/['"]$//r;
            }
            close $fh;
        }
    }
    $api_key = $ORIG_ENV{AI_API_KEY};
    if (!$api_key) {
        print STDERR "Please set AI_API_KEY environment variable or set $BASE_DIR/config\n";
        exit 1;
    }
    if($api_key =~ m/^csk-/){
        $ai_endpoint_url = "https://api.cerebras.ai";
    }
    if($api_key =~ m/^sk-or/){
        $ai_endpoint_url = "https://openrouter.ai/api";
    }
    if((!-s $PROMPT_FILE or ($ORIG_ENV{AI_CLEAR}//0)) and open(my $fh, '<', "$FindBin::Bin/ai/$AI_PROMPT")){
        local $/;
        my $prompt = <$fh>;
        close($fh);
        open(my $pfh, '>', $PROMPT_FILE)
            or die "Failed to write to $PROMPT_FILE: $!\n";
        print {$pfh} $prompt;
        close $pfh or die "Failed to close $PROMPT_FILE: $!\n";
    }
    if(!-s $STATUS_FILE or ($ORIG_ENV{AI_CLEAR}//0)){
        my $prompt;
        if(open(my $fh, '<', $PROMPT_FILE)){
            local $/;
            $prompt = <$fh>;
            close($fh);
        }
        open(my $fh, '>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$fh} $json->encode({ role => 'system', content => ($prompt // "") })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
    }
    return;
}

sub log_info {
    my ($message) = @_;
    return unless $DEBUG;
    my $LOG_FILE = $ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "INFO: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close $LOG_FILE: $!\n";
    return;
}

sub chat_completion {
    my ($input) = @_;
    log_info("User input: $input");
    open(my $sfh, '>>', $STATUS_FILE) or die "Failed to write to $STATUS_FILE: $!\n";
    print {$sfh} $json->encode({role => 'user', content => $input})."\n";
    close $sfh or die "Failed to close $STATUS_FILE: $!\n";
    my @jstr = do {
        open(my $fh, '<', $STATUS_FILE) or die "Failed to read $STATUS_FILE: $!\n";
        map {chomp; JSON::XS::decode_json($_)} <$fh>
    };
    my $req = {
        model       => $ORIG_ENV{AI_MODEL}  // 'llama-4-scout-17b-16e-instruct',
        max_tokens  => $ORIG_ENV{AI_TOKENS} // 8192,
        stream      => JSON::XS::false(),
        messages    => \@jstr,
        temperature => $ORIG_ENV{AI_TEMPERATURE} // 0,
        top_p       => 1
    };
    if($ai_endpoint_url eq "https://openrouter.ai/api"){
        $req->{provider} = {"only" => ["Cerebras"]};
    }
    print STDERR $json->encode($req)."\n" if $DEBUG;
    print STDERR "Requesting completion from AI API $ai_endpoint_url with $api_key\n" if $DEBUG;
    my $response = http("post", "v1/chat/completions", $json->encode($req));
    my $resp = JSON::XS::decode_json($response)->{choices}[0]{message}{content};
    if (!$resp) {
        print "Error: Failed to parse response\n";
        return;
    }
    _utf8_off($resp);
    print "$resp\n";
    log_info("AI response: $resp");
    open($sfh, '>>', $STATUS_FILE) or die "Failed to write to $STATUS_FILE: $!\n";
    print {$sfh} $json->encode({ role => 'assistant', content => $resp })."\n";
    close $sfh or die "Failed to close $STATUS_FILE: $!\n";
    return;
}

sub list_models {
    my $response = http("get", "v1/chat/models");
    my $resp = JSON::XS::decode_json($response)->{choices}[0]{message}{content};
    if (!$resp) {
        print "Error: Failed to parse response\n";
        return;
    }
    return;
}

sub chat_word_completions_cli {
    my ($text, $line, $start, $end) = @_;
    $line =~ s/ +$//g;
    my @rcs = ();
    my @wrd = split m/\s+/, $line, -1;
    print STDERR "W: >".join(", ", @wrd)."<\n" if $DEBUG;
    foreach my $w (@wrd) {
        next unless $w =~ m|^/|;
        foreach my $k (@cmds) {
            push @rcs, $k if !index($k, $w) or $k eq $w;
        }
    }
    print STDERR "R: >".join(", ", @rcs)."<\n" if $DEBUG;
    return '', @rcs;
}

sub setup_readline {
    local $ENV{PERL_RL} = 'Gnu';
    local $ENV{TERM}    = $ORIG_ENV{TERM} // 'vt220';
    eval {require Term::ReadLine; require Term::ReadLine::Gnu};
    if($@){
        print STDERR "Please install Term::ReadLine and Term::ReadLine::Gnu\n\nE.g.:\n  sudo apt install libterm-readline-gnu-perl\n";
        exit 1;
    }
    my $term = Term::ReadLine->new("aicli");
    $term->read_init_file("$BASE_DIR/inputrc");
    $term->ReadLine('Term::ReadLine::Gnu') eq 'Term::ReadLine::Gnu'
        or die "Term::ReadLine::Gnu is required\n";
    $term->enableUTF8();
    $term->using_history();
    $term->ReadHistory($HISTORY_FILE);
    $term->clear_signals();
    my $attribs = $term->Attribs();
    $attribs->{attempted_completion_function} = \&chat_word_completions_cli;
    $attribs->{ignore_completion_duplicates}  = 1;
    return ($term, $attribs);
}

sub get_chat_prompt {
    # https://jafrog.com/2013/11/23/colors-in-terminal.html
    # https://ss64.com/bash/syntax-colors.html
    my $prompt_term1  =
           $ORIG_ENV{AI_PS1}
        //   $colors::reset_color
            .$colors::blue_color3
            .'❲$AI_PROMPT❳ ► '
            .$colors::reset_color;
    my $prompt_term2  =
           $ORIG_ENV{AI_PS2}
        //   $colors::reset_color
            .$colors::blue_color3
            .'│ '
            .$colors::reset_color;
    my $ps1 = eval "return \"$prompt_term1\"" || '► ';
    my $ps2 = eval "return \"$prompt_term2\"" || '│ ';
    return ($ps1, $ps2);
}

sub input_terminal {
    my ($term, $attribs) = setup_readline();
    my ($t_ps1, $t_ps2) = get_chat_prompt();
    return sub {
        my $t_prt = $t_ps1;
        my $buf = '';
      READ_AGAIN:
        my $line = $term->readline($t_prt);
        return unless defined $line;
        if($line !~ m/^$/ms){
            if(!length($buf)){
                my $r_val = handle_command($line);
                if(defined $r_val){
                    if($r_val == 1){
                        $term->WriteHistory($HISTORY_FILE);
                        return;
                    } else {
                        goto READ_AGAIN;
                    }
                }
            }
            $buf .= "$line\n";
            $t_prt = $t_ps2;
            goto READ_AGAIN;
        } else {
            if(length($buf)){
                log_info("BUF: >>$buf<<");
                $term->addhistory($buf);
                $term->WriteHistory($HISTORY_FILE);
                chomp $buf;
                return $buf;
            } else {
                goto READ_AGAIN;
            }
        }
        return;
    };
}

sub input_stdin {
    return sub {
        # always slurp stdin
        local $/;
        return scalar <STDIN>;
    };
}

sub chat_loop {
    my $input_cli_sub = -t STDIN ? input_terminal() : input_stdin();
    while(1){
        my $chat_request = &{$input_cli_sub}();
        unless(defined $chat_request){
            print "\n";
            last;
        }
        next if $chat_request =~ m/^\s*$/;
        chat_completion($chat_request);
    }
    return;
}

sub handle_command {
    my ($line) = @_;
    log_info("Command: $line");
    if ($line =~ m|^/system|) {
        $line =~ s|^/system||;
        open(my $sfh, '>>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$sfh} $json->encode({ role => 'system', content => $line })."\n";
        close $sfh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    }
    if ($line =~ m|^/exit| or $line =~ m|^/quit|) {
        return 1;
    }
    if ($line =~ m|^/clear|) {
        my $prompt = -f $PROMPT_FILE ? do {
            open(my $fh, '<', $PROMPT_FILE)
                or die "Failed to read $PROMPT_FILE: $!\n";
            local $/; <$fh>
        }:'';
        open(my $fh, '>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$fh} $json->encode({ role => 'system', content => ($prompt // "") })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    }
    if ($line =~ m|^/history|) {
        print do {open(my $_hfh, '<', $HISTORY_FILE) or die "Failed to read $HISTORY_FILE: $!\n"; local $/; <$_hfh>};
        return 0;
    }
    if ($line =~ m|^/debug|) {
        $DEBUG = 1;
        return 0;
    }
    if ($line =~ m|^/nodebug|) {
        $DEBUG = 0;
        return 0;
    }
    if ($line =~ m|^/help|) {
        print join(", ", @cmds)."\n";
        return 0;
    }
    if ($line =~ m|^/chdir|) {
        $line =~ s|^/chdir||;
        $line =~ s| +$||;
        $line =~ s|^\s+||;
        if(chdir($line)){
            return 0;
        } else {
            print "Failed to change directory to $line: $!\n";
            return 0;
        }
    }
    if ($line =~ m|^/ls|) {
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                print "$file\n";
            }
            closedir $dh;
        }
        return 0;
    }
    if ($line =~ m|^/pwd|) {
        print Cwd::cwd()."\n";
        return 0;
    }
    if ($line =~ m|^/session|) {
        if($line =~ m|^/session\s+list$|){
            my @sessions = glob("$BASE_DIR/*");
            @sessions = map { $_ =~ s/.*\///; $_ } grep { -d $_ } @sessions;
            print join("\n", sort @sessions)."\n";
        } elsif($line =~ m|^/session\s+(\w+)$|){
            my $new_prompt = $1;
            if(-d "$BASE_DIR/$new_prompt"){
                $ENV{AI_PROMPT} = $new_prompt;
                $AI_PROMPT = $new_prompt;
                $HISTORY_FILE = "$BASE_DIR/$AI_PROMPT/history";
                $PROMPT_FILE = "$BASE_DIR/$AI_PROMPT/prompt";
                $STATUS_FILE = "$BASE_DIR/$AI_PROMPT/chat";
                print "Switched to session: $new_prompt\n";
            } else {
                print "Session '$new_prompt' does not exist.\n";
            }
        } else {
            print "Usage:\n  /session list    - List all sessions\n  /session <name>  - Switch to a session\n";
        }
        return 0;
    }
    if ($line =~ m|^/files|) {
        # slurp the directory and add the contents of the files to the chat
        my $dir_rx = $line;
        $dir_rx =~ s|^/files||;
        $dir_rx =~ s| +$||;
        $dir_rx =~ s|^\s+||;
        $dir_rx = qr/$dir_rx/;
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            my $ignore_list = do {
                local $/;
                open(my $_ifh, '<', '.aiignore') or return '';
                <$_ifh>;
            };
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                next unless -f $file;
                next if $file !~ m/$dir_rx/;
                next if grep {$file eq $_} map {glob($_)} split m/\n/, $ignore_list;
                my $data = do {
                    my $_ffh;
                    local $/;
                    open($_ffh, '<', $file) and <$_ffh>;
                };
                next unless length($data//"");
                $data = '```'."\n".$data."\n".'```'."\n";
                open(my $sfh, '>>', $STATUS_FILE)
                    or next;
                print {$sfh} $json->encode({role => 'user', content => $data})."\n";
                close $sfh;
                print "${colors::green_color}✓${colors::reset_color} added $file to chat\n";
            }
            closedir $dh;
        }
        return 0;
    }
    if ($line =~ m|^/|) {
        print "Unknown command: $line\n";
        return 0;
    }
    return;
}

sub http {
    my ($m, $url, $data) = @_;
    $url = "$ai_endpoint_url/$url";
    eval {
        require WWW::Curl::Easy;
    };
    if($@){
        print STDERR "Please install WWW::Curl::Easy\n\nE.g.:\n  sudo apt install libwww-curl-perl\n";
        exit 1;
    }
    $data //= "";
    print STDERR "URL: $url\n"   if $DEBUG;
    print STDERR "DATA: $data\n" if $DEBUG;
    $curl_handle //= do {
        my $ch = WWW::Curl::Easy->new();
        $ch->setopt(WWW::Curl::Easy::CURLOPT_URL(), $url);
        $ch->setopt(WWW::Curl::Easy::CURLOPT_IPRESOLVE(), WWW::Curl::Easy::CURL_IPRESOLVE_V6());
        $ch->setopt(WWW::Curl::Easy::CURLOPT_WRITEFUNCTION(), sub {
            my ($chunk, $u_ref) = @_;
            $$u_ref .= $chunk;
            return length($chunk);
        });
        $ch->setopt(WWW::Curl::Easy::CURLOPT_POST(), 1);
        $ch->setopt(WWW::Curl::Easy::CURLOPT_VERBOSE(), $DEBUG?1:0);
        $ch->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(), [
            "Accept: application/json",
            "Content-Type: application/json",
            "User-Agent: AI Chat/0.1",
            "Connection: Keep-Alive",
            "Keep-Alive: max=100",
            "Authorization: Bearer $api_key",
        ]);
        $ch;
    };
    my $resp = "";
    $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_WRITEDATA(), \$resp);
    if(lc($m) eq "post"){
        if(length($data)){
            $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDS(), $data);
            $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDSIZE_LARGE(), length($data));
        }
    }
    if(lc($m) eq "get"){
    }
    $curl_handle->perform();
    my $r_code = $curl_handle->getinfo(WWW::Curl::Easy::CURLINFO_HTTP_CODE());
    if($r_code != 200){
        die "ERROR: $r_code\n";
    }
    print STDERR "OK: $r_code\n"      if $DEBUG;
    print STDERR "RESPONSE:\n$resp\n" if $DEBUG;
    return $resp;
}

BEGIN {
package colors;

our $red_color     = "\033[0;31m";
our $green_color   = "\033[0;32m";
our $yellow_color1 = "\033[0;33m";
our $blue_color1   = "\033[0;34m";
our $blue_color2   = "\033[38;5;25;1m";
our $blue_color3   = "\033[38;5;13;1m";
our $magenta_color = "\033[0;35m";
our $cyan_color    = "\033[0;36m";
our $white_color   = "\033[0;37m";
our $reset_color   = "\033[0m";
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

=item B</files>

Add the contents of files matching a pattern to the chat.

=back

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

=back

=cut
