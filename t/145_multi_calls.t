#!/usr/bin/perl
# several tool calls in one answer: each is listed (a tool line per call on the page) and answered
# with a tool message of its own id, in the order of the answer, whatever the server sends with the
# calls: an index for each, the same index for all of them, or none. A call that fails leaves the
# others to run, and the calls are kept in the chat as the answer made them.
use strict; use warnings;

use Test::More;
use FindBin;
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }
sub text_reply {
    my ($text) = @_;
    return [sse({choices => [{delta => {content => $text}}]}, {choices => [{delta => {}, finish_reason => 'stop'}]})];
}

# an answer that makes calls, streamed as the chunks say: [index, id, name, arguments] per chunk, with
# index, id or name left out (undef) where the server leaves them out
sub calls_stream {
    my (@chunks) = @_;
    my @events;
    for my $c (@chunks) {
        my ($index, $id, $name, $args) = @$c;
        my %tc = (function => {arguments => $args});
        $tc{index} = $index if defined $index;
        $tc{id}    = $id    if defined $id;
        $tc{function}{name} = $name if defined $name;
        push @events, +{choices => [+{delta => +{tool_calls => [\%tc]}}]};
    }
    push @events, +{choices => [+{delta => +{}, finish_reason => 'tool_calls'}]};
    return [sse(@events)];
}

sub echo_args { $J->encode({code => "echo $_[0]"}) }

