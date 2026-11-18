#!/usr/bin/perl
# the model opens and closes pods itself: the projects of the broker (pods), the kinds
# of pod (base, node), the cap on the open pods, the idle close, and the four tools
# (pods, pod_open, pod_close, pod_run) over a real broker socket with a fake engine.
# The engine keeps its pods in its own process.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use Socket ();
use IO::Socket::UNIX ();
use POSIX ();
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use utils;
use TestAI;

my $broker_file = Cwd::abs_path("$FindBin::Bin/../broker.pl");
require $broker_file;
TestAI::setup();
my $J = JSON::XS->new->canonical(1)->utf8;
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_podc_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/projects";
mkdir $root or die "mkdir: $!";
mkdir "$root/$_" or die "mkdir: $!" for qw(alpha beta gamma);
open(my $touch, '>', "$root/afile") or die "file: $!";
close $touch;

# the fake engine: the pods (name => status), as libpod answers for them. Every image is there.
my $engine = "$base/engine.sock";
my $epid = fork() // die "fork: $!";
if (!$epid) {
    my %pods = ('aicli-base-alpha' => 'Running');
    my %ctrs;   # the dev containers: a pod's container goes with the pod
    my $srv = IO::Socket::UNIX->new(Local => $engine, Type => Socket::SOCK_STREAM(), Listen => 5) or POSIX::_exit(1);
    while (my $c = $srv->accept) {
        my $buf = '';
        while ($buf !~ m/\r\n\r\n/) { my $n = sysread($c, my $x, 4096); last unless $n; $buf .= $x }
        my ($head, $body) = split /\r\n\r\n/, $buf, 2;
        my ($len) = $head =~ m/Content-Length:\s*(\d+)/i;
        while (defined $len and length($body // '') < $len) { my $n = sysread($c, my $x, 4096); last unless $n; $body .= $x }
        my ($method, $path) = $head =~ m{\A(\S+) (\S+)};
        $path =~ s{\A/v[0-9.]+}{};
        $path =~ s/\?.*\z//;
        my ($code, $resp) = (404, '{}');
        if ($method eq 'GET' and $path =~ m{\A/libpod/images/}) {
            ($code, $resp) = (200, '{}');
        } elsif ($method eq 'POST' and $path eq '/libpod/images/pull') {
            ($code, $resp) = (200, '{}');
        } elsif ($method eq 'GET' and $path eq '/libpod/pods/json') {
            ($code, $resp) = (200, $J->encode([map {{Name => $_, Status => $pods{$_}}} sort keys %pods]));
        } elsif ($method eq 'POST' and $path eq '/libpod/pods/create') {
            my $name = $J->decode($body)->{name};
            ($code, $resp) = $pods{$name} ? (409, '{}') : do { $pods{$name} = 'Created'; (201, '{}') };
        } elsif ($method eq 'POST' and $path eq '/libpod/containers/create') {
            my $name = $J->decode($body)->{name} // '';
            ($code, $resp) = $ctrs{$name} ? (409, '{}') : do { $ctrs{$name} = 1; (201, '{}') };
        } elsif ($method eq 'POST' and $path =~ m{\A/libpod/pods/([^/]+)/(start|stop)\z}) {
            my ($pod, $act) = ($1, $2);
            if ($pods{$pod}) { $pods{$pod} = $act eq 'start' ? 'Running' : 'Exited'; ($code, $resp) = (200, '{}') }
        } elsif ($method eq 'DELETE' and $path =~ m{\A/libpod/pods/([^/]+)\z}) {
            if (delete $pods{$1}) { delete $ctrs{"$1-dev"}; ($code, $resp) = (200, '{}') }
        } elsif ($method eq 'GET' and $path =~ m{\A/libpod/containers/([^/]+)/json\z}) {
            my $pod = $1 =~ s/-dev\z//r;
            ($code, $resp) = ($pods{$pod} and $pods{$pod} eq 'Running') ? (200, '{"State":{"Running":true}}') : (404, '{}');
        }
        print {$c} "HTTP/1.1 $code X\r\nContent-Length: ".length($resp)."\r\nConnection: close\r\n\r\n$resp";
        close $c;
    }
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $engine; select(undef, undef, undef, 0.05) }

my %cfg = (root => $root, host_root => '/host/projects', engine => $engine, max_pods => 2, idle_minutes => 30,
    pods => {
        base => {image => 'img-a', programs => [qw(bash perl grep)], note => 'the basic tools'},
        node => {image => 'img-n', programs => [qw(node npm npx)], note => 'nodejs'},
    });

# the broker in this process (no socket): the kinds, the cap, the idle close, the start after a restart
my $b = broker->new(%cfg, socket => "$base/unused.sock");
is($b->{idle}, 1800, "the idle time: 30 minutes, in seconds");

my $p = $b->_projects();
ok($p->{ok}, "projects answers");
is_deeply([map {$_->{name}} @{$p->{projects}}], [qw(alpha beta gamma)], "the projects are the directories under the root (not the file)");
ok($p->{projects}[0]{pods}{base}, "alpha's base pod runs");
ok(!$p->{projects}[1]{pods}{base}, "beta's base pod is closed");
ok(!$p->{projects}[0]{pods}{node}, "and alpha has no node pod");
is($p->{open_count}, 1, "one pod open");
is($p->{max_pods}, 2, "with the cap");
is_deeply([map {$_->{name}} @{$p->{pods}}], [qw(base node)], "the kinds of pod");
is($p->{pods}[0]{note}, 'the basic tools', "with their notes");
is_deeply($p->{pods}[1]{programs}, [qw(node npm npx)], "and their programs");
ok(!exists $p->{pods}[0]{image}, "the images are not for the model");

my $r = $b->_open({project => 'beta', pod => 'nosuch'});
ok(!$r->{ok}, "a kind the config does not name is refused");
like($r->{error}, qr/no such pod: 'nosuch'/, "and says so");
$r = $b->_open({project => 'beta'});
ok($r->{ok}, "beta opens (the cap is 2, alpha is one)");
ok($r->{created}, "and is made now");
$r = $b->_open({project => 'gamma'});
ok(!$r->{ok}, "a third pod is refused: the cap");
like($r->{error}, qr/2 pods are open already/, "and says so");
$r = $b->_open({project => 'alpha'});
ok($r->{ok}, "a pod that is open already opens again (it is not counted against the cap)");
$r = $b->_close({project => 'beta'});
ok($r->{ok}, "beta closes");
$r = $b->_open({project => 'gamma'});
ok($r->{ok}, "so gamma can open");
$r = $b->_open({project => 'alpha', pod => 'node'});
ok(!$r->{ok}, "a node pod counts against the same cap");

# the idle close: alpha unused for an hour is closed, gamma (used now) stays
$b->{last}{'base/alpha'} = time - 3600;
$b->_reap();
$p = $b->_projects();
my %open = map {$_->{name} => $_->{pods}{base}} @{$p->{projects}};
ok(!$open{alpha}, "alpha, unused for an hour, is closed by the idle check");
ok($open{gamma}, "gamma, used now, stays open");

# a broker started again: the pods it finds count from its start, so none is closed at once
my $b2 = broker->new(%cfg, socket => "$base/unused2.sock");
$b2->_reap();
$p = $b2->_projects();
%open = map {$_->{name} => $_->{pods}{base}} @{$p->{projects}};
ok($open{gamma}, "after a restart an open pod is not closed at once");

# the tools, through a broker that serves its socket (a stand-in client for podman-remote)
my $bsock = "$base/broker.sock";
my $bpid = fork() // die "fork: $!";
if (!$bpid) {
    my $served = broker->new(%cfg, socket => $bsock,
        remote => [$^X, '-e', 'print "ran: @ARGV\n"; exit 0', '--']);
    close(STDERR); open(STDERR, '>', "$base/broker.err");
    $served->serve();
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $bsock; select(undef, undef, undef, 0.05) }

$::ORIG_ENV{AI_POD_ROOT} = $root;
$::ORIG_ENV{AI_BROKER_SOCKET} = $bsock;
$ai::WORKSPACE = "$root/gamma";

ok(tools::available('pods'), "the pod tools are there with a root");
ok(tools::available('pod_run'), "and pod_run");
{
    local $::ORIG_ENV{AI_POD_TOOLS} = 0;
    ok(!tools::available('pods'), "AI_POD_TOOLS=0 takes them away");
}
{
    local $::ORIG_ENV{AI_POD_ROOT};
    delete $::ORIG_ENV{AI_POD_ROOT};
    ok(!tools::available('pod_close'), "and without a root");
}

my $out = tools::pods_4b1e([]);
like($out, qr/gamma  base open, node closed  \(this session's project\)/, "pods: the session's project is marked, with its pods");
like($out, qr/alpha  base closed, node closed/, "pods: a closed project");
like($out, qr/base  bash perl grep  \(the basic tools\)/, "pods: the kinds with their programs");
like($out, qr/node  node npm npx  \(nodejs\)/, "and the node kind");
like($out, qr/1 of 2 pods open/, "pods: the open count and the cap");

my $bash = tools::bash_7c48(['echo hi']);
like($bash, qr/ran: exec --workdir \/work aicli-base-gamma-dev bash -c echo hi/, "bash runs in the open base pod of the session");

$out = tools::pod_close_c03a(['gamma']);
like($out, qr/base pod of gamma is closed; this session's bash, perl and grep need it open again/, "pod_close: says the session needs it open again");
my $ok = eval { tools::bash_7c48(['echo']); 1 };
ok($ok, "bash in a closed base pod opens it first");

$out = tools::pod_open_9d52(['alpha', 'base']);
like($out, qr/base pod of alpha is open \(made now\)/, "pod_open: alpha's base pod was closed by the idle check, so it is made now");
$out = tools::pod_open_9d52(['gamma']);
like($out, qr/base pod of gamma is open \(it was open\)/, "pod_open with no kind is the base pod, and it was open (the bash call before)");
$ok = eval { tools::pod_open_9d52(['beta']); 1 };
ok(!$ok, "a third pod is refused by the cap");
like($@, qr/pods are open already/, "and the tool says why");
$ok = eval { tools::pod_open_9d52(['']); 1 };
ok(!$ok, "pod_open without a project is refused");
like($@, qr/a project name is wanted/, "and says what is wanted");
$ok = eval { tools::pod_open_9d52(['gamma', 'bad']); 1 };
ok(!$ok, "pod_open of a kind the config does not name is refused");
like($@, qr/no such pod: 'bad'/, "and says so");
$ok = eval { tools::pod_close_c03a(['nosuch']); 1 };
ok(!$ok, "pod_close of no project is refused");
like($@, qr/no such project/, "and says so");

# pod_run: a toolchain's program in its own pod; the basic tools' pod runs only its own programs
$out = tools::pod_close_c03a(['alpha']);
like($out, qr/base pod of alpha is closed/, "alpha's base pod closes, to make room for a node pod");
$out = tools::pod_run_5a7e(['node', 'node -v']);
like($out, qr/ran: exec --workdir \/work aicli-node-gamma-dev node -v/, "pod_run: node runs in the node pod of the session's project");
$ok = eval { tools::pod_run_5a7e(['base', 'node -v']); 1 };
ok(!$ok, "node is not a program of the base pod");
like($@, qr/not in the base pod \(its programs: bash, perl, grep\)/, "and the broker says what the base pod runs");
$ok = eval { tools::pod_run_5a7e(['', 'node -v']); 1 };
ok(!$ok, "pod_run without a kind is refused");
like($@, qr/a pod kind is wanted/, "and says so");

kill 'TERM', $bpid; waitpid($bpid, 0);
kill 'TERM', $epid; waitpid($epid, 0);
done_testing();
