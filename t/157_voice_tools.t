#!/usr/bin/perl
# the sound tools of the services: transcribe (a sound file of the workspace to its text, through the speech recognizer
# of AI_ASR_URL: the file, the language and the task in a multipart request), voices (the speech service's voices, with
# a filter) and create_voice (a voice from a recording of the workspace and its words); each offered only with its
# service set, the arguments checked before anything is asked, the services' refusals said
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

sub spew { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

# the services: loop::http answers at once with what $REPLY gives for the request
my (@REQ, $REPLY);
{
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        push @REQ, \%r;
        $r{on_done}->({headers => {}, %{$REPLY->(\%r)}});
        return;
    };
}
sub reply_json { my ($d, $code) = @_; $code //= 200; return sub { {code => $code, error => $code == 200 ? undef : "HTTP status $code", body => $J->encode($d)} } }

TestAI::setup(AI_TOOL_CALLS => 'native', AI_ASR_URL => 'http://asr.test:8000/rocm/v1/audio/transcriptions',
    AI_SPEECH_URL => 'http://speech.test:8000/rocm/');
my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
$ai::WORKSPACE = $ws;
chdir($ws);
spew("$ws/talk.wav", $WAV);
spew("$ws/notes.txt", "words");

# what is offered: each tool with its service
ok(tools::available($_), "available: $_") for qw(transcribe voices create_voice);
{
    local $::ORIG_ENV{AI_ASR_URL} = '';
    ok(!tools::available('transcribe'), "transcribe is not offered without AI_ASR_URL");
}
{
    local $::ORIG_ENV{AI_SPEECH_URL} = '';
    ok(!tools::available($_), "$_ is not offered without AI_SPEECH_URL") for qw(voices create_voice);
}

# transcribe: the file and the fields go to the recognizer, the text comes back
{
    $REPLY = reply_json({text => "  Hello there, world.  "});
    @REQ = ();
    my ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav', 'NL', '']);
    ok(!$err, "a sound is written down") or diag($err);
    is($res, "Hello there, world.\n", "the result is the text, trimmed");
    is($REQ[0]{url}, 'http://asr.test:8000/rocm/v1/audio/transcriptions', "the request goes to AI_ASR_URL as it is");
    is($REQ[0]{method}, 'post', "a POST");
    my ($ct) = grep {/^Content-Type:/} @{$REQ[0]{headers}};
    my ($b) = ($ct // '') =~ m/boundary=(\S+)/;
    ok($b, "a multipart body with its boundary");
    like($REQ[0]{data}, qr/name="language"\r\n\r\nnl\r\n/, "the language, in lower case");
    like($REQ[0]{data}, qr/name="response_format"\r\n\r\njson\r\n/, "the answer asked as JSON");
    like($REQ[0]{data}, qr/name="file"; filename="talk\.wav"\r\nContent-Type: audio\/wav\r\n\r\n\Q$WAV\E\r\n/, "the file, its name and type");
    unlike($REQ[0]{data}, qr/name="task"/, "no task field for a transcription");
    ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav', '', 'translate']);
    like($REQ[-1]{data}, qr/name="task"\r\n\r\ntranslate\r\n/, "translate is sent as the task");
    like($REQ[-1]{data}, qr/name="language"\r\n\r\nen\r\n/, "the language's default is en");
    $REPLY = reply_json({text => ''});
    ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav']);
    like($res, qr/no speech was heard in talk\.wav/, "no text: said so");
    $REPLY = sub { {code => 200, error => undef, body => 'not json'} };
    ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav']);
    like($err // '', qr/the speech recognizer sent no text/, "an answer that is not JSON is an error");
    $REPLY = reply_json({error => {message => 'bad audio'}}, 400);
    ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav']);
    like($err // '', qr/HTTP status 400.*bad audio/, "the recognizer's refusal, with its reason");
    # a body over the web server's limit: nginx answers 413 with a page of its own (loop::http's request keeps the data sent)
    $REPLY = sub { {code => 413, error => 'HTTP status 413', data => $_[0]{data},
                    body => "<html>\n<head><title>413 Request Entity Too Large</title></head>\n</html>"} };
    ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', ['talk.wav']);
    like($err // '', qr/: the service refused the request as too large \(HTTP 413\): 0\.0 MB were sent, more than the service or the web server in front of it takes \(nginx: client_max_body_size\)/,
        "too large (413): the size sent and the likely limit");
    unlike($err // '', qr/<html>|Entity/, "  not nginx's page");
}

# transcribe's refusals: nothing is asked
{
    my $asked = scalar @REQ;
    for my $case ([[''], qr/no input/, "no file"], [['gone.wav'], qr/no such file/, "a file that is not there"],
                  [['../x.wav'], qr/outside of the workspace/, "a file outside the workspace"],
                  [['talk.wav', 'english'], qr/language: a code/, "a language that is not a code"],
                  [['talk.wav', '', 'summarize'], qr/task: transcribe or translate/, "a task that is not one of the two"]) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('transcribe', 'TRANSCRIBE_6b2d', $args);
        like($err // '', $re, "transcribe refuses $what");
    }
    is(scalar(@REQ), $asked, "no request for any of them");
}

# voices: the names and their words, a filter, an empty list
{
    $REPLY = reply_json({data => [{name => 'alice', frames => 120, ref_text => "Hello, I am\nAlice."},
                                  {name => 'bob', frames => 80, ref_text => ''}, {frames => 3}]});
    @REQ = ();
    my ($res, $err) = ai::execute_tool('voices', 'VOICES_2f8e', ['']);
    ok(!$err, "the voices are listed") or diag($err);
    is($res, "alice: Hello, I am Alice.\nbob\n", "a line each: the name and the words of its recording (no name: left out)");
    is($REQ[0]{url}, 'http://speech.test:8000/rocm/v1/audio/voices', "from the speech service's voices");
    is($REQ[0]{method}, 'get', "a GET");
    ($res, $err) = ai::execute_tool('voices', 'VOICES_2f8e', ['^AL']);
    is($res, "alice: Hello, I am Alice.\n", "a filter narrows it (any case)");
    ($res, $err) = ai::execute_tool('voices', 'VOICES_2f8e', ['zed']);
    like($res, qr/no voice matches zed/, "a filter that matches none: said so");
    ($res, $err) = ai::execute_tool('voices', 'VOICES_2f8e', ['(']);
    like($err // '', qr/filter: not a regular expression/, "a filter that is not a regular expression is refused");
    $REPLY = reply_json({data => []});
    ($res, $err) = ai::execute_tool('voices', 'VOICES_2f8e', []);
    like($res, qr/no voices: make one with create_voice/, "no voices: the tool to make one is named");
}

# create_voice: the recording, its words and the name go to the service; the voice is made
{
    $REPLY = reply_json({name => 'carol', frames => 75, seconds => 6.04});
    @REQ = ();
    my ($res, $err) = ai::execute_tool('create_voice', 'CREATE_VOICE_8a1c', ['talk.wav', 'carol', 'The quick brown fox.']);
    ok(!$err, "a voice is made") or diag($err);
    like($res, qr/made the voice carol from 6\.0 seconds of speech: the speech tool can use it now/, "the result names the voice");
    is($REQ[0]{url}, 'http://speech.test:8000/rocm/v1/audio/voices', "the request goes to the speech service's voices");
    is($REQ[0]{method}, 'post', "a POST");
    like($REQ[0]{data}, qr/name="name"\r\n\r\ncarol\r\n/, "the name");
    like($REQ[0]{data}, qr/name="ref_text"\r\n\r\nThe quick brown fox\.\r\n/, "the words of the recording");
    like($REQ[0]{data}, qr/name="file"; filename="clip\.wav"\r\nContent-Type: audio\/wav\r\n\r\n\Q$WAV\E\r\n/, "the recording");
    $REPLY = reply_json({error => {message => "voice 'carol' exists"}}, 409);
    ($res, $err) = ai::execute_tool('create_voice', 'CREATE_VOICE_8a1c', ['talk.wav', 'carol', 'Hi.']);
    like($err // '', qr/there is a voice carol already: choose another name/, "a name the service has: 409, said so");
    $REPLY = reply_json({error => {message => 'the clip: 0.5 to 60 seconds of speech'}}, 400);
    ($res, $err) = ai::execute_tool('create_voice', 'CREATE_VOICE_8a1c', ['talk.wav', 'dave', 'Hi.']);
    like($err // '', qr/the speech service refused the voice: the clip: 0\.5 to 60 seconds/, "the service's refusal, with its reason");
}

# create_voice's refusals: nothing is asked
{
    my $asked = scalar @REQ;
    for my $case ([['', 'x', 'hi'], qr/no input/, "no recording"],
                  [['talk.wav', '-x', 'hi'], qr/the voice name has letters/, "a name starting with -"],
                  [['talk.wav', 'a/b', 'hi'], qr/the voice name has letters/, "a name with a slash"],
                  [['talk.wav', 'a..b', 'hi'], qr/the voice name has letters/, "a name with .."],
                  [['talk.wav', 'x', ''], qr/no text/, "no words"],
                  [['talk.wav', 'x', 'w' x 1001], qr/longer than 1000 characters/, "too many words"],
                  [['notes.txt', 'x', 'hi'], qr/not a WAV file/, "a file that is not a WAV"],
                  [['gone.wav', 'x', 'hi'], qr/no such file/, "a file that is not there"]) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('create_voice', 'CREATE_VOICE_8a1c', $args);
        like($err // '', $re, "create_voice refuses $what");
    }
    is(scalar(@REQ), $asked, "no request for any of them");
}

done_testing();
