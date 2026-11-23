#!/usr/bin/perl
# speech: the WAV of the speech service is written to the workspace whole (the old file goes to the
# undo journal first, a failed write leaves nothing behind), its name as the tool works it out, the
# arguments checked, and the file offered to the page after the call
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $WAV = "RIFF\x24\x00\x00\x00WAVEfmt " . ("\0" x 40);

sub slurp { my ($f) = @_; open(my $h, '<:raw', $f) or return undef; local $/; my $d = <$h>; close $h; return $d }
sub spew  { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

# the speech service: loop::http answers at once with what $REPLY gives for the request
my (@REQ, $REPLY);
{
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        push @REQ, \%r;
        $r{on_done}->($REPLY->(\%r));
        return;
    };
}
$REPLY = sub { {code => 200, error => undef, headers => {}, body => $WAV} };

TestAI::setup(AI_TOOL_CALLS => 'native', AI_SPEECH_URL => 'http://speech.test:8000/rocm/');
my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
$ai::WORKSPACE = $ws;
chdir($ws);

ok(tools::available('speech'), "available: the speech service is set");
{
    local $::ORIG_ENV{AI_SPEECH_URL} = '';
    ok(!tools::available('speech'), "not available without AI_SPEECH_URL");
}

# the WAV, its request, its change in the journal
{
    my ($res, $err) = ai::execute_tool('speech', 'SPEECH_7e2b', ['Good morning.', 'ana', 'morning.wav', 'en', '5']);
    ok(!$err, "a WAV is made") or diag($err);
    like($res, qr/wrote morning\.wav: \d+ bytes of WAV \(voice ana\)/, "the result names the file and the voice");
    is(slurp("$ws/morning.wav"), $WAV, "the file is the WAV the service sent");
    is($REQ[-1]{url}, 'http://speech.test:8000/rocm/v1/audio/speech', "the URL: the base (its slash taken off) and the speech path");
    is_deeply($J->decode($REQ[-1]{data}),
        {input => 'Good morning.', voice => 'ana', response_format => 'wav', language => 'en', seed => 5},
        "the request: the text, the voice, the format, the language and the seed");
    ok(!glob("$ws/.aicli-*"), "no temp file is left");

    my $last = $tools::CHANGES[-1];
    is($last->{tool}, 'speech', "the change is listed under the tool");
    ok($last->{binary}, "as a binary file");
    like(slurp("$ai::AI_SESSION_DIR/undo/journal") // '', qr/"tool":"speech"/, "the journal of the session has the entry");
    @tools::CHANGES = ();
}

# a file of that name already there is kept as it is: the sound goes to the first free name, and the
# result names it
{
    spew("$ws/morning.wav", "old sound");
    my ($res, $err) = ai::execute_tool('speech', 'SPEECH_7e2b', ['Good evening.', 'ana', 'morning.wav']);
    ok(!$err, "a name already taken is made again") or diag($err);
    like($res, qr/\Awrote morning-2\.wav: /, "the sound goes to morning-2.wav, and the result names it");
    is(slurp("$ws/morning.wav"), "old sound", "the file that was there stays as it was");
    is(slurp("$ws/morning-2.wav"), $WAV, "the new sound is the new file");
    is($tools::CHANGES[-1]{path}, 'morning-2.wav', "the change is the new file");
    @tools::CHANGES = ();
}

# the default name: speech_<voice>.wav
{
    my ($res) = ai::execute_tool('speech', 'SPEECH_7e2b', ['Hello.', 'ben']);
    like($res, qr/wrote speech_ben\.wav:/, "no output name: speech_<voice>.wav");
    ok(-f "$ws/speech_ben.wav", "the file is there");
    @tools::CHANGES = ();
}

# refusals: nothing is asked of the service
{
    my $asked = scalar @REQ;
    my @refuse = (
        [['', 'ana', 'x.wav'],              qr/no text/,                          "no text"],
        [['hi', '', 'x.wav'],               qr/no voice/,                         "no voice"],
        [['hi', '../ana', 'x.wav'],         qr/the voice name has letters/,       "a voice name with a slash"],
        [['hi', 'ana', 'x.mp3'],            qr/the output must be a \.wav file/,  "an output that is not a .wav"],
        [['hi', 'ana', 'x.wav', '', 'x'],   qr/seed: a whole number/,             "a seed that is not a number"],
        [['hi', 'ana', '../x.wav'],         qr/outside of the workspace/,         "an output outside the workspace"],
    );
    for my $case (@refuse) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('speech', 'SPEECH_7e2b', $args);
        ok($err, "refused: $what") or diag($res);
        like($err // '', $re, "  and the reason says so");
    }
    is(scalar(@REQ), $asked, "no request went to the service for any of them");
}

# an answer that is not a WAV is an error, and leaves no file
{
    $REPLY = sub { {code => 200, error => undef, headers => {}, body => '{"error":"no voice"}'} };
    my ($res, $err) = ai::execute_tool('speech', 'SPEECH_7e2b', ['hi', 'ana', 'bad.wav']);
    like($err // '', qr/the speech service sent no WAV/, "an answer that is not a WAV is an error");
    ok(!-e "$ws/bad.wav" && !glob("$ws/.aicli-*"), "and leaves no file or temp file");
    $REPLY = sub { {code => 200, error => undef, headers => {}, body => $WAV} };
}

# the file a call made is offered: the name the result gives (a name taken gets another)
is(tools::offered_file('speech', ['hi', 'ana', 'morning.wav', '', ''], $ws, "wrote morning-2.wav: 44 bytes of WAV (voice ana)\n"),
    'morning-2.wav', "the file the result names is offered");
is(tools::offered_file('speech', ['hi', 'ben', '', '', ''], $ws, "wrote speech_ben.wav: 44 bytes of WAV (voice ben)\n"),
    'speech_ben.wav', "the default name too");
ok(!defined tools::offered_file('speech', ['hi', 'ana', 'nothere.wav'], $ws, "wrote nothere.wav: 44 bytes of WAV (voice ana)\n"),
    "a file that is not there is not offered");

done_testing();
