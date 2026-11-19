#!/usr/bin/perl
# the page of accounts: the login's name is the account of a request (nginx's gate); what an
# account sees (its sessions, its projects, its pods, its events) and what it may do (switch,
# message, delete, open) is its own projects only; the local operator (no nginx) sees all.
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
$::UI = 1; # the web interface: a session records its project itself

use ai;
use ui;
use TestAI;

TestAI::setup();
my $J = JSON::XS->new->canonical(1)->utf8;
my $base = Cwd::abs_path(File::Temp::tempdir("aicli_acct_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $root = "$base/master";
mkdir $root or die "mkdir: $!";
for my $p ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta") {
    my ($a) = $p =~ m{\A(.+)/};
    mkdir "$root/$a" unless -d "$root/$a";
    mkdir "$root/$p" or die "mkdir: $!";
}
$ai::ROOT = $root;
$ui::OUTBOX = [];
$ui::active = undef;
$ui::gate = 'gate-secret';
$::ORIG_ENV{AI_PROJECT_FILE} = 'AGENTS.md';

# --- who a request is -----------------------------------------------------------
is(ui::_account({'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', "behind nginx the login's name is the account");
is(ui::_account({'x-aicli-gate' => 'gate-secret'}), '', "a login with no name owns nothing");
is(ui::_account({'x-aicli-gate' => 'gate-secret', 'x-aicli-account' => 'a b'}), '', "a name that is not an account owns nothing");
is(ui::_account({'x-aicli-account' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}), undef, "without the gate (no nginx): the local operator");

# --- what an account sees and may use ---------------------------------------------
ok(ui::_visible('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha'), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sees its project");
ok(!ui::_visible('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta'), "and not bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's");
ok(!ui::_visible('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ''), "not the root");
ok(ui::_visible(undef, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta'), "the local operator sees all");
ok(ui::_visible('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', undef), "nothing active is seen by all");
ok(ui::_owns('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha'), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa may use its project");
ok(!ui::_owns('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta'), "not bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's");
ok(!ui::_owns('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', undef), "nothing to use is not used");
ok(ui::_owns(undef, ''), "the local operator may use the root");

# --- sessions: one of each account --------------------------------------------------
ok(ui::_activate(undef, new => 1, project => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha'), "a session in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's project");
my $acme_session = $ui::active;
# a session with something said in it is listed (an empty one is not)
sub said { my ($name) = @_; open(my $fh, '>>', "$ai::SESSIONS_DIR/$name/chat") or die $!; print {$fh} $J->encode({role => 'user', content => 'hi'})."\n"; close $fh }
said($acme_session);
ok(ui::_activate(undef, new => 1, project => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta'), "a session in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's project (now the active one)");
my $bob_session = $ui::active;
said($bob_session);

my $acme_view = ui::_sessions_data('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
is_deeply([map {$_->{name}} @{$acme_view->{list}}], [$acme_session], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's list: its own session only");
is($acme_view->{current}, '', "the active session is bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa is not told its name");
is($acme_view->{project}, '', "nor its project");
is_deeply($acme_view->{projects}, ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha'], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's projects: its own, and no root");
is_deeply($acme_view->{busy}, [], "no busy session shown to aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

my $local_view = ui::_sessions_data(undef);
is_deeply([sort map {$_->{name}} @{$local_view->{list}}], [sort ($acme_session, $bob_session)], "the local operator's list: all");
is_deeply($local_view->{projects}, ['', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta'], "and all the projects, the root first");

my $bob_view = ui::_sessions_data('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
is($bob_view->{current}, $bob_session, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb is told the active session, which is his");

# --- the events: each one only to whom it is about ----------------------------------
sub client {
    my ($acct) = @_;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die "socketpair: $!";
    $a->blocking(0); $b->blocking(0);
    return {cn => {fh => $a, out => '', account => $acct}, peer => $b};
}
sub got {
    my ($peer) = @_;
    my $raw = '';
    while (defined(my $n = sysread($peer, my $buf, 65536))) { last if $n == 0; $raw .= $buf }
    return $raw;
}
my $c_acme = client('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
my $c_bob  = client('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
my $c_local = client(undef);
@ui::clients = map {$_->{cn}} ($c_acme, $c_bob, $c_local);
ui::publish(tool => {text => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\'s secret'});  # the active session is bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's
my $a_raw = got($c_acme->{peer}); my $b_raw = got($c_bob->{peer}); my $l_raw = got($c_local->{peer});
is($a_raw, '', "an event of bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's session does not reach aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
like($b_raw, qr/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's secret/, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb gets it");
like($l_raw, qr/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's secret/, "the local operator gets it");

ui::publish(models => {list => []});
like(got($c_acme->{peer}), qr/event: models/, "the models are for all");
like(got($c_bob->{peer}), qr/event: models/, "and bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb has them too");

ui::publish(failed => {text => 'a failure of aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, session => $acme_session);
like(got($c_acme->{peer}), qr/a failure of aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/, "a failure of aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's session reaches aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
is(got($c_bob->{peer}), '', "and not bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

ui::publish_each(sessions => sub { ui::_sessions_data($_[0]) });
like(got($c_acme->{peer}), qr/"projects":\["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\/alpha"\]/, "the list sent to aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa is aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's");
like(got($c_local->{peer}), qr/"projects":\[""/, "and the local operator's has the root");

@ui::clients = ();

# --- the routes: what aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa may not do --------------------------------------------------
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
    return ($code, $raw, ($json // ''));
}
my $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = {'x-aicli-account' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'};
my ($code, $raw, $json) = call('GET', '/state', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa);
is($code, 200, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa asks the state: 200");
unlike($json, qr/\Q$bob_session\E/, "and the state does not name bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's session");

($code) = call('POST', '/message', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"text":"hello"}');
is($code, 403, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot message bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's active session");
($code) = call('POST', '/project', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta"}');
is($code, 403, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot switch the page to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's project");
($code) = call('POST', '/session', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, qq({"name":"$bob_session"}));
is($code, 403, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot switch to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's session");
($code) = call('POST', '/session/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, qq({"name":"$bob_session"}));
is($code, 404, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot delete bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's session (as if it is not there)");
($code) = call('POST', '/session/rename', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, qq({"name":"$bob_session","to":"stolen"}));
is($code, 404, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot rename it");
ok(-d "$ai::SESSIONS_DIR/$bob_session", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's session is still there");
($code) = call('POST', '/pod', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"op":"open","project":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta"}');
is($code, 403, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot open a pod of bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's project");
($code) = call('POST', '/session', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"new":true,"project":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/beta"}');
is($code, 403, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cannot make a session in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's project");
($code) = call('POST', '/session', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"new":true}');
is($code, 403, "nor one in the active project, which is bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb's");

($code) = call('POST', '/project', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha"}');
is($code, 200, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa's own project: fine");
is(ai::session_project($ui::active), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha', "and it is the page's project now");
($code) = call('POST', '/session/delete', $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, qq({"name":"$acme_session"}));
ok($code == 200 || $code == 409, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa deletes its own session (or it is busy)") or diag("code $code");

# a login with no name: nothing at all
($code) = call('POST', '/project', {'x-aicli-account' => ''}, '{"name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/alpha"}');
is($code, 403, "a login with no account name is refused");

done_testing();
