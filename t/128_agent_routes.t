#!/usr/bin/perl
# the web interface's agent routes (ui.pm): a user's enrollment token, the list of the agents,
# a revocation. The user is the login's (X-Aicli-User, from nginx); without the login, or with a
# name that is not one, nothing is asked of the broker. The broker's answer goes back on the
# same connection. The broker is a stand-in here (ui::BROKER_ASK).
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use IO::Handle ();
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";

$::DEBUG = 0;
use ai;
use utils;
use ui;

my $J = JSON::XS->new->canonical(1)->utf8;
$ui::gate = 'gate-secret';

my @asked;
my $answer;
$ui::BROKER_ASK = sub { my ($req, $cb) = @_; push @asked, $req; $cb->($answer) };

# a connection with a socket pair: what the route answers is read from the other end
sub call {
    my ($m, $path, $h, $body) = @_;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die "socketpair: $!";
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    @asked = ();
    ui::_dispatch($cn, $m, $path, {'x-aicli-gate' => 'gate-secret', %{$h // {}}}, $body // '');
    my $raw = '';
    my $tries = 0;
    while ($tries++ < 50) {
        my $buf;
        my $n = sysread($b, $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if $cn->{closed} or ($raw =~ m/\r\n\r\n/ and defined $n and $n == 0);
        select(undef, undef, undef, 0.01);
    }
    close($a); close($b);
    my ($code) = $raw =~ m{\AHTTP/1\.1 (\d+)};
    my ($json) = $raw =~ m/\r\n\r\n(.*)\z/s;
    return ($code, eval {$J->decode($json // '')} // {});
}

my $user = {'x-aicli-user' => 'alice'};

$answer = {ok => JSON::XS::true(), token => 'enroll-token-0123456789abcdef'};
my ($code, $d) = call('POST', '/agent/token', $user, '{}');
is($code, 200, "a token: 200");
is($d->{token}, 'enroll-token-0123456789abcdef', "the token, from the broker");
is_deeply($asked[0], {op => 'enroll_token', user => 'alice'}, "asked for alice's token");

($code) = call('POST', '/agent/token', {'x-aicli-gate' => 'gate-secret'}, '{}');
is($code, 403, "no login name (no nginx): 403");
is(scalar @asked, 0, "and the broker is not asked");

($code) = call('POST', '/agent/token', {'x-aicli-user' => "al ice"}, '{}');
is($code, 403, "a login name with a space: 403");

$answer = {ok => JSON::XS::true(), agents => [{name => 'strix', tags => ['arduino'], enrolled => 1}]};
($code, $d) = call('GET', '/agent/list', $user, '');
is($code, 200, "the list: 200");
is($d->{agents}[0]{name}, 'strix', "its agents");
is_deeply($asked[0], {op => 'agents', user => 'alice'}, "asked for alice's agents");

$answer = {ok => JSON::XS::true()};
($code) = call('POST', '/agent/revoke', $user, '{"name":"strix"}');
is($code, 200, "a revocation: 200");
is_deeply($asked[0], {op => 'agent_revoke', user => 'alice', name => 'strix'}, "asked to revoke it, for alice");

($code) = call('POST', '/agent/revoke', $user, '{}');
is($code, 400, "a revocation without a name: 400");

$answer = {ok => JSON::XS::false(), error => "no agent 'strix' of yours"};
($code, $d) = call('POST', '/agent/revoke', $user, '{"name":"strix"}');
is($code, 502, "the broker refuses: 502, with its reason");
is($d->{error}, "no agent 'strix' of yours", "and the reason");

done_testing();
