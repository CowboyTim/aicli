#!/usr/bin/perl
# the icon of the pages: a strawberry in favicon.ico (16, 32, 48, 64 and 256 pixels, one file),
# and favicon.svg; both pages link it, nginx serves it publicly, and the local interface answers
# it without a login too. It is drawn for aicli (no emoji artwork: those belong to their makers).
use strict; use warnings;

use Test::More;
use File::Basename ();
use Cwd ();
use FindBin;
use Socket ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;
my $repo = Cwd::abs_path("$FindBin::Bin/..");   # before TestAI::setup changes the directory
TestAI::setup();

my $dir = "$repo/ai/ui";
my $ico = slurp("$dir/favicon.ico");
ok(length($ico) > 100, "favicon.ico is there");
is(substr($ico, 0, 4), "\x00\x00\x01\x00", "an ICO file");
my $count = unpack('v', substr($ico, 4, 2));
is($count, 5, "five pictures in it");
my @sizes = map {my $w = unpack('C', substr($ico, 6 + 16 * $_, 1)); $w == 0 ? 256 : $w} 0 .. $count - 1;
is_deeply([sort {$a <=> $b} @sizes], [16, 32, 48, 64, 256], "the sizes: 16, 32, 48, 64 and 256");

my $svg = slurp("$dir/favicon.svg");
like($svg, qr/<svg[^>]*viewBox="0 0 64 64"/, "favicon.svg is a 64 by 64 drawing");
like($svg, qr/#d7263d/, "in strawberry red");

for my $page ("$dir/index.html", "$dir/login.html") {
    my $html = slurp($page);
    like($html, qr{<link rel="icon" href="/favicon\.ico"}, File::Basename::basename($page)." links the icon");
    like($html, qr{<link rel="icon" href="/favicon\.svg"}, File::Basename::basename($page)." links the SVG");
}

my $nginx = slurp("$repo/nginx/nginx.conf.template");
like($nginx, qr{location = /favicon\.ico \{\s*alias /etc/nginx/ui/favicon\.ico;}, "nginx serves favicon.ico publicly");
like($nginx, qr{location = /favicon\.svg \{\s*alias /etc/nginx/ui/favicon\.svg;}, "and favicon.svg");

# the local interface, without a login
$ui::html_file = "$dir/index.html";
for my $case (['/favicon.ico', 'image/x-icon', $ico], ['/favicon.svg', 'image/svg+xml', $svg]) {
    my ($path, $type, $body) = @$case;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_dispatch($cn, 'GET', $path, {}, '');
    my $raw = '';
    for (1 .. 50) {
        my $n = sysread($b, my $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if $cn->{closed} or ($raw =~ m/\r\n\r\n/ and defined $n and $n == 0);
        select(undef, undef, undef, 0.01);
    }
    close($a); close($b);
    like($raw, qr{\AHTTP/1\.1 200}, "$path answers 200 without a login");
    like($raw, qr{Content-Type: \Q$type\E}, "as $type");
    my ($got) = $raw =~ m/\r\n\r\n(.*)\z/s;
    is(length($got // ''), length($body), "all of $path");
}

sub slurp { my ($f) = @_; open(my $h, '<:raw', $f) or return ''; local $/; my $d = <$h>; close $h; return $d }

done_testing();
