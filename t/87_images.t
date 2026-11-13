#!/usr/bin/perl
# pictures: the image tool reads a picture in the workspace, the next message
# carries it to the model (a data URL, or an image block for Anthropic)
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;
use File::Temp ();
use MIME::Base64 ();

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

# the first bytes of each format, enough for the check
my $PNG  = "\x89PNG\r\n\x1a\n".("\0" x 20);
my $JPEG = "\xFF\xD8\xFF\xE0".("\x11" x 20);
my $GIF  = "GIF89a".("\x01" x 20);
my $WEBP = "RIFF\x18\0\0\0WEBPVP8 ".("\x02" x 20);
my $TEXT = "just some text, not a picture\n";

sub write_file {
    my ($path, $bytes) = @_;
    open(my $fh, '>:raw', $path) or die "$path: $!";
    print {$fh} $bytes;
    close($fh);
    return $path;
}

# the picture format by its first bytes
{
    is(tools::_image_type($PNG), 'image/png', "types: PNG");
    is(tools::_image_type($JPEG), 'image/jpeg', "types: JPEG");
    is(tools::_image_type($GIF), 'image/gif', "types: GIF");
    is(tools::_image_type($WEBP), 'image/webp', "types: WebP");
    is(tools::_image_type($TEXT), undef, "types: text is no picture");
    is(tools::_image_type("RIFF....WAVE"), undef, "types: a WAV file is no WebP");
}

# the tool is only there for a model that takes pictures
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    ok(!tools::available('image'), "off: no image tool without AI_VISION");
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1);
    ok(tools::available('image'), "vision: the image tool with AI_VISION=1");
    TestAI::mock_http(text_reply("hi"));
    TestAI::capture {ai::chat_completion("hello")};
    my @names = map {$_->{function}{name}} @{$::JSON->decode($TestAI::REQUESTS[0]{data})->{tools}};
    ok((grep {$_ eq 'image'} @names), "vision: the request offers the image tool");
    {
        local $ai::IN_AGENT = 1;
        my @agent = map {$_->{function}{name}} @{$::JSON->decode(ai::build_request([{role => 'user', content => 'x'}]))->{tools}};
        ok(!(grep {$_ eq 'image'} @agent), "vision: a sub-agent is not offered the image tool");
    }
}

