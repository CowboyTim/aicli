#!/usr/bin/perl
# providers: which one the key is for, what their requests look like, and the
# Anthropic Messages stream (its own events, not the OpenAI chunks)
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

# the provider a key belongs to, and where its requests go
sub setup_key {
    my ($key, %env) = @_;
    # AI_LOCAL_SERVER (set by TestAI) would skip the detection by key
    TestAI::setup(AI_API_KEY => $key, AI_LOCAL_SERVER => undef, %env); # ai::chat_setup() runs in there
    return ($ai::AI_PROVIDER, $ai::AI_URL);
}

# provider detection by key prefix: the longest prefix wins
{
    is((setup_key('sk-ant-api03-xyz'))[0], 'anthropic', "key sk-ant-: anthropic");
    is((setup_key('sk-or-v1-xyz'))[0], 'openrouter', "key sk-or-: still openrouter");
    is((setup_key('sk-proj-xyz'))[0], 'openai', "key sk-: openai");
    my ($p, $url) = setup_key('nvapi-xyz');
    is($p, 'nvidia', "key nvapi-: nvidia");
    is($url, 'https://integrate.api.nvidia.com/v1/chat/completions', "nvidia: chat completions URL");
    ($p, $url) = setup_key('sk-ant-api03-xyz');
    is($url, 'https://api.anthropic.com/v1/messages', "anthropic: messages URL");
    ($p, $url) = setup_key('sk-proj-xyz');
    is($url, 'https://api.openai.com/v1/chat/completions', "openai: chat completions URL");
    is((setup_key('sk-proj-xyz', AI_PROVIDER => 'openrouter'))[0], 'openrouter', "AI_PROVIDER wins over the key");
}

# OpenAI: the newer parameter names, no sampling settings it refuses
{
    setup_key('sk-proj-xyz', AI_MODEL => 'some-model');
    my $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    is($req->{max_completion_tokens}, 100_000, "openai: max_completion_tokens instead of max_tokens");
    ok(!exists $req->{max_tokens}, "openai: no max_tokens");
    ok(!exists $req->{top_k} && !exists $req->{min_p}, "openai: no top_k or min_p");
    ok(!exists $req->{temperature}, "openai: default temperature, not sent");
    is($req->{model}, 'some-model', "openai: the model");
}

# Anthropic: system prompt as a field, roles alternate, its headers
{
    setup_key('sk-ant-api03-xyz', AI_MODEL => 'claude-test', AI_TOKENS => 4000);
    my $req = $::JSON->decode(ai::build_request([
        {role => 'system', content => 'be brief'},
        {role => 'user', content => 'first'},
        {role => 'user', content => 'second'},
        {role => 'assistant', content => 'answer'},
        {role => 'user', content => 'last'},
    ]));
    is($req->{system}, 'be brief', "anthropic: the system prompt is a field");
    is(scalar(@{$req->{messages}}), 3, "anthropic: no system message, consecutive user turns joined");
    is($req->{messages}[0]{content}, "first\n\nsecond", "anthropic: joined with a blank line");
    is($req->{messages}[1]{role}, 'assistant', "anthropic: the roles alternate");
    is($req->{max_tokens}, 4000, "anthropic: max_tokens from AI_TOKENS");
    is($req->{model}, 'claude-test', "anthropic: the model");
    ok($req->{stream}, "anthropic: streamed");
    ok(!exists $req->{top_p} && !exists $req->{min_p}, "anthropic: no top_p or min_p");
    {
        local $::ORIG_ENV{AI_RAW} = 1;
        is(ai::build_request([{role => "user", content => "x"}]), undef, "anthropic: no raw completion format");
    }

    my $h = ai::provider_headers('sk-ant-key');
    ok((grep {$_ eq 'x-api-key: sk-ant-key'} @$h), "anthropic: the key in x-api-key");
    ok((grep {$_ eq 'anthropic-version: 2023-06-01'} @$h), "anthropic: the API version header");
    ok(!(grep {m/^Authorization/} @$h), "anthropic: no Authorization header");
}

