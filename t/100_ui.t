#!/usr/bin/perl
# the web interface (ui.pm): the HTTP routes and the token on socket pairs, the
# input queue, and end to end: a forked chat that reads its messages over HTTP
# and streams its answer as server-sent events, with the scripted LLM
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use IO::Socket::IP ();
use IO::Socket::INET ();
use POSIX ();
use File::Temp ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use ui;
use TestAI;
use FakeLLM;

my $ROOT = "$FindBin::Bin/..";
my $TOKEN = '0123456789abcdef0123456789abcdef';

# --- the routes, on a socket pair -------------------------------------------

$ui::token     = $TOKEN;
$ui::html_file = "$ROOT/ai/ui/index.html";

# a connection whose other end the test reads
sub conn {
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC())
        or die "socketpair: $!";
    $a->blocking(0);
    my $cn = {fh => $a, in => '', out => ''};
    $ui::conn{fileno($a)} = $cn;
    return ($cn, $b);
}

# everything the server wrote so far, without waiting for more
sub drain {
    my ($b) = @_;
    $b->blocking(0);
    my $r = '';
    while(1){
        my $n = sysread($b, my $x, 65536);
        last unless $n;
        $r .= $x;
    }
    return $r;
}

sub status_of { my ($r) = @_; return ($r =~ m{^HTTP/1\.1 (\d+) }) ? $1 : undef }
sub body_of   { my ($r) = @_; my ($h, $b) = split /\r\n\r\n/, $r, 2; return $b // '' }

sub request {
    my ($method, $path, %o) = @_;
    my ($cn, $b) = conn();
    my $body = $o{body} // '';
    my $head = "$method $path HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n";
    $head .= "Cookie: aicli_token=$o{cookie}\r\n" if defined $o{cookie};
    $head .= "Origin: $o{origin}\r\n" if defined $o{origin};
    $head .= $o{raw} if defined $o{raw};
    $head .= "Content-Length: ".length($body)."\r\n" unless $o{raw} and $o{raw} =~ /transfer-encoding|content-length/i;
    $head .= "\r\n";
    ui::_feed($cn, $head.$body);
    return drain($b);
}

my $ok_cookie = $TOKEN;
my $r;

$r = request('GET', '/');
is(status_of($r), 401, "no token: the page is refused");

$r = request('GET', '/?token=wrong');
is(status_of($r), 401, "a wrong token is refused");

$r = request('GET', "/?token=$TOKEN");
is(status_of($r), 303, "the token in the address sets the cookie and redirects");
like($r, qr/Set-Cookie: aicli_token=$TOKEN; Path=\/; HttpOnly; SameSite=Strict/, "the cookie is HttpOnly and strict");
like($r, qr{Location: /}, "the redirect goes to the page");

$r = request('GET', '/', cookie => $ok_cookie);
is(status_of($r), 200, "with the cookie the page is served");
like(body_of($r), qr/EventSource/, "the page is the interface");

$r = request('GET', '/state', cookie => $ok_cookie);
is(status_of($r), 200, "state with the cookie");
my $st = $::JSON->decode(body_of($r));
is($st->{busy}, $::JSON->false, "state: not busy");
is($st->{queued}, 0, "state: nothing queued");

$r = request('GET', '/state', cookie => 'nope');
is(status_of($r), 401, "a route refuses a wrong cookie");

$r = request('GET', '/state', raw => "Authorization: Bearer $TOKEN\r\n");
is(status_of($r), 200, "the bearer token works too");

$r = request('POST', '/message', body => '{"text":"hi"}');
is(status_of($r), 401, "posting a message needs the token");

$r = request('POST', '/message', cookie => $ok_cookie, origin => 'http://evil.example', body => '{"text":"hi"}');
is(status_of($r), 403, "a post from another origin is refused");

$r = request('POST', '/message', cookie => $ok_cookie, body => 'not json');
is(status_of($r), 400, "a body that is not JSON is refused");

$r = request('POST', '/message', cookie => $ok_cookie, body => '{"text":"   "}');
is(status_of($r), 400, "an empty message is refused");

$r = request('POST', '/message', cookie => $ok_cookie, body => '{"text":"/session list"}');
is(status_of($r), 400, "a slash command is refused for now");

$r = request('POST', '/message', cookie => $ok_cookie, origin => "http://127.0.0.1:8080", body => '{"text":"hello there"}');
is(status_of($r), 202, "a message is accepted");
is($::JSON->decode(body_of($r))->{queued}, 1, "and queued");
is(ui::queued(), 1, "the queue holds it");

$r = request('GET', '/message', cookie => $ok_cookie);
is(status_of($r), 405, "GET on a POST route");

$r = request('GET', '/nothing', cookie => $ok_cookie);
is(status_of($r), 404, "an unknown route");

$r = request('POST', '/message', cookie => $ok_cookie, raw => "Transfer-Encoding: chunked\r\n", body => '');
is(status_of($r), 501, "chunked request bodies are refused");

$r = request('POST', '/message', cookie => $ok_cookie, raw => "Content-Length: 2000000\r\n", body => '');
is(status_of($r), 413, "a body too big is refused");

# the input: a queued message comes out, the chat's end stops the wait
{
    local $::LOOP = 1;
    my $input = ui::input();
    my $m = $input->();
    is($m, "hello there", "the input gives the queued message");
    is(ui::queued(), 0, "and the queue is empty");
    $::LOOP = 0;
    is($input->(), undef, "when the chat ends the input gives nothing");
    $::LOOP = 1;
}

# voice: a recording is queued, recognized in the input, and goes to the chat

{
    my $wav = "RIFF".("\x00" x 40);
    $r = request('POST', '/voice', body => $wav, cookie => $ok_cookie, raw => "Content-Type: audio/wav\r\n");
    is(status_of($r), 202, "a recording is queued");
    my ($item) = @ui::queue;
    is(ref($item), 'HASH', "as a recording, not as text");
    is(length($item->{audio}), length($wav), "with its bytes");
    @ui::queue = ();

    $r = request('POST', '/voice', body => 'x', cookie => $ok_cookie, raw => "Content-Type: text/plain\r\n");
    is(status_of($r), 415, "a body that is not audio is refused");

    $r = request('POST', '/voice', body => $wav);
    is(status_of($r), 401, "a recording needs the token");

    $r = request('POST', '/voice', body => '', cookie => $ok_cookie, raw => "Content-Type: audio/wav\r\n");
    is(status_of($r), 400, "an empty recording is refused");

    # a recording bigger than a JSON body, up to the voice limit
    my $big = "RIFF".("\x00" x 2_000_000);
    $r = request('POST', '/voice', body => $big, cookie => $ok_cookie, raw => "Content-Type: audio/wav\r\n");
    is(status_of($r), 202, "a recording of 2 MB is accepted");
    @ui::queue = ();
}

{
    no warnings 'redefine';
    local $ai::AI_SESSION_DIR = File::Temp::tempdir(CLEANUP => 1);
    local *ai::transcribe = sub { "spoken words" };
    my @got;
    my $old_sink = $ai::EVENT_SINK;
    $ai::EVENT_SINK = sub { push @got, [@_] };
    local $::LOOP = 1;
    @ui::queue = ({audio => "RIFF"}, "typed next");
    my $input = ui::input();
    is($input->(), "spoken words", "a recording comes out as its text");
    is($got[-1][0], 'heard', "and the page is told what was heard");
    is($got[-1][1]{text}, "spoken words", "the words");
    is($input->(), "typed next", "text after it comes as it is");
    @ui::queue = ({audio => "RIFF"}, "after silence");
    $ai::EVENT_SINK = sub { push @got, [@_] };
    local *ai::transcribe = sub { "" };
    is($input->(), "after silence", "a recording with no words is skipped");
    $ai::EVENT_SINK = $old_sink;
}

# the event stream: the hello, then what is published
{
    my ($cn, $b) = conn();
    ui::_feed($cn, "GET /events HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nCookie: aicli_token=$TOKEN\r\n\r\n");
    my $got = drain($b);
    like($got, qr{^HTTP/1\.1 200 OK\r\nContent-Type: text/event-stream}, "the stream starts");
    like($got, qr/event: state\ndata: \{.*"session"/, "the stream says the state first");
    ui::publish(text => {text => "héllo\nworld"});
    $got = drain($b);
    like($got, qr/event: text\ndata: \{"text":"h[^\n]*llo\\nworld"\}\n\n/, "a published event arrives as one SSE event (json on one line)");
    ui::publish(turn => {state => 'start'});
    like(drain($b), qr/event: turn\ndata: \{"state":"start"\}/, "turn events too");
    ok(scalar(@ui::clients) == 1, "one client is listening");
    ui::_close($cn);
    ok(scalar(@ui::clients) == 0, "closing the client takes it off the list");
}

# --- the listen address: IPv4 and IPv6 ----------------------------------------

for my $bind ('::1', '::', '127.0.0.1') {
    my $probe = IO::Socket::IP->new(LocalHost => $bind, LocalPort => 0, Listen => 1, Proto => 'tcp');
    SKIP: {
        skip "no IPv6 on this machine" unless $probe or $bind !~ /:/;
        ok($probe, "can listen on $bind");
        close($probe) if $probe;
        my $port = ui::start(port => 0, bind => $bind, token => $TOKEN);
        ok($port > 0, "port $port on $bind");
        # the client is a child: this process is the server and runs the loop
        my $cpid = fork() // die "fork: $!";
        if(!$cpid){
            my $c = IO::Socket::IP->new(PeerHost => ($bind eq '::' ? '::1' : $bind), PeerPort => $port, Timeout => 5);
            POSIX::_exit(2) unless $c;
            print {$c} "GET /state HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            my $all = do { local $/; <$c> } // '';
            POSIX::_exit(status_of($all) == 401 ? 0 : 3);
        }
        my $waited;
        loop::run(sub { $waited = waitpid($cpid, POSIX::WNOHANG()) if !defined $waited || $waited == 0; $waited && $waited > 0 });
        is($? >> 8, 0, "the server answers on $bind (401 without a token)");
        ui::stop();
    }
}

# --- stop and start again on the same port -------------------------------------

{
    my $probe = IO::Socket::IP->new(LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
    my $port = $probe->sockport;
    close($probe);
    for my $round (1 .. 3){
        my $got = ui::start(port => $port, bind => '127.0.0.1', token => $TOKEN);
        is($got, $port, "stop and start: round $round listens on the same port");
        ui::stop();
    }
}

# --- TLS: https with a certificate, the handshake on the event loop ---------
# a https GET with a plain Net::SSLeay client: the whole answer, the headers too
sub _https_get {
    my ($port, $path) = @_;
    my $sock = IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => $port, Timeout => 5) or return;
    my $ctx = Net::SSLeay::CTX_new();
    my $ssl = Net::SSLeay::new($ctx);
    Net::SSLeay::set_fd($ssl, fileno($sock));
    my $all;
    if(Net::SSLeay::connect($ssl) > 0){
        Net::SSLeay::write($ssl, "GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        $all = '';
        while(1){
            my $chunk = Net::SSLeay::read($ssl);
            last unless defined $chunk and length $chunk;
            $all .= $chunk;
        }
    }
    Net::SSLeay::free($ssl);
    Net::SSLeay::CTX_free($ctx);
    return $all;
}


SKIP: {
    skip "Net::SSLeay is not installed" unless eval { require Net::SSLeay; 1 };
    skip "no openssl program" unless -x '/usr/bin/openssl' or -x '/bin/openssl';
    my $dir = File::Temp::tempdir("aicli_tls_XXXXXX", TMPDIR => 1, CLEANUP => 1);
    my $rc = system('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
        '-subj', '/CN=localhost', '-keyout', "$dir/key.pem", '-out', "$dir/cert.pem",
        '-batch') >> 8;
    skip "cannot make a test certificate" if $rc;
    my $probe = IO::Socket::IP->new(LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
    my $port = $probe->sockport;
    close($probe);
    my $tls_port = ui::start(port => $port, bind => '127.0.0.1', token => $TOKEN,
        tls_cert => "$dir/cert.pem", tls_key => "$dir/key.pem");
    is($tls_port, $port, "tls: listens on $port");
    # the client is a child: the TLS client is blocking, the server is this loop
    my $cpid = fork() // die "fork: $!";
    if(!$cpid){
        alarm 15;
        my $bits = 0;
        my $one = _https_get($port, '/state');
        $bits |= 1 if defined $one and $one =~ m{^HTTP/1\.1 401};
        my $two = _https_get($port, "/?token=$TOKEN");
        $bits |= 2 if defined $two and $two =~ m{^HTTP/1\.1 303}
            and $two =~ /^Set-Cookie: aicli_token=\S+;.*Secure/mi;
        POSIX::_exit($bits);
    }
    my $waited = 0;
    loop::run(sub { $waited = waitpid($cpid, POSIX::WNOHANG()) if !$waited; $waited && $waited > 0 });
    is($? >> 8, 3, "tls: a https request gets the 401, the token gets the redirect with a Secure cookie");
    ui::stop();
}

# --- the page and the server agree on the themes ---------------------------------

{
    open(my $fh, '<', "$FindBin::Bin/../ai/ui/index.html") or die "no page: $!";
    my $html = do { local $/; <$fh> };
    my ($js) = $html =~ m/var THEMES = \[([^\]]*)\]/;
    my @page = map {s/["\s]//gr} split /,/, ($js // '');
    is_deeply(\@page, \@ai::THEMES, "themes: the page has the names of the server, in the same order");
    my @options = $html =~ m/<option value="(\w+)">\w+<\/option>/g;
    my %in_list = map {($_ => 1)} @ai::THEMES;
    ok(scalar(grep {$in_list{$_} || $_ eq 'system'} @options) >= @ai::THEMES, "themes: the dropdown offers them");
}

# --- what happens goes to stderr in web mode -----------------------------------

{
    my $err = '';
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die;
        local $ai::EVENT_SINK = sub {};
        ai::web_note("request to openai/gpt-a at https://api.openai.com/v1/chat/completions");
    }
    like($err, qr{^\d\d:\d\d:\d\d request to openai/gpt-a at https://}, "web note: a time and the line on stderr");
    $err = '';
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die;
        ai::web_note("nobody listens");
    }
    is($err, '', "web note: nothing without the web interface");
}

# --- the models: the list and the choice go through the chat's flow ----------

{
    my $r = request('POST', '/model', body => '{"id":"openrouter/llama-b"}');
    is(status_of($r), 401, "model: needs the token");
    @ui::queue = ();
    $r = request('POST', '/model', cookie => $ok_cookie, body => '{"id":"openrouter/llama-b"}');
    is(status_of($r), 202, "model: a choice is accepted");
    is_deeply($ui::queue[0], {model => 'openrouter/llama-b'}, "model: queued for the chat's flow");
    $r = request('POST', '/model', cookie => $ok_cookie, body => '{"id":""}');
    is(status_of($r), 400, "model: an empty id is refused");
    $r = request('POST', '/model', cookie => $ok_cookie, body => 'not json');
    is(status_of($r), 400, "model: not JSON is refused");
    $r = request('POST', '/models', cookie => $ok_cookie);
    is(status_of($r), 202, "models: a refresh is accepted");
    is_deeply($ui::queue[1], {models => 1}, "models: queued for the chat's flow");
    @ui::queue = ();
}

{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_API_KEY_OPENROUTER => 'sk-or-test');
    @ai::ALL_MODELS = (['openai', 'gpt-a'], ['openrouter', 'llama-b']);
    ui::_switch_model('openrouter/llama-b');
    is($ai::AI_PROVIDER, 'openrouter', "switch from the page: the provider changes");
    is($ai::SESSION_MODEL, 'llama-b', "switch from the page: the model changes");
    is(ui::_state()->{model}, 'openrouter/llama-b', "the state names the current choice");
    my $err = TestAI::capture {ui::_switch_model('openrouter/no-such')};
    is($ai::SESSION_MODEL, 'no-such', "a choice that is not listed is taken as a bare id at the provider (as /model does)");
}

# --- the speech recognizer: the page is told whether the mic can work -------

{
    local $::ORIG_ENV{AI_ASR_URL};
    delete $::ORIG_ENV{AI_ASR_URL};
    my $err = '';
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die;
        ui::check_voice();
    }
    is($ui::voice, 'none', "voice: no AI_ASR_URL is 'none'");
    is(ui::_state()->{voice}, 'none', "voice: the state says so");
    like($err, qr/AI_ASR_URL is not set, the mic is not available/, "voice: said on stderr");
}
{
    local $::ORIG_ENV{AI_ASR_URL} = 'http://127.0.0.1:1/v1/audio/transcriptions';
    my $err = '';
    $ui::voice = undef;
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die;
        ui::check_voice();
        loop::run(sub { defined $ui::voice });
    }
    is($ui::voice, 'unreachable', "voice: an endpoint that is not there is 'unreachable'");
    like($err, qr/endpoint http:\S+ is not reachable/, "voice: said on stderr as not reachable");
}

# --- end to end: ai.pl --ui as a child process, read over HTTP ----------------

my $llm = FakeLLM::start();
my $tmp = File::Temp::tempdir("aicli_ui_XXXXXX", TMPDIR => 1, CLEANUP => 1);
# a free port: taken and given up, the child takes it right after
my $probe = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "probe: $!";
my $port = $probe->sockport;
close($probe);

my $kid = fork() // die "fork: $!";
if(!$kid){
    open(STDOUT, '>', "$tmp/stdout") or POSIX::_exit(1);
    open(STDERR, '>', "$tmp/stderr") or POSIX::_exit(1);
    %ENV = (
        PATH => $ENV{PATH}, HOME => $tmp, AI_DIR => "$tmp/aicli", AI_CONFIG => "$tmp/noconfig",
        AI_LOCAL_SERVER => $llm, AI_API_KEY => 'sk-ui', AI_MODEL => 'fake-1', AI_SESSION => 'ui', AI_THINKING_VIEW => 'text',
        AI_UI_TOKEN => $TOKEN,
    );
    exec($^X, "-I$ROOT", "$ROOT/ai.pl", "--ui=$port", "--ui-bind=127.0.0.1")
        or POSIX::_exit(1);
}
ok(1, "ai.pl --ui started");

# wait for it to listen
my $up = 0;
for (1 .. 100){
    if(IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1)){ $up = 1; last }
    select(undef, undef, undef, 0.1);
}
ok($up, "it listens on $port") or BAIL_OUT("no server: ".do { local $/; open(my $e, '<', "$tmp/stderr"); <$e> });

sub open_http {
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10)
        or die "connect: $!";
    return $s;
}

