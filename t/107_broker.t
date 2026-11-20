#!/usr/bin/perl
# the broker (broker.pl) without sockets: what a request may ask of it. It runs no program and
# holds no project: a job (exec) goes to an agent of the project's account with the job's tags,
# and the user's agents are kept for the web interface (enrollment, list, revocation). Anything
# else is refused. The agents that answer are in t/123 to t/127.
use strict; use warnings;

use Test::More;
use FindBin;
use JSON::XS ();
use lib "$FindBin::Bin/..";

require "$FindBin::Bin/../broker.pl";

my $J = JSON::XS->new->canonical(1)->utf8;

# a broker with one agent of acme, not connected: its jobs are refused at once
my $b = broker->new(socket => '/tmp/unused.sock', agents => {
    pi => {tags => ['zigbee'], token_sha256 => ('a' x 64), user => 'acme'},
});

sub send_of { my @got; return {got => \@got, send => sub { push @got, $_[0] }} }
sub req { my ($r) = @_; return $b->_dispatch($J->encode($r), undef) }

# the request is one JSON object
like(broker->new(socket => '/tmp/x')->_dispatch("not json", undef)->{error}, qr/a JSON object is wanted/, "not JSON: refused");
like($b->_dispatch("[1,2]", undef)->{error}, qr/a JSON object is wanted/, "a JSON list: refused");

# the operations the broker has now: the pod ones are gone
for my $op (qw(open close list projects)) {
    my $r = req({op => $op, project => 'acme/alpha'});
    ok(!$r->{ok}, "$op is not an operation of the broker");
    like($r->{error}, qr/unknown request '$op'/, "and says so");
}
like(req({op => 'nope'})->{error}, qr/unknown request 'nope'/, "an unknown operation: refused");

# a job: the project, its tags, the program and its arguments
like(req({op => 'exec', project => 'acme/alpha', argv => ['perl', '-v']})->{error}, qr/a list of tags is wanted/,
    "no tags: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => [], argv => ['perl', '-v']})->{error}, qr/a list of tags is wanted/,
    "an empty list of tags: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['Zig Bee'], argv => ['perl', '-v']})->{error}, qr/a list of tags is wanted/,
    "a tag that is not a short lower-case word: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => []})->{error}, qr/a list of the program/,
    "no program: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => 'perl -v'})->{error}, qr/a list of the program/,
    "a command as a string, not a list: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => [['perl']]})->{error}, qr/a list of the program/,
    "an argument that is a list: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => ['x' x 300000]})->{error}, qr/too long/,
    "a command over the size cap: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => ['perl'], timeout => 0})->{error}, qr/a timeout/,
    "a timeout of 0: refused");
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => ['perl'], timeout => 99999})->{error}, qr/a timeout/,
    "a timeout over the broker's limit: refused");

# a project that is not account/project
like(req({op => 'exec', project => 'alpha', tags => ['zigbee'], argv => ['perl']})->{error}, qr/no such project/,
    "a project with no account: refused");
like(req({op => 'exec', project => 'acme/../alpha', tags => ['zigbee'], argv => ['perl']})->{error}, qr/no such project/,
    "a project with a dot-dot: refused");
like(req({op => 'exec', tags => ['zigbee'], argv => ['perl']})->{error}, qr/no such project/,
    "no project: refused");

# a job with no way to answer is refused (the caller has no connection to wait on)
like(req({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => ['perl']})->{error}, qr/needs a connection/,
    "a job with no connection to answer on: refused");

# a job for an agent: the agent's account and tags; not connected: the answer is refused now
{
    my $c = send_of();
    my $r = $b->_dispatch($J->encode({op => 'exec', project => 'acme/alpha', tags => ['zigbee'], argv => ['perl', '-v']}), $c->{send});
    ok(!defined $r, "a job is answered later, through the connection");
    is(scalar @{$c->{got}}, 1, "and it is answered once");
    like($c->{got}[0]{error}, qr/no agent of acme with the tags \(zigbee\) is connected/, "the agent of acme is not connected");
}
{
    my $c = send_of();
    $b->_dispatch($J->encode({op => 'exec', project => 'bob/alpha', tags => ['zigbee'], argv => ['perl', '-v']}), $c->{send});
    like($c->{got}[0]{error}, qr/no agent of bob with the tags \(zigbee\) is configured/,
        "a project of another account: its agents only (none here)");
}
{
    my $c = send_of();
    $b->_dispatch($J->encode({op => 'exec', project => 'acme/alpha', tags => ['zigbee', 'gfx1151'], argv => ['perl']}), $c->{send});
    like($c->{got}[0]{error}, qr/with the tags \(zigbee gfx1151\) is configured/, "an agent must have every tag: none has these");
}

# the user's agents, for the web interface
my $t = req({op => 'enroll_token', user => 'acme'});
ok($t->{ok}, "a user's enrollment token");
ok(length($t->{token}) >= 40, "a long one");
like(req({op => 'enroll_token'})->{error}, qr/a user \(an account name\) is wanted/, "no user: refused");
like(req({op => 'enroll_token', user => 'a b'})->{error}, qr/a user \(an account name\) is wanted/, "a user with a space: refused");
ok(req({op => 'agents', user => 'acme'})->{ok}, "the user's agents");
like(req({op => 'agent_revoke', user => 'acme'})->{error}, qr/a name of an agent is wanted/, "a revocation needs a name");

# the project names: the shape only, nothing is read from the disk
ok($b->project_name('acme/alpha'), "a project's name is account/project");
is($b->project_name('acme/alpha/x'), undef, "not three parts");

done_testing();