# the tool reads a picture in the workspace and queues it
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1);
    my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    local $ai::WORKSPACE = $ws;
    chdir($ws); # relative paths are from here, as in a session
    write_file("$ws/shot.png", $PNG);
    my ($res, $err) = ai::execute_tool('image', 'IMAGE_4e0b', ['shot.png']);
    ok(!$err, "tool: a picture in the workspace is read");
    like($res, qr/image attached: shot\.png \(image\/png, \d+ bytes\)/, "tool: the result says what came in");
    is(scalar(@tools::IMAGES), 1, "tool: one picture is queued");
    is($tools::IMAGES[0]{mime}, 'image/png', "tool: with its format");
    is(MIME::Base64::decode_base64($tools::IMAGES[0]{data}), $PNG, "tool: the bytes come through base64");
    @tools::IMAGES = ();

    # refused: not a picture, a directory, outside the workspace, too big, a sub-agent
    write_file("$ws/notes.txt", $TEXT);
    mkdir("$ws/sub");
    my $far = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    write_file("$far/far.png", $PNG);
    my %refused = (
        'notes.txt' => qr/not a PNG, JPEG, GIF or WebP image/,
        'sub'       => qr/not a file/,
        "$far/far.png" => qr/outside of the workspace/,
    );
    for my $p (sort keys %refused){
        my (undef, $e) = ai::execute_tool('image', 'IMAGE_4e0b', [$p]);
        like($e // '', $refused{$p}, "refused: $p");
    }
    {
        local $::ORIG_ENV{AI_IMAGE_MAX} = 10;
        my (undef, $e) = ai::execute_tool('image', 'IMAGE_4e0b', ['shot.png']);
        like($e // '', qr/more than AI_IMAGE_MAX \(10\)/, "refused: bigger than AI_IMAGE_MAX");
    }
    {
        local $tools::ASYNC = 1;
        my (undef, $e) = ai::execute_tool('image', 'IMAGE_4e0b', ['shot.png']);
        like($e // '', qr/a sub-agent cannot look at pictures/, "refused: not for a sub-agent");
    }
    is(scalar(@tools::IMAGES), 0, "refused: nothing is queued");
}

# a turn: the picture comes in a user message after the result, and goes to
# the API as a data URL; the messages before it stay as they were
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_VISION => 1);
    my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    local $ai::WORKSPACE = $ws;
    chdir($ws); # relative paths are from here, as in a session
    write_file("$ws/shot.png", $PNG);
    TestAI::mock_http(
        calls_reply(['image', 'call_img', '{"path":"shot.png"}']),
        text_reply("a tiny picture"),
    );
    TestAI::capture {ai::chat_completion("what is in shot.png")};

    my @msgs = ai::load_messages();
    is(join(',', map {$_->{role}} @msgs), "system,user,assistant,tool,user,assistant", "turn: the picture comes after the result");
    is($msgs[3]{tool_call_id}, 'call_img', "turn: the result of the call");
    is($msgs[4]{content}, "Image: shot.png", "turn: the message names the file");
    is($msgs[4]{images}[0]{mime}, 'image/png', "turn: the chat file keeps the picture");
    is(MIME::Base64::decode_base64($msgs[4]{images}[0]{data}), $PNG, "turn: the same bytes in the chat file");

    my $first  = $::JSON->decode($TestAI::REQUESTS[0]{data})->{messages};
    my $second = $::JSON->decode($TestAI::REQUESTS[1]{data})->{messages};
    my $sent = $second->[-1];
    is($sent->{role}, 'user', "turn: the request ends with the user message");
    is($sent->{content}[0]{type}, 'text', "turn: its text part first");
    is($sent->{content}[0]{text}, "Image: shot.png", "turn: and its text");
    is($sent->{content}[1]{type}, 'image_url', "turn: then the picture");
    is($sent->{content}[1]{image_url}{url}, "data:image/png;base64,".MIME::Base64::encode_base64($PNG, ''), "turn: as a data URL");
    ok(!exists $sent->{images}, "turn: no images field of ours in the request");
    is_deeply([@$second[0 .. $#$first]], $first, "turn: the messages before are unchanged");
}

# a message without pictures is sent as it is; with pictures the text and the
# picture parts; the chars of a picture count for the context estimate
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    my $plain = {role => 'user', content => 'hi'};
    is_deeply(ai::wire_message($plain), $plain, "wire: a message without pictures is unchanged");
    is(ai::chars_of({role => 'user', content => 'abc', images => [{}]}), 3 + 6000, "estimate: a picture counts as 6000 characters");
    is(ai::chars_of($plain), 2, "estimate: a message without pictures counts its text only");
}

# Anthropic: the text and the picture as content blocks; consecutive user
# messages are joined, the picture block keeps its place
{
    # the key picks the provider: AI_LOCAL_SERVER (set by TestAI) would skip that
    TestAI::setup(AI_API_KEY => 'sk-ant-api03-xyz', AI_LOCAL_SERVER => undef, AI_MODEL => 'claude-test', AI_TOOL_CALLS => 'text');
    is($ai::AI_PROVIDER, 'anthropic', "anthropic: the key picks the provider");
    my $req = $::JSON->decode(ai::build_request([
        {role => 'system', content => 'be brief'},
        {role => 'user', content => 'look'},
        {role => 'user', content => 'Image: a.png', images => [{mime => 'image/png', data => 'QUJD'}]},
        {role => 'assistant', content => 'ok'},
    ]));
    is(scalar(@{$req->{messages}}), 2, "anthropic: the user messages are joined into one");
    is_deeply($req->{messages}[0]{content}, [
        {type => 'text', text => 'look'},
        {type => 'text', text => 'Image: a.png'},
        {type => 'image', source => {type => 'base64', media_type => 'image/png', data => 'QUJD'}},
    ], "anthropic: text blocks, then the picture block");
    is($req->{messages}[1]{content}, 'ok', "anthropic: the answer is still text");
}

# the text protocol: the tool is in the prompt when it is on, and not for a sub-agent
{
    TestAI::setup(AI_TOOL_CALLS => 'text', AI_VISION => 1);
    like(prompt::coder::prompt(), qr/look at an image file/, "prompt: the image tool is listed with AI_VISION");
    unlike(prompt::coder::prompt(exclude => ['agent', 'image']), qr/look at an image file/, "prompt: a sub-agent's list leaves it out");
    TestAI::setup(AI_TOOL_CALLS => 'text');
    unlike(prompt::coder::prompt(), qr/look at an image file/, "prompt: not listed without AI_VISION");
}

done_testing();
