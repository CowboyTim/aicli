#!/usr/bin/perl
# the model opens and closes pods itself: the projects of the broker (pods), the cap on
# the open pods, the idle close, and the three tools (pods, pod_open, pod_close) over a
# real broker socket with a fake engine. The engine keeps its pods in its own process.
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

# the fake engine: the pods (name => status), as libpod answers for them
my $engine = "$base/engine.sock";
my $epid = fork() // die "fork: $!";
if (!$epid) {
    my %pods = ('aicli-alpha' => 'Running');
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
        if ($method eq 'GET' and $path eq '/libpod/pods/json') {
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

my @images = ('img-a', 'img-b');
my %notes = ('img-a' => 'the first image', 'img-b' => 'the second image');
my %cfg = (root => $root, host_root => '/host/projects', engine => $engine, images => \@images,
    image_notes => \%notes, max_pods => 2, idle_minutes => 30);

# the broker in this process (no socket): the cap, the idle close, the start after a restart
my $b = broker->new(%cfg, socket => "$base/unused.sock");
is($b->{idle}, 1800, "the idle time: 30 minutes, in seconds");

my $p = $b->_projects();
ok($p->{ok}, "projects answers");
is_deeply([map {$_->{name}} @{$p->{projects}}], [qw(alpha beta gamma)], "the projects are the directories under the root (not the file)");
ok($p->{projects}[0]{open}, "alpha is open (its pod runs)");
ok(!$p->{projects}[1]{open}, "beta is closed");
is($p->{open_count}, 1, "one pod open");
is($p->{max_pods}, 2, "with the cap");
is_deeply([map {$_->{name}} @{$p->{images}}], \@images, "the images");
is($p->{images}[0]{note}, 'the first image', "with their notes");

my $r = $b->_open({project => 'beta', image => 'bad'});
ok(!$r->{ok}, "an image that is not allowed is refused");
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

# the idle close: alpha unused for an hour is closed, gamma (used now) stays
$b->{last}{alpha} = time - 3600;
$b->_reap();
$p = $b->_projects();
my %open = map {$_->{name} => $_->{open}} @{$p->{projects}};
ok(!$open{alpha}, "alpha, unused for an hour, is closed by the idle check");
ok($open{gamma}, "gamma, used now, stays open");

# a broker started again: the pods it finds count from its start, so none is closed at once
my $b2 = broker->new(%cfg, socket => "$base/unused2.sock");
$b2->_reap();
$p = $b2->_projects();
%open = map {$_->{name} => $_->{open}} @{$p->{projects}};
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
ok(tools::available('pod_open'), "pod_open is there");
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
like($out, qr/gamma  open  \(this session's project\)/, "pods: the session's project is marked, and open");
like($out, qr/alpha  closed/, "pods: a closed project");
like($out, qr/img-a  the first image/, "pods: the images with their notes");
like($out, qr/1 of 2 pods open/, "pods: the open count and the cap");

my $bash = tools::bash_7c48(['echo hi']);
like($bash, qr/ran: exec --workdir \/work aicli-gamma-dev bash -c echo hi/, "bash runs in the open pod of the session");

$out = tools::pod_close_c03a(['gamma']);
like($out, qr/pod of gamma is closed; this session's bash, perl and grep need it open again/, "pod_close: says the session needs it open again");
my $ok = eval { tools::bash_7c48(['echo']); 1 };
ok(!$ok, "bash in the closed pod is refused");
like($@, qr/not open/, "and says so");

$out = tools::pod_open_9d52(['alpha', 'img-a']);
like($out, qr/pod of alpha is open \(made now\)/, "pod_open: a pod that was closed is made now");
$out = tools::pod_open_9d52(['alpha']);
like($out, qr/pod of alpha is open \(it was open\)/, "pod_open of an open pod says it was open");
$out = tools::pod_open_9d52(['gamma']);
like($out, qr/pod of gamma is open/, "pod_open of gamma: the second pod");
$ok = eval { tools::pod_open_9d52(['beta']); 1 };
ok(!$ok, "a third pod is refused by the cap");
like($@, qr/pods are open already/, "and the tool says why");
$ok = eval { tools::pod_open_9d52(['']); 1 };
ok(!$ok, "pod_open without a project is refused");
like($@, qr/a project name is wanted/, "and says what is wanted");
$ok = eval { tools::pod_open_9d52(['gamma', 'bad']); 1 };
ok(!$ok, "pod_open with an image that is not allowed is refused");
like($@, qr/not allowed/, "and says so");
$ok = eval { tools::pod_close_c03a(['nosuch']); 1 };
ok(!$ok, "pod_close of no project is refused");
like($@, qr/no such project/, "and says so");

kill 'TERM', $bpid; waitpid($bpid, 0);
kill 'TERM', $epid; waitpid($epid, 0);
done_testing();
