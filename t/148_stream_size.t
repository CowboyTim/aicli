#!/usr/bin/perl
# the page's event stream stays small: a client that is sent more than 1 MB unread is closed (see ui::_queue),
# so the history of a session keeps to a budget (the newest exchanges), a call's arguments are cut, and an
# event that is too big has its long texts cut before it is queued
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $tmp = TestAI::setup();

# a session with many exchanges of 5 KB, and one write of 1.5 MB
my $name = 'stream-size-test';
mkdir "$ai::SESSIONS_DIR/$name" or die "mkdir: $!";
open(my $fh, '>', "$ai::SESSIONS_DIR/$name/chat") or die $!;
for my $i (1 .. 150) {
    print {$fh} $J->encode({role => 'user', content => "question $i"}), "\n";
    print {$fh} $J->encode({role => 'assistant', content => ("answer $i " x 500)}), "\n";
}
print {$fh} $J->encode({role => 'user', content => 'write it'}), "\n";
print {$fh} $J->encode({role => 'assistant', content => '', tool_calls => [{id => 'call_w', type => 'function',
    function => {name => 'write', arguments => $J->encode({path => 'big.txt', content => 'x' x 1_500_000})}}]}), "\n";
print {$fh} $J->encode({role => 'tool', tool_call_id => 'call_w', content => "[OK] written to big.txt\n"}), "\n";
close $fh;

my $h = ui::_history_data($name);
my $bytes = length($J->encode($h));
ok($bytes < $ui::HISTORY_BYTES + 64 * 1024, "the history takes at most its budget ($bytes bytes)");
ok(${$h->{more}}, "the older exchanges are not in it, and the page is told");
my @msgs = @{$h->{messages}};
ok(@msgs < 200, "fewer than the 200 items (" . scalar(@msgs) . ")");
is($msgs[-1]{role}, 'tool', "the newest is there: the write's result");
my ($w) = grep {($_->{role} // '') eq 'tool' && ($_->{full} // '') =~ /WRITE/} @msgs;
ok($w, "the write's call is in the history");
ok(length($w->{full}) < 5000, "with its content cut (" . length($w->{full}) . " characters)");
like($w->{full}, qr/\(cut: \d+ more characters\)/, "and the cut says how much is not shown");

# an event that is too big to send is cut before it is queued: the client gets it, and stays open
socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
$a->blocking(0); $b->blocking(0);
my $cn = {fh => $a, out => '', req => '', account => undef};
local @ui::clients = ($cn);
ui::publish(tool => {text => 'line', full => 'z' x 1_200_000});
my $raw = '';
for (1 .. 50) {
    my $n = sysread($b, my $buf, 65536);
    if (defined $n and $n > 0) { $raw .= $buf; next }
    last if defined $n and $n == 0;
    select(undef, undef, undef, 0.01);
}
ok(length($raw) > 0 && length($raw) < 1_000_000, "the event goes to the client, under 1 MB (" . length($raw) . " bytes)");
like($raw, qr/event: tool/, "as the tool event");
like($raw, qr/\(cut: the chat has the rest\)/, "its long text is cut, and that is said");
ok(!$cn->{closed}, "the client is not closed");

done_testing();
