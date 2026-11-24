#!/usr/bin/perl
# generate_image: the picture of the image service is written to the workspace whole (the old file
# goes to the undo journal first, a failed write leaves nothing behind), its name and seed as the
# tool works them out, the arguments checked, and the file offered to the page after the call
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use MIME::Base64 ();
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $PNG = MIME::Base64::decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==");

sub slurp { my ($f) = @_; open(my $h, '<:raw', $f) or return undef; local $/; my $d = <$h>; close $h; return $d }
sub spew  { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

# the image service: loop::http answers at once with what $REPLY gives for the request; @REQ has them
my (@REQ, $REPLY);
sub reply_with_png {
    my ($png) = @_;
    return {code => 200, error => undef, headers => {},
        body => $J->encode({data => [{b64_json => MIME::Base64::encode_base64($png, '')}]})};
}
{
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        push @REQ, \%r;
        $r{on_done}->($REPLY->(\%r));
        return;
    };
}
$REPLY = sub { reply_with_png($PNG) };

my $tmp = TestAI::setup(AI_TOOL_CALLS => 'native', AI_IMAGE => 1, AI_IMAGE_URL => 'http://img.test:8000/rocm/');

# a session in a new workspace: relative names are from here, as in a session
sub workspace {
    my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    $ai::WORKSPACE = $ws;
    chdir($ws);
    return $ws;
}
my $ws = workspace();

ok(tools::available('generate_image'), "available: the image service is set");
{
    local $::ORIG_ENV{AI_IMAGE_URL} = '';
    ok(!tools::available('generate_image'), "not available without AI_IMAGE_URL");
}

# ---------------------------------------------------------------------------
# a picture: the request, the file, the result

{
    my ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a red cube', 'cube.png', '512x512', '4', '7']);
    ok(!$err, "a picture is made") or diag($err);
    like($res, qr/wrote cube\.png: 512x512, seed 7, \d+ bytes/, "the result names the file, the size and the seed");
    is(slurp("$ws/cube.png"), $PNG, "the file is the PNG the service sent");
    is($REQ[-1]{url}, 'http://img.test:8000/rocm/v1/images/generations', "the URL: the base (its slash taken off) and the images path");
    is($REQ[-1]{method}, 'post', "a POST");
    is_deeply($J->decode($REQ[-1]{data}),
        {model => 'z-image-turbo', prompt => 'a red cube', response_format => 'b64_json', size => '512x512', steps => 4, seed => 7},
        "the request: the prompt, the size, the steps and the seed");
    ok(!glob("$ws/.aicli-*"), "no temp file is left");
}

# the change is in the undo journal: a new file, marked as binary
{
    my $last = $tools::CHANGES[-1];
    is($last->{tool}, 'generate_image', "the change is listed under the tool");
    is($last->{path}, 'cube.png', "and names the file");
    ok($last->{binary}, "as a binary file");
    ok(!defined $last->{old}, "a new file has no old content");
    my $journal = slurp("$ai::AI_SESSION_DIR/undo/journal") // '';
    like($journal, qr/"tool":"generate_image"/, "the journal of the session has the entry");
    @tools::CHANGES = ();
}

