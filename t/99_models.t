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

# the model tool: switch to an id the provider lists, refuse any other
{
    TestAI::setup(AI_API_KEY => 'sk-test', AI_PROVIDER => 'openai', AI_LOCAL_SERVER => undef, AI_TOOL_CALLS => 'native');
    $ai::SESSION_MODEL = 'llama-b';
    mock_models('{"data":[{"id":"gpt-a"},{"id":"llama-b"}]}');
    my $out = tools::model_7e21(['gpt-a']);
    like($out, qr{the model is now openai/gpt-a}, "model: switched");
    is($ai::SESSION_MODEL, 'gpt-a', "model: the session's model is the new one");
    is(ai::read_session_model(), 'gpt-a', "model: and it is kept in the session");
    is(ai::read_session_provider(), 'openai', "model: the provider is kept in the session too");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    my $err = eval {tools::model_7e21(['not-there']); 1} ? '' : $@;
    like($err, qr/no model 'not-there' at any provider/, "model: an id no provider lists is refused");
    is($ai::SESSION_MODEL, 'gpt-a', "model: and nothing changed");
    mock_models('{"data":[{"id":"gpt-a"}]}');
    $err = eval {tools::model_7e21(['']); 1} ? '' : $@;
    like($err, qr/no model given/, "model: an empty id is refused");
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

done_testing();
