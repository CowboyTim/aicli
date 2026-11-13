#!/usr/bin/perl
# convert (ImageMagick) and the shrinking of a picture for the image tool: the
# program runs in a forked child with the tool environment and the policy of
# aicli. A stand-in program checks the arguments, the environment and the
# refusals; the real program, when it is installed, checks the results.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;
use File::Temp ();
use File::Basename ();
use MIME::Base64 ();

my $PNG = "\x89PNG\r\n\x1a\n".("\0" x 20);

sub write_file {
    my ($path, $bytes) = @_;
    open(my $fh, '>:raw', $path) or die "$path: $!";
    print {$fh} $bytes;
    close($fh);
    return $path;
}

sub slurp_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return;
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

sub lines_of {
    my ($path) = @_;
    my $c = slurp_file($path) // '';
    return split m/\n/, $c;
}

# the stand-in: logs its arguments and environment to ./stub.log, writes its
# output (the last argument), and fails for a name with "fail" in it
my $STUB = <<'SH';
#!/bin/sh
for last; do :; done
{ for a in "$@"; do printf 'ARG %s\n' "$a"; done; env | sed 's/^/ENV /'; } > ./stub.log
case "$*" in *fail*) echo "stub failure on purpose" >&2; exit 3 ;; esac
printf 'stub-output' > "$last"
SH

# a session in a new workspace (the directory of the process), with the stand-in
# first on the PATH
sub fresh_stub {
    my (%env) = @_;
    my $bin = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    write_file("$bin/magick", $STUB);
    chmod 0755, "$bin/magick";
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1, PATH => "$bin:$ENV{PATH}", %env);
    $tools::MAGICK_LOOKED = 0;
    my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    $ai::WORKSPACE = $ws;
    chdir($ws); # relative names are from here, as in a session
    return $ws;
}

# a session with the programs of this machine
sub fresh_real {
    my (%env) = @_;
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1, %env);
    $tools::MAGICK_LOOKED = 0;
    my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    $ai::WORKSPACE = $ws;
    chdir($ws);
    return $ws;
}

# a program run with some environment variables, its messages kept away
sub run_quiet {
    my ($env, @cmd) = @_;
    local %ENV = (%ENV, %$env);
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null') or die "STDERR: $!";
    my $status = system(@cmd);
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!";
    return $status;
}

# ---------------------------------------------------------------------------
# the stand-in: the arguments, the environment, the result, the journal

