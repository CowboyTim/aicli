#!/usr/bin/perl
# the broker's side of the remote agents (remote_hub.pm), with no sockets: the agents of the
# config and their tokens (only the SHA-256 is kept), held polls and the jobs for the tags, the
# answers, and the times (a poll that ends, a job nobody takes, an agent that does not answer)
use strict; use warnings;

use Test::More;
use FindBin;
use MIME::Base64 ();
use Digest::SHA ();
use JSON::XS ();
use lib "$FindBin::Bin/..";

use remote_hub;

my $J = JSON::XS->new->canonical(1)->utf8;

# the agents' tokens (the config has their hashes only)
my %TOKEN = (pi => 'pi-token-0123456789abcdef', strix => 'strix-token-0123456789abcdef');
sub hash_of { return Digest::SHA::sha256_hex($_[0]) }

# a connection: records what it was answered, in order
sub conn { my @got; return {got => \@got, send => sub { push @got, [@_] }} }

sub hub {
    return remote_hub->new(agents => {
        pi    => {tags => ['zigbee', 'armv6'], token_sha256 => hash_of($TOKEN{pi})},
        strix => {tags => ['arduino', 'gfx1151'], token_sha256 => hash_of($TOKEN{strix})},
    });
}

sub poll { my ($auth) = @_; return {method => 'GET', path => '/agents/poll',
    headers => {authorization => $auth}} }
sub bearer { my ($name) = @_; return "Bearer $TOKEN{$name}" }

sub result { my ($auth, $id, $body) = @_; return {method => 'POST', path => "/agents/result/$id",
    headers => {authorization => $auth}, body => $body} }

# the first answer of a connection, decoded when it has a job
sub job_of { my ($c) = @_; my $a = $c->{got}[0] or return undef; return $a->[0] == 200 ? $J->decode($a->[1]) : undef }

# nothing configured: disabled
ok(remote_hub->new(agents => {})->enabled, "no agents: the listener is still on, for an enrollment");
eval { remote_hub->new(agents => {'pi' => {tags => []}}) };
like($@, qr/its token/, "an agent without its token hash is refused");
eval { remote_hub->new(agents => {'bad name' => {tags => [], token_sha256 => hash_of('x')}}) };
like($@, qr/an agent's name/, "an agent name with a space is refused");
eval { remote_hub->new(agents => {pi => {tags => ['Big Tag'], token_sha256 => hash_of('x')}}) };
like($@, qr/a tag is a short lower-case word/, "a tag with a capital is refused");
eval { remote_hub->new(agents => {pi => {tags => [], token_sha256 => 'not-a-hash'}}) };
like($@, qr/its token/, "a token hash that is not sha256 is refused");

# who gets in: the token of a configured agent, and nothing else
{
    my $h = hub();
    my $c = conn();
    $h->http(poll('Bearer nope-nope-nope-nope-nope'), $c->{send}, 100);
    is($c->{got}[0][0], 403, "a token that is not any agent's: 403");
    $c = conn();
    $h->http(poll(undef), $c->{send}, 100);
    is($c->{got}[0][0], 403, "no token: 403");
    $c = conn();
    $h->http(poll('Basic '.$TOKEN{pi}), $c->{send}, 100);
    is($c->{got}[0][0], 403, "not a bearer token: 403");
    $c = conn();
    $h->http({method => 'GET', path => '/nope', headers => {authorization => bearer('pi')}}, $c->{send}, 100);
    is($c->{got}[0][0], 404, "a path that is not one of the agents': 404");
    is($h->agent_of_token($TOKEN{strix}), 'strix', "the token names its agent");
    is($h->agent_of_token(undef), undef, "no token names no agent");
}

# a held poll, a job for its tags, the answer
{
    my $h = hub();
    my $pi = conn();
    $h->http(poll(bearer('pi')), $pi->{send}, 100);
    ok(!@{$pi->{got}}, "a poll with no job is held");
    my ($done, $id);
    $id = $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['perl', '-e', 'print 1'], timeout => 30,
        now => 101, done => sub { $done = shift });
    ok($id, "a job for the zigbee tag is queued");
    my $job = job_of($pi);
    ok($job, "the held poll of pi gets the job");
    is($job->{id}, $id, "the job's id");
    is_deeply($job->{argv}, ['perl', '-e', 'print 1'], "its argv");
    is($job->{project}, 'alpha', "its project");
    ok(!defined $done, "the job is not answered yet");

    # the wrong agent cannot answer it
    my $strix = conn();
    $h->http(poll(bearer('strix')), $strix->{send}, 102);
    my $c = conn();
    $h->http(result(bearer('strix'), $id, '{"exit":0,"output":""}'), $c->{send}, 103);
    is($c->{got}[0][0], 404, "another agent cannot answer the job: 404");

    # a poll while busy
    $c = conn();
    $h->http(poll(bearer('pi')), $c->{send}, 103);
    is($c->{got}[0][0], 409, "a busy agent that polls again: 409");

    $c = conn();
    $h->http(result(bearer('pi'), $id, '{"exit":3,"output":"'.MIME::Base64::encode_base64("out\n", '').'"}'), $c->{send}, 104);
    is($c->{got}[0][0], 200, "the agent's answer: 200");
    is_deeply($done, {ok => JSON::XS::true(), exit => 3, output => "out\n"}, "the job's answer: exit and output");
    $c = conn();
    $h->http(result(bearer('pi'), $id, '{"exit":0,"output":""}'), $c->{send}, 105);
    is($c->{got}[0][0], 404, "an answer twice: 404");
}

