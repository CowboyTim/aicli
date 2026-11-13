#!/usr/bin/perl
# speech: the recorder is a child that gets SIGINT when the time is up, the
# recording goes to the speech recognizer as multipart/form-data, the text is
# the next request. The recorder here is a script that writes a file on SIGINT.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = TestAI::setup();
my $rec = "$tmp/fake-recorder";
open(my $fh, '>', $rec) or die $!;
print {$fh} <<'SH';
#!/bin/sh
# records nothing: on SIGINT it writes a file to the last argument and exits
for out; do :; done
trap 'printf "RIFFfake" > "$out"; exit 0' INT
while :; do sleep 0.05; done
SH
close $fh;
chmod 0755, $rec;

# the multipart body
{
    my $body = ai::multipart_body('BOUND', ['model', 'whisper'], ['file', "\x00\x01bytes", 'voice.wav', 'audio/wav']);
    like($body, qr/\A--BOUND\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper\r\n--BOUND\r\n/, "multipart: a plain field");
    like($body, qr/name="file"; filename="voice\.wav"\r\nContent-Type: audio\/wav\r\n\r\n\x00\x01bytes\r\n--BOUND--\r\n\z/, "multipart: the file, closed");
}

# programs
{
    ok(ai::find_program('sh'), "programs: found in PATH");
    ok(!ai::find_program('no-such-program-aicli'), "programs: not found is undef");
}

# the recording stops when its time is up, the file is there
{
    local $::ORIG_ENV{AI_RECORDER} = $rec;
    my $file = "$tmp/voice.wav";
    my $ok = ai::voice_record($file, 0.5);
    ok($ok, "record: the recorder ran and wrote the file");
    is(ai::slurp($file), "RIFFfake", "record: the file is the one the recorder finished");
}

# no recorder installed
{
    local $::ORIG_ENV{AI_RECORDER} = 'no-such-recorder-aicli';
    my $err = TestAI::capture {ok(!ai::voice_record("$tmp/x.wav", 0.1), "record: no recorder, nothing recorded")};
    like($err, qr/no recorder/, "record: said so");
}

# a recorder that fails writes no file: its own message says why
{
    my $bad = "$tmp/failing-recorder";
    open(my $bh, '>', $bad) or die $!;
    print {$bh} "#!/bin/sh\necho 'pw-record: cannot connect to PipeWire' >&2\nexit 1\n";
    close $bh;
    chmod 0755, $bad;
    local $::ORIG_ENV{AI_RECORDER} = $bad;
    my $ok;
    my $err = TestAI::capture {$ok = ai::voice_record("$tmp/failed.wav", 0.2)};
    ok(!$ok, "failing recorder: no recording");
    like($err, qr/wrote no recording: .*cannot connect to PipeWire/, "failing recorder: the recorder's message is shown");
}

# the level of the recording and the footer item while it is made
{
    my $loud = "$tmp/level-loud.raw";
    open(my $lf, '>:raw', $loud) or die $!;
    print {$lf} pack('s<*', map {$_ % 2 ? 16000 : -16000} 1 .. 8000);
    close $lf;
    my $silent = "$tmp/level-silent.raw";
    open(my $sf, '>:raw', $silent) or die $!;
    print {$sf} pack('s<*', (0) x 8000);
    close $sf;
    ok(ai::voice_level($loud) > 0.85, "level: a loud recording is near the top");
    is(ai::voice_level($silent), 0, "level: silence is zero");
    is(ai::voice_level("$tmp/no-such.raw"), 0, "level: no file is zero");

    @ai::VOICE_LEVELS = (0, 0.2, 0.5, 0.9, 1);
    my $meter = ai::voice_meter();
    like($meter, qr/\A\Q${\ tui::glyph('rec')}\E \s+\S+\z/, "meter: the record glyph, then the cells");
    {
        local $::ORIG_ENV{AI_GLYPHS} = "unicode";
        is(length(ai::voice_meter()), 1 + 1 + 8, "meter: the glyph, a space and eight cells");
    }

    # the item is shown while the recorder runs and taken away when it is done
    package FakeTUI { sub new { bless {calls => []}, shift } sub set { push @{$_[0]{calls}}, "set $_[1]" } sub unset { push @{$_[0]{calls}}, "unset $_[1]" } sub clear {} }
    TestAI::setup(AI_RECORDER => $rec);
    local $ai::TUI = FakeTUI->new;
    my $ok;
    TestAI::capture {$ok = ai::voice_record("$tmp/meter.wav", 0.3)};
    ok($ok, "meter: the recording was made");
    is_deeply($ai::TUI->{calls}, ['set recording', 'unset recording'], "meter: the item comes and goes with the recorder");
}

