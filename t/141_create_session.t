#!/usr/bin/perl
# the model makes a session in its project: the worker names it and asks the master, which makes it
# in the project (with the files a new session has) and lists it; a switch to it in the same answer
# is accepted (the master has it when the turn is over); the same name twice is refused; not for
# a sub-agent or the terminal.
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
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_create_XXXXXX", TMPDIR => 1, CLEANUP => 1));
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

ui::_activate(undef, new => 1, project => 'acme/alpha') or die "alpha";
my $here = $ui::active;
$ui::worker{$here} = {fake => 1, busy => 1, pending => 0, seen => time(), closing => 0};

# availability
{
    local $ai::EVENT_SINK = sub {};
    local $ai::IN_AGENT = 0;
    ok(tools::available('create_session'), "the page's session can make one");
    local $ai::IN_AGENT = 1;
    ok(!tools::available('create_session'), "a sub-agent cannot");
}
{
    local $ai::EVENT_SINK = undef;
    ok(!tools::available('create_session'), "not in the terminal");
}

# the tool: a name, an event for the page, the name known here for a switch
my @sent;
my $new;
{
    local $ai::EVENT_SINK = sub { push @sent, [@_] };
    local $ai::AI_SESSION = $here;
    my $out = tools::create_session_9d4e([]);
    ($new) = $out =~ /session (session-\S+) is made/;
    ok($new, "the tool names the new session: $new");
    is($sent[-1][0], 'create', "and asks the master to make it");
    is($sent[-1][1]{name}, $new, "that name");
    ok(!-d "$ai::SESSIONS_DIR/$new", "it is not on disk yet (the master makes it)");
    my $ok = eval { tools::switch_session_5a1f([$new]) };
    like($ok, qr/the page will switch to \Q$new\E/, "a switch to it in the same answer is accepted");
}

# a name given: used when it is free, refused when it is not or is not a name
{
    local $ai::EVENT_SINK = sub { push @sent, [@_] };
    local $ai::AI_SESSION = $here;
    my $out = tools::create_session_9d4e(['my-topic']);
    like($out, qr/session my-topic is made/, "a name given is the name made");
    is($sent[-1][1]{name}, 'my-topic', "and it is asked for");
    eval { tools::create_session_9d4e([$here]) };
    like($@, qr/there is a session/, "a name in use is refused");
    eval { tools::create_session_9d4e(['bad name']) };
    like($@, qr/the name 'bad name'/, "a bad name is refused");
}

# the master makes it, in the project of the session that asked, and lists it
events();
ui::_worker_event($here, {event => 'create', data => {name => $new}});
ok(-d "$ai::SESSIONS_DIR/$new", "the master made the session");
is(ai::session_project($new), 'acme/alpha', "in the project of the session that asked");
ok(scalar(grep {$_->[0] eq 'sessions'} events()), "and the list is sent to the page");

# the same name again: refused, nothing changes
my $cwd_before = ai::slurp("$ai::SESSIONS_DIR/$new/cwd");
ui::_worker_event($here, {event => 'create', data => {name => $new}});
is(ai::slurp("$ai::SESSIONS_DIR/$new/cwd"), $cwd_before, "the same name again: the session is left as it was");

# a bad name is refused
ui::_worker_event($here, {event => 'create', data => {name => '../evil'}});
ok(!-e "$base/evil", "a name with a slash is not made");

# the switch of the page to it, when the turn is over
ui::_worker_event($here, {event => 'switch', data => {to => $new}});
ui::_worker_event($here, {event => 'turn', data => {state => 'end'}});
is($ui::active, $new, "the page switched to the new session when the turn was over");

done_testing();
