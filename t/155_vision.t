#!/usr/bin/perl
# the tools that need a capability of the server: the image tool (vision), generate_image (image) and generate_audio
# (audio). Each is offered by its flag (AI_VISION, AI_IMAGE, AI_AUDIO: 1 always, 0 never); unset, when the server's
# model list has a model with that capability for the chat's provider. No such model: the tool is not offered.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

# the list is the return value of utils::http (the mock of TestAI streams), one body per request
sub mock_models {
    my @bodies = @_;
    no warnings 'redefine';
    *utils::http = sub {
        my ($m, $url, $data, $key, $cb, $headers) = @_;
        $utils::http_error = undef;
        $utils::http_code  = 200;
        die "no more list pages were expected\n" unless @bodies;
        return shift @bodies;
    };
}

my $full = '{"data":['
    .'{"id":"vis-1","capabilities":["completion","vision","tools"]},'
    .'{"id":"text-1","capabilities":["completion","tools"]},'
    .'{"id":"z-image-turbo","capabilities":["image"]},'
    .'{"id":"audioldm2","capabilities":["audio"]},'
    .'{"id":"nocaps-1"}'
    .']}';
my $text = '{"data":[{"id":"text-1","capabilities":["completion","tools"]}]}';

# a chat setup with the server's list (or none), and the given environment
sub scenario {
    my ($list, %env) = @_;
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native',
        AI_IMAGE_URL => 'http://img.test:8000/rocm/', AI_AUDIO_URL => 'http://audio.test:8000/rocm/', %env);
    %ai::MODEL_CAPS = ();
    mock_models($list) if defined $list;
    ai::fetch_models() if defined $list;
}

# the list: the capabilities of its models are kept, and the tools follow them with the flags unset
{
    scenario($full);
    is_deeply($ai::MODEL_CAPS{"openai/vis-1"}, [qw(completion vision tools)], "the capabilities of a model are kept");
    ok(!exists $ai::MODEL_CAPS{"openai/nocaps-1"}, "a model with no capabilities in the list has none kept");
    ok(tools::available('image'), "a list with a vision model: the image tool is offered (unset)");
    ok(tools::available('generate_image'), "a list with an image model: generate_image is offered (unset)");
    ok(tools::available('generate_audio'), "a list with an audio model: generate_audio is offered (unset)");
}

# the default is per provider's list, not per chat model: the tool is offered whatever model the chat is on
{
    scenario($full);
    $ai::SESSION_MODEL = 'text-1';
    ok(tools::available('image'), "a text model: the image tool is still offered, a vision model is listed");
    $ai::SESSION_MODEL = 'nocaps-1';
    ok(tools::available('image'), "a model the list gives no capabilities: offered too, the list has a vision model");
}

# a list with none of the capabilities: the tools are not offered, unless their flag says 1
{
    scenario($text);
    ok(!tools::available('image'), "no vision model listed: the image tool is not offered");
    ok(!tools::available('generate_image'), "no image model listed: generate_image is not offered");
    ok(!tools::available('generate_audio'), "no audio model listed: generate_audio is not offered");
}
{
    scenario($text, AI_VISION => 1, AI_IMAGE => 1, AI_AUDIO => 1);
    ok(tools::available('image'), "AI_VISION=1 offers the image tool, the list or not");
    ok(tools::available('generate_image'), "AI_IMAGE=1 offers generate_image, the list or not");
    ok(tools::available('generate_audio'), "AI_AUDIO=1 offers generate_audio, the list or not");
}

# 0 never offers the tool, even when the list has its model
{
    scenario($full, AI_VISION => 0, AI_IMAGE => 0, AI_AUDIO => 0);
    ok(!tools::available('image'), "AI_VISION=0: the image tool is never offered");
    ok(!tools::available('generate_image'), "AI_IMAGE=0: generate_image is never offered");
    ok(!tools::available('generate_audio'), "AI_AUDIO=0: generate_audio is never offered");
}

# no list at all (the server did not answer): unset is off; the flag 1 still offers
{
    scenario(undef);
    ok(!tools::available('image'), "no list: the image tool is off");
    scenario(undef, AI_VISION => 1);
    ok(tools::available('image'), "no list: AI_VISION=1 still offers it");
}

# the generators also need their URL: a flag 1 with no URL offers nothing
{
    scenario($full, AI_IMAGE_URL => '', AI_AUDIO_URL => '', AI_IMAGE => 1, AI_AUDIO => 1);
    ok(!tools::available('generate_image'), "no AI_IMAGE_URL: generate_image is not offered, flag or not");
    ok(!tools::available('generate_audio'), "no AI_AUDIO_URL: generate_audio is not offered, flag or not");
}

done_testing();
