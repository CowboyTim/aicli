#!/usr/bin/perl
# native tool calls: the tools go in the request, the calls come back in
# tool_calls, their results are tool messages with the id of the call
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }

# a reply that makes calls: [name, id, arguments-json] per call
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

my $tmp = TestAI::setup(AI_TOOL_CALLS => 'native');

# the request: the tools, and no text syntax in the system prompt
{
    TestAI::mock_http(text_reply("hello"));
    TestAI::capture {ai::chat_completion("hi")};
    my $req = $::JSON->decode($TestAI::REQUESTS[0]{data});
    ok(ref($req->{tools}) eq 'ARRAY' && @{$req->{tools}}, "request: the tools are sent");
    my %names = map {($_->{function}{name} => 1)} @{$req->{tools}};
    ok($names{bash} && $names{list} && $names{agent}, "request: bash, list and agent among them");
    my ($bash) = grep {$_->{function}{name} eq 'bash'} @{$req->{tools}};
    is_deeply($bash->{function}{parameters}{required}, ['code'], "request: the required arguments of bash");
    ok(exists $bash->{function}{parameters}{properties}{code}, "request: its argument has a schema");
    my @names = map {$_->{function}{name}} @{$req->{tools}};
    is_deeply(\@names, [sort @names], "request: the tools are sorted, so the request stays the same");
    unlike($req->{messages}[0]{content}, qr{///|TOOLS SYNTAX}, "request: no text syntax in the system prompt");
}

# a call the server made runs; its result goes back as a tool message
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
                calls_reply(['bash', 'call_one', '{"code":"echo native-ok"}']),
        text_reply("it said native-ok"),
    );
    my $out = TestAI::capture {ai::chat_completion("run it")};
    like($out, qr/native-ok/, "call: the tool ran and its result is shown");
    my @msgs = ai::load_messages();
    is(join(',', map {$_->{role}} @msgs), "system,user,assistant,tool,assistant", "call: the roles of the turn");
    is($msgs[2]{tool_calls}[0]{id}, 'call_one', "call: the assistant message keeps the call id");
    is($msgs[2]{tool_calls}[0]{function}{name}, 'bash', "call: and its name");
    is($msgs[3]{tool_call_id}, 'call_one', "call: the result refers to the call");
    like($msgs[3]{content}, qr/^native-ok/, "call: the result is the plain output, no text envelope");
    my $second = $::JSON->decode($TestAI::REQUESTS[1]{data});
    is($second->{messages}[-1]{role}, 'tool', "call: the second request ends with the tool result");
    is($second->{messages}[-2]{role}, 'assistant', "call: and the call of the model before it");
}

# the calls come in pieces: arguments are put together by index
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    my $pieces = [sse(
        {choices => [{delta => {tool_calls => [{index => 0, id => 'call_p', function => {name => 'bash', arguments => '{"co'}}]}}]},
        {choices => [{delta => {tool_calls => [{index => 0, function => {arguments => 'de":"echo pieces"}'}}]}}]},
        {choices => [{delta => {}, finish_reason => 'tool_calls'}]},
    )];
    TestAI::mock_http($pieces, text_reply("ok"));
    my $out = TestAI::capture {ai::chat_completion("pieces")};
    like($out, qr/pieces/, "pieces: the joined arguments ran");
}

# a call that does not fit its tool is answered with the error, nothing runs
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
                calls_reply(['bash', 'call_bad', '{"nope":1}'], ['nosuchtool', 'call_none', '{}']),
        text_reply("sorry"),
    );
    TestAI::capture {ai::chat_completion("bad")};
    my @msgs = ai::load_messages();
    my ($bad, $none) = grep {($_->{role} // '') eq 'tool'} @msgs;
    like($bad->{content}, qr/bad arguments for 'bash'.*\"code\": string \(required\)/, "bad: missing argument, the JSON arguments are named");
    unlike($bad->{content}, qr/\/\/\/|Expected syntax/, "bad: no text syntax in a native error");
    like($none->{content}, qr/no tool named 'NOSUCHTOOL'/, "bad: an unknown tool is named");
    is($bad->{tool_call_id}, 'call_bad', "bad: answered with its id");
    is($none->{tool_call_id}, 'call_none', "bad: and the other one too");
}

# the arguments of a call go to the right place: a tool with two or more
# arguments gets each one at its own position (the syntax names each twice)
{
    is_deeply([tools::arg_names($tools::TOOLS->{lines})], ['path', 'range'], "args: names once each, in order");
    my $args = tools::native_args('lines', '{"path":"utils.pm","range":"1-30"}');
    is_deeply($args, ['utils.pm', '1-30'], "args: lines gets the path and then the range");
    is_deeply(tools::native_args('replace', '{"path":"a","old":"b","new":"c"}'), ['a', 'b', 'c'], "args: replace gets all three in order");
}

# the text syntax still works when the model writes it (AI_TOOL_CALLS=text keeps the prompt)
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
                text_reply("///BASH_7c48+EO_dfd7\necho in-text\nEO_dfd7[9]\nBASH_7c48"),
        text_reply("done"),
    );
    my $out = TestAI::capture {ai::chat_completion("text")};
    like($out, qr/in-text/, "fallback: a call written in the text still runs");
}

# a sub-agent makes native calls too, without the agent tool; its answer comes
# back to the main agent as a tool message
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return calls_reply(['bash', 'call_sub', '{"code":"echo from-sub"}']) if @$msgs == 2;
        return text_reply("sub got: ".($msgs->[-1]{content} // ''));
    });
    TestAI::mock_http(
        calls_reply(['agent', 'call_main', '{"task":"run echo"}']),
        text_reply("main done"),
    );
    TestAI::capture {ai::chat_completion("delegate")};
    my @agent_tools = map {$_->{function}{name}} @{$::JSON->decode($TestAI::AGENT_REQUESTS[0]{data})->{tools} // []};
    ok(!grep({$_ eq 'agent'} @agent_tools) && grep({$_ eq 'bash'} @agent_tools), "agent: its tools are sent, without agent");
    my @msgs = ai::load_messages();
    my ($res) = grep {($_->{role} // '') eq 'tool' and ($_->{tool_call_id} // '') eq 'call_main'} @msgs;
    like($res->{content} // '', qr/sub got: from-sub/, "agent: its answer is the tool result of the main agent");
}

# FastFlowLM: no sub-agents. The agent tool is not in the request, and a call
# written as text is refused (it does not run)
{
    TestAI::setup(AI_LOCAL_SERVER => 'http://localhost:8001/v1', AI_PROVIDER => 'flm', AI_TOOL_CALLS => 'native');
    my %names = map {($_->{function}{name} => 1)} @{tools::native_list()};
    ok(!$names{agent}, "flm: no agent tool in the request");
    ok($names{bash}, "flm: the other tools are there");
    my (undef, $err) = ai::execute_tool('agent', 'agent', ['do it']);
    like($err // '', qr/tool 'agent' is not available here/, "flm: an agent call is refused");
    my ($out, $err2) = ai::execute_tool('bash', 'bash', ['echo still-here']);
    ok(!$err2 && $out =~ m/still-here/, "flm: a bash call still runs");
}

# AI_RAW and Anthropic: no tools in the request
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_RAW => 1);
    ok(!ai::native_calls(), "raw: no native calls");
    TestAI::setup(AI_TOOL_CALLS => 'text');
    ok(!ai::native_calls(), "AI_TOOL_CALLS=text: no native calls");
    TestAI::setup(AI_TOOL_CALLS => 'native');
    ok(ai::native_calls(), "default-ish: native");
}

done_testing();
