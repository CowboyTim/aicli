#!/usr/bin/perl
# the broker (broker.pl): what it lets a request do, and what it asks the engine.
# A fake engine on a Unix socket answers like the libpod API and records every
# request; the real engine (Podman on the host) is not needed for this.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use IO::Socket::UNIX ();
use Socket ();
use POSIX ();
use JSON::XS ();
use lib "$FindBin::Bin/..";

require "$FindBin::Bin/../broker.pl";

my $J = JSON::XS->new->canonical(1)->utf8;
my $tmp = File::Temp::tempdir("aicli_brk_XXXXXX", TMPDIR => 1, CLEANUP => 1);

# --- the projects: a tree the broker sees as its root ------------------------

my $root = "$tmp/projects";
mkdir $root or die "mkdir: $!";
mkdir "$root/alpha" or die "mkdir: $!";
mkdir "$root/beta" or die "mkdir: $!";
mkdir "$root/.hidden" or die "mkdir: $!";
open(my $fh, '>', "$root/notes.txt") or die "notes: $!";
close $fh;
symlink("$root/alpha", "$root/link") or die "symlink: $!";

is(broker::_bytes('2g'), 2 * 1024**3, "a memory size: 2g");
is(broker::_bytes('512m'), 512 * 1024**2, "512m");
is(broker::_bytes('4096'), 4096, "bytes");
ok(!eval {broker::_bytes('lots'); 1}, "a memory size that is not one is refused");

ok(!eval {broker->new(images => ['x']); 1}, "no host root: refused");
ok(!eval {broker->new(host_root => '/h')}, "no image allowed: refused");

# --- the fake engine ---------------------------------------------------------

