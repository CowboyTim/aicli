#!/usr/bin/perl
# whether the chat's model takes pictures: the server's model list gives a model the capability "vision"; AI_VISION
# overrides it (1 always, 0 never). The image tool is offered when the model does.
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

my $list = '{"data":['
    .'{"id":"vis-1","kind":"chat","capabilities":["completion","vision","tools"]},'
    .'{"id":"text-1","kind":"chat","capabilities":["completion","tools"]},'
    .'{"id":"nocaps-1"}'
    .']}';

{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    mock_models($list);
    my $ids = ai::fetch_models();
    is_deeply($ids, [qw(vis-1 text-1 nocaps-1)], "the list has its models");
    is_deeply($ai::MODEL_CAPS{"openai/vis-1"}, [qw(completion vision tools)], "the capabilities of a model are kept");
    is_deeply($ai::MODEL_CAPS{"openai/text-1"}, [qw(completion tools)], "another model's capabilities are its own");
    ok(!exists $ai::MODEL_CAPS{"openai/nocaps-1"}, "a model with no capabilities in the list has none kept");

    # the chat's model decides, unless AI_VISION says otherwise
    $ai::SESSION_MODEL = 'vis-1';
    ok(ai::vision_allowed(), "a model with the capability vision takes pictures");
    ok(tools::available('image'), "the image tool is offered for it");
    $ai::SESSION_MODEL = 'text-1';
    ok(!ai::vision_allowed(), "a model without it does not");
    ok(!tools::available('image'), "and the image tool is not offered for it");
    $ai::SESSION_MODEL = 'nocaps-1';
    ok(!ai::vision_allowed(), "a model the list gives no capabilities does not");

    # AI_VISION overrides the list, both ways
    $ai::SESSION_MODEL = 'text-1';
    local $::ORIG_ENV{AI_VISION} = '1';
    ok(ai::vision_allowed(), "AI_VISION=1 offers the tool for a model without the capability");
    $ai::SESSION_MODEL = 'vis-1';
    local $::ORIG_ENV{AI_VISION} = '0';
    ok(!ai::vision_allowed(), "AI_VISION=0 never offers it, even for a model with the capability");
    ok(!tools::available('image'), "and the image tool is not offered");
}

# a server that lists nothing: the tool stays off unless AI_VISION=1
{
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9', AI_TOOL_CALLS => 'native');
    %ai::MODEL_CAPS = ();
    $ai::SESSION_MODEL = 'anything';
    ok(!ai::vision_allowed(), "no list: no picture model");
    local $::ORIG_ENV{AI_VISION} = '1';
    ok(ai::vision_allowed(), "no list: AI_VISION=1 still offers it");
}

done_testing();
