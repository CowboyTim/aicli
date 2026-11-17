#!/usr/bin/perl
# the tools in the project's pod: bash, perl and grep of a workspace that is a
# project run in its dev container, through the broker (a real broker process, a
# fake engine, and a stand-in for the engine's client that shows what it is given)
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use Socket ();
use IO::Socket::UNIX ();
use POSIX ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use utils;
use TestAI;

my $broker_file = Cwd::abs_path("$FindBin::Bin/../broker.pl");
TestAI::setup();
my $J = JSON::XS->new->canonical(1)->utf8;
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_podt_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/projects";
mkdir $root or die "mkdir: $!";
mkdir "$root/alpha" or die "mkdir: $!";
mkdir "$root/alpha/src" or die "mkdir: $!";
mkdir "$root/loose" or die "mkdir: $!";
open(my $fh, '>', "$root/alpha/src/main.txt") or die "file: $!";
print {$fh} "needle here\n";
close $fh;

# a fake engine that knows the pod of alpha (open) and nothing else
my $engine = "$base/engine.sock";
my $epid = fork() // die "fork: $!";
if (!$epid) {
    my $srv = IO::Socket::UNIX->new(Local => $engine, Type => Socket::SOCK_STREAM(), Listen => 5) or POSIX::_exit(1);
    my %pods = ('aicli-alpha' => 1);
    while (my $c = $srv->accept) {
        my $buf = '';
        while ($buf !~ m/\r\n\r\n/) { my $n = sysread($c, my $x, 4096); last unless $n; $buf .= $x }
        my ($head) = split /\r\n\r\n/, $buf, 2;
        my ($method, $path) = $head =~ m{\A(\S+) (\S+)};
        $path =~ s{\A/v[0-9.]+}{};
        my ($code, $resp) = (404, '{}');
        if ($method eq 'GET' and $path eq '/libpod/pods/json') {
            ($code, $resp) = (200, $J->encode([map {{Name => $_, Status => 'Running'}} sort keys %pods]));
        } elsif ($method eq 'GET' and $path =~ m{\A/libpod/containers/([^/]+)/json\z}) {
            my $pod = $1 =~ s/-dev\z//r;
            ($code, $resp) = $pods{$pod} ? (200, '{"State":{"Running":true}}') : (404, '{}');
        }
        print {$c} "HTTP/1.1 $code X\r\nContent-Length: ".length($resp)."\r\nConnection: close\r\n\r\n$resp";
        close $c;
    }
    POSIX::_exit(0);
}

# the broker, with a stand-in for podman-remote: it prints its argv and exits 3 for "fail"
my $bsock = "$base/broker.sock";
my $bpid = fork() // die "fork: $!";
if (!$bpid) {
    require $broker_file;
    my $b = broker->new(root => $root, host_root => '/host/projects', engine => $engine, images => ['x'],
        socket => $bsock, remote => [$^X, '-e', 'print "ran: @ARGV\n"; exit(($ARGV[-1] // "") eq "fail" ? 3 : 0)', '--']);
    close(STDERR); open(STDERR, '>', "$base/broker.err");
    $b->serve();
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $bsock && -S $engine; select(undef, undef, undef, 0.05) }

$::ORIG_ENV{AI_POD_ROOT} = $root;
$::ORIG_ENV{AI_BROKER_SOCKET} = $bsock;
$ai::WORKSPACE = "$root/alpha";

my $out = tools::bash_7c48(['echo hi']);
like($out, qr/ran: exec --workdir \/work aicli-alpha-dev bash -c echo hi/, "bash runs in the dev container of the project, as bash -c");

my $ok = eval { tools::bash_7c48(['fail']); 1 };
ok(!$ok, "a command that fails is a tool error");
like($@, qr/exit code: 3/, "with the exit code of the command");

$out = tools::grep_6629(["$root/alpha/src", 'needle']);
like($out, qr/ran: exec --workdir \/work aicli-alpha-dev grep -rn -e needle -- src\n/, "grep: the path is the pod's, relative to the project");

# the process is in its workspace, as a worker is
chdir("$root/alpha/src");
$ai::WORKSPACE = "$root/alpha/src";
$out = tools::grep_6629(['.', 'needle']);
like($out, qr/-- \.\n/, "a workspace inside the project: paths relative to it");
chdir("$root/alpha");
$ai::WORKSPACE = "$root/alpha";

$ai::WORKSPACE = $root; # the root itself is no project
$ok = eval { tools::bash_7c48(['echo']); 1 };
ok(!$ok, "a workspace that is no project is refused");
like($@, qr/not one/, "and says so");
$ai::WORKSPACE = "$root/loose"; # a project whose pod is not open
$ok = eval { tools::bash_7c48(['echo']); 1 };
ok(!$ok, "a project without an open pod is refused");
like($@, qr/not open/, "and says so");

$ai::WORKSPACE = "$root/alpha";
$ok = eval { tools::grep_6629(["/etc/passwd", 'root']); 1 };
ok(!$ok, "a path outside the project is refused");

$::ORIG_ENV{AI_POD_TOOLS} = 0;
delete $::ORIG_ENV{AI_POD_ROOT};
$out = tools::bash_7c48(['echo local']);
like($out, qr/local/, "without AI_POD_ROOT the tools run here, as before");

chdir('/');
kill 'TERM', $bpid; waitpid($bpid, 0);
kill 'TERM', $epid; waitpid($epid, 0);
done_testing();
