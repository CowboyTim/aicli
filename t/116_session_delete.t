#!/usr/bin/perl
# the web interface deletes a session: its directory goes; deleting the active one makes a new
# session (the page follows); the others are left alone.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

use ai;
use ui;
use TestAI;

TestAI::setup();
$ui::OUTBOX = [];
ui::_activate(undef, new => 1);
my $first = $ui::active;
ui::_activate(undef, new => 1);
my $second = $ui::active;
ok(-d "$ai::SESSIONS_DIR/$first" && -d "$ai::SESSIONS_DIR/$second", "two sessions exist");

# an inactive session: removed, the active one stays
is(ui::_delete_session($first), undef, "deleting the session that is not active works");
ok(!-d "$ai::SESSIONS_DIR/$first", "its directory is gone");
is($ui::active, $second, "the active session is the same");
ok(-d "$ai::SESSIONS_DIR/$second", "and the active session is kept");

# the active session: removed, and a new one is made and active
is(ui::_delete_session($second), undef, "deleting the active session works");
ok(!-d "$ai::SESSIONS_DIR/$second", "its directory is gone");
ok(defined $ui::active && $ui::active ne $second, "a new session is active");
ok(-d "$ai::SESSIONS_DIR/$ui::active", "and its directory exists");

# rename: an inactive session keeps the active one; the active one is opened under the new name
ui::_activate(undef, new => 1);
my $a = $ui::active;
ui::_activate(undef, new => 1);
my $b = $ui::active;
is(ui::_rename_session($a, 'zz-renamed-inactive'), undef, "renaming a session that is not active");
ok(-d "$ai::SESSIONS_DIR/zz-renamed-inactive" && !-d "$ai::SESSIONS_DIR/$a", "its directory has the new name");
is($ui::active, $b, "the active session is the same");
is(ui::_rename_session($b, 'zz-renamed-active'), undef, "renaming the active session");
is($ui::active, 'zz-renamed-active', "and it is the active one under the new name");
ok(-d "$ai::SESSIONS_DIR/zz-renamed-active" && !-d "$ai::SESSIONS_DIR/$b", "with its directory moved");
ok(defined ui::_rename_session('zz-renamed-inactive', 'zz-renamed-active'), "a name that exists is refused");
ok(defined ui::_rename_session('no-such-session-xyz', 'zz-other'), "an unknown session is refused");

done_testing();
