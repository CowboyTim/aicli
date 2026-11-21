#!/usr/bin/perl
# the enrollment end to end: a broker process with its state file, the socket operations the
# web interface uses (a token for a user, the agents of a user, a revocation), `ai.pl --enroll`
# on a machine (the agent's token is kept in agent.json), `ai.pl --agent` with that file (no
# token on its command line) running a job, and the revoked agent's job refused.
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
use lib "$FindBin::Bin/..";

my $J = JSON::XS->new->canonical(1)->utf8;
my $broker_pl = Cwd::abs_path("$FindBin::Bin/../broker.pl");
my $ai_pl     = Cwd::abs_path("$FindBin::Bin/../ai.pl");

my $tmp = File::Temp::tempdir(CLEANUP => 1, DIR => '/tmp');
mkdir "$tmp/ai";
my $socket = "$tmp/broker.sock";

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
open(my $cfh, '>', "$tmp/broker.json") or die $!;
print {$cfh} $J->encode({socket => $socket});
close($cfh);

my $broker_pid = fork();
if (!$broker_pid) {
    $ENV{AI_BROKER_CONFIG} = "$tmp/broker.json";
    $ENV{AI_BROKER_SOCKET} = $socket;
    $ENV{AI_BROKER_AGENT_LISTEN} = "127.0.0.1:$agent_port";
    $ENV{AI_BROKER_STATE} = "$tmp/state.json";
    open(STDERR, '>', "$tmp/broker.log");
    exec($^X, $broker_pl, 'serve') or POSIX::_exit(127);
}
ok(wait_for(sub { -S $socket and IO::Socket::IP->new(PeerAddr => '127.0.0.1', PeerPort => $agent_port) }, 10),
    "the broker listens for its tools and its agents");

# one request on the Unix socket, the answer when there is one
sub ask {
    my ($req) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $socket, Type => Socket::SOCK_STREAM()) or return {ok => 0, error => "no socket: $!"};
    print {$c} $J->encode($req)."\n";
    my $line = do { local $/ = "\n"; <$c> } // '';
    close($c);
    return eval {$J->decode($line)} // {ok => 0, error => "no answer: $line"};
}

# the web interface's operations for a user
my $t = ask({op => 'enroll_token', user => 'acme'});
ok($t->{ok}, "a token for alice");
my $token = $t->{token};
ok(length($token) >= 40, "a long one");
ok(!ask({op => 'agents'})->{ok}, "the agents need a user");

# a wrong token is refused by ai.pl --enroll, and nothing is kept
my $out = `$^X $ai_pl --enroll not-the-token-0123456789abcdef --broker http://127.0.0.1:$agent_port --name strix --tags arduino 2>&1`;
my $rc = $? >> 8;
is($rc, 1, "a wrong token: ai.pl --enroll fails");
like($out, qr/the enrollment token is not any user/, "and says so");
ok(!-e "$tmp/ai/agent.json", "no agent.json for a refused enrollment");

# the enrollment of this machine
$out = `AI_DIR=$tmp/ai $^X $ai_pl --enroll $token --broker http://127.0.0.1:$agent_port --name strix --tags arduino,gfx1151 2>&1`;
is($? >> 8, 0, "ai.pl --enroll succeeds");
like($out, qr/enrolled strix \(tags: arduino, gfx1151\)/, "and says what it enrolled");
ok(-f "$tmp/ai/agent.json", "its credentials are kept");
is((stat("$tmp/ai/agent.json"))[2] & 07777, 0600, "in a file only the user reads");
unlike($out, qr/\Q$token\E/, "the enrollment token is not printed");

# a second enrollment on the same machine reuses its agent: no second agent, the file kept
my $file_before = do { local $/; open(my $fh, '<', "$tmp/ai/agent.json") or die $!; <$fh> };
$out = `AI_DIR=$tmp/ai $^X $ai_pl --enroll $token --broker http://127.0.0.1:$agent_port --name strix --tags arduino 2>&1`;
is($? >> 8, 0, "a second enrollment on this machine: ok");
like($out, qr/reusing strix/, "it reuses strix");
is(do { local $/; open(my $fh, '<', "$tmp/ai/agent.json") or die $!; <$fh> }, $file_before, "agent.json is kept as it was");
$out = `AI_DIR=$tmp/ai $^X $ai_pl --enroll $token --broker http://127.0.0.1:$agent_port --name other --tags arduino 2>&1`;
is($? >> 8, 1, "another name on this machine: refused");
like($out, qr/this machine's agent is strix/, "and says so");

my $list = ask({op => 'agents', user => 'acme'});
is_deeply([map {$_->{name}} @{$list->{agents}}], ['strix'], "alice's agents: strix");
is_deeply($list->{agents}[0]{tags}, ['arduino', 'gfx1151'], "with its tags");
is(ask({op => 'agents', user => 'bob'})->{agents}[0], undef, "bob has none");

# the agent runs, with the credentials of its file only
my $agent_pid = fork();
if (!$agent_pid) {
    %ENV = (AI_DIR => "$tmp/ai", PATH => $ENV{PATH}, HOME => $tmp);
    open(STDERR, '>', "$tmp/agent.log");
    exec($^X, $ai_pl, '--agent', '--programs', 'perl', '--work', "$tmp/work") or POSIX::_exit(127);
}

my $first;
ok(wait_for(sub {
    $first = ask({op => 'exec', project => 'acme/alpha', tags => ['arduino'], argv => ['perl', '-e', 'print "from strix\n"']});
    ($first->{error} // '') !~ /is connected/;
}, 20), "the enrolled agent connects");
is($first->{exit}, 0, "the job runs on it");
is(MIME::Base64::decode_base64($first->{output}), "from strix\n", "its output comes back");

# a revocation: the job is refused from then on
my $rev = ask({op => 'agent_revoke', user => 'acme', name => 'strix'});
ok($rev->{ok}, "acme revokes strix");
is_deeply(ask({op => 'agents', user => 'acme'})->{agents}, [], "and it is gone");
my $after = ask({op => 'exec', project => 'acme/alpha', tags => ['arduino'], argv => ['perl', '-v']});
like($after->{error}, qr/no agent of acme with the tags \(arduino\) is configured/, "a job for its tags: no agent now");

# one command: the enrollment with --programs runs the agent at once (no second run, no --token);
# the enrollment token enrolls any number of agents, so the same token is used again
my $one_pid = fork();
if (!$one_pid) {
    %ENV = (AI_DIR => "$tmp/ai2", PATH => $ENV{PATH}, HOME => $tmp);
    open(STDERR, '>', "$tmp/one.log");
    open(STDOUT, '>', "$tmp/one.out");
    exec($^X, $ai_pl, '--enroll', $token, '--broker', "http://127.0.0.1:$agent_port", '--name', 'oneshot',
        '--tags', 'arduino', '--programs', 'perl', '--work', "$tmp/work2") or POSIX::_exit(127);
}
my $one;
ok(wait_for(sub {
    $one = ask({op => 'exec', project => 'acme/alpha', tags => ['arduino'], argv => ['perl', '-e', 'print "one command\n"']});
    ($one->{error} // '') !~ /is connected|is configured/;
}, 20), "the enrollment runs the agent at once");
is(MIME::Base64::decode_base64($one->{output} // ''), "one command\n", "and its job runs");
ok(-f "$tmp/ai2/agent.json", "its credentials are kept for the next start");

kill 'TERM', $one_pid, $agent_pid, $broker_pid;
waitpid($_, 0) for $one_pid, $agent_pid, $broker_pid;

done_testing();
