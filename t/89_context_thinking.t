#!/usr/bin/perl
# the reasoning setting (AI_THINKING, /thinking), and long sessions: the first
# request is kept through compactions, each one is recorded, /context shows it
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

# the setting: a session's file wins over AI_THINKING
{
    TestAI::setup(AI_THINKING => 'off', AI_SUMMARY_CHUNKS => 1);
    is(ai::thinking_setting(), 'off', "setting: AI_THINKING");
    is(ai::thinking_text(), 'off (AI_THINKING)', "setting: where it comes from");
    ai::handle_command("/thinking on");
    is(ai::thinking_setting(), 'on', "setting: the session's file wins");
    is(ai::thinking_text(), 'on (session)', "setting: shown as the session's");
    my $out = TestAI::capture {ai::handle_command("/thinking 4000")};
    is(ai::thinking_setting(), 4000, "setting: a token budget");
    like($out, qr/thinking: 4000 \(session\)/, "setting: /thinking shows it");
    TestAI::capture {ai::handle_command("/thinking default")};
    is(ai::thinking_setting(), 'off', "setting: default takes the session file away");
    my $bad = TestAI::capture {ai::handle_command("/thinking maybe")};
    like($bad, qr/Usage: \/thinking/, "setting: a bad value is refused");
}
{
    TestAI::setup(AI_SUMMARY_CHUNKS => 1, AI_SUMMARY_CHUNKS => 1);
    is(ai::thinking_setting(), undef, "setting: nothing set is the server's default");
    is(ai::thinking_text(), 'server default (default)', "setting: said as the default");
}

# what the request says
{
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_THINKING => 'off', AI_MODEL => 'm', AI_SUMMARY_CHUNKS => 1);
    my $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(exists $req->{chat_template_kwargs} && !$req->{chat_template_kwargs}{enable_thinking}, "request: thinking off for the server");
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_THINKING => '2500', AI_MODEL => 'm', AI_SUMMARY_CHUNKS => 1);
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    is($req->{reasoning_budget}, 2500, "request: the budget as reasoning_budget");
    ok($req->{chat_template_kwargs}{enable_thinking}, "request: and thinking on");
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_MODEL => 'm', AI_SUMMARY_CHUNKS => 1);
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(!exists $req->{chat_template_kwargs} && !exists $req->{reasoning_budget}, "request: nothing sent when not set");

    TestAI::setup(AI_API_KEY => 'nvapi-x', AI_LOCAL_SERVER => undef, AI_MODEL => 'nemo', AI_SUMMARY_CHUNKS => 1);
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok($req->{chat_template_kwargs}{enable_thinking}, "request: nvidia keeps thinking on by default");

    TestAI::setup(AI_API_KEY => 'sk-proj-x', AI_LOCAL_SERVER => undef, AI_THINKING => 'off', AI_MODEL => 'gpt', AI_SUMMARY_CHUNKS => 1);
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(!exists $req->{chat_template_kwargs} && !exists $req->{reasoning_budget}, "request: openai is not sent the server's options");
}

# a long session: compactions keep the first request, are recorded, /context shows them
{
    TestAI::setup(AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 1);
    ai::append_messages({role => 'user', content => "FIRST: build the parser ".("x" x 300)});
    for my $i (1 .. 12){
        ai::append_messages({role => 'assistant', content => "step $i ".("y" x 400)},
                            {role => 'user', content => "go on $i ".("z" x 400)});
    }
    TestAI::mock_http([TestAI::content("the summary"), TestAI::done()]);
    my $out = TestAI::capture {ai::compact_context(summarize => 1)};
    like($out, qr/context: summarized \d+ older messages/, "long: compacted");
    my @msgs = ai::load_messages();
    like($msgs[1]{content}, qr/The first request of the user, word for word:\nFIRST: build the parser/, "long: the first request is in the note");
    like($msgs[1]{content}, qr/\nthe summary\n/, "long: and the summary");
    ok(-f "$TestAI::TMP/aicli/sessions/test/first_request" || -f "$ai::AI_SESSION_DIR/first_request", "long: the first request is kept in the session");
    my @rec = map {$::JSON->decode($_)} grep {m/\S/} split /\n/, ai::slurp("$ai::AI_SESSION_DIR/compactions") // '';
    is(scalar(@rec), 1, "long: the compaction is recorded");
    is($rec[0]{messages}[0], 26, "long: messages before (the system prompt and 25 more)");
    ok($rec[0]{messages}[1] < $rec[0]{messages}[0], "long: fewer after");

    my $ctx = TestAI::capture {ai::handle_command("/context")};
    like($ctx, qr/compactions: 1/, "/context: the count of compactions");
    like($ctx, qr/last: .*summarized/, "/context: the last one");
    like($ctx, qr/thinking:\s+server default/, "/context: the thinking setting");
    my $sum = TestAI::capture {ai::handle_command("/context summary")};
    like($sum, qr/the summary/, "/context summary: the last summary");

    # a second compaction keeps the same first request
    ai::append_messages({role => 'assistant', content => "more ".("q" x 400)}, {role => 'user', content => "more ".("w" x 400)}) for 1 .. 10;
    TestAI::mock_http([TestAI::content("second summary"), TestAI::done()]);
    TestAI::capture {ai::compact_context(summarize => 1)};
    @msgs = ai::load_messages();
    like($msgs[1]{content}, qr/FIRST: build the parser/, "long: still there after a second compaction");

    # a new conversation has a new first request
    ai::handle_command("/clear");
    ok(!-f "$ai::AI_SESSION_DIR/first_request", "clear: the first request of the old one is gone");
}

