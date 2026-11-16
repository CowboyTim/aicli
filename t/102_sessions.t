#!/usr/bin/perl
# the sessions of the web interface: each session has a worker process, two
# sessions run their turns at the same time, and the page can switch away from a
# busy session. ai.pl --ui as a child, with the scripted LLM ("slow" hangs).
use strict; use warnings;

use Test::More;
use FindBin;
use IO::Socket::INET ();
use POSIX ();
use File::Temp ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use FakeLLM;

my $ROOT  = "$FindBin::Bin/..";
my $TOKEN = '0123456789abcdef0123456789abcdef';
my $tmp   = File::Temp::tempdir("aicli_sess_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $llm   = FakeLLM::start();

my $probe = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "probe: $!";
my $port = $probe->sockport;
close($probe);

my $k = fork() // die "fork: $!";
if (!$k) {
    open(STDOUT, '>', "$tmp/stdout") or POSIX::_exit(1);
    open(STDERR, '>', "$tmp/stderr") or POSIX::_exit(1);
    %ENV = (
        PATH => $ENV{PATH}, HOME => $tmp, AI_DIR => "$tmp/aicli", AI_CONFIG => "$tmp/noconfig",
        AI_LOCAL_SERVER => $llm, AI_API_KEY => 'sk-sess', AI_MODEL => 'fake-1', AI_SESSION => 's1',
        AI_UI_TOKEN => $TOKEN,
    );
    exec($^X, "-I$ROOT", "$ROOT/ai.pl", "--ui=$port", "--ui-bind=127.0.0.1") or POSIX::_exit(1);
}
my $up = 0;
for (1 .. 100) {
    if (IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1)) { $up = 1; last }
    select(undef, undef, undef, 0.1);
}
ok($up, "ai.pl --ui is up") or BAIL_OUT("no interface");

# the event stream of the page, read in the background of each step
my $ev = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10) or die "connect: $!";
print {$ev} "GET /events HTTP/1.1\r\nHost: x\r\nCookie: aicli_token=$TOKEN\r\n\r\n";
my ($buf, $hdr, @events) = ('', 0);

sub pump {
    my ($done) = @_;
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 20;
    eval {
        until ($done->()) {
            my $n = sysread($ev, my $chunk, 65536);
            die "closed\n" unless $n;
            $buf .= $chunk;
            if (!$hdr and $buf =~ s/\A.*?\r\n\r\n//s) { $hdr = 1 }
            $buf =~ s/\A:[^\n]*\n\n//s while $buf =~ m/\A:/;
            while ($buf =~ s/\A(event: (\w+)\ndata: (.*?)\n\n)//s) {
                push @events, [$2, $::JSON->decode($3)];
            }
        }
        1;
    } or diag("pump: $@");
    alarm 0;
    return $done->();
}

sub last_of { my ($type) = @_; my @e = grep {$_->[0] eq $type} @events; return @e ? $e[-1][1] : undef }
sub busy_list { my $b = last_of('busy'); return $b ? $b->{list} : [] }

sub post {
    my ($path, $body) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10) or die "connect: $!";
    print {$s} "POST $path HTTP/1.1\r\nHost: x\r\nCookie: aicli_token=$TOKEN\r\nContent-Length: "
        .length($body)."\r\nConnection: close\r\n\r\n$body";
    my $r = do { local $/; <$s> };
    return ($r // '') =~ m{^HTTP/1\.1 (\d+)} ? $1 : 0;
}

sub child_pids {
    my ($ppid) = @_;
    opendir(my $dh, '/proc') or return ();
    my @kids;
    for my $e (grep {/^\d+$/} readdir $dh) {
        open(my $fh, '<', "/proc/$e/stat") or next;
        my $st = <$fh>;
        close($fh);
        my ($pp) = $st =~ m/\)\s+\S+\s+(\d+)/ or next;
        push @kids, $e if $pp == $ppid;
    }
    closedir($dh);
    return @kids;
}

ok(pump(sub { last_of('state') }), "the page gets the state");
is(last_of('state')->{session}, 's1', "the first session is the one of the chat");

# a new session, active: a slow turn in it
is(post('/session', '{"new":true}'), 200, "a new session is made");
ok(pump(sub { last_of('state')->{session} ne 's1' }), "the page is in the new one");
my $two = last_of('state')->{session};
is(post('/message', '{"text":"slow one"}'), 202, "a message for it");
ok(pump(sub { grep {$_ eq $two} @{busy_list()} }), "its turn runs (busy)");

# the page switches away while that turn runs: the other session is used
is(post('/session', '{"name":"s1"}'), 200, "switch to s1 while the new one is busy");
ok(pump(sub { last_of('state')->{session} eq 's1' }), "the page is in s1");
is(post('/message', '{"text":"slow two"}'), 202, "a message for s1");
ok(pump(sub { @{busy_list()} == 2 }), "both turns run at the same time");
is(scalar(child_pids($k)), 2, "each session has a worker process of its own");

# the abort goes to the active session only
is(post('/abort', '{}'), 200, "abort");
ok(pump(sub { !(grep {$_ eq 's1'} @{busy_list()}) }), "s1's turn stops");
ok((grep {$_ eq $two} @{busy_list()}), "the other session's turn goes on");

# ctrl-C in the interface ends it all
kill 'INT', $k;
my $w = 0;
for (1 .. 100) {
    $w = waitpid($k, POSIX::WNOHANG());
    last if $w;
    select(undef, undef, undef, 0.1);
}
is($w, $k, "ctrl-C ends the interface");
is(scalar(child_pids($k)), 0, "and its workers");

FakeLLM::stop();
done_testing();