# bad answers
{
    my $h = hub();
    my $pi = conn();
    $h->http(poll(bearer('pi')), $pi->{send}, 100);
    my $done;
    my $id = $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], timeout => 5, now => 100, done => sub { $done = shift });
    my $c = conn();
    $h->http(result(bearer('pi'), $id, 'not json'), $c->{send}, 101);
    is($c->{got}[0][0], 400, "an answer that is not JSON: 400");
    $c = conn();
    $h->http(result(bearer('pi'), 'a' x 24, '{"exit":0}'), $c->{send}, 101);
    is($c->{got}[0][0], 404, "an answer for a job that is not there: 404");
    ok(!defined $done, "and the job stays open");
}

# no agent for the tags, and no agent connected
{
    my $h = hub();
    my ($done, $r);
    $r = $h->submit(project => 'alpha', tags => ['rocm'], argv => ['x'], now => 100, done => sub { $done = shift });
    ok(!$r, "no agent has the rocm tag: no job");
    like($done->{error}, qr/no agent with the tags \(rocm\) is configured/, "and the reason");
    $done = undef;
    $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], now => 100, done => sub { $done = shift });
    like($done->{error}, qr/is connected/, "an agent with the tag that never polled: not connected");
    $done = undef;
    $h->http(poll(bearer('pi')), conn()->{send}, 200);
    $h->tick(200);
    $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], now => 201, done => sub { $done = shift });
    ok(!defined $done, "an agent that polled lately (its poll held): the job queues");
}

# times: a held poll ends, a job nobody takes is refused, an agent that does not answer loses its job
{
    my $h = hub();
    my $pi = conn();
    $h->http(poll(bearer('pi')), $pi->{send}, 100);
    $h->tick(100 + $remote_hub::POLL_WAIT - 1);
    ok(!@{$pi->{got}}, "a poll is held until its time");
    $h->tick(100 + $remote_hub::POLL_WAIT);
    is($pi->{got}[0][0], 204, "then it ends with 204");

    # pi is not polling now, but polled lately: the job queues
    my $done;
    $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], now => 150, done => sub { $done = shift });
    ok(!defined $done, "a job waits for pi, which polled lately");
    $h->tick(150 + $remote_hub::JOB_WAIT - 1);
    ok(!defined $done, "still waiting before JOB_WAIT");
    $h->tick(150 + $remote_hub::JOB_WAIT);
    like($done->{error}, qr/no agent took the job/, "after JOB_WAIT the job is refused");
}
{
    my $h = hub();
    my $pi = conn();
    $h->http(poll(bearer('pi')), $pi->{send}, 300);
    my $done;
    my $id = $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], timeout => 20, now => 300, done => sub { $done = shift });
    ok(job_of($pi), "pi takes the job");
    $h->tick(300 + 20 + $remote_hub::GRACE - 1);
    ok(!defined $done, "the agent has its timeout and the grace to answer");
    $h->tick(300 + 20 + $remote_hub::GRACE);
    like($done->{error}, qr/did not answer in time/, "after that the job is refused");
    my $c = conn();
    $h->http(poll(bearer('pi')), $c->{send}, 400);
    ok(!$c->{got}[0] || $c->{got}[0][0] != 409, "and the agent is free again");
    $c = conn();
    $h->http(result(bearer('pi'), $id, '{"exit":0}'), $c->{send}, 401);
    is($c->{got}[0][0], 404, "a late answer is refused");
}

# an answer with a huge output is cut
{
    my $h = hub();
    my $pi = conn();
    $h->http(poll(bearer('pi')), $pi->{send}, 100);
    my $done;
    my $id = $h->submit(project => 'alpha', tags => ['zigbee'], argv => ['x'], timeout => 5, now => 100, done => sub { $done = shift });
    my $big = MIME::Base64::encode_base64('a' x ($remote_hub::MAX_OUT + 10), '');
    $h->http(result(bearer('pi'), $id, $J->encode({exit => 0, output => $big})), conn()->{send}, 101);
    like($done->{output}, qr/\[output cut\]\n\z/, "an output over the cap is cut");
    ok(length($done->{output}) < $remote_hub::MAX_OUT + 30, "to the cap");
}

done_testing();