# FastFlowLM (the NPU): one request at a time, so one sub-agent; native tool calls stay the default
{
    TestAI::setup(AI_LOCAL_SERVER => 'http://localhost:8001/v1', AI_PROVIDER => 'flm', AI_MODEL => 'qwen3:4b', AI_TOOL_CALLS => "native", AI_SUMMARY_CHUNKS => 1);
    is(ai::max_agents(), 1, "flm: one sub-agent at a time");
    is(ai::default_tokens(), 8192, "flm: a shorter answer limit by default");
    ok(ai::native_calls(), "flm: native tool calls by default");
    TestAI::setup(AI_LOCAL_SERVER => 'http://localhost:8001/v1', AI_PROVIDER => 'flm', AI_MAX_AGENTS => 3, AI_SUMMARY_CHUNKS => 1);
    is(ai::max_agents(), 3, "flm: AI_MAX_AGENTS wins");
    TestAI::setup(AI_LOCAL_SERVER => 'http://localhost:8001/v1', AI_PROVIDER => 'flm', AI_TOOL_CALLS => 'text', AI_SUMMARY_CHUNKS => 1);
    ok(!ai::native_calls(), "flm: AI_TOOL_CALLS=text still works");
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_SUMMARY_CHUNKS => 1);
    is(ai::max_agents(), 4, "other providers: four");
    is(ai::default_tokens(), 100_000, "other providers: the long limit");
}

# a long older part is summarized in pieces, each one carrying the summary so far
sub long_history {
    ai::append_messages({role => 'user', content => "FIRST: build the parser ".("x" x 1500)});
    for my $i (1 .. 12){
        ai::append_messages({role => 'assistant', content => "step $i ".("y" x 1500)},
                            {role => 'user', content => "go on $i ".("z" x 1500)});
    }
}
{
    TestAI::setup(AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 3);
    long_history();
    TestAI::mock_http([TestAI::content("S1 the parser"), TestAI::done()],
                      [TestAI::content("S2 more work"), TestAI::done()],
                      [TestAI::content("S3 the end"), TestAI::done()]);
    TestAI::capture {ai::compact_context(summarize => 1)};
    is(scalar(@TestAI::REQUESTS), 3, "pieces: one request per piece, at most AI_SUMMARY_CHUNKS");
    like(TestAI::sent_messages(1)->[1]{content}, qr/The summary of the conversation so far:\nS1 the parser/, "pieces: the second carries the first summary");
    like(TestAI::sent_messages(2)->[1]{content}, qr/The summary of the conversation so far:\nS2 more work/, "pieces: the third carries the second");
    like(TestAI::sent_messages(2)->[1]{content}, qr/Update the summary above/, "pieces: asked to update, not to start over");
    my @msgs = ai::load_messages();
    like($msgs[1]{content}, qr/\nS3 the end\n/, "pieces: the last summary is the one kept");
}
{
    TestAI::setup(AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 3, AI_RETRIES => 0);
    long_history();
    TestAI::mock_http([TestAI::content("S1 kept"), TestAI::done()], undef, undef);
    TestAI::capture {ai::compact_context(summarize => 1)};
    my @msgs = ai::load_messages();
    like($msgs[1]{content}, qr/\nS1 kept\n/, "pieces: a piece that fails keeps the summary so far");
    is(scalar(@TestAI::REQUESTS), 2, "pieces: nothing more is asked after the failure");
}

# automatic compaction: after the answer that takes the conversation over the
# threshold, not when the next message is sent; not for -p, not when switched off
sub small_history {
    for my $i (1 .. 4){
        ai::append_messages({role => 'user', content => "question $i ".("q" x 800)},
                            {role => 'assistant', content => "answer $i ".("a" x 800)});
    }
}
{
    TestAI::setup(AI_PROMPT_TEMPLATE => "default", AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 1);
    small_history();
    TestAI::mock_http([TestAI::content("BIG ANSWER ".("b" x 3000)), TestAI::done()],
                      [TestAI::content("SUMMARY NOW"), TestAI::done()]);
    my $out = TestAI::capture {ai::chat_completion("one more thing")};
    my $at_answer = index($out, "BIG ANSWER");
    my $at_compact = index($out, "[context: summarized");
    ok($at_compact > $at_answer && $at_answer >= 0, "auto: compacted after the answer that went over");
    is(scalar(@TestAI::REQUESTS), 2, "auto: one request for the answer, one for the summary");
    like($TestAI::REQUESTS[0]{data}, qr/one more thing/, "auto: the first request is the answer, not a summary before it");
    like((ai::load_messages())[1]{content}, qr/SUMMARY NOW/, "auto: the summary is in the conversation");
}
{
    TestAI::setup(AI_PROMPT_TEMPLATE => "default", AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 1, AI_AUTO_COMPACT => 0);
    small_history();
    TestAI::mock_http([TestAI::content("BIG ANSWER ".("b" x 3000)), TestAI::done()]);
    my $out = TestAI::capture {ai::chat_completion("one more thing")};
    unlike($out, qr/\[context: summarized/, "auto: AI_AUTO_COMPACT=0 leaves it");
}
{
    TestAI::setup(AI_PROMPT_TEMPLATE => "default", AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1, AI_SUMMARY_CHUNKS => 1);
    small_history();
    TestAI::mock_http([TestAI::content("BIG ANSWER ".("b" x 3000)), TestAI::done()]);
    my $out = do { local $ai::ONE_SHOT = 1; TestAI::capture {ai::chat_completion("one more thing")} };
    unlike($out, qr/\[context: summarized/, "auto: not after -p (one request and out)");
}

done_testing();
