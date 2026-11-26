#!/usr/bin/perl
# the models of the provider: every page of the list (Anthropic pages it), the
# models and model tools for the model itself, and the sub-agents without them
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

use ai;
use TestAI;

# the list is the return value of utils::http (the mock of TestAI streams): one
# body per request, in order, and what was asked for in @REQ
our @REQ;
sub mock_models {
    my @bodies = @_;
    @REQ = ();
    no warnings 'redefine';
    *utils::http = sub {
        my ($m, $url, $data, $key, $cb, $headers) = @_;
        push @REQ, {method => $m, url => $url, key => $key};
        $utils::http_error = undef;
        $utils::http_code  = 200;
        die "no more list pages were expected (request ".scalar(@REQ).")\n" unless @bodies;
        return shift @bodies;
    };
}

# Anthropic: the list comes in pages, every page is read
{
    TestAI::setup(AI_API_KEY => 'sk-ant-test', AI_PROVIDER => 'anthropic', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    mock_models(
        '{"data":[{"id":"claude-a"},{"id":"claude-b"}],"has_more":true,"last_id":"claude-b"}',
        '{"data":[{"id":"claude-c"}],"has_more":false,"last_id":"claude-c"}',
    );
    my $ids = ai::fetch_models();
    is_deeply($ids, [qw(claude-a claude-b claude-c)], "anthropic: all pages of the list");
    like($REQ[0]{url}, qr{/v1/models\?limit=1000$}, "anthropic: the first page asks for 1000");
    like($REQ[1]{url}, qr{/v1/models\?limit=1000&after_id=claude-b$}, "anthropic: the next page starts after the last id");
    is(scalar(@REQ), 2, "anthropic: two requests for two pages");
}

# the others: one list, no paging parameters
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    mock_models('{"data":[{"id":"gpt-a","context_length":8000},{"id":"llama-b"}]}');
    my $ids = ai::fetch_models();
    is_deeply($ids, [qw(gpt-a llama-b)], "openai: the list");
    is($REQ[0]{url}, 'https://api.openai.com/v1/models', "openai: one request, no paging");
    is($ai::MODEL_CONTEXT{'openai/gpt-a'}, 8000, "the context size is kept, by provider and id");
}

# the models tool: the list, a filter, the current model
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    local $ai::SESSION_MODEL = 'llama-b';
    mock_models('{"data":[{"id":"gpt-a","context_length":8000},{"id":"llama-b"}]}');
    my $out = tools::models_3c9a(['']);
    like($out, qr/^models: 2\n/, "models: the count");
    like($out, qr{openai/gpt-a  \(context 8000\)}, "models: the context when known");
    like($out, qr{openai/llama-b  current}, "models: the current one is marked");
    mock_models('{"data":[{"id":"gpt-a"},{"id":"llama-b"}]}');
    like(tools::models_3c9a(['^gpt']), qr{^models: 1 matching '\^gpt'\n.*openai/gpt-a}s, "models: a filter on the ids narrows it");
    mock_models('{"data":[{"id":"gpt-a"},{"id":"llama-b"}]}');
    unlike(tools::models_3c9a(['^gpt']), qr/llama/, "models: and leaves the others out");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    like(tools::models_3c9a(['^zzz']), qr/^models: 0 matching '\^zzz'/, "models: no match says so");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    my $err = eval {tools::models_3c9a(['(']); 1} ? '' : $@;
    like($err, qr/not a regular expression/, "models: a broken filter is an error");
}

