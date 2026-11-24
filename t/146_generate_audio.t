#!/usr/bin/perl
# generate_audio: the WAV of the audio service (AudioLDM 2) is written to the workspace whole (the old file goes to
# the undo journal first, a failed write leaves nothing behind), its name as the tool works it out, the arguments
# checked, and the file offered to the page after the call
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

# the audio service: loop::http answers at once with what $REPLY gives for the request
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

TestAI::setup(AI_TOOL_CALLS => 'native', AI_AUDIO => 1, AI_AUDIO_URL => 'http://audio.test:8000/rocm/');
my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
$ai::WORKSPACE = $ws;
chdir($ws);

ok(tools::available('generate_audio'), "available: the audio service is set");
{
    local $::ORIG_ENV{AI_AUDIO_URL} = '';
    ok(!tools::available('generate_audio'), "not available without AI_AUDIO_URL");
}

# the WAV, its request, its change in the journal
{
    my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', ['ocean waves on a shore', 'waves.wav', '5', '100', '3']);
    ok(!$err, "a WAV is made") or diag($err);
    like($res, qr/wrote waves\.wav: \d+ bytes of WAV \(seconds 5, seed 3\)/, "the result names the file, the length and the seed");
    is(slurp("$ws/waves.wav"), $WAV, "the file is the WAV the service sent");
    is($REQ[-1]{url}, 'http://audio.test:8000/rocm/v1/audio/generations', "the URL: the base (its slash taken off) and the generations path");
    is_deeply($J->decode($REQ[-1]{data}),
        {model => 'audioldm2', prompt => 'ocean waves on a shore', seconds => 5, steps => 100, seed => 3},
        "the request: the model, the prompt, the length, the steps and the seed");
    ok(!glob("$ws/.aicli-*"), "no temp file is left");

    my $last = $tools::CHANGES[-1];
    is($last->{tool}, 'generate_audio', "the change is listed under the tool");
    ok($last->{binary}, "as a binary file");
    like(slurp("$ai::AI_SESSION_DIR/undo/journal") // '', qr/"tool":"generate_audio"/, "the journal of the session has the entry");
    @tools::CHANGES = ();
}

# the defaults: the length, the steps and the seed are the server's (5 s, 100 steps, seed 0); the name is audio_<seed>.wav
{
    my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', ['rain on a roof']);
    ok(!$err, "a prompt alone is enough") or diag($err);
    like($res, qr/wrote audio_0\.wav: \d+ bytes of WAV \(seconds 5, seed 0\)/, "no output name: audio_<seed>.wav, the defaults named");
    is_deeply($J->decode($REQ[-1]{data}), {model => 'audioldm2', prompt => 'rain on a roof', seed => 0},
        "the request leaves out what is not given");
    ok(-f "$ws/audio_0.wav", "the file is there");
    @tools::CHANGES = ();
}

# a file of that name already there is kept as it is: the sound goes to the first free name, and the result names it
{
    spew("$ws/waves.wav", "old sound");
    my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', ['wind', 'waves.wav']);
    ok(!$err, "a name already taken is made again") or diag($err);
    like($res, qr/\Awrote waves-2\.wav: /, "the sound goes to waves-2.wav, and the result names it");
    is(slurp("$ws/waves.wav"), "old sound", "the file that was there stays as it was");
    is(slurp("$ws/waves-2.wav"), $WAV, "the new sound is the new file");
    is($tools::CHANGES[-1]{path}, 'waves-2.wav', "the change is the new file");
    @tools::CHANGES = ();
}

# refusals: nothing is asked of the service
{
    my $asked = scalar @REQ;
    my @refuse = (
        [['', 'x.wav'],                       qr/no prompt/,                           "no prompt"],
        [['hi', 'x.wav', '11'],               qr/seconds: a number from 1 to 10/,      "a length above 10 seconds"],
        [['hi', 'x.wav', 'long'],             qr/seconds: a number from 1 to 10/,      "a length that is not a number"],
        [['hi', 'x.wav', '', '201'],          qr/steps: a whole number from 1 to 200/, "more steps than the server takes"],
        [['hi', 'x.wav', '', '', 'x'],        qr/seed: a whole number/,                "a seed that is not a number"],
        [['hi', 'x.mp3'],                     qr/the output must be a \.wav file/,     "an output that is not a .wav"],
        [['hi', '../x.wav'],                  qr/outside of the workspace/,            "an output outside the workspace"],
    );
    for my $case (@refuse) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', $args);
        ok($err, "refused: $what") or diag($res);
        like($err // '', $re, "  and the reason says so");
    }
    is(scalar(@REQ), $asked, "no request went to the service for any of them");
}

# without the service set, the tool is not offered (the call is refused as unavailable), and the handler says so too
{
    my $asked = scalar @REQ;
    local $::ORIG_ENV{AI_AUDIO_URL} = '';
    my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', ['hi', 'x.wav']);
    like($err // '', qr/not available here/, "no AI_AUDIO_URL: the tool is refused as not available");
    eval { tools::generate_audio_5e1c(['hi', 'x.wav']) };
    like($@, qr/no audio service is set up \(AI_AUDIO_URL\)/, "and the handler says what is missing");
    is(scalar(@REQ), $asked, "nothing is asked of the service");
}

# an answer that is not a WAV is an error, and leaves no file
{
    $REPLY = sub { {code => 200, error => undef, headers => {}, body => '{"error":"busy"}'} };
    my ($res, $err) = ai::execute_tool('generate_audio', 'GENERATE_AUDIO_5e1c', ['hi', 'bad.wav']);
    like($err // '', qr/the audio service sent no WAV/, "an answer that is not a WAV is an error");
    ok(!-e "$ws/bad.wav" && !glob("$ws/.aicli-*"), "and leaves no file or temp file");
    $REPLY = sub { {code => 200, error => undef, headers => {}, body => $WAV} };
}

# the file a call made is offered: the name the result gives (a name taken gets another)
is(tools::offered_file('generate_audio', ['hi', 'waves.wav', '', '', ''], $ws, "wrote waves-2.wav: 44 bytes of WAV (seconds 5, seed 0)\n"),
    'waves-2.wav', "the file the result names is offered");
is(tools::offered_file('generate_audio', ['hi', '', '', '', ''], $ws, "wrote audio_0.wav: 44 bytes of WAV (seconds 5, seed 0)\n"),
    'audio_0.wav', "the default name too");
ok(!defined tools::offered_file('generate_audio', ['hi', 'nothere.wav'], $ws, "wrote nothere.wav: 44 bytes of WAV (seconds 5, seed 0)\n"),
    "a file that is not there is not offered");

done_testing();