# the token of ai.pl is not ours: it prints it on stderr, the test reads that
my $ev = open_http();
print {$ev} "GET /events HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nCookie: aicli_token=$TOKEN\r\n\r\n";

my $post = open_http();
my $msg = '{"text":"say something"}';
print {$post} "POST /message HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nCookie: aicli_token=$TOKEN\r\n"
    ."Content-Type: application/json\r\nContent-Length: ".length($msg)."\r\nConnection: close\r\n\r\n$msg";
my $pr = do { local $/; <$post> };
is(status_of($pr), 202, "the message is posted to the chat child");

# read the stream until the turn ends
my @seen;
my $text = '';
my $thought = '';
my $usage = '';
{
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 20;
    my $buf = '';
    my $done = 0;
    my $header_done = 0;
    eval {
        while(!$done){
            my $n = sysread($ev, my $chunk, 65536);
            die "stream closed\n" unless $n;
            $buf .= $chunk;
            if(!$header_done and $buf =~ s/\A.*?\r\n\r\n//s){
                $header_done = 1;
            }
            while($buf =~ s/\A(event: (\w+)\ndata: (.*?)\n\n)//s){
                my ($type, $data) = ($2, $3);
                push @seen, $type;
                $text .= $::JSON->decode($data)->{text} if $type eq 'text';
                $thought .= $::JSON->decode($data)->{text} if $type eq 'think';
                $usage .= $::JSON->decode($data)->{text} if $type eq 'usage';
                $done = 1 if $type eq 'turn' and $::JSON->decode($data)->{state} eq 'end';
            }
        }
        1;
    } or diag("stream: $@");
    alarm 0;
}
ok(scalar(grep {$_ eq 'turn'} @seen), "the stream shows the turn");
ok(scalar(grep {$_ eq 'tool'} @seen), "a tool call is its own event");
ok(scalar(grep {$_ eq 'result'} @seen), "and its result too");
ok(scalar(grep {$_ eq 'text'} @seen), "the answer streams as text events");
like($text, qr/\S/, "the answer has text");
ok(length($thought), "the thinking comes as think events");
unlike($text.$thought, qr/\x1b/, "no terminal colours in what the page gets");
like($usage, qr/^\[tokens: /, "the token statistics come to the page too");
is(scalar(grep {$_ eq 'failed'} @seen), 0, "no failure event");

my $state = do {
    my $s = open_http();
    print {$s} "GET /state HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nCookie: aicli_token=$TOKEN\r\nConnection: close\r\n\r\n";
    my $all = do { local $/; <$s> };
    $::JSON->decode(body_of($all));
};
is($state->{busy}, $::JSON->false, "after the turn the chat is not busy");

close($ev);
kill 'TERM', $kid;
waitpid($kid, 0);
ok(1, "the chat child is stopped");

# --- the phone's address: a local IPv4 address, or none ------------------------

{
    my $lan = ui::_lan_address(4);
    my $lan6 = ui::_lan_address(6);
    my $v6_ok = !defined $lan6 || ($lan6 =~ m/^[0-9a-f:]+$/ && $lan6 !~ m/^fe80/i);
    ok($v6_ok, "the IPv6 phone address is global (or none)");
    SKIP: {
        skip "no /proc/net/fib_trie here", 1 unless -r '/proc/net/fib_trie';
        my $v4_ok = !defined $lan || ($lan =~ m/^\d+\.\d+\.\d+\.\d+$/ && $lan !~ m/^127\./);
        ok($v4_ok, "the phone address is a local IPv4 address (or none)");
    }
}

# --- errors of the chat reach the page too

{
    my @got;
    my $old_sink = $ai::EVENT_SINK;
    $ai::EVENT_SINK = sub { push @got, [@_] };
    $log::on_error = sub { $ai::EVENT_SINK->(failed => {text => ai::web_text($_[0])}) };
    local $SIG{__WARN__} = sub {};
    log::error("\e[31mstopped after 50 tool turns\e[0m");
    $log::on_error = undef;
    $ai::EVENT_SINK = $old_sink;
    is(scalar(@got), 1, "an error is sent to the page");
    is($got[0][0], 'failed', "as a failed event");
    is($got[0][1]{text}, "stopped after 50 tool turns", "without the colours");
}

# --- ctrl-C: stops the turn, a second one (idle) ends the program --------------

{
    my $probe2 = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        or die "probe: $!";
    my $p2 = $probe2->sockport;
    close($probe2);
    my $k = fork() // die "fork: $!";
    if(!$k){
        open(STDOUT, '>', "$tmp/stdout2") or POSIX::_exit(1);
        open(STDERR, '>', "$tmp/stderr2") or POSIX::_exit(1);
        %ENV = (
            PATH => $ENV{PATH}, HOME => $tmp, AI_DIR => "$tmp/aicli2", AI_CONFIG => "$tmp/noconfig",
            AI_LOCAL_SERVER => $llm, AI_API_KEY => 'sk-ui', AI_MODEL => 'fake-1', AI_SESSION => 'ui2',
            AI_UI_TOKEN => $TOKEN,
        );
        exec($^X, "-I$ROOT", "$ROOT/ai.pl", "--ui=$p2", "--ui-bind=127.0.0.1") or POSIX::_exit(1);
    }
    my $up2 = 0;
    for (1 .. 100){
        if(IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $p2, Timeout => 1)){ $up2 = 1; last }
        select(undef, undef, undef, 0.1);
    }
    ok($up2, "a second ai.pl --ui is up");

    my $ev2 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $p2, Timeout => 10) or die "connect: $!";
    print {$ev2} "GET /events HTTP/1.1\r\nHost: x\r\nCookie: aicli_token=$TOKEN\r\n\r\n";
    my $post2 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $p2, Timeout => 10) or die "connect: $!";
    my $m2 = '{"text":"slow"}';
    print {$post2} "POST /message HTTP/1.1\r\nHost: x\r\nCookie: aicli_token=$TOKEN\r\nContent-Length: ".length($m2)."\r\nConnection: close\r\n\r\n$m2";
    my $pr2 = do { local $/; <$post2> };
    is(status_of($pr2), 202, "the slow message is queued");

    # read events until one of the given type and state arrives
    my $buf2 = '';
    my $wait_turn = sub {
        my ($state) = @_;
        my $found = 0;
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        eval {
            while(!$found){
                my $n = sysread($ev2, my $chunk, 65536);
                die "closed\n" unless $n;
                $buf2 .= $chunk;
                $buf2 =~ s/\A.*?\r\n\r\n//s if $buf2 =~ m/\r\n\r\n/ and $buf2 =~ m/\AHTTP/; # the header, once
                $buf2 =~ s/\A:[^\n]*\n\n//s; # keep-alive comments
                while($buf2 =~ s/\A(event: (\w+)\ndata: (.*?)\n\n)//s){
                    my ($type, $data) = ($2, $3);
                    $found = 1 if $type eq 'turn' and $::JSON->decode($data)->{state} eq $state;
                }
            }
            1;
        } or diag("events: $@");
        alarm 0;
        return $found;
    };
    ok($wait_turn->('start'), "the slow turn starts");
    select(undef, undef, undef, 0.5);
    kill 'INT', $k;
    ok($wait_turn->('end'), "ctrl-C ends the running turn");
    my $alive = kill(0, $k);
    ok($alive, "and the program stays (the turn was stopped, not the chat)");

    kill 'INT', $k;
    my $w = 0;
    for (1 .. 100){
        $w = waitpid($k, POSIX::WNOHANG());
        last if $w;
        select(undef, undef, undef, 0.1);
    }
    is($w, $k, "a second ctrl-C while idle ends the program");
    is($? >> 8, 130, "with exit 130, as on the terminal");
}

FakeLLM::stop();
done_testing();
