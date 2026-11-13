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

# the recognizer: the text, and what is sent
{
    TestAI::setup(AI_RECORDER => $rec, AI_ASR_URL => 'http://127.0.0.1:52625/v1/audio/transcriptions');
    TestAI::mock_http(['{"text":"  open the file  "}']);
    my $text = ai::voice_once(0.5);
    is($text, "open the file", "asr: the text, without the spaces around");
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