# the request goes out with its headers (scripted HTTP)
{
    setup_key('sk-ant-api03-xyz', AI_MODEL => 'claude-test');
    TestAI::mock_http([
        "event: message_start\n".'data: {"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1,"cache_read_input_tokens":10}}}'."\n\n",
        "event: content_block_delta\n".'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}'."\n\n",
        "event: content_block_delta\n".'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}'."\n\n",
        "event: message_delta\n".'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}'."\n\n",
        "event: message_stop\n".'data: {"type":"message_stop"}'."\n\n",
    ]);
    my $out = TestAI::capture {ai::chat_completion("hi")};
    (my $plain = $out) =~ s/\e\[[0-9;]*m//g;
    like($plain, qr/Hello there/, "anthropic: the answer streams in");
    my $req = $TestAI::REQUESTS[0];
    is($req->{url}, 'https://api.anthropic.com/v1/messages', "anthropic: sent to the messages URL");
    ok((grep {$_ eq 'x-api-key: sk-ant-api03-xyz'} @{$req->{headers}}), "anthropic: sent with the key in its header");
    my $u = ai::load_usage();
    is($u->{total_tokens}, 25 + 10 + 7, "anthropic: usage counted (input incl. cache, output)");
    is($u->{last_prompt_tokens}, 35, "anthropic: input tokens of the request");
}

# the stream on its own: thinking, error
{
    setup_key('sk-ant-api03-xyz');
    my $seen = '';
    my $st = ai::new_stream(sub {$seen .= "[$_[0]]$_[1]"});
    $st->{feed}->("event: content_block_delta\n".'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}'."\n\n");
    $st->{feed}->("event: content_block_delta\n".'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}'."\n\n");
    $st->{feed}->("event: ping\n".'data: {"type":"ping"}'."\n\n");
    is($seen, "[think]hmm[text]ok", "stream: thinking and text kept apart, pings ignored");
    is($st->{content}, "ok", "stream: the answer is the text only");

    my $e = ai::new_stream(sub {});
    $e->{feed}->("event: error\n".'data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'."\n\n");
    is($e->{error}{error}{type}, 'overloaded_error', "stream: an error event is an error");
    like(ai::format_api_error($e->{error}), qr/Overloaded/, "stream: the error message is shown");
}

# the view of sub-agents, and the prompt in ASCII
{
    setup_key('sk-proj-xyz');
    my $out = TestAI::capture {ai::agent_view("agent 3", "bash: ls   -la")};
    like($out, qr/agent 3: bash: ls -la/, "agent view: one line, spaces made one");
    {
        local $::ORIG_ENV{AI_AGENT_VIEW} = 0;
        is(TestAI::capture {ai::agent_view("agent 3", "x")}, "", "agent view: AI_AGENT_VIEW=0 hides it");
    }
    my $long = TestAI::capture {ai::agent_view("agent 4", "y" x 500)};
    cmp_ok(length($long), "<", 200, "agent view: clipped to the width");

    local $::ORIG_ENV{AI_GLYPHS} = 'ascii';
    (my $p = ai::get_chat_prompt(0)) =~ s/\e\[[0-9;]*m//g;
    ok($p !~ m/[^\x00-\x7f]/, "prompt: ASCII glyph set has nothing outside ASCII");
    like($p, qr/> \z/, "prompt: ends with the ASCII arrow");
    local $::ORIG_ENV{AI_GLYPHS} = 'unicode';
    (my $u = ai::get_chat_prompt(0)) =~ s/\e\[[0-9;]*m//g;
    like($u, qr/\x{25ba} \z/, "prompt: unicode arrow with the unicode set");
}

# with the footer on, the prompt is short: the footer has the session and model
{
    setup_key('sk-proj-xyz');
    (my $long = ai::get_chat_prompt(0)) =~ s/\e\[[0-9;]*m//g;
    like($long, qr/test/, "prompt: without the footer, the session is in it");
    no warnings 'redefine';
    local *tui::bar = sub {1};
    (my $short = ai::get_chat_prompt(0)) =~ s/\e\[[0-9;]*m//g;
    is($short, "\x{25ba} ", "prompt: with the footer, only the arrow");
}

# the HTTP handles come from one curl family, the multi handle from the same
{
    ok($curl::FAMILY =~ m/^(?:Net|WWW)::Curl$/, "curl: a family loaded: $curl::FAMILY");
    ok(curl->new, "curl: an easy handle");
    my $m = loop::_multi();
    ok($m && ref($m) =~ m/^\Q$curl::FAMILY\E::Multi$/, "curl: the multi handle of the same family");
}

# a call without its /// header, inside a code fence, is run; a tag in prose is not a call
{
    setup_key('sk-proj-xyz');
    my @c = ai::parse_tool_calls("I will list it.\n```\nLIST_a41d+EO_6c08\n/workdir\nEO_6c08[8]\nLIST_a41d\n```\n");
    is(scalar(@c), 1, "tool call: a fenced call without /// is found");
    is($c[0] && $c[0]{tool}, 'LIST_a41d', "tool call: the right tool");
    is($c[0] && $c[0]{args}[0], '/workdir', "tool call: its argument");
    my @p = ai::parse_tool_calls("the tag LIST_a41d+EO_6c08 is not a call here\n");
    is(scalar(@p), 0, "tool call: a tag in the middle of a line is not a call");
}

done_testing();