# a file of that name already there is kept as it is: the picture goes to the first free name, and
# the result names it (the chat shows each picture as it was made)
{
    spew("$ws/cube.png", "old bytes");
    my ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a red cube', 'cube.png', '512x512', '4', '7']);
    ok(!$err, "a name already taken is made again") or diag($err);
    like($res, qr/\Awrote cube-2\.png: 512x512, seed 7/, "the picture goes to cube-2.png, and the result names it");
    is(slurp("$ws/cube.png"), "old bytes", "the file that was there stays as it was");
    is(slurp("$ws/cube-2.png"), $PNG, "the new picture is the new file");
    is($tools::CHANGES[-1]{path}, 'cube-2.png', "the change is the new file");
    ok(!defined $tools::CHANGES[-1]{old}, "a new file: no old content for undo");
    ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a blue cube', 'cube.png', '512x512', '4', '7']);
    like($res // '', qr/\Awrote cube-3\.png/, "and the next one goes to the next free name, cube-3.png");
    is(slurp("$ws/cube-2.png"), $PNG, "cube-2.png is not touched by it");
    @tools::CHANGES = ();
}

# the default names: image_<seed>.png, and seed 42 when none is given
{
    my ($res) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a dog', '', '', '', '3']);
    like($res, qr/wrote image_3\.png: 1024x1024, seed 3/, "no output name: image_<seed>.png, and 1024 x 1024");
    ok(-f "$ws/image_3.png", "the file is there");
    is($REQ[-1]{data} =~ /"seed":3/ ? 1 : 0, 1, "the seed of the request is the one given");

    ($res) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a cat', '', '', '', '']);
    like($res, qr/wrote image_42\.png: 1024x1024, seed 42/, "no seed: 42");
    @tools::CHANGES = ();
}

# ---------------------------------------------------------------------------
# refusals: nothing is asked of the service, nothing is written

{
    mkdir "$ws/a_dir.png";
    my $asked = scalar @REQ;
    my @refuse = (
        [['', 'x.png'],                    qr/no prompt/,                          "no prompt"],
        [['a', 'x.jpg'],                   qr/the output must be a \.png file/,    "an output that is not a .png"],
        [['a', 'x.png', '', '0'],          qr/steps: a whole number from 1 to 50/, "steps 0"],
        [['a', 'x.png', '', '51'],         qr/steps: a whole number from 1 to 50/, "steps 51"],
        [['a', 'x.png', '', 'many'],       qr/steps: a whole number from 1 to 50/, "steps not a number"],
        [['a', 'x.png', '', '', 'x1'],     qr/seed: a whole number/,              "a seed that is not a number"],
        [['a', '../x.png'],                qr/outside of the workspace/,           "an output outside the workspace"],
    );
    for my $case (@refuse) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', $args);
        ok($err, "refused: $what") or diag($res);
        like($err // '', $re, "  and the reason says so");
    }
    is(scalar(@REQ), $asked, "no request went to the service for any of them");
    ok(!-e "$ws/x.png" && !-e "$ws/x.jpg", "and nothing was written");
}

# a name taken by a folder is taken too: the picture goes to the next free name, the folder stays
{
    my $before = scalar @REQ;
    my ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a', 'a_dir.png']);
    ok(!$err, "a folder of that name: the picture is made") or diag($err);
    like($res // '', qr/\Awrote a_dir-2\.png/, "it goes to a_dir-2.png");
    ok(-d "$ws/a_dir.png", "and the folder stays");
    is(scalar(@REQ), $before + 1, "one request for it");
}

# no service set up: the sub itself refuses (the tool is not offered then, see available)
{
    local $::ORIG_ENV{AI_IMAGE_URL} = '';
    my $ok = eval {tools::generate_image_3a7c(['a', 'x.png']); 1};
    ok(!$ok, "without AI_IMAGE_URL the tool refuses");
    like($@, qr/no image service is set up/, "and says which setting is missing");
}

# the service's failures: its error, or an answer with no picture, is an error and leaves no file
{
    $REPLY = sub { {code => 500, error => "HTTP status 500", headers => {}, body => "out of memory"} };
    my ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a', 'fail.png']);
    like($err // '', qr/HTTP status 500/, "a failed request is an error");
    ok(!-e "$ws/fail.png", "and leaves no file");

    $REPLY = sub { {code => 200, error => undef, headers => {}, body => '{"data":[]}'} };
    ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a', 'empty.png']);
    like($err // '', qr/the image service sent no image/, "an answer with no picture is an error");
    ok(!-e "$ws/empty.png", "and leaves no file");

    $REPLY = sub { reply_with_png("GIF89a" . ("\0" x 20)) };
    ($res, $err) = ai::execute_tool('generate_image', 'GENERATE_IMAGE_3a7c', ['a', 'wrong.png']);
    like($err // '', qr/the image service sent no PNG/, "a picture that is not a PNG is refused");
    ok(!-e "$ws/wrong.png" && !glob("$ws/.aicli-*"), "and leaves no file or temp file");
    $REPLY = sub { reply_with_png($PNG) };
}

# ---------------------------------------------------------------------------
# the file a call made is offered to the page: its name with the defaults, when it is there

# (the name is the one the result gives: a name that was taken gets another)
is(tools::offered_file('generate_image', ['a', 'cube.png', '', '', ''], $ws, "wrote cube-2.png: 1024x1024, seed 42, 9 bytes\n"),
    'cube-2.png', "the file the result names is offered");
is(tools::offered_file('generate_image', ['a', '', '', '', '3'], $ws, "wrote image_3.png: 1024x1024, seed 3, 9 bytes\n"),
    'image_3.png', "the default name too");
ok(!defined tools::offered_file('generate_image', ['a', 'missing.png'], $ws, "wrote missing.png: 1024x1024, seed 42, 9 bytes\n"),
    "a file that is not there is not offered");
ok(!defined tools::offered_file('generate_image', ['a', '../outside.png'], $ws, "wrote ../outside.png: 1024x1024, seed 42, 9 bytes\n"),
    "a file outside the workspace is not offered");
ok(!defined tools::offered_file('generate_image', ['a', 'cube.png'], $ws, "[ERROR] problem running tool 'generate_image': HTTP status 500\n"),
    "a failed call offers no file");
ok(!defined tools::offered_file('bash', ['ls'], $ws), "a tool that writes no file offers nothing");

# ---------------------------------------------------------------------------
# a turn of the chat: the picture is made, and the page gets the file as an event

{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_IMAGE => 1, AI_IMAGE_URL => 'http://img.test:8000/rocm', AI_TOOL_DISPLAY => 'brief');
    my $ws2 = workspace();
    my @EV;
    local $ai::EVENT_SINK = sub { push @EV, [@_] };
    TestAI::mock_http(
        calls_reply(['generate_image', 'call_img', $J->encode({prompt => 'a blue cube', output => 'chat.png'})]),
        text_reply("here it is"),
    );
    TestAI::capture {ai::chat_completion("draw a blue cube")};
    my ($file) = grep {$_->[0] eq 'file'} @EV;
    ok($file, "a turn: the call's file is sent to the page as a file event");
    is($file ? $file->[1]{path} : undef, 'chat.png', "with its name in the workspace");
    ok(-f "$ws2/chat.png", "and the file is there");
    like($TestAI::REQUESTS[1]{data} // '', qr/wrote chat\.png/, "the model gets the result as before");
    # the page's tool line: the summary, and the whole call for when it is opened
    my ($tool_ev) = grep {$_->[0] eq 'tool'} @EV;
    ok($tool_ev, "a turn in brief display: the tool line is sent to the page");
    like($tool_ev ? ($tool_ev->[1]{full} // '') : '',
        qr/\AGENERATE_IMAGE\n  prompt: a blue cube\n  output: chat\.png\n  size: \(empty\)/,
        "with the whole call: the name, then each argument in full");
}

# a call that failed offers no file
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_IMAGE => 1, AI_IMAGE_URL => 'http://img.test:8000/rocm');
    my $ws3 = workspace();
    my @EV;
    local $ai::EVENT_SINK = sub { push @EV, [@_] };
    $REPLY = sub { {code => 500, error => "HTTP status 500", headers => {}, body => "busy"} };
    TestAI::mock_http(
        calls_reply(['generate_image', 'call_bad', $J->encode({prompt => 'a cube', output => 'bad.png'})]),
        text_reply("it failed"),
    );
    TestAI::capture {ai::chat_completion("draw again")};
    ok(!grep({$_->[0] eq 'file'} @EV), "a failed call sends no file event");
    $REPLY = sub { reply_with_png($PNG) };
}

# ---------------------------------------------------------------------------
# the same helpers as t/86 use, for the scripted turns

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

done_testing();