# the preview while it is recorded: passes over the new audio, the words that
# two passes agree on are final, the footer shows the rest
{
    is(length(ai::wav_of_pcm("abcd")), 44 + 4, "wav: a 44 byte header and the data");
    like(ai::wav_of_pcm("abcd"), qr/\ARIFF.{4}WAVEfmt .{4}.{16}data\x04\x00\x00\x00abcd\z/s, "wav: the header of 16 kHz mono 16 bit");
    is(ai::pcm_peak(pack('s<*', 3, -700, 20)), 700, "peak: the loudest sample");

    # agreement: the segments both passes give the same way, the last never
    is_deeply([ai::heard_agree([{text => 'a', end => 1}, {text => 'b', end => 2}, {text => 'c', end => 3}],
                               [{text => 'a', end => 1}, {text => 'b', end => 2}, {text => 'x', end => 3}], 6)],
              [2, 2], "agree: two agreeing segments are final, the last is not");
    is_deeply([ai::heard_agree([{text => 'a', end => 1}, {text => 'b', end => 2}], [], 6)], [0, 0], "agree: nothing without a pass before");
    is_deeply([ai::heard_agree([{text => 'a', end => 1}, {text => 'b', end => 2}], [], 30)], [1, 1], "agree: a long buffer is cut at its last segment");
    is_deeply([ai::heard_agree([{text => 'Hello,', end => 1}, {text => 'x', end => 2}], [{text => 'hello', end => 1}], 6)], [1, 1], "agree: punctuation and case do not count");

    # two passes: the recording comes in two parts, the second pass sees the new part
    my $prec = "$tmp/preview-recorder";
    open(my $ph, '>', $prec) or die $!;
    print {$ph} <<"PL";
#!$^X
use strict; use warnings;
my \$out = \$ARGV[-1];
\$SIG{INT} = sub { exit 0 };
\$| = 1;
sub noise { pack('s<*', map {int(rand(20000)) - 10000} 1 .. \$_[0]) }
open(my \$fh, '>:raw', \$out) or die "cannot write \$out: \$!\\n";
print {\$fh} 'RIFF'.pack('V', 0).'WAVE'.'fmt '.pack('V', 16).pack('vvVVvv', 1, 1, 16000, 32000, 2, 16).'data'.pack('V', 0);
print {\$fh} noise(56000); # 3.5 s
\$fh->flush;
select(undef, undef, undef, 0.7);
print {\$fh} noise(56000);
\$fh->flush;
select(undef, undef, undef, 0.7);
print {\$fh} noise(48000); # 3 s more
\$fh->flush;
sleep 1 while 1;
PL
    close $ph;
    chmod 0755, $prec;

    TestAI::setup(AI_RECORDER => $prec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    package FakeTUI2 { sub new { bless {calls => []}, shift } sub set { push @{$_[0]{calls}}, "set $_[1]" } sub unset { push @{$_[0]{calls}}, "unset $_[1]" } sub clear {} }
    local $ai::TUI = FakeTUI2->new;
    my @answers = (
        [{text => ' hello there', end => 1.5}, {text => ' general', end => 3.0}],
        [{text => ' hello there', end => 1.5}, {text => ' general kenobi', end => 3.0}, {text => ' you are', end => 3.4}],
        [{text => ' general kenobi', end => 1.5}, {text => ' you are', end => 1.9}, {text => ' now', end => 2.5}],
    );
    my @sent;
    no warnings 'redefine';
    local *loop::http = sub {
        my (%r) = @_;
        push @sent, \%r;
        my $segs = shift @answers;
        $r{on_done}->({body => $::JSON->encode({text => 'ignored', segments => $segs}), code => 200, error => undef});
        return;
    };
    my $ok;
    TestAI::capture {$ok = ai::voice_record("$tmp/preview.wav", 3.5)};
    ok($ok, "preview: the recording was made");
    is(scalar(@sent), 3, "preview: three passes went to the recognizer");
    my $datalen = sub {
        my ($body) = @_;
        my $fmt = index($body, 'WAVEfmt ');
        my $at = index($body, 'data', $fmt);
        return unpack('V', substr($body, $at + 4, 4));
    };
    is($datalen->($sent[0]{data}), 112000, "preview: the first pass is the audio so far, 3.5 seconds");
    is($datalen->($sent[1]{data}), 224000, "preview: the second pass is all of it, 7 seconds: the words are final only after it");
    is($datalen->($sent[2]{data}), 272000, "preview: the third starts where the final words end (1.9 s in), 8.5 seconds");
    like($sent[0]{data}, qr/name="response_format"\r\n\r\nverbose_json/, "preview: the passes ask for the segments");
    is(ai::voice_heard(), "hello there general kenobi you are now", "preview: the final words and the rest of the last pass");
    is_deeply($ai::TUI->{calls}, ['set recording', 'set heard', 'unset recording', 'unset heard'], "preview: the footer items come and go");
}

# AI_ASR_PROMPT goes to the recognizer, with the model
{
    my $f = "$tmp/prompt.wav";
    ai::spew($f, "RIFFprompt");
    TestAI::setup(AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions', AI_ASR_PROMPT => 'Code me, Perl.');
    TestAI::mock_http(['{"text":"Code me"}']);
    is(ai::transcribe($f), "Code me", "prompt: the text");
    like($TestAI::REQUESTS[0]{data}, qr/name="prompt"\r\n\r\nCode me, Perl\.\r\n/, "prompt: sent with the request");
    like($TestAI::REQUESTS[0]{data}, qr/name="model"\r\n\r\nwhisper-large-v3-turbo\r\n/, "prompt: the model is still there");
    TestAI::setup(AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    TestAI::mock_http(['{"text":"hi"}']);
    ai::transcribe($f);
    unlike($TestAI::REQUESTS[0]{data}, qr/name="prompt"/, "prompt: not sent when not set");
}

# the recognizer: the text, and what is sent
{
    TestAI::setup(AI_RECORDER => $rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    $::ORIG_ENV{TMPDIR} = $tmp; # the recordings go to the temp dir of the test
    TestAI::mock_http(['{"text":"  open the file  "}']);
    my $text = ai::voice_once(0.5);
    is($text, "open the file", "asr: the text, without the spaces around");
    my $dir = ai::voice_dir();
    is((stat $dir)[2] & 0777, 0700, "voice: the recording directory is private to the user");
    ok(!-e "$dir/voice.wav", "voice: the recording is removed after it was recognized");
    my $req = $TestAI::REQUESTS[0];
    is($req->{url}, 'http://127.0.0.1:52625/v1/audio/transcriptions', "asr: sent to the recognizer");
    my ($ct) = grep {/^Content-Type: multipart/} @{$req->{headers} // []};
    like($ct // '', qr/^Content-Type: multipart\/form-data; boundary=\S+$/, "asr: sent as multipart");
    like($req->{data}, qr/name="file"; filename="voice\.wav"\r\nContent-Type: audio\/wav\r\n\r\nRIFFfake\r\n/, "asr: the recording is the file part");
    like($req->{data}, qr/name="model"\r\n\r\nwhisper-large-v3-turbo\r\n/, "asr: the default model");
}

# nothing configured, or nothing said
{
    TestAI::setup(AI_RECORDER => $rec);
    my $err = TestAI::capture {ok(!defined ai::voice_once(0.1), "asr: no recognizer, no text")};
    like($err, qr/no speech recognizer set/, "asr: said so");
}
{
    TestAI::setup(AI_RECORDER => $rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    TestAI::mock_http(['{"text":""}']);
    ok(!defined ai::voice_once(0.1), "asr: an empty text is no request");
}

# /voice: heard, then the request goes to the model
{
    TestAI::setup(AI_RECORDER => $rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions', AI_TOOL_CALLS => 'text');
    TestAI::mock_http(['{"text":"say hello"}'], [TestAI::content("hello back"), TestAI::done()]);
    my $out = TestAI::capture {ai::handle_command("/voice 0.5")};
    like($out, qr/heard:.*say hello/, "/voice: the text is shown");
    like($out, qr/hello back/, "/voice: the model answers it");
    like($TestAI::REQUESTS[1]{data}, qr/say hello/, "/voice: the text is the request");
    is(scalar(@TestAI::REQUESTS), 2, "/voice: one request to the recognizer, one to the model");
}

# push to talk: Enter starts, Enter stops (the keys come from a file here)
sub keys_from {
    my ($name, $keys) = @_;
    open(my $fh, '>', "$tmp/$name") or die $!;
    print {$fh} $keys;
    close $fh;
    return "$tmp/$name";
}
{
    TestAI::setup(AI_RECORDER => $rec, AI_VOICE_MAX => 10);
    my $file = "$tmp/ptt.wav";
    local *STDIN;
    open(STDIN, '<', keys_from('keys-two', "\n\n")) or die $!;
    my $out = TestAI::capture {ok(ai::voice_ptt($file), "ptt: start and stop")};
    is(ai::slurp($file), "RIFFfake", "ptt: the recording is finished");
    like($out, qr/recording, Enter to stop/, "ptt: said that it records");
}
{
    TestAI::setup(AI_RECORDER => $rec, AI_VOICE_MAX => 10);
    my $file = "$tmp/ptt2.wav";
    local *STDIN;
    open(STDIN, '<', keys_from('keys-one', "\n")) or die $!;
    TestAI::capture {ok(ai::voice_ptt($file), "ptt: input that ends while recording stops it")};
    is(ai::slurp($file), "RIFFfake", "ptt: the recording is finished at the end of the input");
}
{
    TestAI::setup(AI_RECORDER => $rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    TestAI::mock_http(['{"text":"push to talk"}']);
    local *STDIN;
    open(STDIN, '<', keys_from('keys-asr', "\n\n")) or die $!;
    my $text;
    TestAI::capture {$text = ai::voice_once(undef)};
    is($text, "push to talk", "ptt: the recording goes to the recognizer");
}

# a recording without sound is not sent: the recognizer makes up a word for it
{
    my $wav = sub {
        my $pcm = pack('s<*', @{$_[0]});
        return 'RIFF'.pack('V', 36 + length $pcm).'WAVE'.'fmt '.pack('V', 16)
            .pack('vvVVvv', 1, 1, 16000, 32000, 2, 16).'data'.pack('V', length $pcm).$pcm;
    };
    my $silent = "$tmp/silent.wav";
    open(my $sh, '>:raw', $silent) or die $!; print {$sh} $wav->([(0) x 8000]); close $sh;
    my $loud = "$tmp/loud.wav";
    open(my $lh, '>:raw', $loud) or die $!; print {$lh} $wav->([map {$_ % 2 ? 8000 : -8000} 1 .. 8000]); close $lh;
    ok(ai::voice_quiet($silent), "quiet: a silent recording is quiet");
    ok(!ai::voice_quiet($loud), "quiet: a loud recording is not");
    ok(!ai::voice_quiet("$tmp/no-such-file.wav"), "quiet: a missing file is not quiet, the recognizer decides");

    # a recorder that makes a silent file: no request, and it says so
    my $quiet_rec = "$tmp/quiet-recorder";
    open(my $qh, '>', $quiet_rec) or die $!;
    print {$qh} "#!/bin/sh\nfor out; do :; done\ntrap 'cp \"$silent\" \"\$out\"; exit 0' INT\nwhile :; do sleep 0.05; done\n";
    close $qh;
    chmod 0755, $quiet_rec;
    TestAI::setup(AI_RECORDER => $quiet_rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    my $before = scalar(@TestAI::REQUESTS);
    my $text;
    my $out = TestAI::capture {$text = ai::voice_once(0.3)};
    ok(!defined $text, "quiet: no text");
    like($out, qr/nothing heard/, "quiet: said that nothing was heard");
    is(scalar(@TestAI::REQUESTS), $before, "quiet: no request to the recognizer");
}

done_testing();
