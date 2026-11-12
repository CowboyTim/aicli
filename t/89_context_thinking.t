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
    TestAI::setup(AI_THINKING => 'off');
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
    TestAI::setup();
    is(ai::thinking_setting(), undef, "setting: nothing set is the server's default");
    is(ai::thinking_text(), 'server default (default)', "setting: said as the default");
}

# what the request says
{
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_THINKING => 'off', AI_MODEL => 'm');
    my $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(exists $req->{chat_template_kwargs} && !$req->{chat_template_kwargs}{enable_thinking}, "request: thinking off for the server");
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_THINKING => '2500', AI_MODEL => 'm');
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    is($req->{reasoning_budget}, 2500, "request: the budget as reasoning_budget");
    ok($req->{chat_template_kwargs}{enable_thinking}, "request: and thinking on");
    TestAI::setup(AI_LOCAL_SERVER => 'http://127.0.0.1:9/v1/', AI_MODEL => 'm');
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(!exists $req->{chat_template_kwargs} && !exists $req->{reasoning_budget}, "request: nothing sent when not set");

    TestAI::setup(AI_API_KEY => 'nvapi-x', AI_LOCAL_SERVER => undef, AI_MODEL => 'nemo');
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok($req->{chat_template_kwargs}{enable_thinking}, "request: nvidia keeps thinking on by default");

    TestAI::setup(AI_API_KEY => 'sk-proj-x', AI_LOCAL_SERVER => undef, AI_THINKING => 'off', AI_MODEL => 'gpt');
    $req = $::JSON->decode(ai::build_request([{role => 'user', content => 'hi'}]));
    ok(!exists $req->{chat_template_kwargs} && !exists $req->{reasoning_budget}, "request: openai is not sent the server's options");
}

# a long session: compactions keep the first request, are recorded, /context shows them
{
    TestAI::setup(AI_CONTEXT_TOKENS => 3000, AI_CONTEXT_SUMMARY => 1);
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

done_testing();
