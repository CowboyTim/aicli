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

done_testing();
