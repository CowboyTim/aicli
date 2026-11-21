#!/usr/bin/perl
# a login's page starts in its own work: the stream's connect makes the account's newest session
# the active one (or a new one in its first project) when the active session is not its own; the
# local operator keeps what it had, and an account with no project of its own stays as it is.
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
my $J = JSON::XS->new->canonical(1)->utf8;

TestAI::setup();
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_home_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
my $ACME = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
my $BOB  = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
my $NONE = 'cccccccccccccccccccccccccccccccc';
for my $p ("$ACME/alpha", "$BOB/beta") {
    my ($a) = $p =~ m{\A(.+)/};
    mkdir "$root/$a" unless -d "$root/$a";
    mkdir "$root/$p" or die "mkdir: $!";
}
$ai::ROOT = $root;
$ui::OUTBOX = [];
$ui::gate = 'gate-secret';
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

# bob's page was the last one: its session is the active one
ok(ui::_activate(undef, new => 1, project => "$BOB/beta"), "bob has a session (the active one)");
my $bob_session = $ui::active;
ok(!ui::_owns($ACME, ui::_active_rel()), "it is not acme's");

# acme logs in: its page starts in its own work, a new session in its project
ui::_home($ACME);
ok(defined $ui::active && $ui::active ne $bob_session, "acme's login makes another session active");
is(ai::session_project($ui::active), "$ACME/alpha", "in acme's project");
ok(ui::_owns($ACME, ui::_active_rel()), "and acme may use it");

# a second login of acme: its own session is kept, nothing new
my $acme_session = $ui::active;
ui::_home($ACME);
is($ui::active, $acme_session, "the account's own active session is kept");

# the local operator keeps what it had
ui::_home(undef);
is($ui::active, $acme_session, "no account (the local operator): nothing changes");

# an account with no project of its own: nothing changes
ui::_home($NONE);
is($ui::active, $acme_session, "an account with no project keeps the active session");

# acme's newest session is the one chosen when there are two
ok(ui::_activate(undef, new => 1, project => "$ACME/alpha"), "a second session of acme");
my $newest = $ui::active;
# a session is listed once something was said in it, and its age is its chat file's time
for my $s ($acme_session, $newest) {
    open(my $fh, '>>', "$ai::SESSIONS_DIR/$s/chat") or die $!;
    print {$fh} $J->encode({role => 'user', content => 'hi'})."\n";
    close $fh;
}
utime(time - 100, time - 100, "$ai::SESSIONS_DIR/$acme_session/chat");
ui::_activate($acme_session);
ui::_home($BOB);
ui::_home($ACME);
is($ui::active, $newest, "acme's newest session is the home of its login");

done_testing();