{
    my $ws = fresh_stub(AI_API_KEY => 'nvapi-secret-key');
    write_file("$ws/shot.png", $PNG);
    ok(tools::available('convert'), "stub: convert is there where a magick program is");

    my ($res, $err) = ai::execute_tool('convert', 'CONVERT_5d1a', ['shot.png', 'out.jpg', '800', '', '', '', '80']);
    ok(!$err, "stub: a conversion runs") or diag($err);
    like($res, qr{converted shot\.png to out\.jpg}, "stub: the result names both files");

    my @args = map {s/^ARG //r} grep {/^ARG /} lines_of("$ws/stub.log");
    is($args[0], './shot.png[0]', "stub: the first frame of the input");
    is_deeply([@args[1 .. 6]], ['-auto-orient', '-resize', '800x>', '-strip', '-quality', '80'],
        "stub: the options, in order: upright, resize that only shrinks, metadata stripped, quality");
    like($args[-1], qr{\A\./\.aicli-convert-\d+-out\.jpg\z}, "stub: written to a temp name next to the output");

    my %env = map {m/\A([^=]*)=(.*)\z/s ? ($1 => $2) : ()} map {s/^ENV //r} grep {/^ENV /} lines_of("$ws/stub.log");
    is($env{MAGICK_CONFIGURE_PATH}, "$TestAI::ROOT/ai/imagemagick", "stub: the policy of aicli is set for the program");
    ok(-f "$env{MAGICK_CONFIGURE_PATH}/policy.xml", "stub: and that directory has the policy");
    ok(length($env{MAGICK_TEMPORARY_PATH} // ''), "stub: a temp directory for ImageMagick");
    ok(!(grep {m/\AAI_/} keys %env), "stub: no AI_ variable reaches the program");
    ok(!(grep {m/nvapi-secret-key/} values %env), "stub: no API key reaches the program");
    ok(length($env{PATH} // ''), "stub: the PATH of the tool environment is there");

    is(slurp_file("$ws/out.jpg"), 'stub-output', "stub: the output is the program's file");
    ok(!glob("$ws/.aicli-convert-*"), "stub: no temp file is left");
    ok($tools::CHANGES[-1]{binary} && $tools::CHANGES[-1]{path} eq 'out.jpg',
        "stub: the change is in the journal, marked as a picture");
    @tools::CHANGES = ();

    # an existing output is replaced, and its old bytes are kept for undo
    write_file("$ws/out.jpg", "old");
    ai::execute_tool('convert', 'CONVERT_5d1a', ['shot.png', 'out.jpg']);
    is($tools::CHANGES[-1]{old}, 'old', "stub: the old file is kept for undo");
    is(slurp_file("$ws/out.jpg"), 'stub-output', "stub: and replaced");
    @tools::CHANGES = ();
}

{
    my $ws = fresh_stub();
    write_file("$ws/shot.png", $PNG);
    write_file("$ws/notes.txt", "not a picture\n");
    write_file("$ws/pct%.png", $PNG);
    write_file("$ws/fail.png", $PNG);
    symlink("$ws/shot.png", "$ws/link.png");
    my @refused = (
        [['', 'out.jpg'], qr/no picture to read/],
        [['shot.png', ''], qr/no file to write/],
        [['missing.png', 'o.jpg'], qr/not a file/],
        [['notes.txt', 'o.jpg'], qr/not a picture ImageMagick reads/],
        [['shot.png', 'o.pdf'], qr/must end in/],
        [['shot.png', 'o.ps'], qr/must end in/],
        [['shot.png', 'o[1].png'], qr/\[ \] and % are not allowed/],
        [['pct%.png', 'o.png'], qr/\[ \] and % are not allowed/],
        [['shot.png', '../o.png'], qr/outside of the workspace/],
        [['shot.png', 'o.jpg', 'abc'], qr/width must be/],
        [['shot.png', 'o.jpg', '0'], qr/width must be/],
        [['shot.png', 'o.jpg', '20000'], qr/width must be/],
        [['shot.png', 'o.jpg', '', '-5'], qr/height must be/],
        [['shot.png', 'o.jpg', '', '', '', '', '0'], qr/quality must be/],
        [['shot.png', 'o.jpg', '', '', '', '', '101'], qr/quality must be/],
        [['shot.png', 'o.jpg', '', '', '800x600'], qr/crop must be/],
        [['shot.png', 'o.jpg', '', '', '', '45'], qr/rotate must be/],
        [['shot.png', 'link.png'], qr/link or a directory/],
    );
    foreach my $case (@refused){
        my ($args, $re) = @$case;
        my (undef, $e) = ai::execute_tool('convert', 'CONVERT_5d1a', $args);
        like($e // '', $re, "refused: ".join(' ', map {"'$_'"} @$args));
    }
    ok(!glob("$ws/o*") && !-e "$ws/o.jpg", "refused: nothing was written");

    # the program fails: the reason is the result, and nothing is written
    my (undef, $e) = ai::execute_tool('convert', 'CONVERT_5d1a', ['fail.png', 'o.jpg']);
    like($e // '', qr/exit code: 3/, "failed: the reason of the program is the error");
    ok(!-e "$ws/o.jpg" && !glob("$ws/.aicli-convert-*"), "failed: no output and no temp file");
}

{
    my $ws = fresh_stub(AI_CONVERT_MAX => 10);
    write_file("$ws/shot.png", $PNG);
    my (undef, $e) = ai::execute_tool('convert', 'CONVERT_5d1a', ['shot.png', 'o.jpg']);
    like($e // '', qr/more than AI_CONVERT_MAX \(10\)/, "limit: a bigger input is refused by AI_CONVERT_MAX");
}

{
    my $empty = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1, PATH => $empty);
    $tools::MAGICK_LOOKED = 0;
    ok(!tools::available('convert'), "availability: no convert without a magick program on the PATH");
    ok(tools::available('image'), "availability: image is there with AI_VISION, without a program");
}

# a sub-agent runs it too: the program is a job of the loop, the result comes
# when it is over
{
    my $ws = fresh_stub();
    write_file("$ws/shot.png", $PNG);
    my @done;
    ai::execute_tool_async('convert', 'CONVERT_5d1a', ['shot.png', 'async.png', '', '', '', '', ''],
        sub {@done = @_});
    loop::run(sub {@done});
    like($done[0] // '', qr/converted shot\.png to async\.png/, "sub-agent: the conversion is a job of the loop");
    is($done[1], undef, "sub-agent: and it has no error");
    ok(-f "$ws/async.png", "sub-agent: the output is there");
    @tools::CHANGES = ();
}

# the shrinking of an oversized picture needs a JPEG out of the program: a
# stand-in that writes something else is refused
{
    my $ws = fresh_stub(AI_IMAGE_MAX => 10);
    write_file("$ws/shot.png", $PNG);
    my (undef, $e) = ai::execute_tool('image', 'IMAGE_4e0b', ['shot.png']);
    like($e // '', qr/more than AI_IMAGE_MAX \(10\), and could not be made smaller: ImageMagick wrote no JPEG/,
        "shrink: a program that writes no JPEG is refused");
    ok(!glob("$ws/aicli-shrink-*") && !@tools::IMAGES, "shrink: nothing is queued, no temp file");
}

# ---------------------------------------------------------------------------
# the real program, when there is one

my $real = do {
    TestAI::setup();
    $tools::MAGICK_LOOKED = 0;
    tools::_magick();
};

SKIP: {
    skip "no ImageMagick (convert or magick) on the PATH", 1 unless $real;

    my @identify = (File::Basename::basename($real) eq 'magick') ? ($real, 'identify') : ('identify');
    my $dims = sub {
        my ($file) = @_;
        open(my $p, '-|', @identify, '-format', '%w %h', $file) or return '';
        my $l = <$p> // '';
        close($p);
        return $l;
    };
    my $magic = sub {
        my ($file) = @_;
        return substr(slurp_file($file) // '', 0, 12);
    };

    my $ws = fresh_real();
    ok(run_quiet({}, $real, '-size', '100x50', 'xc:red', "$ws/red.png") == 0, "real: a test picture is made");

    my ($r, $e) = ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'small.jpg', '40']);
    ok(!$e, "real: a resize runs") or diag($e);
    is($dims->('small.jpg'), '40 20', "real: resized to the width, the proportions kept");

    ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'big.png', '200', '200']);
    is($dims->('big.png'), '100 50', "real: a picture is never made bigger");

    ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'crop.png', '', '', '20x10+5+5']);
    is($dims->('crop.png'), '20 10', "real: a crop");

    ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'turn.png', '', '', '', '90']);
    is($dims->('turn.png'), '50 100', "real: a turn by 90 degrees");

    for my $f (qw(png gif webp bmp tif)){
        ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', "f.$f"]);
    }
    ok(substr($magic->('f.png'), 0, 4) eq "\x89PNG", "real: png written");
    ok(substr($magic->('f.gif'), 0, 3) eq 'GIF', "real: gif written");
    ok(substr($magic->('f.webp'), 0, 4) eq 'RIFF' && substr($magic->('f.webp'), 8, 4) eq 'WEBP', "real: webp written");
    ok(substr($magic->('f.bmp'), 0, 2) eq 'BM', "real: bmp written");
    ok(substr($magic->('f.tif'), 0, 4) =~ m/\A(?:II\*\0|MM\0\*)\z/, "real: tif written");

    ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'q10.jpg', '', '', '', '', '10']);
    ai::execute_tool('convert', 'CONVERT_5d1a', ['red.png', 'q95.jpg', '', '', '', '', '95']);
    ok(-s "$ws/q10.jpg" < -s "$ws/q95.jpg", "real: a lower quality makes a smaller jpg");
    @tools::CHANGES = ();

    # the policy of aicli stops what it must: PostScript runs no program, PDF is not written
    write_file("$ws/evil.ps", "%!PS-Adobe-3.0\n72 72 moveto (x) show showpage\n");
    my $policy = { MAGICK_CONFIGURE_PATH => "$TestAI::ROOT/ai/imagemagick" };
    isnt(run_quiet($policy, $real, 'evil.ps', 'p.png'), 0, "policy: PostScript is not converted");
    isnt(run_quiet($policy, $real, 'red.png', 'p.pdf'), 0, "policy: PDF is not written");
    ok(!-s "$ws/p.png" && !-s "$ws/p.pdf", "policy: and no output came of it");
    is(run_quiet($policy, $real, 'red.png', 'p.png'), 0, "policy: a PNG still converts");

    # the picture of the image tool made smaller: an oversized noise picture
    my $big = fresh_real(AI_IMAGE_MAX => 300000);
    ok(run_quiet({}, $real, '-size', '1500x1500', 'xc:', '+noise', 'Random', "$big/noise.png") == 0, "real: a big picture is made");
    ok(-s "$big/noise.png" > 300000, "real: and it is bigger than the limit");
    my ($ir, $ie) = ai::execute_tool('image', 'IMAGE_4e0b', ['noise.png']);
    ok(!$ie, "real: an oversized picture is made smaller") or diag($ie);
    like($ir // '', qr{image/jpeg, \d+ bytes, made from \d+ bytes}, "real: the result says it was made smaller");
    my $img = $tools::IMAGES[0] // {};
    is($img->{mime}, 'image/jpeg', "real: as a JPEG");
    my $raw = MIME::Base64::decode_base64($img->{data} // '');
    ok(length($raw) <= 300000 && substr($raw, 0, 3) eq "\xFF\xD8\xFF", "real: under the limit, and a JPEG");
    @tools::IMAGES = ();
}

done_testing();