my $engine_sock = "$tmp/engine.sock";
my $rec = "$tmp/records.jsonl";
my $epid = fork() // die "fork: $!";
if (!$epid) {
    POSIX::setsid();
    unlink $engine_sock;
    my $srv = IO::Socket::UNIX->new(Local => $engine_sock, Type => Socket::SOCK_STREAM(), Listen => 5)
        or POSIX::_exit(1);
    my %pods;
    while (my $c = $srv->accept) {
        my $buf = '';
        while ($buf !~ m/\r\n\r\n/) {
            my $n = sysread($c, my $x, 4096);
            last unless $n;
            $buf .= $x;
        }
        my ($head, $body) = split /\r\n\r\n/, $buf, 2;
        $body //= '';
        my ($len) = $head =~ m/Content-Length: (\d+)/i;
        while (length($body) < ($len // 0)) {
            my $n = sysread($c, my $x, 4096);
            last unless $n;
            $body .= $x;
        }
        my ($method, $path) = $head =~ m{\A(\S+) (\S+)};
        if (open(my $r, '>>', $rec)) { print {$r} $J->encode({method => $method, path => $path, body => $body})."\n"; close $r }
        my ($code, $resp);
        if ($method eq 'GET' and $path eq '/libpod/pods/json') {
            ($code, $resp) = (200, $J->encode([map {{Name => $_, Status => 'Created'}} sort keys %pods]));
        } elsif ($method eq 'POST' and $path eq '/libpod/pods/create') {
            my $n = eval {$J->decode($body)->{name}};
            ($code, $resp) = $pods{$n} ? (409, '{"cause":"exists"}') : do {$pods{$n} = 1; (201, '{"Id":"p"}')};
        } elsif ($method eq 'POST' and $path eq '/libpod/containers/create') {
            ($code, $resp) = (201, '{"Id":"c"}');
        } elsif ($method eq 'POST' and $path =~ m{\A/libpod/pods/([^/]+)/start\z}) {
            ($code, $resp) = $pods{$1} ? (200, '{}') : (404, '{"cause":"no such pod"}');
        } elsif ($method eq 'POST' and $path =~ m{\A/libpod/pods/([^/]+)/stop\z}) {
            ($code, $resp) = (200, '{}');
        } elsif ($method eq 'DELETE' and $path =~ m{\A/libpod/pods/([^/?]+)}) {
            delete $pods{$1};
            ($code, $resp) = (200, '{}');
        } else {
            ($code, $resp) = (404, '{"cause":"not faked"}');
        }
        print {$c} "HTTP/1.1 $code X\r\nContent-Type: application/json\r\nContent-Length: "
            .length($resp)."\r\nConnection: close\r\n\r\n$resp";
        close $c;
    }
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $engine_sock; select(undef, undef, undef, 0.05) }

sub records {
    open(my $r, '<', $rec) or return ();
    my @r = map {$J->decode($_)} grep {m/\S/} <$r>;
    close $r;
    return @r;
}
sub clear_records { unlink $rec }
sub nrec { my @r = records(); return scalar @r }

my $b = broker->new(
    root      => $root,
    host_root => '/host/projects',
    engine    => $engine_sock,
    images    => ['local/ai/aicli:latest'],
    memory    => '2g',
    pids      => 512,
);

# --- what a request may be ----------------------------------------------------

my $r = $b->handle('not json');
ok(!$r->{ok}, "not JSON is refused");
$r = $b->handle('{"op":"run","project":"alpha"}');
ok(!$r->{ok}, "an operation that is not open, close or list is refused");
like($r->{error}, qr/unknown request 'run'/, "and the reason says which");

for my $bad ('../beta', '.hidden', 'alpha/src', 'notes.txt', 'link', 'no-such', '', ' alpha', 'a' x 80) {
    clear_records();
    my $res = $b->handle($J->encode({op => 'open', project => $bad}));
    ok(!$res->{ok}, "project '$bad' is refused");
    is(nrec(), 0, "and the engine is not asked");
}

clear_records();
$r = $b->handle($J->encode({op => 'open', project => 'alpha', image => 'docker.io/evil:latest'}));
ok(!$r->{ok}, "an image that is not allowed is refused");
is(nrec(), 0, "and the engine is not asked for it");

# --- open, reopen, list, close -----------------------------------------------

clear_records();
$r = $b->handle($J->encode({op => 'open', project => 'alpha'}));
ok($r->{ok}, "open alpha");
is($r->{pod}, 'aicli-alpha', "its pod is named for it");
ok($r->{created}, "and it was made");
my @rec = records();
is_deeply([map {"$_->{method} $_->{path}"} @rec],
    ['GET /libpod/pods/json', 'POST /libpod/pods/create', 'POST /libpod/containers/create', 'POST /libpod/pods/aicli-alpha/start'],
    "the calls: list, make the pod, make the container, start the pod");

my ($spec) = grep {$_->{path} eq '/libpod/containers/create'} @rec;
my $s = $spec->{body} ? $J->decode($spec->{body}) : {};
is($s->{pod}, 'aicli-alpha', "the container is in the pod");
is(scalar(@{$s->{mounts}}), 1, "one mount");
is($s->{mounts}[0]{source}, '/host/projects/alpha', "the project's directory on the host, and only it");
is($s->{mounts}[0]{destination}, '/work', "it is /work inside");
ok(!$s->{privileged}, "not privileged");
is_deeply($s->{cap_drop}, ['ALL'], "no capabilities");
ok($s->{no_new_privileges}, "no new privileges");
is($s->{resource_limits}{memory}{limit}, 2 * 1024**3, "the memory limit of the config");
is($s->{resource_limits}{pids}{limit}, 512, "and the process limit");
unlike($spec->{body}, qr/\.sock|engine|docker/, "no socket of any engine in the spec");

clear_records();
$r = $b->handle($J->encode({op => 'open', project => 'alpha'}));
ok($r->{ok}, "open alpha again");
ok(!$r->{created}, "it is not made twice");
is_deeply([map {"$_->{method} $_->{path}"} records()],
    ['GET /libpod/pods/json', 'POST /libpod/pods/aicli-alpha/start'],
    "only the start is asked");

$r = $b->handle($J->encode({op => 'open', project => 'beta'}));
ok($r->{ok}, "open beta as well");

$r = $b->handle('{"op":"list"}');
is_deeply([sort map {$_->{name}} @{$r->{pods}}], ['aicli-alpha', 'aicli-beta'], "list: the project pods");

$r = $b->handle($J->encode({op => 'close', project => 'alpha'}));
ok($r->{ok}, "close alpha");
$r = $b->handle('{"op":"list"}');
is_deeply([map {$_->{name}} @{$r->{pods}}], ['aicli-beta'], "alpha is gone from the list");

# --- the engine not there -----------------------------------------------------

my $lonely = broker->new(root => $root, host_root => '/host/projects', engine => "$tmp/none.sock", images => ['x']);
$r = $lonely->handle($J->encode({op => 'open', project => 'alpha'}));
ok(!$r->{ok}, "without an engine the open fails");
like($r->{error}, qr/not reachable|did not list/, "and says so");

# --- the socket: a request and its answer over the broker's own socket --------

my $bsock = "$tmp/broker.sock";
my $bpid = fork() // die "fork: $!";
if (!$bpid) {
    $b->{socket} = $bsock;
    $b->serve();
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $bsock; select(undef, undef, undef, 0.05) }
my $answer = main::ask($bsock, {op => 'open', project => 'beta'});
ok($answer->{ok}, "over the socket: open beta");
$answer = main::ask($bsock, {op => 'open', project => '../etc'});
ok(!$answer->{ok}, "over the socket: a bad project is refused");
kill 'TERM', $bpid;
waitpid($bpid, 0);

# --- the log: every request and every engine call, one line each ------------------

{
    my $logf = "$tmp/broker.log";
    open(my $lf, '>', $logf) or die "log: $!";
    my $old = $broker::LOG;
    $broker::LOG = $lf;
    $b->handle('{"op":"open","project":"../etc"}');
    $b->handle($J->encode({op => 'open', project => 'alpha'}));
    close($lf);
    $broker::LOG = $old;
    open(my $in, '<', $logf) or die "log: $!";
    my $text = do { local $/; <$in> };
    close($in);
    like($text, qr/request op=open project=\.\.\/etc -> refused: no such project/, "a refused request is logged, with the reason");
    like($text, qr/engine GET \/libpod\/pods\/json -> 200/, "an engine call is logged, with its status");
    like($text, qr/request op=open project=alpha -> ok/, "and an accepted one");
    unlike($text, qr/"mounts"|privileged/, "the body of a request is not logged");
}

# --- the program itself: started as the container starts it, it logs and listens

{
    my $cfg = "$tmp/broker.json";
    open(my $cf, '>', $cfg) or die "cfg: $!";
    print {$cf} $J->encode({root => $root, images => ['x:latest'], memory => '1g', pids => 64});
    close $cf;
    my $err = "$tmp/start.err";
    my $sock = "$tmp/start.sock";
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        open(STDERR, '>', $err) or POSIX::_exit(9);
        open(STDOUT, '>', "$tmp/start.out") or POSIX::_exit(9);
        $ENV{AI_BROKER_CONFIG} = $cfg;
        $ENV{AI_BROKER_HOST_ROOT} = '/host/projects';
        $ENV{AI_BROKER_SOCKET} = $sock;
        $ENV{AI_BROKER_ENGINE} = "$tmp/none.sock";
        exec($^X, "$FindBin::Bin/../broker.pl", 'serve') or POSIX::_exit(9);
    }
    for (1 .. 100) { last if -S $sock; select(undef, undef, undef, 0.05) }
    my $answer = main::ask($sock, {op => 'list'});
    kill 'TERM', $pid;
    waitpid($pid, 0);
    open(my $ef, '<', $err) or die "err: $!";
    my $log = do { local $/; <$ef> } // '';
    close $ef;
    like($log, qr/broker\[\d+\]: starting: root=\S+ host_root=\/host\/projects/, "the program logs its start, with the settings");
    like($log, qr/listening on \S+ as uid \d+/, "and that it listens, as which user");
    like($log, qr/request op=list project=- -> /, "and the requests it answers");
    ok(!$answer->{ok}, "list without an engine is refused, as it should be");
}

# --- the chunked answers of the engine ---------------------------------------

is(broker::_dechunk("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), "hello world", "a chunked answer is put together");

kill 'TERM', $epid;
waitpid($epid, 0);
done_testing();
