#!/usr/bin/perl
# the page's account of a request: the account ID nginx sends (X-Aicli-Account, a UUID without
# its dashes, from the login's passwd comment), behind the gate only; a missing or bad one owns
# nothing; the local operator (no gate) has none of that and sees all. A login with a dash or an
# address has an ID like any other, so its projects and page work the same.
use strict; use warnings;

use Test::More;
use File::Temp ();
use Cwd ();
use Socket ();
use JSON::XS ();
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;

use ai;
use ui;
use TestAI;
require "$FindBin::Bin/../broker.pl";

TestAI::setup();
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_login_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
$ai::ROOT = $root;
$ui::OUTBOX = [];
$ui::active = undef;
$ui::gate = 'gate-secret';
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

my $id = '3f2a1b4c5d6e4f708192a3b4c5d6e7f8';
is(ui::_account({'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => $id}), $id, "behind nginx the account ID");
is(ui::_account({'x-aicli-gate' => 'gate-secret'}), '', "no account ID: owns nothing");
is(ui::_account({'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => 'not an id'}), '', "a bad account ID: owns nothing");
is(ui::_account({'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => "$id\n"}), '', "one with a newline: owns nothing");
is(ui::_account({'x-aicli-account' => $id}), undef, "without the gate (no nginx): the local operator");
is(ui::_account({'x-aicli-gate' => 'wrong', 'x-aicli-account' => $id}), undef, "a wrong gate secret: not the gate");

# a login with a dash and an address: its ID is an account like any other
my $mine = '0123456789abcdef0123456789abcdef';
mkdir "$root/$mine" or die "mkdir: $!";
mkdir "$root/$mine/proj" or die "mkdir: $!";
is_deeply(ai::project_dirs(), ["$mine/proj"], "its project is listed");
my $b = broker->new(socket => "$base/unused.sock");
ok($b->project_name("$mine/proj"), "the broker takes the project's name (account ID and project)");
ok(!$b->project_name("$mine/../proj"), "and a name with a dot-dot is not one");

# the page: a project made for that login
my ($sa, $sb);
socketpair($sa, $sb, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
$sa->blocking(0); $sb->blocking(0);
my $cn = {fh => $sa, out => ''};
ui::_dispatch($cn, 'POST', '/project/new', {'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => $mine}, '{"name":"lab"}');
my $raw = '';
for (1 .. 50) {
    my $n = sysread($sb, my $buf, 65536);
    if (defined $n and $n > 0) { $raw .= $buf; next }
    last if $n == 0 || $cn->{closed};
    select(undef, undef, undef, 0.01);
}
like($raw, qr/HTTP\/1\.1 200/, "a project for that login: 200");
ok(-d "$root/$mine/lab", "made in its account");

is_deeply([grep {ui::_visible($mine, $_)} @{ai::project_dirs()}], ["$mine/lab", "$mine/proj"],
    "its own projects are its view");
is_deeply([grep {ui::_visible('ffffffffffffffffffffffffffffffff', $_)} @{ai::project_dirs()}], [],
    "another account sees none of it");

done_testing();
