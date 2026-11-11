#!/usr/bin/perl
# retry with backoff, rate limits, token usage and budget, context management
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $ok = sub {[TestAI::content($_[0] // "fine"), TestAI::done()]};
my $bash = sub {"///BASH_7c48+EO_dfd7\n$_[0]\nEO_dfd7\nBASH_7c48\n"};

# durations in rate limit headers
{
    is(ai::parse_duration("12"), 12, "duration: seconds");
    is(ai::parse_duration("0.5"), 0.5, "duration: fraction");
    is(ai::parse_duration("6m0s"), 360, "duration: go style");
    is(ai::parse_duration("1h2m3s"), 3723, "duration: hours");
    is(ai::parse_duration("250ms"), 0.25, "duration: ms");
    is(ai::parse_duration("Wed, 21 Oct 2015 07:28:00 GMT"), undef, "duration: a date is not understood");
    is(ai::parse_duration(undef), undef, "duration: nothing");
    my $d = ai::parse_duration(time() + 30);
    ok($d > 28 && $d <= 30, "duration: epoch seconds");
    $d = ai::parse_duration((time() + 30) * 1000);
    ok($d > 28 && $d <= 30, "duration: epoch milliseconds");

    is(ai::rate_limit_wait({'retry-after' => 7, 'x-ratelimit-reset-requests' => '1s'}), 7, "wait: retry-after wins");
    is(ai::rate_limit_wait({'retry-after-ms' => 1500, 'retry-after' => 7}), 1.5, "wait: retry-after-ms first");
    is(ai::rate_limit_wait({'x-ratelimit-reset-requests' => '2s', 'x-ratelimit-reset-tokens' => '6m0s'}), 2, "wait: soonest reset");
    is(ai::rate_limit_wait({}), undef, "wait: not told");
    $d = ai::rate_limit_wait({}, {error => {metadata => {headers => {'X-RateLimit-Reset' => (time() + 20) * 1000}}}});
    ok($d > 18 && $d <= 20, "wait: openrouter error metadata");
}

# what kind of error
{
    my $c = ai::classify_error(429, {error => {message => "slow down"}}, "", {'retry-after' => 3});
    is_deeply($c, {code => 429, retryable => 1, wait => 3}, "classify: 429 with retry-after");
    ok(ai::classify_error($_, undef, "", {})->{retryable}, "classify: $_ is retryable") for 0, 408, 500, 502, 503, 504, 529;
    ok(!ai::classify_error($_, undef, "", {})->{retryable}, "classify: $_ is not") for 400, 401, 403, 404, 422;
    ok(ai::classify_error(200, {error => {message => "Overloaded"}}, "", {})->{retryable}, "classify: overloaded in a stream");
    is(ai::classify_error(200, {error => {code => 429, message => "x"}}, "", {})->{code}, 429, "classify: code of the error body");
    $c = ai::classify_error(400, {error => {message => "This model's maximum context length is 8192 tokens"}}, "", {});
    ok($c->{context} && !$c->{retryable}, "classify: context length");
    ok(ai::classify_error(400, undef, "the request exceeds the available context size", {})->{context}, "classify: llama.cpp context message");
}

# retry with backoff
{
    TestAI::setup(AI_RETRIES => 3, AI_RETRY_DELAY => 0.01);
    TestAI::mock_http(TestAI::fail(503, '{"error":{"message":"busy"}}'), TestAI::fail(0), $ok->("at last"));
    my $out = TestAI::capture {ai::chat_completion("hi")};
    is(scalar(@TestAI::REQUESTS), 3, "retry: two failures, then success");
    like($out, qr/ERROR: busy.*\[retry 1 of 3 in.*\[retry 2 of 3 in.*at last/s, "retry: said so");
    is(TestAI::roles(ai::load_messages()), "system,user,assistant", "retry: one user message, one answer");
    is(TestAI::roles(@{TestAI::sent_messages(2)}), "system,user", "retry: the same request again");

    # gives up
    TestAI::mock_http(map {TestAI::fail(500)} 1 .. 4);
    $out = TestAI::capture {ai::chat_completion("again")};
    is(scalar(@TestAI::REQUESTS), 4, "retry: 1 + AI_RETRIES attempts");
    like($out, qr/retry 3 of 3.*ERROR: HTTP status 500/s, "retry: final error shown");
    is((ai::load_messages())[-1]{content}, "again", "retry: user message kept");

    # not everything is worth a retry
    TestAI::mock_http(TestAI::fail(401, '{"error":{"message":"bad key"}}'));
    $out = TestAI::capture {ai::chat_completion("auth")};
    is(scalar(@TestAI::REQUESTS), 1, "retry: not for 401");
    like($out, qr/ERROR: bad key/, "retry: error shown");

    # an answer that already started is kept, not asked again
    TestAI::mock_http([TestAI::content("half an ans"), TestAI::sse({error => {message => "Overloaded"}})]);
    $out = TestAI::capture {ai::chat_completion("partial")};
    is(scalar(@TestAI::REQUESTS), 1, "retry: not after a partial answer");
    is((ai::load_messages())[-1]{content}, "half an ans", "retry: partial answer kept");

    # backoff grows, with jitter, and is capped
    local $::ORIG_ENV{AI_RETRY_DELAY} = 2;
    my @d = map {ai::retry_delay($_)} 1 .. 8;
    ok($d[0] >= 1.5 && $d[0] <= 2.5, "backoff: first ~2s");
    ok($d[2] >= 6 && $d[2] <= 10, "backoff: third ~8s");
    ok($d[7] <= 75, "backoff: capped");
    is(ai::retry_delay(3, 1.5), 1.6, "backoff: what the API asks for wins");
}

# rate limits
{
    TestAI::setup(AI_RETRIES => 2, AI_RETRY_DELAY => 30);
    TestAI::mock_http(TestAI::fail(429, '{"error":{"message":"rate limit"}}', 'retry-after' => '0.4'), $ok->());
    my $t0 = Time::HiRes::time();
    my $out = TestAI::capture {ai::chat_completion("hi")};
    my $took = Time::HiRes::time() - $t0;
    is(scalar(@TestAI::REQUESTS), 2, "rate limit: retried");
    ok($took >= 0.4 && $took < 5, "rate limit: waited what Retry-After says (".sprintf("%.2fs", $took).")");

    # too long to wait for
    TestAI::mock_http(TestAI::fail(429, '{"error":{"message":"daily limit"}}', 'retry-after' => '3600'));
    $out = TestAI::capture {ai::chat_completion("more")};
    is(scalar(@TestAI::REQUESTS), 1, "rate limit: no retry when the wait is too long");
    like($out, qr/ERROR: daily limit \(asked to wait 3600s, more than AI_RETRY_MAX_WAIT=120\)/, "rate limit: says why");

    # ctrl-C ends the wait
    TestAI::mock_http(TestAI::fail(429, undef, 'retry-after' => '60'), $ok->());
    local $SIG{ALRM} = sub {$::ABORT = 1};
    $t0 = Time::HiRes::time();
    alarm(1);
    $out = TestAI::capture {ai::chat_completion("wait")};
    alarm(0);
    $::ABORT = 0;
    ok(Time::HiRes::time() - $t0 < 4, "rate limit: ctrl-C stops waiting");
    is(scalar(@TestAI::REQUESTS), 1, "rate limit: no request after ctrl-C");
}

# token usage
{
    my $tmp = TestAI::setup(AI_SHOW_USAGE => 1);
    TestAI::mock_http([TestAI::content("Hello"), TestAI::usage(100, 20), TestAI::done()]);
    my $out = TestAI::capture {ai::chat_completion("hi")};
    ok(JSON::XS::decode_json($TestAI::REQUESTS[0]{data})->{stream_options}{include_usage}, "usage: asked for in the request");
    like($out, qr/\[tokens: 100 in \+ 20 out, session 120 \| \d+\.\ds/, "usage: line after the answer");
    my $u = ai::load_usage();
    is_deeply([@{$u}{qw(requests prompt_tokens completion_tokens total_tokens)}], [1, 100, 20, 120], "usage: counted");
    ok($u->{chars_per_token} > 1.5, "usage: token size learned ($u->{chars_per_token} chars)");
    ok(!$u->{estimated}, "usage: not estimated");

    # a tool turn counts twice, the server does not always report
    TestAI::mock_http([TestAI::content($bash->('true')), TestAI::usage(200, 30), TestAI::done()], $ok->("done"));
    $out = TestAI::capture {ai::chat_completion("tool")};
    $u = ai::load_usage();
    is($u->{requests}, 3, "usage: every request counted");
    ok($u->{estimated}, "usage: marked as estimated when the API does not report");
    like($out, qr/\[tokens: ~\d+ in \+ \d+ out, session \d+/, "usage: estimate is marked with ~");
    ok($u->{total_tokens} > 350, "usage: estimate added ($u->{total_tokens})");

    my ($r, $o);
    $o = TestAI::capture {$r = ai::handle_command("/usage")};
    like($o, qr/^requests:   3\ntokens:     ~\d+ in \+ \d+ out = $u->{total_tokens}\ncontext:    ~\d+ tokens in \d+ messages/, "/usage: shows it");
    $o = TestAI::capture {ai::handle_command("/usage reset")};
    is(ai::load_usage()->{total_tokens} // 0, 0, "/usage reset: counters gone");
    ok(ai::load_usage()->{chars_per_token}, "/usage reset: token size kept");

    # per session
    TestAI::capture {ai::handle_command("/session create other")};
    is(ai::load_usage()->{requests} // 0, 0, "usage: is per session");
}
{
    TestAI::setup(AI_USAGE => 0, AI_SHOW_USAGE => 0);
    TestAI::mock_http($ok->());
    my $out = TestAI::capture {ai::chat_completion("hi")};
    ok(!exists JSON::XS::decode_json($TestAI::REQUESTS[0]{data})->{stream_options}, "AI_USAGE=0: not asked for");
    unlike($out, qr/tokens:/, "AI_SHOW_USAGE=0: no line");
}

# token budget
{
    TestAI::setup(AI_TOKEN_BUDGET => 500, AI_SHOW_USAGE => 1);
    TestAI::mock_http(
        [TestAI::content($bash->('echo 1')), TestAI::usage(200, 100), TestAI::done()],
        [TestAI::content($bash->('echo 2')), TestAI::usage(250, 100), TestAI::done()],
        $ok->("never asked"),
    );
    my $out = TestAI::capture {ai::chat_completion("go")};
    is(scalar(@TestAI::REQUESTS), 2, "budget: the tool loop stops when it is used up");
    like($out, qr/session 300 of 500/, "budget: shown in the usage line");
    like($out, qr/token budget used up: 650 of 500 tokens/, "budget: said so");
    TestAI::mock_http($ok->());
    $out = TestAI::capture {ai::chat_completion("more")};
    is(scalar(@TestAI::REQUESTS), 0, "budget: no new request");
    isnt((ai::load_messages())[-1]{content}, "more", "budget: refused input is not saved");
    TestAI::capture {ai::handle_command("/usage reset")};
    $out = TestAI::capture {ai::chat_completion("more")};
    is(scalar(@TestAI::REQUESTS), 1, "budget: works again after /usage reset");
}

# context management
my $big_tool = sub {{role => 'user', content => "[BASH_7c48 RESULT_d170\n".("$_[0] output line\n" x 300)."RESULT_d170]"}};
{
    # old tool output goes first, without asking the model
    my $tmp = TestAI::setup(AI_CONTEXT_TOKENS => 6000);
    ai::write_messages({role => 'system', content => 'sys'},
        {role => 'user', content => 'first task'},
        (map {({role => 'assistant', content => "call $_"}, $big_tool->($_))} 1 .. 4),
        {role => 'assistant', content => 'all done'});
    my $before = ai::estimate_tokens(ai::load_messages());
    ok($before > 6000 * 0.8, "context: over the threshold ($before tokens)");
    TestAI::mock_http($ok->("ok"));
    my $out = TestAI::capture {ai::chat_completion("next task")};
    is(scalar(@TestAI::REQUESTS), 1, "prune: no summary request needed");
    like($out, qr/\[context: old tool output removed from \d+ messages, ~\d+ -> ~\d+ tokens\]/, "prune: said so");
    my @msgs = ai::load_messages();
    is(scalar(@msgs), 13, "prune: no message removed");
    like($msgs[3]{content}, qr/\A\[BASH_7c48 RESULT_d170\n1 output line\n.*\[\.\.\. \d+ characters of old tool output removed to save context \.\.\.\].*RESULT_d170\]\z/s, "prune: tool result cut, still a result");
    ok(ai::estimate_tokens(@{TestAI::sent_messages(0)}) < 6000 * 0.8, "prune: the request fits");
    is($msgs[1]{content}, "first task", "prune: the rest is untouched");
    like(ai::slurp("$tmp/aicli/sessions/test/chat.archive"), qr/(?:1 output line\\n){300}/, "prune: full output is in the archive");
}
{
    # a long conversation is summarized by the model
    my $tmp = TestAI::setup(AI_CONTEXT_TOKENS => 6000);
    my @old = map {({role => 'user', content => "question $_ ".("lorem ipsum " x 150)}, {role => 'assistant', content => "answer $_ ".("dolor sit " x 150)})} 1 .. 8;
    ai::write_messages({role => 'system', content => 'sys'}, @old);
    TestAI::mock_http($ok->("<think>hm</think>The user asked 8 things about lorem."), $ok->("and the answer"));
    my $out = TestAI::capture {ai::chat_completion("question 9")};
    is(scalar(@TestAI::REQUESTS), 2, "summary: one request for the summary, one for the answer");
    my $sreq = TestAI::sent_messages(0);
    is(TestAI::roles(@$sreq), "system,user", "summary: own small conversation");
    like($sreq->[1]{content}, qr/\AUSER:\nquestion 1 .*ASSISTANT:\nanswer 1 .*Summarize the conversation above/s, "summary: transcript of the old part");
    unlike($out, qr/The user asked 8 things/, "summary: not printed");
    like($out, qr/\[context: summarizing \d+ older messages\.\.\.\].*\[context: summarized \d+ older messages, ~\d+ -> ~\d+ tokens\]/s, "summary: said so");
    my @msgs = ai::load_messages();
    is($msgs[0]{content}, "sys", "summary: system prompt kept");
    is($msgs[1]{content}, "[Summary of the conversation so far, the older messages were removed to save context]\nThe user asked 8 things about lorem.", "summary: replaces the old part");
    is($msgs[-2]{content}, "question 9", "summary: the new input is still there");
    is($msgs[-1]{content}, "and the answer", "summary: and answered");
    ok(scalar(@msgs) < 12, "summary: fewer messages (".scalar(@msgs).")");
    like($msgs[-3]{content}, qr/^answer 8 /, "summary: recent messages kept as they are");
    my $sent = TestAI::sent_messages(1);
    ok(ai::estimate_tokens(@$sent) < 6000 * 0.8, "summary: the request fits");
    like(ai::slurp("$tmp/aicli/sessions/test/chat.archive"), qr/question 1 lorem/, "summary: removed messages are archived");
    is(ai::load_usage()->{requests}, 2, "summary: its tokens are counted too");

    # nothing to do when it fits
    TestAI::mock_http($ok->());
    $out = TestAI::capture {ai::chat_completion("small")};
    unlike($out, qr/context:/, "fits: nothing compacted");
    is(scalar(@TestAI::REQUESTS), 1, "fits: one request");
}
{
    # without a summary: AI_CONTEXT_SUMMARY=0, or the summary fails
    foreach my $case (['AI_CONTEXT_SUMMARY=0', {AI_CONTEXT_SUMMARY => 0}, 1], ['failing summary', {}, 2]){
        my ($name, $env, $requests) = @$case;
        TestAI::setup(AI_CONTEXT_TOKENS => 6000, %$env);
        ai::write_messages({role => 'system', content => 'sys'},
            map {({role => 'user', content => "q$_ ".("x y " x 400)}, {role => 'assistant', content => "a$_ ".("z " x 800)})} 1 .. 8);
        TestAI::mock_http(($requests == 2 ? (TestAI::fail(400, '{"error":{"message":"no"}}')) : ()), $ok->("answer"));
        my $out = TestAI::capture {ai::chat_completion("q9")};
        is(scalar(@TestAI::REQUESTS), $requests, "$name: requests");
        like($out, qr/\[context: dropped \d+ older messages/, "$name: dropped");
        my @msgs = ai::load_messages();
        is($msgs[1]{content}, "[The older messages of this conversation were removed to save context]", "$name: note for the model");
        is($msgs[-1]{content}, "answer", "$name: the chat goes on");
    }
}
{
    # unknown context size: the "too long" error of the API starts it
    TestAI::setup();
    is(ai::context_limit(), 0, "reactive: context size unknown");
    ai::write_messages({role => 'system', content => 'sys'},
        map {({role => 'user', content => "q$_ ".("x y " x 400)}, {role => 'assistant', content => "a$_ ".("z " x 800)})} 1 .. 8);
    TestAI::mock_http(
        TestAI::fail(400, '{"error":{"message":"the request exceeds the available context size, try increasing it"}}'),
        $ok->("short summary"),
        $ok->("now it fits"),
    );
    my $out = TestAI::capture {ai::chat_completion("q9")};
    is(scalar(@TestAI::REQUESTS), 3, "reactive: failed request, summary, request again");
    like($out, qr/context: summarized/, "reactive: compacted");
    unlike($out, qr/ERROR/, "reactive: no error for the user");
    is((ai::load_messages())[-1]{content}, "now it fits", "reactive: answered");

    # only once per input
    # (the request, the summary, the request again: all refused)
    TestAI::mock_http(map {TestAI::fail(400, '{"error":{"message":"maximum context length is 10 tokens"}}')} 1 .. 3);
    ai::append_messages(map {{role => 'user', content => "more ".("w " x 2000)}} 1 .. 4);
    $out = TestAI::capture {ai::chat_completion("again")};
    like($out, qr/ERROR: maximum context length/, "reactive: gives up when it does not help");
    is(scalar(@TestAI::REQUESTS), 3, "reactive: compacted only once per input");
}

# /compact, and the context size from the API
{
    TestAI::setup();
    ai::write_messages({role => 'system', content => 'sys'},
        map {({role => 'user', content => "q$_ ".("x y " x 200)}, {role => 'assistant', content => "a$_ ".("z " x 400)})} 1 .. 6);
    TestAI::mock_http($ok->("the summary"));
    my $out = TestAI::capture {ai::handle_command("/compact")};
    like($out, qr/context: summarized \d+ older messages/, "/compact: summarized");
    like((ai::load_messages())[1]{content}, qr/the summary\z/, "/compact: summary in the conversation");
    ai::handle_command("/clear");
    TestAI::mock_http();
    $out = TestAI::capture {ai::handle_command("/compact")};
    like($out, qr/Nothing to compact/, "/compact: nothing to do on an empty chat");

    TestAI::mock_http(sub {'{"data":[{"id":"m-small","context_length":8192},{"id":"m-llama","meta":{"n_ctx":4096}},{"id":"m-unknown"}]}'});
    ai::fetch_models();
    TestAI::capture {ai::handle_command("/model m-small")};
    is(ai::context_limit(), 8192, "context size: from the model list (context_length)");
    TestAI::capture {ai::handle_command("/model m-llama")};
    is(ai::context_limit(), 4096, "context size: from the model list (meta.n_ctx)");
    TestAI::capture {ai::handle_command("/model m-unknown")};
    is(ai::context_limit(), 0, "context size: unknown");
    TestAI::mock_http(sub {'{"default_generation_settings":{"n_ctx":16384}}'});
    is(ai::fetch_server_context(), 16384, "context size: llama.cpp /props");
    like($TestAI::REQUESTS[0]{url}, qr{/props$}, "context size: asked at /props");
    is(ai::context_limit(), 16384, "context size: server value is the fallback");
    {
        local $::ORIG_ENV{AI_CONTEXT_TOKENS} = 1000;
        is(ai::context_limit(), 1000, "context size: AI_CONTEXT_TOKENS wins");
        local $::ORIG_ENV{AI_CONTEXT_TOKENS} = 0;
        is(ai::context_limit(), 0, "context size: 0 switches it off");
    }
    %ai::MODEL_CONTEXT = ();
    $ai::SERVER_CONTEXT = undef;
}

done_testing();
