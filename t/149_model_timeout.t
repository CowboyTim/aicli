#!/usr/bin/perl
# the start does not hang on a model server that takes the connection and never answers: the model list and
# the context are asked with a timeout (ai::LIST_TIMEOUT), and the start goes on with no models
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use IO::Socket::INET ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use utils;
use TestAI;

# a listener nobody accepts from: the kernel takes the connection, the answer never comes
my $silent = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "listen: $!";
my $port = $silent->sockport;
my $tmp = TestAI::setup(AI_LOCAL_SERVER => "http://127.0.0.1:$port", AI_TOOL_CALLS => 'native');
$ai::AI_ENDPOINT_URL = "http://127.0.0.1:$port";
$ai::LIST_TIMEOUT = 2;
$ai::LIST_CONNECT_TIMEOUT = 2;

my $t0 = Time::HiRes::time();
my $models = ai::fetch_models();
my $secs = Time::HiRes::time() - $t0;
ok(!defined $models, "a model list that never comes is no list");
ok(defined $utils::http_error, "and the request ends with an error: " . ($utils::http_error // ''));
cmp_ok($secs, '>=', 1.5, "the request waited for its timeout (" . sprintf('%.1f', $secs) . " s)");
cmp_ok($secs, '<', 10, "and not longer");

# the start itself: the command table is built and goes on, with no models
$t0 = Time::HiRes::time();
@ai::MODELS = ();
ai::setup_commands();
$secs = Time::HiRes::time() - $t0;
is(scalar(@ai::MODELS), 0, "the start goes on with no models");
cmp_ok($secs, '<', 15, "the start takes the timeouts, not a hang (" . sprintf('%.1f', $secs) . " s)");

done_testing();
