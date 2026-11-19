#!/usr/bin/perl
# a remote agent end to end: the broker process (its agent listener and its Unix socket) and an
# `ai.pl --agent` process that polls it with its token. (nginx in front is not here: the agent
# would reach it over TLS, and the listener takes the same requests.) A tool call on an agent's
# kind goes out, runs in the agent's project directory, and comes back with its output and exit
# code. Refusals: the agent's own program list, the kind's list, an open, a wrong token.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use POSIX ();
use MIME::Base64 ();
use IO::Socket::UNIX ();
use IO::Socket::IP ();
use JSON::XS ();
use Digest::SHA ();
use lib "$FindBin::Bin/..";

my $J = JSON::XS->new->canonical(1)->utf8;
my $broker_pl = Cwd::abs_path("$FindBin::Bin/../broker.pl");
my $ai_pl     = Cwd::abs_path("$FindBin::Bin/../ai.pl");
my $TOKEN = 'agent-token-'.$$.'-0123456789abcdef';

plan skip_all => "no perl for the child processes" unless -x $^X;

my $tmp = File::Temp::tempdir(CLEANUP => 1, DIR => '/tmp');
mkdir "$tmp/root"; mkdir "$tmp/root/acme"; mkdir "$tmp/root/acme/alpha";
mkdir "$tmp/ai";

sub free_port {
    my $s = IO::Socket::IP->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die "port: $!";
    my $p = $s->sockport; close $s; return $p;
}

sub wait_for {
    my ($test, $secs) = @_;
    for (1 .. $secs * 10) { return 1 if $test->(); select(undef, undef, undef, 0.1) }
    return 0;
}

my $agent_port = free_port();
my $socket = "$tmp/broker.sock";

my $cfg = {
    root => "$tmp/root", host_root => "$tmp/root", socket => $socket, engine => "$tmp/no-engine.sock",
    pods => {
        arduino => {tags => ['arduino'], programs => ['perl', 'bash'], note => 'boards'},
    },
    agents => {strix => {tags => ['arduino'], token_sha256 => Digest::SHA::sha256_hex($TOKEN), user => 'acme'}},
};
open(my $cfh, '>', "$tmp/broker.json") or die $!;
print {$cfh} $J->encode($cfg);
close($cfh);

# the broker: the Unix socket for the tools, the listener for the agents
my $broker_pid = fork();
if (!$broker_pid) {
    $ENV{AI_BROKER_CONFIG} = "$tmp/broker.json";
    $ENV{AI_BROKER_SOCKET} = $socket;
    $ENV{AI_BROKER_AGENT_LISTEN} = "127.0.0.1:$agent_port";
    open(STDERR, '>', "$tmp/broker.log");
    exec($^X, $broker_pl, 'serve') or POSIX::_exit(127);
}
ok(wait_for(sub { -S $socket and IO::Socket::IP->new(PeerAddr => '127.0.0.1', PeerPort => $agent_port) }, 10),
    "the broker listens for its tools and its agents");

# the agent: ai.pl --agent, its own process, no chat and no key
my $agent_pid = fork();
if (!$agent_pid) {
    %ENV = (AI_DIR => "$tmp/ai", PATH => $ENV{PATH}, HOME => $tmp);
    open(STDERR, '>', "$tmp/agent.log");
    exec($^X, $ai_pl, '--agent', '--broker', "http://127.0.0.1:$agent_port", '--name', 'strix',
        '--programs', 'perl', '--work', "$tmp/work", '--token', $TOKEN) or POSIX::_exit(127);
}

# a tool's call: one JSON line to the Unix socket, the answer comes when the agent has run it
sub ask {
    my ($req) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $socket, Type => Socket::SOCK_STREAM()) or return {ok => 0, error => "no socket: $!"};
    print {$c} $J->encode($req)."\n";
    my $line = do { local $/ = "\n"; <$c> } // '';
    close($c);
    return eval {$J->decode($line)} // {ok => 0, error => "no answer: $line"};
}

# the agent connects (its first poll); until then the broker says so, which is retried
my $first;
ok(wait_for(sub {
    $first = ask({op => 'exec', project => 'acme/alpha', pod => 'arduino', argv => ['perl', '-e', 'print "hi\n"; exit 3']});
    ($first->{error} // '') !~ /is connected/;
}, 20), "the agent connects");
is($first->{ok}, 1, "the job ran on the agent");
is($first->{exit}, 3, "its exit code");
is(MIME::Base64::decode_base64($first->{output}), "hi\n", "its output");

my $where = ask({op => 'exec', project => 'acme/alpha', pod => 'arduino',
    argv => ['perl', '-MCwd', '-e', 'print Cwd::getcwd()']});
is(MIME::Base64::decode_base64($where->{output}), "$tmp/work/acme/alpha", "the job runs in the project's directory on the agent");

my $bash = ask({op => 'exec', project => 'acme/alpha', pod => 'arduino', argv => ['bash', '-c', 'echo no']});
is($bash->{exit}, 126, "a program the kind lists but the agent does not run: refused by the agent");
like(MIME::Base64::decode_base64($bash->{output}), qr/refused: bash is not a program of this agent/, "and says so");

my $nope = ask({op => 'exec', project => 'acme/alpha', pod => 'arduino', argv => ['ls']});
ok(!$nope->{ok}, "a program the kind does not list: refused by the broker");
like($nope->{error}, qr/not in the arduino pod/, "and says so");

my $open = ask({op => 'open', project => 'acme/alpha', pod => 'arduino'});
ok(!$open->{ok}, "open refuses a kind on an agent");
like($open->{error}, qr/runs on an agent/, "and says so");

my $unknown = ask({op => 'exec', project => 'acme/alpha', pod => 'rocm', argv => ['perl', '-v']});
like($unknown->{error}, qr/no such pod/, "a kind that is not configured: refused");

kill 'TERM', $agent_pid, $broker_pid;
waitpid($_, 0) for $agent_pid, $broker_pid;

done_testing();
