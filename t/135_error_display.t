#!/usr/bin/perl
# the errors of a tool are read whole on the page: a line is not cut at the terminal's width (the
# page wraps it), an error has more lines
use strict; use warnings;

use Test::More;
use FindBin;
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;
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

done_testing();
