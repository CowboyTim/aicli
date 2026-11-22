#!/usr/bin/perl
# the model lists the sessions of its project and switches the page to one of them: the list
# is this project's (the empty ones left out, a filter on the names), a switch goes to a session
# of the same project only; the master does it when the turn is over, and only if the page is
# still on this session; a switch whose target is gone is refused as a failure.
use strict; use warnings;

use Test::More;
use File::Temp ();
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;

use ai;
use ui;

use TestAI;
use JSON::XS ();

TestAI::setup();
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_switch_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
for my $p ('acme/alpha', 'acme/beta') { my ($a) = $p =~ m{\A(.+)/}; mkdir "$root/$a" unless -d "$root/$a"; mkdir "$root/$p" or die "mkdir: $!" }
$ai::ROOT = $root;
$ai::SESSIONS_DIR = "$base/sessions";
mkdir $ai::SESSIONS_DIR or die;
$ui::OUTBOX = [];   # fake workers: no processes
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

pipe(my $page_rd, my $page_wr) or die "pipe: $!";
my $page = {out => '', account => undef, fh => $page_wr};
@ui::clients = ($page);
sub events {
    my $raw = '';
    my $rin = '';
    vec($rin, fileno($page_rd), 1) = 1;
    while (select(my $rout = $rin, undef, undef, 0)) {
        my $n = sysread($page_rd, my $buf, 65536);
        last unless $n;
        $raw .= $buf;
    }
    my @e;
    while ($raw =~ m/event: (\w+)\ndata: (.*?)\n\n/gs) { push @e, [$1, JSON::XS::decode_json($2)] }
    return @e;
}

# three sessions of alpha (one of them empty, left out of the list), one of beta
ui::_activate(undef, new => 1, project => 'acme/alpha') or die "alpha 1";
my $one = $ui::active;
ui::_activate(undef, new => 1, project => 'acme/alpha') or die "alpha 2";
my $two = $ui::active;
ui::_activate(undef, new => 1, project => 'acme/beta') or die "beta";
my $other = $ui::active;
# the newest one is the empty one (no chat): not listed (only this one is, if it is current)
ok(-d "$ai::SESSIONS_DIR/$two", "two sessions of alpha, one of beta");

{
    local $ai::EVENT_SINK = sub {};
    local $ai::AI_SESSION = $one;
    my $out = tools::list_sessions_3b7d(['']);
    like($out, qr/\Q$one\E  \(this one\)/, "the list has this session, marked");
    unlike($out, qr/\Q$other\E/, "not a session of another project");
    my $f = tools::list_sessions_3b7d(['zzz-no-such']);
    like($f, qr/no session of this project matches/, "a filter with no match says so");
    local $ai::IN_AGENT = 1;
    ok(!tools::available('list_sessions') && !tools::available('switch_session'), "a sub-agent has neither");
}
{
    local $ai::EVENT_SINK = undef;
    ok(!tools::available('list_sessions'), "not in the terminal");
}

# switching: the checks, then the request
my @sent;
{
    local $ai::EVENT_SINK = sub { push @sent, [@_] };
    local $ai::AI_SESSION = $one;
    my $ok = eval { tools::switch_session_5a1f([$two]) };
    like($ok, qr/the page will switch to \Q$two\E when this answer is over/, "a session of this project: accepted");
    is_deeply($sent[-1], ['switch', {to => $two}], "the request goes to the page's master");
    eval { tools::switch_session_5a1f([$other]) };
    like($@, qr/in another project/, "another project's session is refused");
    eval { tools::switch_session_5a1f(['no-such-one']) };
    like($@, qr/there is no session 'no-such-one'/, "a missing one is refused");
    eval { tools::switch_session_5a1f([$one]) };
    like($@, qr/this session is '\Q$one\E' already/, "its own is refused");
}

# the master: the request is kept, the page sees it, it is applied when the turn is over
ui::_activate($one) or die "the page on one";
$ui::worker{$one} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};
events();
ui::_worker_event($one, {event => 'switch', data => {to => $two}});
is($ui::pending_switch{$one}, $two, "kept");
my @st = grep {$_->[0] eq 'state' && ($_->[1]{switch} // '') eq $two} events();
ok(@st, "the page is told (a refresh too: in the state)");
is(ui::_master_state(undef)->{switch}, $two, "the state of a refresh has it");

ui::_worker_event($one, {event => 'turn', data => {state => 'end'}});
is($ui::active, $two, "the page switched to it when the turn was over");
ok(!defined $ui::pending_switch{$one}, "nothing pending");
ok(!defined ui::_master_state(undef)->{switch}, "the state has none");

# the page moved away before the turn ended: the switch is not done
ui::_activate(undef, new => 1, project => 'acme/alpha') or die;
my $here = $ui::active;
$ui::worker{$here} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};
ui::_worker_event($here, {event => 'switch', data => {to => $one}});
ui::_activate($other) or die "move away";
ui::_worker_event($here, {event => 'turn', data => {state => 'end'}});
is($ui::active, $other, "the page was elsewhere: it stays there");
ok(!defined $ui::pending_switch{$here}, "and the request is dropped");

# the target is gone by the time the turn ends: refused, the page is told
ui::_activate(undef, new => 1, project => 'acme/alpha') or die;
my $src = $ui::active;
$ui::worker{$src} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};
mkdir "$ai::SESSIONS_DIR/gone-soon" or die;
ui::_worker_event($src, {event => 'switch', data => {to => 'gone-soon'}});
rmdir "$ai::SESSIONS_DIR/gone-soon";
events();
ui::_worker_event($src, {event => 'turn', data => {state => 'end'}});
is($ui::active, $src, "refused: the page stays");
ok(scalar(grep {$_->[0] eq 'failed' && $_->[1]{text} =~ /did not happen/} events()), "and the page is told");

done_testing();
