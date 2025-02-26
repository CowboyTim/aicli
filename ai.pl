#!/usr/bin/perl

use strict;
use warnings;

use JSON;
use LWP::UserAgent;
use Term::ReadLine;
use HTTP::Request::Common qw(POST);
use Fatal qw(open close rename);

# Constants
my $BASE_DIR = $ENV{AI_DIR} // (glob('~/'))[0];
my $CONFIG_FILE = $ENV{AI_CONFIG} // "$BASE_DIR/.airc";
my $DEBUG = $ENV{DEBUG} // 0;
my $AI_PROMPT = $ENV{AI_PROMPT} || 'default';
my $HISTORY_FILE = "$BASE_DIR/.ai_history_${AI_PROMPT}";
my $PROMPT_FILE = "$BASE_DIR/.ai_prompt_${AI_PROMPT}";
my $STATUS_FILE = "$BASE_DIR/.ai_chat_status_${AI_PROMPT}";

# Variables
my ($json, $cerebras_api_key);

# Main execution
ai_setup();
ai_chat();
exit 0;

sub ai_setup {
    $json //= JSON->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;
    if (!-f $CONFIG_FILE) {
        print "Please set AI_DIR/AI_CONFIG environment variable or set $BASE_DIR/.airc\n";
        exit 1;
    } else {
        open(my $fh, ". $CONFIG_FILE; set|");
        my %envs = map { chomp; split m/=/, $_, 2 } grep m/^AI_/, <$fh>;
        while (my ($key, $value) = each %envs) {
            $ENV{$key} = $value =~ s/^['"]//r =~ s/['"]$//r;
        }
        close $fh;
    }
    $cerebras_api_key = $ENV{AI_CEREBRAS_API_KEY};
    if (!$cerebras_api_key) {
        print "Please set AI_CEREBRAS_API_KEY environment variable\n";
        exit 1;
    }
    if (!-s $STATUS_FILE or ($ENV{AI_CLEAR} // 0)) {
        my $prompt = -f $PROMPT_FILE ? do { open(my $fh, '<', $PROMPT_FILE); local $/; <$fh> } : '';
        open(my $fh, '>', $STATUS_FILE);
        print {$fh} $json->encode({ role => 'system', content => $prompt }) . "\n";
        close $fh;
    }
    return;
}

sub ai_chat_completion {
    my ($input) = @_;
    open(my $sfh, '>>', $STATUS_FILE);
    print {$sfh} $json->encode({ role => 'user', content => $input }) . "\n";
    close $sfh;
    my @jstr = do { open(my $fh, '<', $STATUS_FILE); map { chomp; JSON::decode_json($_) } <$fh> };
    my $req = {
        model       => $ENV{AI_MODEL}  // 'llama-3.3-70b',
        max_tokens  => $ENV{AI_TOKENS} // 8192,
        stream      => JSON::false(),
        messages    => \@jstr,
        temperature => $ENV{AI_TEMPERATURE} // 0,
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

sub ai_chat {
    my $term = Term::ReadLine->new('AI');
    $term->enableUTF8();
    $term->using_history();
    $term->ReadHistory($HISTORY_FILE);
    $term->clear_signals();
    my $attribs = $term->Attribs();
    $attribs->{attempted_completion_function} = \&ai_chat_word_completions_cli;
    $attribs->{ignore_completion_duplicates}  = 1;
    while (1) {
        my $line = $term->readline("|$AI_PROMPT|> ");
        last unless defined $line;
        next if $line =~ m/^\s*$/;
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
