#!/usr/bin/perl
# the pods of the web interface: the master asks the broker (a real broker.pl
# process, over its socket, with a fake engine) to open, close and list the
# projects' pods, in a child of the loop; the answers are events for the page
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
use ui;
use utils;
use TestAI;

my $broker_file = Cwd::abs_path("$FindBin::Bin/../broker.pl"); # before setup, which changes directory
TestAI::setup();
my $J = JSON::XS->new->canonical(1)->utf8;
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_pods_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/projects";
mkdir $root or die "mkdir: $!";
mkdir "$root/alpha" or die "mkdir: $!";
mkdir "$root/beta" or die "mkdir: $!";
$ai::ROOT = $root;

# the list of projects comes from the root; the pods from the broker
my $data = ui::_pods_data({ok => JSON::XS::true(), pods => [{name => 'aicli-base-alpha', status => 'Running'}]});
is_deeply([map {[$_->{name}, $_->{status}, $_->{open} ? 1 : 0]} @{$data->{projects}}],
    [['alpha', 'Running', 1], ['beta', 'not started', 0]],
    "the projects with the state of their pods");
ok(!$data->{available}, "without a broker socket the pods are not available");

# --- a fake engine, and the broker in front of it, as the container runs it ---

my $engine = "$base/engine.sock";
my $bsock  = "$base/broker.sock";
my $epid = fork() // die "fork: $!";
if (!$epid) {
    my $srv = IO::Socket::UNIX->new(Local => $engine, Type => Socket::SOCK_STREAM(), Listen => 5) or POSIX::_exit(1);
    my %pods;
    while (my $c = $srv->accept) {
        my $buf = '';
        while ($buf !~ m/\r\n\r\n/) { my $n = sysread($c, my $x, 4096); last unless $n; $buf .= $x }
        my ($head, $body) = split /\r\n\r\n/, $buf, 2;
        $body //= '';
        my ($len) = $head =~ m/Content-Length: (\d+)/i;
        while (length($body) < ($len // 0)) { my $n = sysread($c, my $x, 4096); last unless $n; $body .= $x }
        my ($method, $path) = $head =~ m{\A(\S+) (\S+)};
        $path =~ s{\A/v[0-9.]+}{};
        my ($code, $resp) = (404, '{"cause":"not faked"}');
        if ($method eq "GET" and $path =~ m{\A/libpod/images/}) {
            ($code, $resp) = (200, "{}"); # the image is there
        } elsif ($method eq "POST" and $path =~ m{\A/libpod/images/pull}) {
            ($code, $resp) = (200, "{}");
        } elsif ($method eq "GET" and $path eq "/libpod/pods/json") {
            ($code, $resp) = (200, $J->encode([map {{Name => $_, Status => 'Running'}} sort keys %pods]));
        } elsif ($method eq 'POST' and $path eq '/libpod/pods/create') {
            $pods{$J->decode($body)->{name}} = 1; ($code, $resp) = (201, '{}');
        } elsif ($method eq 'POST' and $path eq '/libpod/containers/create') {
            ($code, $resp) = (201, '{"Id":"c"}');
        } elsif ($method eq 'POST' and $path =~ m{\A/libpod/pods/([^/]+)/start\z}) {
            ($code, $resp) = (200, '{}');
        } elsif ($method eq 'POST' and $path =~ m{\A/libpod/pods/([^/]+)/stop\z}) {
            ($code, $resp) = (200, '{}');
        } elsif ($method eq 'DELETE' and $path =~ m{\A/libpod/pods/([^/?]+)}) {
            delete $pods{$1}; ($code, $resp) = (200, '{}');
        }
        print {$c} "HTTP/1.1 $code X\r\nContent-Length: ".length($resp)."\r\nConnection: close\r\n\r\n$resp";
        close $c;
    }
    POSIX::_exit(0);
}
my $bpid = fork() // die "fork: $!";
if (!$bpid) {
    my $b = do { local @ARGV; require $broker_file; broker->new(root => $root, host_root => '/host/projects', engine => $engine, images => ['x:latest'], socket => $bsock) };
    close(STDERR); open(STDERR, '>', "$base/broker.err");
    $b->serve();
    POSIX::_exit(0);
}
for (1 .. 100) { last if -S $bsock && -S $engine; select(undef, undef, undef, 0.05) }

# the master asks the broker by its socket: the answer is a broker event, then the pods
$ui::BROKER_SOCKET = $bsock;
my @got;
{
    no warnings 'redefine';
    local *ui::publish = sub { push @got, [@_] };
    ui::_pod_request('open', 'alpha');
    loop::run(sub { grep {$_->[0] eq 'pods'} @got });
}
my ($broker_ev) = grep {$_->[0] eq 'broker'} @got;
ok($broker_ev, "the answer of the broker comes as an event");
ok($broker_ev->[1]{ok}, "open alpha is done");
is($broker_ev->[1]{pod}, 'aicli-base-alpha', "and names the pod");
my ($pods_ev) = grep {$_->[0] eq 'pods'} @got;
ok($pods_ev && $pods_ev->[1]{available}, "then the pods are sent again, with the broker there");
my ($alpha) = grep {$_->{name} eq 'alpha'} @{$pods_ev->[1]{projects}};
ok($alpha && $alpha->{open}, "and alpha has its pod");

@got = ();
{
    no warnings 'redefine';
    local *ui::publish = sub { push @got, [@_] };
    ui::_pod_request('close', 'alpha');
    loop::run(sub { grep {$_->[0] eq 'pods'} @got });
}
ok((grep {$_->[0] eq 'broker' and $_->[1]{ok}} @got), "close alpha is done");
($pods_ev) = grep {$_->[0] eq 'pods'} @got;
($alpha) = grep {$_->{name} eq 'alpha'} @{$pods_ev->[1]{projects}};
ok(!$alpha->{open}, "and alpha has no pod any more");

# a broker that is not there: the page is told why, nothing else breaks
$ui::BROKER_SOCKET = "$base/nobody.sock";
@got = ();
{
    no warnings 'redefine';
    local *ui::publish = sub { push @got, [@_] };
    ui::_pod_request('list', undef);
    loop::run(sub { grep {$_->[0] eq 'pods'} @got });
}
my ($err) = grep {$_->[0] eq 'broker'} @got;
ok($err && !$err->[1]{ok}, "without the broker the request is refused");
like($err->[1]{error}, qr/not reachable/, "and says so");

kill 'TERM', $bpid; waitpid($bpid, 0);
kill 'TERM', $epid; waitpid($epid, 0);
done_testing();
