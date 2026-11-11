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
        die "the LLM script ran out at request ".scalar(@REQUESTS)."\n" unless @SCRIPT;
        my $step = shift @SCRIPT;
        if(!defined $step){
            $utils::http_error = "HTTP status 500";
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

# the messages of request number $i (0 based) as sent to the API
sub sent_messages {
    my ($i) = @_;
    return JSON::XS::decode_json($REQUESTS[$i]{data})->{messages};
}

sub roles {
    return join(',', map {$_->{role}} @_);
}

1;
