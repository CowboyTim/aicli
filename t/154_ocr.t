#!/usr/bin/perl
# the ocr tool: the text of a picture of the workspace, read by tesseract. A stand-in program checks the
# arguments and writes the text to the file tesseract writes (base.txt); the real tesseract is used when it is
# installed. A tool whose program is not on the PATH is not offered; the temp file is removed.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $bin = File::Temp::tempdir(CLEANUP => 1);
my $stub = <<'SH';
#!/bin/sh
printf '%s\n' "$@" > "__BIN__/tesseract.args"
mode=$(cat "__BIN__/ocr.mode" 2>/dev/null)
case "$mode" in
  empty) : > "$2.txt"; exit 0 ;;
  fail) echo "Failed loading language 'xyz'" >&2; exit 1 ;;
  *) printf 'Hello OCR\nsecond line\n' > "$2.txt"; exit 0 ;;
esac
SH
$stub =~ s/__BIN__/$bin/g;
open(my $sh, '>', "$bin/tesseract") or die $!;
print {$sh} $stub;
close($sh);
chmod 0755, "$bin/tesseract";
sub mode_of { my ($m) = @_; open(my $fh, '>', "$bin/ocr.mode") or die $!; print {$fh} $m; close($fh) }
sub args_of { open(my $fh, '<', "$bin/tesseract.args") or die $!; my @a = map {chomp; $_} <$fh>; close($fh); return @a }
sub leftovers { my @l = glob(ai::tmpdir()."/aicli-ocr-*"); return scalar(@l) }
sub put { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

my $tmp = TestAI::setup(PATH => "$bin:$ENV{PATH}");
my $ws = "$tmp/work";
mkdir $ws or die "work: $!";
ai::set_workspace($ws);
chdir($ws) or die "chdir: $!";
put("$ws/scan.png", "\x89PNG\r\n\x1a\n" . ("x" x 20));
put("$ws/notes.png", "plain text, not a picture\n");

ok(tools::available('ocr'), "the ocr tool is offered where tesseract is installed");

# the text of the picture, the defaults: English, page mode 3
mode_of('text');
{
    my $r = tools::ocr_b8e4(["scan.png"]);
    is($r, "text of scan.png (eng):\nHello OCR\nsecond line", "ocr: the text of the picture, with its language");
    my @a = args_of();
    like($a[0], qr{scan\.png\z}, "ocr: the picture, named in the workspace");
    like($a[1], qr{/aicli-ocr-\d+-\d+\z}, "ocr: the output base is a temp file");
    is(join(' ', @a[2 .. $#a]), "-l eng --psm 3", "ocr: English and page mode 3 by default");
    is(leftovers(), 0, "ocr: the temp file is removed");
}

# the language and the page mode as asked; several languages joined
{
    tools::ocr_b8e4(["scan.png", "nld", "6"]);
    is(join(' ', (args_of())[2 .. 5]), "-l nld --psm 6", "ocr: a language and a page mode as asked");
    tools::ocr_b8e4(["scan.png", "eng+nld", ""]);
    is(join(' ', (args_of())[2 .. 5]), "-l eng+nld --psm 3", "ocr: several languages joined with +");
}

# no text found is said, not an empty answer
mode_of('empty');
{
    eval {tools::ocr_b8e4(["scan.png"])};
    like($@, qr/no text found in scan\.png/, "ocr: a picture with no text is said");
    is(leftovers(), 0, "ocr: and its temp file is removed");
}

# a failure of the program is an error with what it said
mode_of('fail');
{
    eval {tools::ocr_b8e4(["scan.png", "xyz"])};
    like($@, qr/Failed loading language 'xyz'/, "ocr: a failure of the program is an error with its output");
    is(leftovers(), 0, "ocr: and no temp file is left");
}

# refusals, nothing is read
mode_of('text');
{
    eval {tools::ocr_b8e4(["scan.png", "eng;rm"])};
    like($@, qr/the language is a name such as eng/, "refused: a language that is not a name");
    eval {tools::ocr_b8e4(["scan.png", "eng", "14"])};
    like($@, qr/from 0 to 13/, "refused: a page mode above 13");
    eval {tools::ocr_b8e4(["scan.png", "eng", "x"])};
    like($@, qr/from 0 to 13/, "refused: a page mode that is not a number");
    eval {tools::ocr_b8e4(["notes.png"])};
    like($@, qr/not a picture tesseract reads/, "refused: a file that is not a picture");
    eval {tools::ocr_b8e4(["missing.png"])};
    like($@, qr/not a file/, "refused: no such file");
    eval {tools::ocr_b8e4(["../outside.png"])};
    like($@, qr/outside of the workspace|not a file/, "refused: a path out of the workspace");
    eval {tools::ocr_b8e4([""])};
    like($@, qr/no picture to read/, "refused: no picture named");
}

# without the program the tool is not offered
{
    local $::ORIG_ENV{PATH} = File::Temp::tempdir(CLEANUP => 1);
    ok(!tools::available('ocr'), "no tesseract on the PATH: ocr is not offered");
}

# the real program, when it is installed: its text of a picture with text (no picture with text is made here)
SKIP: {
    local $::ORIG_ENV{PATH} = "/usr/bin:/bin";
    tools::_program('tesseract') or skip "tesseract is not installed here (the tesseract-ocr package)", 1;
    skip "no picture with text to read in the tests (a real run needs one)", 1;
}

chdir("/") or die "chdir: $!";
done_testing();
