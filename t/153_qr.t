#!/usr/bin/perl
# the QR tools: qr_encode writes a text as a PNG in the workspace (qrencode), qr_decode reads the codes of a picture
# (zbarimg). Stand-in programs check the arguments and give the answers; the real qrencode writes a real code when
# it is installed; the real zbarimg is used when it is installed (the round trip). A tool whose program is not on
# the PATH is not offered.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }
sub calls_reply {
    my (@calls) = @_;
    my @events;
    my $i = 0;
    for my $c (@calls){
        my ($name, $id, $args) = @$c;
        push @events, +{choices => [+{delta => +{tool_calls => [+{index => $i++, id => $id, function => +{name => $name, arguments => $args}}]}}]};
    }
    push @events, +{choices => [+{delta => +{}, finish_reason => 'tool_calls'}]};
    return [sse(@events)];
}
sub text_reply {
    my ($text) = @_;
    return [sse({choices => [{delta => {content => $text}}]}, {choices => [{delta => {}, finish_reason => 'stop'}]})];
}

# the stand-ins: qrencode logs its arguments and writes a file that starts like a PNG; zbarimg answers what
# the mode file says (found, none, error). Written with their own paths: the tool's environment is a whitelist.
my $bin = File::Temp::tempdir(CLEANUP => 1);
sub stub {
    my ($name, $body) = @_;
    open(my $fh, '>', "$bin/$name") or die "$name: $!";
    print {$fh} "#!/bin/sh\n$body";
    close($fh);
    chmod 0755, "$bin/$name";
}
stub('qrencode', <<"SH");
printf '%s\\n' "\$@" > "$bin/qrencode.args"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out="\$2"; shift; fi
  shift
done
printf '\\211PNG\\r\\n\\032\\nstub' > "\$out"
exit 0
SH
stub('zbarimg', <<"SH");
mode=\$(cat "$bin/zbar.mode" 2>/dev/null)
case "\$mode" in
  none) exit 4 ;;
  error) echo "zbarimg: cannot open the image" ; exit 1 ;;
  *) echo "https://example.org/found"; exit 0 ;;
esac
SH
sub zbar_mode { my ($m) = @_; open(my $fh, '>', "$bin/zbar.mode") or die $!; print {$fh} $m; close($fh) }

my $empty = File::Temp::tempdir(CLEANUP => 1);

