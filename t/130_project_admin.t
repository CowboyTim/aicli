#!/usr/bin/perl
# the page's projects: created in the login's account and switched to, renamed (only without
# sessions: their conversations name the old path), deleted (with its sessions and files only on
# force; never the one the page is on, never a busy one), and nothing of another account touched
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

TestAI::setup();
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_padm_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
mkdir "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; mkdir "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha" or die "mkdir: $!";
mkdir "$root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";  mkdir "$root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta" or die "mkdir: $!";
$ai::ROOT = $root;
$ui::OUTBOX = [];
$ui::active = undef;
$ui::gate = 'gate-secret';
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

sub call {
    my ($m, $path, $h, $body) = @_;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die "socketpair: $!";
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_dispatch($cn, $m, $path, {'x-aicli-gate' => 'gate-secret', %{$h // {}}}, $body // '');
    my $raw = '';
    for (1 .. 50) {
        my $n = sysread($b, my $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if $cn->{closed} or ($raw =~ m/\r\n\r\n/ and defined $n and $n == 0);
        select(undef, undef, undef, 0.01);
    }
    close($a); close($b);
    my ($code) = $raw =~ m{\AHTTP/1\.1 (\d+)};
    my ($json) = $raw =~ m/\r\n\r\n(.*)\z/s;
    return ($code, eval {JSON::XS->new->decode($json // '')} // {});
}
my $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = {'x-aicli-account' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'};
my $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  = {'x-aicli-account' => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'};
$ui::token = 'local-token-0123456789abcdef'; # the local operator: the token, no gate
my $local = {'x-aicli-gate' => undef, authorization => "Bearer $ui::token"};

# --- create ---------------------------------------------------------------------------
my ($code, $d) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"gamma"}');
is($code, 200, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa creates gamma");
is($d->{project}, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma', "in its account");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma", "the directory is there");
is(ai::session_project($ui::active), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma', "and the page switched to it");
my $gamma_session = $ui::active;

($code) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"gamma"}');
is($code, 409, "a name taken: 409");
($code) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"a/b"}');
is($code, 400, "a name with a slash: 400 (an account is not made here)");
($code) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":".hidden"}');
is($code, 400, "a hidden name: 400");
($code) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":""}');
is($code, 400, "an empty name: 400");
($code) = call('POST', '/project/new', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"x y"}');
is($code, 400, "a name with a space: 400");
($code) = call('POST', '/project/new', {'x-aicli-account' => 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'}, '{"name":"q"}');
is($code, 200, "a login with no project yet: its account directory is made, the project too");
ok(-d "$root/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/q", "under the account's directory");
($code) = call('POST', '/project/new', {'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => 'bad name'}, '{"name":"q"}');
is($code, 403, "a login with a bad account name: 403");
($code, $d) = call('POST', '/project/new', $local, '{"name":"dave/proj"}');
is($code, 200, "the local operator names account/project");
ok(-d "$root/dave/proj", "and it is made");
($code) = call('POST', '/project/new', $local, '{"name":"proj"}');
is($code, 400, "the local operator without an account: 400");

# --- rename ---------------------------------------------------------------------------
($code, $d) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma","to":"delta"}');
is($code, 200, "gamma has a session: renamed with it");
is($d->{project}, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/delta', "to delta");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/delta" && !-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma", "the directory moved");
($code) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/delta","to":"gamma"}');
is($code, 200, "and back to gamma");

mkdir "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/eps" or die "mkdir: $!";
($code, $d) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/eps","to":"zeta"}');
is($code, 200, "a project with no session is renamed");
is($d->{project}, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta', "in the same account");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta" && !-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/eps", "the directory moved");
($code) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta","to":"x/y"}');
is($code, 400, "a new name with a slash: 400");
($code) = call('POST', '/project/rename', $local, '{"name":"dave/proj","to":"other/proj"}');
is($code, 400, "a project keeps its account: 400");
($code) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta","to":"gamma"}');
is($code, 409, "a name taken: 409");
($code, $d) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta","to":"zeta2"}');
is($code, 200, "a bare new name is kept in the account");
is($d->{project}, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta2', "to zeta2");
($code) = call('POST', '/project/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta2","to":"zeta"}');
is($code, 200, "and back to zeta");
($code) = call('POST', '/project/rename', $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta","to":"stolen"}');
is($code, 404, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cannot rename aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's project");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta", "and it is still there");

# --- delete ---------------------------------------------------------------------------
($code) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma"}');
is($code, 409, "the page is on gamma's session: not deleted");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma", "still there");

($code) = call('POST', '/project', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha"}');
is($code, 200, "the page moves to alpha");
($code, $d) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma"}');
is($code, 409, "gamma has a session and files: 409, asked again");
like($d->{error}, qr/1 sessions and 0 files/, "and it says what is in it");
ok(-d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma" && -d "$ai::SESSIONS_DIR/$gamma_session", "nothing removed yet");

($code) = call('POST', '/project/delete', $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma"}');
is($code, 404, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cannot delete aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's project");

($code, $d) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma","force":true}');
is($code, 200, "with force it goes, with its session");
ok(!-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/gamma", "the directory is gone");
ok(!-d "$ai::SESSIONS_DIR/$gamma_session", "and its session");

# the page is on the project that is deleted: the page moves to another project of the account first
mkdir "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega" or die "mkdir: $!";
($code) = call('POST', '/project', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega"}');
is(ai::session_project($ui::active), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega', "the page is on omega");
($code, $d) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega","force":true}');
is($code, 200, "omega, the page's own project, is deleted: the page moves first");
ok(!-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega", "and its directory is gone");
isnt(ai::session_project($ui::active), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/omega', "the page is on another project");
ok(ui::_owns('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ai::session_project($ui::active)), "of its own account");

mkdir "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/empty" or die "mkdir: $!";
($code) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/empty"}');
is($code, 200, "an empty project with no session goes without force");

open(my $fh, '>', "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta/file.txt") or die $!; print {$fh} "x\n"; close $fh;
($code) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta"}');
is($code, 409, "a project with files is asked about (force)");
ok(-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta/file.txt", "its file is still there");
($code) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta","force":true}');
is($code, 200, "with force, files and all");
ok(!-e "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/zeta", "gone");

($code) = call('POST', '/project/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":""}');
is($code, 400, "no name: 400");
($code) = call('POST', '/project/delete', $local, '{"name":"dave/proj"}');
is($code, 409, "dave's project has the session it was made with: asked about first");
($code) = call('POST', '/project/delete', $local, '{"name":"dave/proj","force":true}');
is($code, 200, "the local operator deletes dave's project with force");
ok(!-e "$root/dave/proj", "gone");

# the account's last project, the page on it: it goes with force, and the page has no session and no
# session is left in the project (the page does not make a new one in a project that is removed)
my $ffff = 'ffffffffffffffffffffffffffffffff';
mkdir "$root/$ffff" or die "mkdir: $!";
mkdir "$root/$ffff/only" or die "mkdir: $!";
ok(ui::_project("$ffff/only"), "the page is on ffff's only project");
my $only_session = $ui::active;
($code) = call('POST', '/project/delete', {'x-aicli-account' => $ffff, 'x-aicli-gate' => 'gate-secret'}, '{"name":"' . $ffff . '/only","force":true}');
is($code, 200, "the last project goes with force");
ok(!-e "$root/$ffff/only", "gone");
is($ui::active, undef, "the page has no session now");
ok(!-d "$ai::SESSIONS_DIR/$only_session", "and the page's session went with it");
is_deeply(ui::_project_sessions("$ffff/only"), [], "no session is left in the removed project");
ok(-d "$root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's project is untouched by all of that");

done_testing();
