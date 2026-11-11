#!/usr/bin/perl
# the agent loop: request, stream, tools, request again - with a scripted LLM
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my ($Y, $G, $R) = ($colors::yellow_color1, $colors::green_color, $colors::reset_color);
my $bash = sub {"///BASH_7c48+EO_dfd7\n$_[0]\nEO_dfd7\nBASH_7c48\n"};

# a plain answer
{
    TestAI::setup();
    TestAI::mock_http([TestAI::content("Hello"), TestAI::content(" there"), TestAI::done()]);
    my $out = TestAI::capture {ai::chat_completion("hi")};
    is(scalar(@TestAI::REQUESTS), 1, "plain: one request");
    is($TestAI::REQUESTS[0]{url}, "http://127.0.0.1:9/v1/chat/completions", "plain: url, /v1 not doubled");
    my $sent = TestAI::sent_messages(0);
    is(TestAI::roles(@$sent), "system,user", "plain: system + user sent");
    is($sent->[1]{content}, "hi", "plain: the user input is sent");
    like($sent->[0]{content}, qr{///BASH_7c48\+EO_dfd7}, "plain: coder prompt has the tools");
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant", "plain: user and assistant are saved");
    is($msgs[1]{content}, "hi", "plain: user message saved");
    is($msgs[2]{content}, "Hello there", "plain: answer saved");
    is($out, "${G}Hello${R}${G} there${R}\n", "plain: answer printed");
}

# a tool call: the result goes back to the model in a 2nd request
{
    TestAI::setup();
    TestAI::mock_http(
        [TestAI::content("Let me look.\n".$bash->('echo "hi-$((40+2))"')), TestAI::done()],
        [TestAI::content("It says hi-42."), TestAI::done()],
    );
    my $out = TestAI::capture {ai::chat_completion("run it")};
    is(scalar(@TestAI::REQUESTS), 2, "tool: two requests");
    my $sent = TestAI::sent_messages(1);
    is(TestAI::roles(@$sent), "system,user,assistant,user", "tool: 2nd request has answer + tool result");
    like($sent->[2]{content}, qr{^Let me look\.\n///BASH_7c48}, "tool: the tool call of the model is sent back");
    is($sent->[3]{content}, "[BASH_7c48 RESULT_d170\nhi-42\n\nRESULT_d170]", "tool: the tool result is sent");
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,assistant", "tool: every step saved once");
    is($msgs[4]{content}, "It says hi-42.", "tool: final answer saved");
    like($out, qr/\Q${Y}[TOOL BASH_7c48(...))]${R}\E/, "tool: call announced");
    like($out, qr/hi-42/, "tool: result shown");

    # the next user input continues the same conversation
    TestAI::mock_http([TestAI::content("Sure."), TestAI::done()]);
    TestAI::capture {ai::chat_completion("thanks")};
    is(TestAI::roles(@{TestAI::sent_messages(0)}), "system,user,assistant,user,assistant,user", "tool: history is complete on the next input");
}

# several tool turns in a row, and a failing tool
{
    TestAI::setup();
    TestAI::mock_http(
        [TestAI::content($bash->('echo one')), TestAI::done()],
        [TestAI::content($bash->('echo two; exit 3')), TestAI::done()],
        [TestAI::content("done"), TestAI::done()],
    );
    TestAI::capture {ai::chat_completion("go")};
    is(scalar(@TestAI::REQUESTS), 3, "turns: three requests");
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,assistant,user,assistant", "turns: all saved, in order");
    like($msgs[3]{content}, qr/RESULT_d170\none\n/, "turns: 1st result");
    like($msgs[5]{content}, qr/\A\[BASH_7c48 ERROR_9a78\n.*exit code: 3, output: two\n/s, "turns: failure reported as error with output");
}

# a model that never stops calling tools is stopped
{
    TestAI::setup(AI_MAX_TURNS => 3);
    TestAI::mock_http(map {[TestAI::content($bash->('true')), TestAI::done()]} 1 .. 10);
    my $out = TestAI::capture {ai::chat_completion("loop")};
    is(scalar(@TestAI::REQUESTS), 3, "max turns: stopped after AI_MAX_TURNS requests");
    like($out, qr/stopped after 3 tool turns/, "max turns: said so");
}

# failing request: the user message is kept, nothing else
{
    TestAI::setup();
    TestAI::mock_http(undef);
    my $out = TestAI::capture {ai::chat_completion("hello?")};
    is(TestAI::roles(ai::load_messages()), "system,user", "error: user message kept, no assistant");
    like($out, qr/ERROR: HTTP status 500/, "error: reported");

    # error body of the API
    TestAI::mock_http(sub {
        my ($cb) = @_;
        $cb->(undef, '{"error":{"code":429,"message":"slow down"}}');
        $utils::http_error = "HTTP status 429";
        return;
    });
    $out = TestAI::capture {ai::chat_completion("again")};
    like($out, qr/ERROR: 429: slow down/, "error: API message shown");

    # error in the middle of a stream
    TestAI::mock_http([TestAI::content("par"), TestAI::sse({error => {message => "overloaded"}})]);
    $out = TestAI::capture {ai::chat_completion("more")};
    like($out, qr/ERROR: overloaded/, "error: mid-stream error shown");
}

# thinking: reasoning deltas and <think> blocks are shown, not kept
{
    TestAI::setup();
    TestAI::mock_http([
        TestAI::reasoning("Let me "), TestAI::reasoning("think."),
        TestAI::content("\n\nThe answer"), TestAI::content(" is 4."), TestAI::done(),
    ]);
    my $out = TestAI::capture {ai::chat_completion("2+2?")};
    is($out, "${Y}Let me ${R}${Y}think.${R}\n${G}The answer${R}${G} is 4.${R}\n", "thinking: reasoning in its own color, then the answer");
    is((ai::load_messages())[2]{content}, "The answer is 4.", "thinking: only the answer is saved");

    # <think> tags inside the content, split over deltas
    TestAI::mock_http([
        (map {TestAI::content($_)} "<thi", "nk>hm, a ", "tool?</th", "ink>\n", "No <b>tool</b>", " needed <"),
        TestAI::done(),
    ]);
    $out = TestAI::capture {ai::chat_completion("and now?")};
    unlike($out, qr/think>/, "think tags: tags are not shown");
    is($out, "${Y}hm, a ${R}${Y}tool?${R}\n${G}No <b>tool</b>${R}${G} needed ${R}${G}<${R}\n", "think tags: colored by state");
    is((ai::load_messages())[-1]{content}, "No <b>tool</b> needed <", "think tags: thinking not saved");

    # tools mentioned while thinking don't run
    TestAI::mock_http([TestAI::content("<think>\n".$bash->('echo NO')."</think>\nNothing to do."), TestAI::done()]);
    $out = TestAI::capture {ai::chat_completion("think only")};
    is(scalar(@TestAI::REQUESTS), 1, "think tags: tool call in thinking is not executed");
    unlike($out, qr/TOOL BASH/, "think tags: no tool announced");
}
{
    TestAI::setup(AI_SHOW_THINKING => 0);
    TestAI::mock_http([TestAI::reasoning("secret"), TestAI::content("<think>more</think>shown"), TestAI::done()]);
    my $out = TestAI::capture {ai::chat_completion("quiet")};
    is($out, "${G}shown${R}\n", "AI_SHOW_THINKING=0: thinking hidden");
}

# SSE framing: events split anywhere, CRLF, comments, other "reasoning" key
{
    TestAI::setup();
    my $stream = ": keep-alive\r\n\r\n"
        .TestAI::sse({choices => [{delta => {reasoning => "r"}}]})
        .TestAI::content("caf\x{e9} \x{263a}") =~ s/\n/\r\n/gr
        .TestAI::sse({choices => []})
        .TestAI::content(" ok").TestAI::done();
    TestAI::mock_http([unpack("(a7)*", $stream)]);
    my $out = TestAI::capture {ai::chat_completion("utf8 \x{263a}")};
    my @msgs = ai::load_messages();
    is($msgs[1]{content}, "utf8 \x{263a}", "sse: user text saved as text");
    is($msgs[2]{content}, "caf\x{e9} \x{263a} ok", "sse: answer reassembled, as text");
    like($out, qr/caf\xc3\xa9 \xe2\x98\xba/, "sse: printed as UTF-8");
    like($out, qr/\Q${Y}r${R}\E/, "sse: 'reasoning' key shown as thinking");

    TestAI::mock_http([TestAI::content("fine"), TestAI::done()]);
    TestAI::capture {ai::chat_completion("again")};
    is(TestAI::sent_messages(0)->[2]{content}, "caf\x{e9} \x{263a} ok", "sse: sent back without double encoding");
}

# a not streamed reply works too
{
    TestAI::setup();
    TestAI::mock_http(['{"choices":[{"message":{"role":"assistant","content":"whole"}}]}']);
    my $out = TestAI::capture {ai::chat_completion("no stream")};
    is((ai::load_messages())[2]{content}, "whole", "non-stream: answer saved");
    is($out, "${G}whole${R}\n", "non-stream: answer printed");
}

# ctrl-C during the answer: the turn stops, tools don't run
{
    TestAI::setup();
    TestAI::mock_http(sub {
        my ($cb) = @_;
        $cb->(undef, TestAI::content("partial ".$bash->('echo NO')));
        $::ABORT = 1;
        my $n = $cb->(undef, TestAI::content("more"));
        is($n, 0, "abort: the stream callback stops the transfer");
        $utils::http_error = "interrupted";
        return;
    });
    my $out = TestAI::capture {ai::chat_completion("stop me")};
    $::ABORT = 0;
    is(scalar(@TestAI::REQUESTS), 1, "abort: no further request");
    like($out, qr/\[interrupted\]/, "abort: said so");
    unlike($out, qr/RESULT_d170/, "abort: the tool did not run");
    is(TestAI::roles(ai::load_messages()), "system,user,assistant", "abort: partial answer kept");
}

done_testing();
