package TestAI;
# helpers for the tests: a scratch AI_DIR, output capture, a scripted LLM

use strict; use warnings;

use FindBin;
use File::Temp ();
use JSON::XS ();

our $ROOT = "$FindBin::Bin/..";
our $TMP;
our @REQUESTS;   # what was "sent": {method, url, data, key}
our @SCRIPT;     # what the "LLM" answers, one entry per request

# fresh base dir + session, ai.pm set up like ai.pl does
sub setup {
    my (%env) = @_;
    $TMP = File::Temp::tempdir("aicli_t_XXXXXX", TMPDIR => 1, CLEANUP => 1);
    %::ORIG_ENV = (
        PATH            => $ENV{PATH},
        HOME            => $TMP,
        AI_DIR          => "$TMP/aicli",
        AI_CONFIG       => "$TMP/noconfig",
        AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/',
        AI_SESSION      => 'test',
        AI_PROMPT_TEMPLATE      => 'coder',
        AI_PROMPT_TEMPLATE_FILE => "$ROOT/ai/coder",
        AI_RETRIES      => 0, # tests that want retries or the usage line ask for it
        AI_SHOW_USAGE   => 0,
        %env,
    );
    $FindBin::Bin = $ROOT; # where ai.pm looks for the prompt templates
    mkdir "$TMP/aicli" or die $!;
    $::LOOP  = 1;
    $::ABORT = 0;
    ai::chat_setup("$TMP/aicli");
    return $TMP;
}

# run code, return what it printed on STDOUT+STDERR
sub capture(&) {
    my ($code) = @_;
    my $fn = "$TMP/capture.$$";
    STDOUT->flush(); STDERR->flush();
    open(my $oldout, '>&', \*STDOUT) or die $!;
    open(my $olderr, '>&', \*STDERR) or die $!;
    open(STDOUT, '>', $fn) or die $!;
    open(STDERR, '>&', \*STDOUT) or die $!;
    STDOUT->autoflush(1); STDERR->autoflush(1);
    my $ok = eval {$code->(); 1};
    my $err = $@;
    open(STDOUT, '>&', $oldout) or die $!;
    open(STDERR, '>&', $olderr) or die $!;
    die $err unless $ok;
    open(my $fh, '<', $fn) or die $!;
    local $/;
    my $out = <$fh>;
    unlink $fn;
    return $out // '';
}

# one SSE event
sub sse {
    my ($data) = @_;
    return "data: ".(ref($data) ? JSON::XS->new->utf8->canonical->encode($data) : $data)."\n\n";
}

sub content   { sse({choices => [{delta => {content => $_[0]}}]}) }
sub reasoning { sse({choices => [{delta => {reasoning_content => $_[0]}}]}) }
sub done      { sse('[DONE]') }
sub usage     { sse({choices => [], usage => {prompt_tokens => $_[0], completion_tokens => $_[1], total_tokens => $_[0] + $_[1]}}) }

# a failed request: fail($code, $json_body, header => value, ...)
sub fail {
    my ($code, $body, %headers) = @_;
    return sub {
        my ($cb) = @_;
        $cb->(undef, $body) if defined $body;
        $utils::http_code    = $code;
        %utils::http_headers = %headers;
        $utils::http_error   = $code ? "HTTP status $code" : "Couldn't connect to server";
        return;
    };
}

# replace utils::http by the script in @SCRIPT: an entry is a list of raw
# chunks to stream, a sub($callback, $request), or undef for a failed request
sub mock_http {
    @REQUESTS = ();
    @SCRIPT   = @_;
    no warnings 'redefine';
    *utils::http = sub {
        my ($m, $url, $data, $key, $cb) = @_;
        my $req = {method => $m, url => $url, data => $data, key => $key};
        push @REQUESTS, $req;
        $utils::http_error = undef;
        $utils::http_code  = 200;
        %utils::http_headers = ();
        die "the LLM script ran out at request ".scalar(@REQUESTS)."\n" unless @SCRIPT;
        my $step = shift @SCRIPT;
        if(!defined $step){
            $utils::http_error = "HTTP status 500";
            $utils::http_code  = 500;
            return;
        }
        return $step->($cb, $req) if ref($step) eq 'CODE';
        foreach my $chunk (@$step){
            my $n = $cb->(undef, $chunk);
            if(($n // 0) != length($chunk)){
                $utils::http_error = "interrupted";
                return;
            }
        }
        return "";
    };
    return;
}

# The LLM of the sub-agents: they talk through loop::http, several at a time,
# so there is no script but a responder: sub($messages, $request) that returns
# the chunks to stream, or {code, body, headers} for a failure, or a number of
# seconds to hang. @AGENT_REQUESTS has what was asked, $MAX_INFLIGHT how many
# requests were open at once.
our (@AGENT_REQUESTS, $INFLIGHT, $MAX_INFLIGHT);
sub mock_agent_http {
    my ($responder, %o) = @_;
    @AGENT_REQUESTS = ();
    ($INFLIGHT, $MAX_INFLIGHT) = (0, 0);
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        my $req = {%r, code => 0, error => undef, headers => {}, body => '', messages => JSON::XS::decode_json($r{data})->{messages}};
        push @AGENT_REQUESTS, $req;
        $INFLIGHT++;
        $MAX_INFLIGHT = $INFLIGHT if $INFLIGHT > $MAX_INFLIGHT;
        my $step = $responder->($req->{messages}, $req);
        loop::timer(ref($step) ? ($o{delay} // 0.02) : $step, sub {
            my ($aborted) = @_;
            $INFLIGHT--;
            if($aborted or !ref($step)){
                $req->{error} = $aborted ? "interrupted" : "Timeout was reached";
            } elsif(ref($step) eq 'HASH'){
                $r{on_data}->(undef, $step->{body}) if defined $step->{body};
                $req->{code}    = $step->{code} // 0;
                $req->{headers} = $step->{headers} // {};
                $req->{error}   = $req->{code} ? "HTTP status $req->{code}" : "Couldn't connect to server";
            } else {
                $r{on_data}->(undef, $_) for @$step;
                $req->{code} = 200;
            }
            $r{on_done}->($req);
        });
        return $req;
    };
    return;
}

# the messages of request number $i (0 based) as sent to the API
sub sent_messages {
    my ($i) = @_;
    return JSON::XS::decode_json($REQUESTS[$i]{data})->{messages};
}

sub roles {
    return join(',', map {$_->{role}} @_);
}

1;
