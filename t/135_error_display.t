#!/usr/bin/perl
# the errors of a tool are read whole on the page: a line is not cut at the terminal's width (the
# page wraps it), an error has more lines; and the broker keeps the engine's own text of a failure
# (a pull that is refused says why) instead of an empty reason
use strict; use warnings;

use Test::More;
use FindBin;
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;
require "$FindBin::Bin/../broker.pl";
TestAI::setup();

my $long = join('', map {"word$_ "} 1 .. 60); # longer than the 100 columns of the terminal
my $cut = ai::to_text(ai::clip_lines($long, 8, "  "));   # bytes, as the tools make them
like($cut, qr/\x{2026}/, "in a terminal a long line is cut at the width");
{
    local $ai::EVENT_SINK = sub {};
    my $whole = ai::to_text(ai::clip_lines($long, 8, "  "));
    unlike($whole, qr/\x{2026}/, "on the page it is not cut");
    my $many = join("\n", map {"line $_"} 1 .. 30);
    my $err = ai::clip_lines($many, 40, "  ");
    like($err, qr/line 30/, "an error of 30 lines is shown whole (up to 40)");
    unlike(ai::clip_lines($many, 8, "  "), qr/line 30/, "a result of 30 lines is still cut to 8");
}

my $b = broker->new(root => "/tmp", host_root => "/tmp", socket => "/tmp/unused.sock",
    pods => {base => {image => 'reg.example/aicli/pod-base:latest', programs => ['bash']}});
my $refused = JSON::XS->new->encode({message => 'unauthorized: authentication required'});
like($b->_failed('the image x could not be pulled', 401, $refused)->{error},
    qr/unauthorized: authentication required/, "a message of the engine is in the reason");
my $text = JSON::XS->new->encode({error => 'initializing source docker://reg.example/aicli/pod-base:latest: reading manifest: unauthorized'});
like($b->_failed('the image x could not be pulled', 500, $text)->{error},
    qr/reading manifest: unauthorized/, "a body with no known field: its text is the reason, all of it");
is($b->_failed('the image x could not be pulled', 500, '')->{error},
    'the image x could not be pulled (engine answered 500)', "an empty answer: no reason, as before");

done_testing();