# the tool messages the model got back in request $n (0 first): [id, content] in their order
sub results_in {
    my ($n) = @_;
    my $req = $J->decode($TestAI::REQUESTS[$n]{data});
    return map {[$_->{tool_call_id}, $_->{content}]} grep {($_->{role} // '') eq 'tool'} @{$req->{messages}};
}

sub run_turn {
    my (@chunks) = @_;
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_TOOL_DISPLAY => 'brief');
    TestAI::mock_http(calls_stream(@chunks), text_reply("all done"));
    my @EV;
    local $ai::EVENT_SINK = sub { push @EV, [@_] };
    TestAI::capture {ai::chat_completion("several things")};
    return \@EV;
}

# 1. an index for each call, as most servers send it
{
    my $EV = run_turn(
        [0, 'call_a', 'bash', echo_args('one')],
        [1, 'call_b', 'bash', echo_args('two')],
        [2, 'call_c', 'bash', echo_args('three')],
    );
    my @r = results_in(1);
    is_deeply(\@r, [['call_a', "one\n"], ['call_b', "two\n"], ['call_c', "three\n"]],
        "indexes 0, 1 and 2: each call is answered with its own id, in order");
    is(scalar(grep {$_->[0] eq 'tool'} @$EV), 3, "and each of them is listed on the page (a tool line each)");
}

# 2. the same index for every call (each with its own id): they are three calls, not one
{
    my $EV = run_turn(
        [0, 'call_a', 'bash', echo_args('one')],
        [0, 'call_b', 'bash', echo_args('two')],
        [0, 'call_c', 'bash', echo_args('three')],
    );
    my @r = results_in(1);
    is_deeply(\@r, [['call_a', "one\n"], ['call_b', "two\n"], ['call_c', "three\n"]],
        "the same index for all: three calls, each answered with its own id");
    is(scalar(grep {$_->[0] eq 'tool'} @$EV), 3, "and three tool lines");
}

# 3. no index at all: each call has its own id
{
    my $EV = run_turn(
        [undef, 'call_a', 'bash', echo_args('one')],
        [undef, 'call_b', 'bash', echo_args('two')],
    );
    my @r = results_in(1);
    is_deeply(\@r, [['call_a', "one\n"], ['call_b', "two\n"]],
        "no index: two calls, each answered with its own id");
    is(scalar(grep {$_->[0] eq 'tool'} @$EV), 2, "and two tool lines");
}

# 4. the arguments of two calls come in pieces, mixed together: each call keeps its own pieces
{
    my $EV = run_turn(
        [0, 'call_a', 'bash', '{"code":"echo '],
        [1, 'call_b', 'bash', '{"code":"echo '],
        [0, undef, undef, 'alpha"}'],
        [1, undef, undef, 'beta"}'],
    );
    my @r = results_in(1);
    is_deeply(\@r, [['call_a', "alpha\n"], ['call_b', "beta\n"]],
        "pieces of two calls mixed: each call has its own arguments");
}

# 5. a call that fails (no such tool) leaves the others to run, and each gets an answer
{
    my $EV = run_turn(
        [0, 'call_a', 'bash', echo_args('one')],
        [1, 'call_b', 'no_such_tool', '{}'],
        [2, 'call_c', 'bash', echo_args('three')],
    );
    my @r = results_in(1);
    is(scalar(@r), 3, "three answers for three calls, though one failed");
    is($r[0][0], 'call_a', "the first call is answered first");
    is($r[1][0], 'call_b', "the failed call is answered, with its id");
    like($r[1][1], qr/no tool named|Unknown tool|ERROR/, "and it says it failed");
    is_deeply([@r[0, 2]], [['call_a', "one\n"], ['call_c', "three\n"]], "the others ran");
}

# 6. the calls are kept in the chat as the answer made them: one assistant message, all its calls
{
    my @chunks = (
        [0, 'call_a', 'bash', echo_args('one')],
        [0, 'call_b', 'bash', echo_args('two')],
    );
    run_turn(@chunks);
    my @lines = map {$J->decode($_)} grep {/\S/} split /\n/, do {
        my $f = "$ai::SESSIONS_DIR/".($ai::AI_SESSION // 'test')."/chat";
        open(my $h, '<', $f) or die "$f: $!"; local $/; <$h>;
    };
    my ($assistant) = grep {($_->{role} // '') eq 'assistant' && $_->{tool_calls}} @lines;
    is(scalar(@{$assistant->{tool_calls} // []}), 2, "the chat keeps the answer with both of its calls");
    is_deeply([map {$_->{id}} @{$assistant->{tool_calls}}], ['call_a', 'call_b'], "with their ids");
}

# 7. each call shows how long it took, and the usage of the session keeps the totals per tool
{
    my $EV = run_turn(
        [0, 'call_a', 'bash', echo_args('one')],
        [1, 'call_b', 'bash', echo_args('two')],
    );
    my @took = grep {$_->[0] eq 'result' and ($_->[1]{text} // '') =~ /took \d/} @$EV;
    is(scalar(@took), 2, "each call shows how long it took, in its result line");
    my $u = ai::load_usage();
    is($u->{tools}{bash}{calls}, 2, "the usage of the session counts the calls of each tool");
    is($u->{tools}{bash}{errors} // 0, 0, "and their errors");
    ok($u->{tools}{bash}{seconds} > 0, "and the time they took");
    my $out = TestAI::capture {ai::handle_command('/usage')};
    like($out, qr/^  bash\s+2 calls, 0 errors, /m, "/usage lists the tools: calls, errors, time in all and on average");
}

# 8. a sub-agent's own calls count in the session's tools too, and the agent call takes its time
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_TOOL_DISPLAY => 'brief');
    TestAI::mock_agent_http(sub {
        my ($messages) = @_;
        return text_reply("the agent's answer") if (($messages->[-1]{role} // '') eq 'tool');
        return calls_stream([0, 'call_sub', 'bash', echo_args('from the agent')]);
    });
    TestAI::mock_http(
        calls_stream([0, 'call_ag', 'agent', $J->encode({task => 'look at it'})]),
        text_reply("done"),
    );
    TestAI::capture {ai::chat_completion("delegate it")};
    my $u = ai::load_usage();
    is($u->{tools}{agent}{calls}, 1, "the agent call is counted");
    is($u->{tools}{bash}{calls}, 1, "and the call the agent made");
    ok($u->{tools}{agent}{seconds} >= $u->{tools}{bash}{seconds}, "the agent's time covers the calls it made");
}

done_testing();