# what each model is, as the server's list says it (rocm-inference: kind and capabilities): the models tool and the /models
# command name it, the generators' models with the tool that uses them; a model that is not a chat model is not switched to
# (the model tool, set_model) and is not one of the page's choices
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    local $ai::SESSION_MODEL = 'qwen-4b';
    %ai::MODEL_CAPS = ();
    %ai::MODEL_KIND = ();
    my $list = '{"data":['
        .'{"id":"qwen-4b","kind":"chat","capabilities":["completion","tools","vision"],"context_length":219136},'
        .'{"id":"trellis-2","kind":"3d","capabilities":["3d"]},'
        .'{"id":"z-image-turbo","kind":"image","capabilities":["image"]},'
        .'{"id":"whisper-tiny","kind":"transcription","capabilities":["transcription"],"context_length":2048},'
        .'{"id":"embeddinggemma","kind":"embedding","capabilities":["embedding"]},'
        .'{"id":"caps-only","capabilities":["completion"]},'
        .'{"id":"plain","context_length":8000}'
        .']}';
    mock_models($list);
    my $out = tools::models_3c9a(['']);
    like($out, qr{openai/qwen-4b  \(chat, tools, vision; context 219136\)  current}, "models: a chat model, what it can do, its context");
    like($out, qr{openai/trellis-2  \(image to 3D model, the generate_3d tool\)}, "models: the 3D model and the tool that uses it");
    like($out, qr{openai/z-image-turbo  \(image generation, the generate_image tool\)}, "models: the image model and its tool");
    like($out, qr{openai/whisper-tiny  \(speech to text, the transcribe tool; context 2048\)}, "models: the recognizer and its tool");
    like($out, qr{openai/embeddinggemma  \(embeddings\)}, "models: an embedding model (no tool)");
    like($out, qr{openai/caps-only  \(chat\)}, "models: no kind, but the capability completion: a chat model");
    like($out, qr{openai/plain  \(context 8000\)\n}, "models: a model the list says nothing about: its context alone");

    mock_models($list);
    my $err = eval {tools::model_7e21(['trellis-2']); 1} ? '' : $@;
    like($err, qr{openai/trellis-2 is not a chat model \(image to 3D model\): the generate_3d tool uses it},
        "model: the 3D model is refused, and the tool to use named");
    is($ai::PENDING_MODEL, undef, "model: nothing pending");
    like(ai::set_model('openai', 'z-image-turbo') // '', qr/is not a chat model \(image generation\)/, "set_model: refused too (the page, /model)");
    is($ai::SESSION_MODEL, 'qwen-4b', "set_model: the chat keeps its model");
    is(ai::set_model('openai', 'plain'), undef, "set_model: a model the list says nothing about is taken");
    $ai::SESSION_MODEL = 'qwen-4b';

    require ui;
    local @ai::ALL_MODELS = map {['openai', $_]} qw(qwen-4b trellis-2 z-image-turbo whisper-tiny embeddinggemma caps-only plain);
    is_deeply(ui::_models_data()->{list}, ['openai/qwen-4b', 'openai/caps-only', 'openai/plain'],
        "the page's choices: the chat models (and those the list says nothing about), not the others");
    %ai::MODEL_CAPS = ();
    %ai::MODEL_KIND = ();
}

# the model tool: the switch is for the next turn, an id no list has is refused
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    $ai::SESSION_MODEL = 'llama-b';
    mock_models('{"data":[{"id":"gpt-a"},{"id":"llama-b"}]}');
    my $out = tools::model_7e21(['gpt-a']);
    like($out, qr{the model changes to openai/gpt-a when the next message comes}, "model: asked for, for the next message");
    is($ai::SESSION_MODEL, 'llama-b', "model: this turn finishes with the current model");
    ai::apply_pending_model();
    is($ai::SESSION_MODEL, 'gpt-a', "model: the next turn uses the new one");
    is(ai::read_session_model(), 'gpt-a', "model: and it is kept in the session");
    is(ai::read_session_provider(), 'openai', "model: the provider is kept in the session too");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    my $err = eval {tools::model_7e21(['not-there']); 1} ? '' : $@;
    like($err, qr/no model 'not-there' at any provider/, "model: an id no provider lists is refused");
    is($ai::PENDING_MODEL, undef, "model: nothing pending after a refusal");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    $err = eval {tools::model_7e21(['']); 1} ? '' : $@;
    like($err, qr/no model given/, "model: an empty id is refused");
}

# a part of the id finds the model: qwen3.6 finds Qwen3.6-35B-A3B-ROCMFP4
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef);
    my $pairs = [['openai', 'Qwen3.5-4B-ROCMFP4'], ['openai', 'Qwen3.6-35B-A3B-ROCMFP4'], ['openai', 'gpt-a']];
    is_deeply(ai::resolve_model('qwen3.6', $pairs), ['openai', 'Qwen3.6-35B-A3B-ROCMFP4'], "part: qwen3.6 is the 3.6 model");
    is_deeply(ai::resolve_model('QWEN3.6-35b', $pairs), ['openai', 'Qwen3.6-35B-A3B-ROCMFP4'], "part: any case");
    is_deeply(ai::resolve_model('qwen3.6 35b a3b', $pairs), ['openai', 'Qwen3.6-35B-A3B-ROCMFP4'], "part: spaces count as nothing");
    my $err = eval {ai::resolve_model('qwen', $pairs); 1} ? '' : $@;
    like($err, qr/part of more than one model, give the whole label: openai\/Qwen3\.5-4B-ROCMFP4, openai\/Qwen3\.6-35B/, "part: ambiguous lists the candidates");
    ok(!defined ai::resolve_model('nothing-like-it', $pairs), "part: no part, no model");
}

# sub-agents cannot wait for the list, nor switch the model
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    my %names = map {($_->{function}{name} => 1)} @{tools::native_list()};
    ok($names{models} && $names{model}, "the model tools are in the chat");
    {
        local $ai::IN_AGENT = 1;
        my %sub = map {($_->{function}{name} => 1)} @{tools::native_list(exclude => ['agent', 'image'])};
        ok(!$sub{models} && !$sub{model}, "a sub-agent has neither model tool");
    }
}

