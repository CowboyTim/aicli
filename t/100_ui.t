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
                $done = 1 if $type eq 'turn' and $::JSON->decode($data)->{state} eq 'end';
            }
        }
        1;
    } or diag("stream: $@");
    alarm 0;
}
ok(scalar(grep {$_ eq 'turn'} @seen), "the stream shows the turn");
ok(scalar(grep {$_ eq 'text'} @seen), "the answer streams as text events");
like($text, qr/\S/, "the answer has text");
ok(length($thought), "the thinking comes as think events");
unlike($text.$thought, qr/\x1b/, "no terminal colours in what the page gets");
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

FakeLLM::stop();
done_testing();
