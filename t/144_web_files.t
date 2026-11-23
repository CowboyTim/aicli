#!/usr/bin/perl
# the files of a session on the page: GET /file serves what lies in the session's project (a picture
# or a sound inline, the rest as a download) to the login whose account the project is, and refuses
# a link or '..' that leads out of the project. The history gives the file of each call that wrote
# one, and the master passes a worker's file event on to the page, with its session.
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use JSON::XS ();
use MIME::Base64 ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $PNG = MIME::Base64::decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==");

my $tmp = TestAI::setup();
$ai::ROOT = "$tmp/root"; # after the setup: the projects are under it
my $root = $ai::ROOT;
$ui::token = 'tok-files';
$ui::gate  = 'gate-files';

# the projects of two logins: the directories are the account IDs (32 hex digits)
my $A = 'ab' x 16;
my $B = 'cd' x 16;

sub put { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }
for my $d ($root, "$root/$A", "$root/$A/proj", "$root/$A/proj/out", "$root/$B", "$root/$B/other") {
    mkdir $d or die "$d: $!";
}
put("$root/$A/proj/pic.png", $PNG);
put("$root/$A/proj/my pic.png", $PNG);
put("$root/$A/proj/notes.txt", "hello\n");
put("$root/$A/proj/page.html", "<script>alert(1)</script>");
put("$root/$A/proj/out/shot.png", $PNG);
put("$root/$B/other/secret.png", $PNG);
put("$tmp/outside.txt", "outside the projects\n");
symlink("$tmp/outside.txt", "$root/$A/proj/leak.txt") or die "symlink: $!";
symlink("$root/$A/proj/pic.png", "$root/$A/proj/inside.png") or die "symlink: $!";

# the sessions, each in its project (the cwd file, as a session keeps it)
sub session {
    my ($name, $dir) = @_;
    mkdir "$ai::SESSIONS_DIR/$name" or die "$name: $!";
    put("$ai::SESSIONS_DIR/$name/cwd", "$root/$dir\n");
}
session('mine', "$A/proj");
session('theirs', "$B/other");

