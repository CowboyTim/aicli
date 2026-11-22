#!/usr/bin/perl
# the model renames its session: the tool checks the name and sends the request (only in the
# web interface, not for a sub-agent); the master keeps it, shows it on the page (also on a
# refresh), and does it when the session's turn is over and no input is queued. A name that is
# taken at that time is refused as a failure of the session.
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
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_rename_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
mkdir "$root/acme" or die; mkdir "$root/acme/alpha" or die;
$ai::ROOT = $root;
$ai::SESSIONS_DIR = "$base/sessions";
mkdir $ai::SESSIONS_DIR or die;
# a page: what the master sends to it comes out of a pipe, read back here
pipe(my $page_rd, my $page_wr) or die "pipe: $!";
$ui::OUTBOX = [];  # the sessions are fake workers here: no processes
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
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

# the tool: available for the page only, and for the page's own session
my $sink = sub {};
{
    local $ai::EVENT_SINK = $sink;
    local $ai::IN_AGENT = 0;
    ok(tools::available('rename_session'), "the page's session can rename itself");
    local $ai::IN_AGENT = 1;
    ok(!tools::available('rename_session'), "a sub-agent cannot");
}
{
    local $ai::EVENT_SINK = undef;
    ok(!tools::available('rename_session'), "not in the terminal");
}

# ui::_activate makes a session in the project (the page's); the tool names it
ok(ui::_activate(undef, new => 1, project => 'acme/alpha'), "a session in acme/alpha");
my $old = $ui::active;
ok(-d "$ai::SESSIONS_DIR/$old", "it is on disk");

my @sent;
{
    local $ai::EVENT_SINK = sub { push @sent, [@_] };
    local $ai::AI_SESSION = $old;
    my $ok = eval { tools::rename_session_8f2c(['renamed-one']) };
    like($ok, qr/renamed to renamed-one when this answer is over/, "the tool accepts a name");
    is_deeply($sent[-1], ['rename', {to => 'renamed-one'}], "and sends the request for the page");
    eval { tools::rename_session_8f2c(['bad name']) };
    like($@, qr/the name 'bad name'/, "a name with a space is refused");
    eval { tools::rename_session_8f2c(['']) };
    like($@, qr/a session name is wanted/, "an empty name is refused");
    eval { tools::rename_session_8f2c([$old]) };
    like($@, qr/this session is '\Q$old\E' already/, "its own name is refused");
    mkdir "$ai::SESSIONS_DIR/taken" or die;
    eval { tools::rename_session_8f2c(['taken']) };
    like($@, qr/there is a session 'taken' already/, "a taken name is refused");
    rmdir "$ai::SESSIONS_DIR/taken";
}

# the master: a fake worker (no process) that is busy, then its turn ends
$ui::worker{$old} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};
events();
ui::_worker_event($old, {event => 'rename', data => {to => 'renamed-one'}});
is($ui::pending_rename{$old}, 'renamed-one', "the request is kept");
my @st = grep {$_->[0] eq 'state' && ($_->[1]{rename} // '') eq 'renamed-one'} events();
ok(@st, "the page is told it is pending (state, for a refresh too)");
my $s = ui::_master_state(undef);
is($s->{rename}, 'renamed-one', "a refresh gets it in the state");
ok(-d "$ai::SESSIONS_DIR/$old", "the session is not renamed while its turn runs");

ui::_worker_event($old, {event => 'turn', data => {state => 'end'}});
ok(!-d "$ai::SESSIONS_DIR/$old", "the turn is over: the old name is gone");
ok(-d "$ai::SESSIONS_DIR/renamed-one", "and the session is in the new one");
is($ui::active, 'renamed-one', "the page is on it");
ok(!defined $ui::pending_rename{$old}, "nothing pending any more");
ok(!defined ui::_master_state(undef)->{rename}, "and the state has no rename");

# queued input: the rename waits until nothing is queued
ui::_activate(undef, new => 1, project => 'acme/alpha') or die;
my $q = $ui::active;
$ui::worker{$q} = {fake => 1, busy => 1, pending => 1, seen => time(), closing => 0};
ui::_worker_event($q, {event => 'rename', data => {to => 'queued-one'}});
ui::_worker_event($q, {event => 'turn', data => {state => 'end'}});
ok(-d "$ai::SESSIONS_DIR/$q", "queued input: not renamed at this end");
$ui::worker{$q}{pending} = 0;
ui::_worker_event($q, {event => 'turn', data => {state => 'end'}});
ok(-d "$ai::SESSIONS_DIR/queued-one", "renamed at the end with nothing queued");

# a name taken by the time the turn ends: refused, the page is told, the session stays
ui::_activate(undef, new => 1, project => 'acme/alpha') or die;
my $r = $ui::active;
$ui::worker{$r} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};
mkdir "$ai::SESSIONS_DIR/was-free" or die;
ui::_worker_event($r, {event => 'rename', data => {to => 'was-free'}});
events();
ui::_worker_event($r, {event => 'turn', data => {state => 'end'}});
ok(-d "$ai::SESSIONS_DIR/$r", "refused: the session keeps its name");
ok(scalar(grep {$_->[0] eq 'failed' && $_->[1]{text} =~ /did not happen/} events()), "and the page is told");

done_testing();
