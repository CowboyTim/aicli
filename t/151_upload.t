#!/usr/bin/perl
# the "+" of the page: POST /upload keeps any kind of file in the active session's project, in its uploads/ folder,
# under a name that is free there; a name is only its last part, the account of the project decides who may put
# a file there, a link named uploads is refused, and a body over the limit is refused by the reader
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8 if eval {require JSON::XS; 1};

my $tmp = TestAI::setup();
$ai::ROOT = "$tmp/root";
my $root = $ai::ROOT;
$ui::token = 'tok-upload';
$ui::gate  = 'gate-upload';

my $A = 'ab' x 16;
my $B = 'cd' x 16;

sub put { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }
for my $d ($root, "$root/$A", "$root/$A/proj", "$root/$A/link", "$root/$B", "$root/$B/other") {
    mkdir $d or die "$d: $!";
}
mkdir "$tmp/outside" or die $!;
symlink("$tmp/outside", "$root/$A/link/uploads") or die "symlink: $!";

sub session {
    my ($name, $dir) = @_;
    mkdir "$ai::SESSIONS_DIR/$name" or die "$name: $!";
    put("$ai::SESSIONS_DIR/$name/cwd", "$root/$dir\n");
}
session('mine', "$A/proj");
session('linked', "$A/link");
session('theirs', "$B/other");

# a request to the local interface, as nginx sends it: the gate's secret and the login's account
sub post {
    my ($path, $body, %h) = @_;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_dispatch($cn, 'POST', $path, {%h}, $body);
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
    my ($head, $json) = split /\r\n\r\n/, $raw, 2;
    my ($status) = ($head // '') =~ m{\AHTTP/1\.1 (\d{3})};
    my $data = eval {JSON::XS->new->decode($json // '')} // {};
    return ($status // 0, $data);
}

my %mine = ('x-aicli-gate' => 'gate-upload', 'x-aicli-account' => $A);
my %theirs = ('x-aicli-gate' => 'gate-upload', 'x-aicli-account' => $B);

# the page's active session is the one the file goes to
$ui::active = 'mine';
my ($s, $d) = post("/upload?name=notes.txt", "hello\n", %mine);
is($s, 201, "a file is kept");
is($d->{path}, "uploads/notes.txt", "...in uploads/, under its name");
is($d->{session}, 'mine', "...of the active session");
is($d->{size}, 6, "...and the answer has its size");
is(do {open(my $f, '<:raw', "$root/$A/proj/uploads/notes.txt") or die $!; local $/; <$f>}, "hello\n", "the bytes are the file's");

# a name taken goes to the next free one; the file there stays
($s, $d) = post("/upload?name=notes.txt", "second\n", %mine);
is($d->{path}, "uploads/notes-2.txt", "a name taken: the next free one");
is(do {open(my $f, '<:raw', "$root/$A/proj/uploads/notes.txt") or die $!; local $/; <$f>}, "hello\n", "...and the file there is not replaced");

# any kind of file, bytes as they are
my $bin = "\x00\x01\xfe\xffMZ";
($s, $d) = post("/upload?name=tool.exe", $bin, %mine);
is($s, 201, "any kind of file: an executable is kept");
is(do {open(my $f, '<:raw', "$root/$A/proj/uploads/tool.exe") or die $!; local $/; <$f>}, $bin, "...the bytes as they were");

# a name is only its last part, and what is left of it: no folders, no hidden name
($s, $d) = post("/upload?name=" . "..%2F..%2Fescape%20me.sh", "x", %mine);
is($d->{path}, "uploads/escape me.sh", "a name with folders: only its last part, the spaces kept");
ok(!-e "$root/$A/proj/escape me.sh" && !-e "$root/$A/escape me.sh", "...and nothing is written outside uploads/");
($s, $d) = post("/upload?name=.hidden", "x", %mine);
is($d->{path}, "uploads/hidden", "a hidden name: the dot goes");
($s) = post("/upload?name=....", "x", %mine);
is($s, 400, "a name with nothing left is refused");
($s) = post("/upload", "x", %mine);
is($s, 400, "no name is refused");

# another account's session is not written to
$ui::active = 'theirs';
($s) = post("/upload?name=x.txt", "x", %mine);
is($s, 403, "another account's session: refused");
ok(!-e "$root/$B/other/uploads/x.txt", "...and nothing is written there");

# a project whose uploads is a link is refused
$ui::active = 'linked';
($s) = post("/upload?name=x.txt", "x", %mine);
is($s, 403, "uploads that is a link: refused");
ok(!-e "$tmp/outside/x.txt", "...and nothing is written through it");

# no session on the page: nothing to put the file in
$ui::active = undef;
($s) = post("/upload?name=x.txt", "x", %mine);
is($s, 403, "no session on the page: refused");

# a body over the limit is refused by the reader, before it is read
{
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_feed($cn, "POST /upload?name=big.bin HTTP/1.1\r\n"
        ."Host: localhost\r\nX-Aicli-Gate: gate-upload\r\nContent-Length: ".($ui::MAX_UPLOAD + 1)."\r\n\r\n");
    my $raw = '';
    for (1 .. 50) {
        my $n = sysread($b, my $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if defined $n and $n == 0;
        select(undef, undef, undef, 0.01);
    }
    like($raw, qr{\AHTTP/1\.1 413 }, "a file over the limit is refused (413)");
    close($a);
    close($b);
}

done_testing();
