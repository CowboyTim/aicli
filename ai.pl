#!/usr/bin/perl

use strict; use warnings;

use LWP::UserAgent;
use Term::ReadLine;
use Fatal qw(open close);

my ($json, $history_file, $prompt_file, $status_file, $debug, $cerebras_api_key);
do_setup();
crbrs_chat();
exit 0;

sub do_setup {
    require JSON;
    $json //= JSON->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;

    my $base_dir    = $ENV{AI_DIR}    // (glob('~/'))[0];
    my $config_file = $ENV{AI_CONFIG} // "$base_dir/.airc";
    $debug = $ENV{DEBUG} // 0;

    my $ai_prompt = $ENV{AI_PROMPT} || 'default';
    $history_file = "$base_dir/.ai_history_${ai_prompt}";
    $prompt_file  = "$base_dir/.ai_prompt_${ai_prompt}";
    $status_file  = "$base_dir/.ai_chat_status_${ai_prompt}";

    if(!-f $config_file){
        print "Please set AI_CONFIG environment variable or set $base_dir/.airc\n";
        exit 1;
    } else {
        open(my $fh, ". $config_file; set|");
        my %envs = map {chomp; split m/=/, $_, 2} grep m/^AI_/, <$fh>;
        while (my ($key, $value) = each %envs){
            $ENV{$key} = $value =~ s/^['"]//r =~ s/['"]$//r;
        }
        close $fh;
    }
    $cerebras_api_key = $ENV{AI_CEREBRAS_API_KEY};
    if(!$cerebras_api_key){
        print "Please set AI_CEREBRAS_API_KEY environment variable\n";
        exit 1;
    }

    if(!-s $status_file || ($ENV{AI_CLEAR}//0)){
        if (-f $prompt_file) {
            my $prompt = do {open(my $fh, '<', $prompt_file); local $/; <$fh>};
            open(my $fh, '>', $status_file);
            print {$fh} $json->encode({role => 'system', content => $prompt})."\n";
            close $fh;
        } else {
            open(my $fh, '>', $status_file);
            print {$fh} $json->encode({role => 'system', content => ''})."\n";
            close $fh;
        }
    }
    return;
}

sub crbrs_chat_completion {
    my ($input) = @_;
    open(my $sfh, '>>', $status_file);
    print {$sfh} $json->encode({role => 'user', content => $input})."\n";
    close $sfh;
    my @jstr = do {open(my $fh, '<', $status_file); map {chomp; JSON::decode_json($_)} <$fh>};
    my $req = {
        model       => $ENV{AI_MODEL}  // 'llama-3.3-70b',
        max_tokens  => $ENV{AI_TOKENS} // 8192,
        stream      => JSON::false(),
        messages    => \@jstr,
        temperature => $ENV{AI_TEMPERATURE} // 0,
        top_p       => 1
    };
    print $json->encode($req)."\n" if $debug;
    my $ua = LWP::UserAgent->new();
    print "Requesting completion from Cerebras AI API... $cerebras_api_key\n" if $debug;
    use HTTP::Request::Common qw(POST);
    my $http_req = POST('https://api.cerebras.ai/v1/chat/completions',
        'User-Agent'    => 'Cerebras AI Chat/0.1',
        'Accept'        => 'application/json',
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer $cerebras_api_key",
        'Content' => $json->encode($req),
    );
    print $http_req->as_string() if $debug;
    my $response = $ua->request($http_req);
    if(!$response->is_success()){
        print $response->status_line()."\n";
        return;
    }
    if($debug == 1){
        print $response->decoded_content()
    }
    my $resp = JSON::decode_json($response->decoded_content())->{choices}[0]{message}{content};
    if(!$resp){
        print "Error: Failed to parse response\n";
        return;
    }
    print "$resp\n";
    open($sfh, '>>', $status_file);
    print {$sfh} $json->encode({role => 'assistant', content => $resp})."\n";
    close $sfh;
    return;
}

sub crbrs_chat {
    my $term = Term::ReadLine->new('Chat');
    my $history = $term->GetHistory;
    open(my $hfh, '>>', $history_file);
    print {$hfh} $history;
    while (1) {
        my $line = $term->readline('|chat|> ');
        if (!$line) {
            last;
        }
        if ($line =~ m|^/system|) {
            $line =~ s|^/system||;
            open(my $fh, '>', $status_file);
            print {$fh} $json->encode({role => 'system', content => $line})."\n";
            close $fh;
            next;
        }
        if ($line =~ m|^/exit| || $line =~ m|^/quit|) {
            last;
        }
        if ($line =~ m|^/clear|) {
            open(my $fh, '>', $status_file);
            print {$fh} $json->encode({role => 'system', content => ''});
            close $fh;
            next;
        }
        if ($line =~ m|^/history|) {
            print do {open(my $_hfh, '<', $history_file); local $/; <$_hfh>};
            next;
        }
        if ($line =~ m|^/debug|) {
            $debug = 1;
            next;
        }
        if ($line =~ m|^/nodebug|) {
            $debug = 0;
            next;
        }
        if ($line =~ m|^/help|) {
            print "/exit, /quit, /clear, /history, /help, /debug, /nodebug, /system\n";
            next;
        }
        crbrs_chat_completion($line);
    }
    print {$hfh} $term->GetHistory;
    close $hfh;
    return;
}