# a request to the local interface: the headers nginx would send (the gate's secret, the account)
sub get {
    my ($path, %h) = @_;
    my $method = delete $h{_method} // 'GET';
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_dispatch($cn, $method, $path, {%h}, '');
    my $raw = '';
    for (1 .. 200) {
        my $n = sysread($b, my $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if defined $n and $n == 0;
        last if $cn->{closed};
        select(undef, undef, undef, 0.01);
    }
    close($a);
    close($b);
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    my ($status) = ($head // '') =~ m{\AHTTP/1\.1 (\d{3})};
    my %hdr = map {my ($k, $v) = m/\A([^:]+):\s*(.*)\z/; (lc($k), $v)} grep {/:/} split /\r\n/, $head // '';
    return ($status // 0, \%hdr, $body // '');
}
my %mine = ('x-aicli-gate' => 'gate-files', 'x-aicli-account' => $A);
my %theirs = ('x-aicli-gate' => 'gate-files', 'x-aicli-account' => $B);

# ---------------------------------------------------------------------------
# GET /file

{
    my ($st) = get("/file?session=mine&path=pic.png");
    is($st, 401, "no login, no file");

    my ($s, $h, $body) = get("/file?session=mine&path=pic.png", %mine);
    is($s, 200, "a picture of the session's project");
    is($h->{'content-type'}, 'image/png', "as a PNG");
    is($h->{'content-disposition'}, 'inline; filename="pic.png"', "shown inline");
    is($body, $PNG, "the bytes of the file");
    is($h->{'x-content-type-options'}, 'nosniff', "nosniff");
    is($h->{'content-security-policy'}, 'sandbox', "and sandboxed");
    is($h->{'cache-control'}, 'no-store', "not kept by the browser");

    ($s, $h) = get("/file?session=mine&path=pic.png&download=1", %mine);
    is($h->{'content-disposition'}, 'attachment; filename="pic.png"', "a download when asked for");
    is($h->{'content-type'}, 'image/png', "with its type");

    ($s, $h, $body) = get("/file?session=mine&path=notes.txt", %mine);
    is($s, 200, "a text file");
    is($h->{'content-disposition'}, 'attachment; filename="notes.txt"', "is a download, not inline");
    is($body, "hello\n", "its bytes");

    ($s, $h) = get("/file?session=mine&path=page.html", %mine);
    is($h->{'content-disposition'}, 'attachment; filename="page.html"', "an HTML file is only ever a download");
    is($h->{'content-type'}, 'application/octet-stream', "as an unknown type");

    ($s, $h) = get("/file?session=mine&path=out/shot.png", %mine);
    is($s, 200, "a file in a folder of the project");

    ($s, $h) = get("/file?session=mine&path=my%20pic.png", %mine);
    is($s, 200, "a name with a space (the URL escapes it)");
    is($h->{'content-disposition'}, 'inline; filename="my_pic.png"', "and the header has a safe name");

    ($s) = get("/file?session=mine&path=inside.png", %mine);
    is($s, 200, "a link inside the project is followed");

    ($s) = get("/file?session=mine&path=leak.txt", %mine);
    is($s, 404, "a link that leads out of the project is refused");

    ($s) = get("/file?session=mine&path=../../$B/other/secret.png", %mine);
    is($s, 404, "'..' out of the project is refused");

    ($s) = get("/file?session=mine&path=/etc/passwd", %mine);
    is($s, 400, "an absolute path is refused");

    ($s) = get("/file?session=mine&path=missing.png", %mine);
    is($s, 404, "a file that is not there");

    ($s) = get("/file?session=mine&path=out", %mine);
    is($s, 404, "a folder is not a file");

    ($s) = get("/file?session=theirs&path=secret.png", %mine);
    is($s, 404, "another login's session is not seen (not even its files)");

    ($s, $h, $body) = get("/file?session=theirs&path=secret.png", %theirs);
    is($s, 200, "its own login sees its own file");

    ($s) = get("/file?session=nope&path=pic.png", %mine);
    is($s, 404, "no such session");

    ($s) = get("/file?session=..%2Fmine&path=pic.png", %mine);
    is($s, 400, "a session name that is not a name is refused");

    ($s) = get("/file?session=mine&path=", %mine);
    is($s, 400, "no path, no file");

    ($s) = get("/file?session=mine", %mine);
    is($s, 400, "no path at all");

    {
        local $ui::MAX_FILE = 10;
        ($s) = get("/file?session=mine&path=pic.png", %mine);
        is($s, 413, "a file bigger than the limit is refused");
    }

    ($s) = get("/file?session=mine&path=pic.png", %mine, _method => 'POST');
    is($s, 405, "only GET");
}

# ---------------------------------------------------------------------------
# the history: a call that wrote a file that is still there has it in its files

{
    my $name = 'mine';
    put("$ai::SESSIONS_DIR/$name/chat", join '', map {$J->encode($_)."\n"} (
        {role => 'user', content => 'draw, then write'},
        {role => 'assistant', content => '', tool_calls => [{id => 'c1', type => 'function',
            function => {name => 'generate_image', arguments => $J->encode({prompt => 'a cube', output => 'out/shot.png'})}}]},
        {role => 'tool', tool_call_id => 'c1', content => "wrote out/shot.png: 1024x1024, seed 42, 9 bytes\n"},
        {role => 'assistant', content => '', tool_calls => [{id => 'c2', type => 'function',
            function => {name => 'generate_image', arguments => $J->encode({prompt => 'x', output => 'gone.png'})}}]},
        {role => 'tool', tool_call_id => 'c2', content => "wrote gone.png\n"},
        {role => 'assistant', content => '', tool_calls => [{id => 'c3', type => 'function',
            function => {name => 'generate_image', arguments => $J->encode({prompt => 'x', output => 'pic.png'})}}]},
        {role => 'tool', tool_call_id => 'c3', content => "[ERROR] problem running tool 'generate_image': HTTP status 500\n"},
        {role => 'assistant', content => '', tool_calls => [{id => 'c4', type => 'function',
            function => {name => 'write', arguments => $J->encode({path => 'notes.txt', content => 'x'})}}]},
        {role => 'tool', tool_call_id => 'c4', content => "[OK] wrote notes.txt\n"},
        {role => 'assistant', content => '', tool_calls => [{id => 'c5', type => 'function',
            function => {name => 'generate_image', arguments => $J->encode({prompt => 'x', output => 'out/shot.png'})}}]},
    ));
    my @tools = grep {$_->{role} eq 'tool'} @{ui::_history_data($name)->{messages}};
    is(scalar(@tools), 5, "five calls in the history");
    is_deeply($tools[0]{files}, ['out/shot.png'], "a picture the call wrote is listed with it");
    ok(!$tools[1]{files}, "a file that is gone is not listed");
    ok(!$tools[2]{files}, "a failed call lists no file, though the name exists");
    is_deeply($tools[3]{files}, ['notes.txt'], "a write lists its file");
    ok(!exists $tools[4]{files}, "a call with no result yet lists none");
    is(ui::_history_data($name)->{session}, 'mine', "the history names its session (the page's links need it)");
}

# ---------------------------------------------------------------------------
# the master: a worker's file event goes to the page when its session is the active one

{
    my @pub;
    no warnings 'redefine';
    local *ui::publish = sub { push @pub, [@_] };
    local $ui::active = 'mine';
    local %ui::worker = (mine => {busy => 0, pending => 0}, theirs => {busy => 0, pending => 0});

    ui::_worker_event('mine', {event => 'file', data => {path => 'out/shot.png'}});
    is_deeply(\@pub, [['file', {path => 'out/shot.png', session => 'mine'}]],
        "the active session's file goes to the page, with its session");

    @pub = ();
    ui::_worker_event('theirs', {event => 'file', data => {path => 'secret.png'}});
    is(scalar(@pub), 0, "a session that is not the page's active one sends nothing");

    @pub = ();
    ui::_worker_event('mine', {event => 'file', data => {path => ''}});
    is(scalar(@pub), 0, "an empty path sends nothing");
}

# the session's tool calls and their time: in the state (the page's header, on a refresh too), and the
# stats of each call go to the page while the session is the active one
{
    my $usage = {tools => {bash => {calls => 2, errors => 0, seconds => 0.5}, write => {calls => 1, errors => 1, seconds => 1.25}}};
    put("$ai::SESSIONS_DIR/mine/usage", JSON::XS->new->canonical(1)->encode($usage));
    local $ui::active = 'mine';
    local %ui::worker = (mine => {busy => 0, pending => 0});
    my $st = ui::_master_state(undef);
    is_deeply($st->{tools}, {tools => 3, seconds => 1.75}, "the state has the session's tool calls and their time");
    my @pub;
    no warnings 'redefine';
    local *ui::publish = sub { push @pub, [@_] };
    ui::_worker_event('mine', {event => 'stats', data => {tools => 4, seconds => 2.0}});
    is_deeply(\@pub, [['stats', {tools => 4, seconds => 2.0}]], "a stats event goes to the page of the active session");
}

done_testing();