# several providers at once: one list, "provider/id", the choices by label
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef,
        AI_API_KEY_OPENROUTER => 'sk-or-test', AI_TOOL_CALLS => 'native');
    is_deeply(ai::provider_names(), ['openai', 'openrouter'], "providers: the main one, then the others with a key");
    mock_models('{"data":[{"id":"gpt-a"}]}', '{"data":[{"id":"openai/gpt-a"},{"id":"llama-b"}]}');
    my ($pairs, $errors) = ai::all_models();
    is_deeply([map {ai::model_label($_)} @$pairs], ['openai/gpt-a', 'openrouter/openai/gpt-a', 'openrouter/llama-b'],
        "all_models: one list of every provider");
    is_deeply($errors, [], "all_models: no errors");
    is($REQ[1]{key}, 'sk-or-test', "all_models: each provider with its own key");
    is($REQ[1]{url}, 'https://openrouter.ai/api/v1/models', "all_models: each provider with its own endpoint");
    is($ai::AI_PROVIDER, 'openai', "all_models: the chat's provider is back afterwards");
    is_deeply(ai::resolve_model('openrouter/llama-b', $pairs), ['openrouter', 'llama-b'], "resolve: a label of the list");
    is_deeply(ai::resolve_model('gpt-a', $pairs), ['openai', 'gpt-a'], "resolve: a bare id is the chat's provider first");
    is_deeply(ai::resolve_model('llama-b', $pairs), ['openrouter', 'llama-b'], "resolve: a bare id at one provider");
    ok(!defined ai::resolve_model('nope', $pairs), "resolve: no such model is undef");
    my $pairs2 = [['openrouter', 'x'], ['nvidia', 'x']];
    my $err = eval {ai::resolve_model('x', $pairs2); 1} ? '' : $@;
    like($err, qr{more than one provider: name one of openrouter/x, nvidia/x}, "resolve: a bare id at two providers asks for the label");

    # the choice moves the chat to that provider, and the session keeps it
    is(ai::set_model('openrouter', 'llama-b'), undef, "set_model: worked");
    is($ai::AI_PROVIDER, 'openrouter', "set_model: the chat's provider is the choice");
    is($ai::api_key, 'sk-or-test', "set_model: its key");
    is($ai::AI_URL, 'https://openrouter.ai/api/v1/chat/completions', "set_model: its URL");
    is($ai::SESSION_MODEL, 'llama-b', "set_model: its model");
    is(ai::read_session_provider(), 'openrouter', "set_model: the provider is kept in the session");
    is(ai::current_label(), 'openrouter/llama-b', "the current label");
    ai::use_provider('openai');
    is(ai::read_session_provider(), 'openrouter', "use_provider does not write the session");
}

# the context of a model is kept with its provider
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_API_KEY_NVIDIA => 'nvapi-test');
    mock_models('{"data":[{"id":"same","context_length":1000}]}', '{"data":[{"id":"same","context_length":2000}]}');
    ai::all_models();
    is($ai::MODEL_CONTEXT{'openai/same'}, 1000, "context: openai's");
    is($ai::MODEL_CONTEXT{'nvidia/same'}, 2000, "context: nvidia's, the same id is another model");
}

# no model set at startup: the first model of the provider's list
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_MODEL => undef);
    $ai::SESSION_MODEL = undef;
    @ai::MODELS = ();
    mock_models('{"data":[{"id":"gpt-first"},{"id":"gpt-second"}]}');
    ai::setup_commands();
    is($ai::SESSION_MODEL, 'gpt-first', "startup: no model set, the first of the provider's list");
    is($ai::AI_PROVIDER, 'openai', "startup: of the main provider");
}
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_MODEL => 'chosen');
    $ai::SESSION_MODEL = 'chosen';
    @ai::MODELS = ();
    mock_models('{"data":[{"id":"gpt-first"}]}');
    ai::setup_commands();
    is($ai::SESSION_MODEL, 'chosen', "startup: a model that is set is kept");
}

# the theme tool: a name of the list, only in the web interface, never for a sub-agent
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    my %names = map {($_->{function}{name} => 1)} @{tools::native_list()};
    ok(!$names{theme}, "theme: not offered in the terminal");
    my @got;
    local $ai::EVENT_SINK = sub { push @got, [@_] };
    %names = map {($_->{function}{name} => 1)} @{tools::native_list()};
    ok($names{theme}, "theme: offered in the web interface");
    is(tools::theme_5c2e(['Matrix']), "the web interface is now matrix\n", "theme: a name of the list, in any case");
    is_deeply($got[0], ['theme', {text => 'matrix'}], "theme: the page gets the name, as an event");
    my $err = eval {tools::theme_5c2e(['<style>body{}</style>']); 1} ? '' : $@;
    like($err, qr/no theme/, "theme: anything else is refused, no code goes to the page");
    is(scalar(@got), 1, "theme: nothing sent for a refusal");
    {
        local $ai::IN_AGENT = 1;
        my %sub = map {($_->{function}{name} => 1)} @{tools::native_list(exclude => ['agent', 'image'])};
        ok(!$sub{theme}, "theme: a sub-agent does not have it");
    }
}

# the markdown line of the prompt: for the web interface only
{
    TestAI::setup();
    local $::UI = undef;
    unlike(ai::prompt_context(), qr/Markdown/, "prompt: no markdown line in the terminal");
    local $::UI = 8080;
    like(ai::prompt_context(), qr/Write your answers in Markdown/, "prompt: the markdown line in the web interface");
}

done_testing();