# a turn in a workspace with the stand-ins on the PATH
sub setup_ws {
    my $tmp = TestAI::setup(AI_TOOL_CALLS => 'native', PATH => "$bin:$ENV{PATH}");
    my $ws = "$tmp/work";
    mkdir $ws or die "work: $!";
    ai::set_workspace($ws);
    chdir($ws) or die "chdir: $!";
    return $ws;
}
sub put { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

my $ws = setup_ws();
ok(tools::available('qr_encode'), "the qr_encode tool is offered where qrencode is installed");
ok(tools::available('qr_decode'), "the qr_decode tool is offered where zbarimg is installed");

# encode: the stand-in gets the text after "--", the size and the level, and writes the file
{
    my $r = tools::qr_encode_9d42(["-n not an option", "code.png", "6", "H"]);
    like($r, qr/^wrote .*code\.png: a QR code of 16 bytes at level H, 6 pixels a square/, "encode: the result says what was written");
    open(my $fh, '<', "$bin/qrencode.args") or die $!;
    my @args = map {chomp; $_} <$fh>;
    close($fh);
    my ($dash) = grep {$args[$_] eq '--'} 0 .. $#args;
    ok(defined $dash && $args[$dash + 1] eq '-n not an option', "encode: the text comes after -- (a text that starts with - is a text)");
    # the program writes a temp file next to the output, which is renamed when the whole thing worked
    like(join(' ', @args[0 .. $dash - 1]), qr{^-o \S*\.aicli-qr-\d+-code\.png -t PNG -s 6 -l H$},
        "encode: the output (a temp file beside it), the PNG type, the size and the level");
    ok(-f "$ws/code.png", "encode: the file is in the workspace");
}

# defaults: qr.png, 8 pixels, level M; a name taken goes to the next free one
{
    my $r = tools::qr_encode_9d42(["hello", "", "", ""]);
    like($r, qr/qr\.png: a QR code of 5 bytes at level M, 8 pixels/, "encode: the defaults are qr.png, level M and 8 pixels");
    $r = tools::qr_encode_9d42(["hello", "qr.png", "", ""]);
    like($r, qr/qr-2\.png/, "encode: a name taken gets the next free one");
    ok(-f "$ws/qr.png" && -f "$ws/qr-2.png", "encode: both files are there");
}

# refusals: nothing written
{
    eval {tools::qr_encode_9d42(["", "a.png", "", ""])};
    like($@, qr/no text to encode/, "refused: no text");
    eval {tools::qr_encode_9d42(["x", "a.jpg", "", ""])};
    like($@, qr/must end in \.png/, "refused: not a PNG name");
    eval {tools::qr_encode_9d42(["x", "a.png", "33", ""])};
    like($@, qr/from 1 to 32/, "refused: size too big");
    eval {tools::qr_encode_9d42(["x", "a.png", "", "X"])};
    like($@, qr/L, M, Q or H/, "refused: a level that is not one");
    eval {tools::qr_encode_9d42(["x\0y", "a.png", "", ""])};
    like($@, qr/NUL/, "refused: a NUL byte");
    ok(!-e "$ws/a.png", "refused: nothing written");
}

# decode: the text of the code, from the stand-in
{
    put("$ws/code.png", "\x89PNG\r\n\x1a\n");
    zbar_mode('found');
    my $r = tools::qr_decode_3b1e(["code.png"]);
    like($r, qr/^QR code in code\.png:\nhttps:\/\/example\.org\/found$/, "decode: the text of the code");
    zbar_mode('none');
    eval {tools::qr_decode_3b1e(["code.png"])};
    like($@, qr/no QR code found in code\.png/, "decode: no code is said, not a failure of the program");
    zbar_mode('error');
    eval {tools::qr_decode_3b1e(["code.png"])};
    like($@, qr/zbarimg: cannot open/, "decode: a failure of the program is an error with its output");
    put("$ws/notes.png", "plain text, not a picture\n");
    eval {tools::qr_decode_3b1e(["notes.png"])};
    like($@, qr/not a picture zbarimg reads/, "decode: a file that is not a picture is refused");
    eval {tools::qr_decode_3b1e(["../outside.png"])};
    like($@, qr/outside of the workspace|not a file/, "decode: a path out of the workspace is refused");
}

# in a turn: the model asks for a code, the page is offered the PNG
{
    my @events;
    local $ai::EVENT_SINK = sub { push @events, [@_] };
    local $::UI = 1;
    TestAI::mock_http(
        calls_reply(['qr_encode', 'call_qr', $::JSON->encode({text => 'https://example.org/turn', output => 'turn.png'})]),
        text_reply('made the code'),
    );
    TestAI::capture {ai::chat_completion("make a code")};
    ok(-f "$ws/turn.png", "turn: the model's call wrote the code");
    my @files = map {$_->[1]{path}} grep {$_->[0] eq 'file'} @events;
    ok(scalar(grep {m/turn\.png\z/} @files), "turn: the page is offered the code's file");
    my ($tool) = grep {($_->{role} // '') eq 'tool'} ai::load_messages();
    like($tool->{content} // '', qr/^wrote .*turn\.png/, "turn: the model gets the result");
}

# without the program the tool is not offered
{
    local $::ORIG_ENV{PATH} = $empty;
    ok(!tools::available('qr_encode'), "no qrencode on the PATH: qr_encode is not offered");
    ok(!tools::available('qr_decode'), "no zbarimg on the PATH: qr_decode is not offered");
}

# the real program: a code written by the installed qrencode is a PNG (and, with zbarimg, reads back)
SKIP: {
    local $::ORIG_ENV{PATH} = "/usr/bin:/bin"; # the installed programs, not the stand-ins
    tools::_program('qrencode') or skip "qrencode is not installed", 2;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $real_ws = "$dir";
    chdir($real_ws) or die $!;
    ai::set_workspace($real_ws);
    my $r = tools::qr_encode_9d42(["real round trip " . time, "real.png", "8", "M"]);
    like($r, qr/^wrote .*real\.png/, "real qrencode: the code is written");
    open(my $fh, '<:raw', "$real_ws/real.png") or die $!;
    read($fh, my $head, 8);
    close($fh);
    is($head, "\x89PNG\r\n\x1a\n", "real qrencode: a PNG");
    ai::set_workspace($ws);
}
SKIP: {
    local $::ORIG_ENV{PATH} = "/usr/bin:/bin";
    tools::_program('zbarimg') or skip "zbarimg is not installed here (the zbar-tools package)", 1;
    my $text = "round trip " . time;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    chdir($dir) or die $!;
    ai::set_workspace($dir);
    tools::qr_encode_9d42([$text, "rt.png", "8", "M"]);
    like(tools::qr_decode_3b1e(["rt.png"]), qr/\Q$text\E/, "round trip: the real zbarimg reads back the text");
    ai::set_workspace($ws);
}

done_testing();
