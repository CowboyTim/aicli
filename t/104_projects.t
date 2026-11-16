#!/usr/bin/perl
# projects: the directories under the root. A session is made in one, with its
# AGENTS.md in its prompt; the page's project switch goes to the newest session of
# it, or makes one; the directories that are not projects are left out.
use strict; use warnings;

use Test::More;
use File::Temp ();
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1; # the web interface: a session records its project itself, not the process directory

use ai;
use ui;
use TestAI;

TestAI::setup();
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $d = <$h>; return $d }
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_proj_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
mkdir "$root/alpha" or die "mkdir: $!";
mkdir "$root/beta" or die "mkdir: $!";
mkdir "$root/.hidden" or die "mkdir: $!";
open(my $fh, '>', "$root/alpha/AGENTS.md") or die "AGENTS.md: $!";
print {$fh} "ALPHA-RULES: the alpha way\n";
close $fh;
open($fh, '>', "$root/notes.txt") or die "notes: $!";
print {$fh} "a file, not a project\n";
close $fh;

$ai::ROOT = $root;
$ui::OUTBOX = [];
$ui::active = undef;

is_deeply(ai::project_dirs(), ['alpha', 'beta'], "the projects are the directories under the root (not hidden, not files)");
is(ai::project_path(''), $root, "the root is the project of ''");
is(ai::project_path('alpha'), "$root/alpha", "and a project's directory is under it");

$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md'; # the test setup has none: this one wants the project's
ok(ui::_activate(undef, new => 1, project => 'alpha'), "a new session in alpha");
my $name = $ui::active;
is(ai::session_project($name), 'alpha', "the session is in alpha");
is(slurp("$ai::SESSIONS_DIR/$name/cwd"), "$root/alpha\n", "and records it");
like(slurp("$ai::SESSIONS_DIR/$name/chat"), qr/ALPHA-RULES/, "its prompt has the AGENTS.md of the project");
like(slurp("$ai::SESSIONS_DIR/$name/chat"), qr/Workspace: \Q$root\E\/alpha/, "and names the project as its workspace");
is($ai::ROOT, $root, "the master is still at the root");

ok(ui::_project('beta'), "the page switches to beta");
is(ai::session_project($ui::active), 'beta', "a new session there (none existed)");
ok(ui::_project(''), "the page switches to the root");
is(ai::session_project($ui::active), '', "the root");
ok(!ui::_project('nope'), "a project that is not there is refused");
like($ui::last_error, qr/no project 'nope'/, "and the reason is kept");
is(ui::_sessions_data()->{project}, '', "the page is told the project");
is_deeply(ui::_sessions_data()->{projects}, ['', 'alpha', 'beta'], "and the list of them, the root first");

ok(ui::_activate(undef, new => 1), "a new session with no project named is made in the active one (the root)");
is(ai::session_project($ui::active), '', "in the root");
ok(ui::_project('alpha'), "back to alpha");
is(ui::_sessions_data()->{project}, 'alpha', "and it is the active project");

done_testing();
