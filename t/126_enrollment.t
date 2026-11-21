#!/usr/bin/perl
# the enrollment of agents (remote_hub.pm, no sockets): a user's enrollment token (only its
# hash is kept, a new one replaces it), an agent enrolled with it gets its own token (only its
# hash is kept), the names and tags checked, the agents of a user listed and revoked, and the
# state file that keeps them over a restart
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Digest::SHA ();
use JSON::XS ();
use lib "$FindBin::Bin/..";

use remote_hub;

my $J = JSON::XS->new->canonical(1)->utf8;
my $dir = File::Temp::tempdir(CLEANUP => 1, DIR => '/tmp');
my $file = "$dir/state.json";

sub conn { my @got; return {got => \@got, send => sub { push @got, [@_] }} }
sub poll_with { my ($t) = @_; return {method => 'GET', path => '/agents/poll', headers => {authorization => "Bearer $t"}} }
sub enroll_req { my ($body) = @_; return {method => 'POST', path => '/agents/enroll', headers => {}, body => $J->encode($body)} }

my $h = remote_hub->new(state_file => $file);

my $alice = $h->issue_enroll('alice');
ok(length($alice) >= 40, "an enrollment token is long");
like($alice, qr/\A[A-Za-z0-9_-]+\z/, "and URL-safe");
my $bob = $h->issue_enroll('bob');
ok($alice ne $bob, "each user gets their own");

# only the hash of the token is kept
open(my $fh, '<', $file) or die $!;
my $raw = do { local $/; <$fh> };
close($fh);
unlike($raw, qr/\Q$alice\E/, "the state has no enrollment token in it");
like($raw, qr/\Q@{[Digest::SHA::sha256_hex($alice)]}\E/, "the state has its hash");
is((stat($file))[2] & 07777, 0600, "the state file is 0600");

# an agent enrolls with the user's token
my $r = $h->enroll($alice, 'strix', ['arduino', 'gfx1151'], 100);
ok($r->{ok}, "an agent enrolls with the token of its user");
is($r->{name}, 'strix', "under its name");
is_deeply($r->{tags}, ['arduino', 'gfx1151'], "with its tags");
my $strix = $r->{token};
ok(length($strix) >= 40, "and gets its own token");
unlike(do { open(my $f2, '<', $file) or die; local $/; <$f2> }, qr/\Q$strix\E/, "the state has not the agent's token either");

# the token is reusable: a second agent of the same user
my $r2 = $h->enroll($alice, 'pi', ['zigbee'], 100);
ok($r2->{ok}, "the same token enrolls a second agent");
my $pi_token = $r2->{token};

# refusals
my $bad = $h->enroll('not-a-token-at-all-0000', 'x', ['arduino'], 100);
is($bad->{status}, 403, "a token that is no user's: 403");
is($h->enroll($alice, 'strix', ['arduino'], 100)->{status}, 409, "a name taken: 409");
is($h->enroll($alice, 'Bad Name', ['arduino'], 100)->{status}, 400, "a name with a space: 400");
is($h->enroll($alice, 'new1', [], 100)->{status}, 400, "no tags: 400");
is($h->enroll($alice, 'new1', ['Big'], 100)->{status}, 400, "a tag with a capital: 400");
is($h->enroll($alice, 'new1', 'arduino', 100)->{status}, 400, "tags that are not a list: 400");
is($h->enroll(undef, 'new1', ['arduino'], 100)->{status}, 403, "no token: 403");

# a new token replaces the old one of that user
my $alice2 = $h->issue_enroll('alice');
is($h->enroll($alice, 'new1', ['arduino'], 100)->{status}, 403, "the old token of alice no longer enrolls");
ok($h->enroll($alice2, 'new1', ['arduino'], 100)->{ok}, "the new one does");

# the agents of a user
my $list = $h->agents_of('alice');
is_deeply([map {$_->{name}} @$list], ['new1', 'pi', 'strix'], "alice's agents, by name");
is($list->[0]{online}, 0, "new1 has not polled: offline");
$h->{seen}{new1} = time;
is($h->agents_of('alice')->[0]{online}, 1, "new1 polled just now: online");
$h->{seen}{new1} = time - 3600;
is($h->agents_of('alice')->[0]{online}, 0, "and offline again an hour later");
is_deeply($h->agents_of('bob'), [], "bob has none");
ok(!exists $list->[0]{token_sha256}, "the list has no hashes");

# the agent's token works for its polls
my $c = conn();
$h->http(poll_with($strix), $c->{send}, 200);
ok(!@{$c->{got}}, "the enrolled agent's token: its poll is held");

# a revocation: only the owner, and the token stops working
is($h->revoke('bob', 'strix')->{ok}, 0, "bob cannot revoke alice's agent");
is($h->revoke('alice', 'strix')->{ok}, 1, "alice revokes her agent");
$c = conn();
$h->http(poll_with($strix), $c->{send}, 201);
is($c->{got}[0][0], 403, "the revoked agent's token: 403");
is_deeply([sort map {$_->{name}} @{$h->agents_of('alice')}], ['new1', 'pi'], "and it is gone from the list");
ok($h->agent_of_token($pi_token), "the other agents still work");

# the state file keeps the agents, and the enrollment, over a restart
my $again = remote_hub->new(state_file => $file);
is_deeply([sort map {$_->{name}} @{$again->agents_of('alice')}], ['new1', 'pi'], "after a restart: the agents are there");
is($again->agent_of_token($pi_token), 'pi', "and their tokens");
my $r3 = $again->enroll($alice2, 'late', ['arduino'], 300);
ok($r3->{ok}, "and the enrollment token works after a restart");

# a name of the config is taken by the state too
my $cfg = eval { remote_hub->new(state_file => $file, agents => {pi => {tags => ['x'], token_sha256 => Digest::SHA::sha256_hex('y')}}) };
like($@, qr/in the config and in the state/, "a name in both the config and the state is refused");

done_testing();
