#!/usr/bin/perl
# end to end: real HTTP (curl) against a fake LLM server, in-process and ai.pl
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;
use FakeLLM;

plan(skip_all => "needs Net::Curl or WWW::Curl")
    unless Net::Curl::Easy->can('new') or WWW::Curl::Easy->can('new');

my $url = FakeLLM::start();
my $tmp = TestAI::setup(AI_LOCAL_SERVER => $url, AI_API_KEY => 'sk-e2e', AI_MODEL => 'fake-1');
my ($Y, $G, $R) = ($colors::yellow_color1, $colors::green_color, $colors::reset_color);

# the whole loop: thinking, tool call, tool result, final answer
{
    my $out = TestAI::capture {ai::chat_completion("go")};
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,assistant", "loop: conversation complete");
    is($msgs[3]{content}, "[BASH_7c48 RESULT_d170\ne2e-42\n\nRESULT_d170]", "loop: the tool ran");
    is($msgs[4]{content}, "The tool said: e2e-42 (messages: 4, model: fake-1, auth: Bearer sk-e2e)", "loop: the model got result, history, model and key");
    like($out, qr/\A\Q${Y}The user wants ${R}${Y}a command.${R}\E\n\Q${G}I will run\E/, "loop: thinking shown before the answer");
    like($out, qr/\Q${G}The tool said: e2e-42\E/, "loop: final answer shown");
}

# models
{
    is_deeply(ai::fetch_models(), ["fake-1", "fake-2"], "models: fetched");
    my $out = TestAI::capture {ai::handle_command("/model")};
    like($out, qr/\* fake-1.*  fake-2/s, "models: /model lists them");
}

# API errors don't kill the chat
{
    my $out = TestAI::capture {ai::chat_completion("fail please")};
    like($out, qr/ERROR: 429: rate limit of the fake/, "error: HTTP 429 body shown");
    is((ai::load_messages())[-1]{content}, "fail please", "error: user message kept");
    ai::handle_command("/clear");
}

# ctrl-C while the server is silent: back within the select() tick
{
    local $SIG{ALRM} = sub {$::ABORT = 1};
    my $t0 = Time::HiRes::time();
    alarm(1);
    my $out = TestAI::capture {ai::chat_completion("slow please")};
    alarm(0);
    my $took = Time::HiRes::time() - $t0;
    $::ABORT = 0;
    like($out, qr/let me think for a long time/, "abort: got the start of the stream");
    like($out, qr/\[interrupted\]/, "abort: interrupted");
    ok($took < 5, "abort: back after ".sprintf("%.1fs", $took));
    ai::handle_command("/clear");
}

# rate limit: the Retry-After header of the real response is honoured
{
    local $::ORIG_ENV{AI_RETRIES} = 2;
    local $::ORIG_ENV{AI_RETRY_DELAY} = 30;
    my $t0 = Time::HiRes::time();
    my $out = TestAI::capture {ai::chat_completion("limited $tmp/limit")};
    my $took = Time::HiRes::time() - $t0;
    like($out, qr/ERROR: 429: rate limit of the fake.*\[retry 1 of 2 in 1\.1s/s, "rate limit: waits what the server says");
    like($out, qr/The tool said: e2e-42/, "rate limit: then goes on");
    ok($took >= 1 && $took < 10, "rate limit: took ".sprintf("%.1fs", $took));
    is($utils::http_headers{'content-type'}, "text/event-stream", "response headers are read");
    ai::handle_command("/clear");
}

# token usage as reported by the server, context size of the server
{
    TestAI::capture {ai::handle_command("/usage reset")};
    local $::ORIG_ENV{AI_SHOW_USAGE} = 1;
    my $out = TestAI::capture {ai::chat_completion("go")};
    like($out, qr/\[tokens: 200 in \+ 7 out, session 207 \|.*\[tokens: 400 in \+ 7 out, session 614 \|/s, "usage: from the stream, per request");
    is(ai::load_usage()->{total_tokens}, 614, "usage: counted");
    is(ai::fetch_server_context(), 4096, "context size: from /props");
    $ai::SERVER_CONTEXT = undef;
    ai::handle_command("/clear");
}

# sub-agents: two conversations and their tools at the same time, real HTTP
{
    my $t0 = Time::HiRes::time();
    my $out = TestAI::capture {ai::chat_completion("agents please")};
    my $took = Time::HiRes::time() - $t0;
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,user,assistant", "agents: two results for the model");
    like($msgs[3]{content}, qr/\A\[AGENT_f2a8 RESULT_d170\nThe tool said: A-done by \d+ \(messages: 4,/, "agents: answer of the 1st, it ran its own tool loop");
    like($msgs[4]{content}, qr/\A\[AGENT_f2a8 RESULT_d170\nThe tool said: B-done by \d+ /, "agents: answer of the 2nd, in call order");
    my ($pa) = $msgs[3]{content} =~ m/A-done by (\d+)/;
    my ($pb) = $msgs[4]{content} =~ m/B-done by (\d+)/;
    isnt($pa, $pb, "agents: each ran its own bash");
    ok($took >= 2 && $took < 3.7, "agents: 2 x 2s of work in ".sprintf("%.1fs", $took).", so side by side");
    unlike($out, qr/on it|sleep 2/, "agents: their thinking and tool calls are not printed");
    my @transcripts = glob("$tmp/aicli/sessions/test/agents/*.chat");
    is(scalar(@transcripts), 2, "agents: transcripts saved");
    ai::handle_command("/clear");
}

# the same connection handle keeps working after errors and aborts
{
    my $out = TestAI::capture {ai::chat_completion("go again")};
    like($out, qr/The tool said: e2e-42/, "reuse: loop works again");
}

# nobody listening
{
    local $ai::AI_URL = "http://127.0.0.1:1/v1/chat/completions";
    my $out = TestAI::capture {ai::chat_completion("anyone?")};
    like($out, qr/ERROR: \S/, "refused: error shown, no die");
}

# and the real thing: ai.pl as a process
{
    delete local @ENV{qw(AI_PROXY HTTPS_PROXY HTTP_PROXY https_proxy http_proxy)};
    local $ENV{AI_DIR} = "$tmp/e2e";
    local $ENV{AI_CONFIG} = "$tmp/noconfig";
    local $ENV{AI_LOCAL_SERVER} = $url;
    local $ENV{AI_SESSION} = "e2e";
    local $ENV{AI_PROMPT_TEMPLATE} = "coder";
    delete local @ENV{qw(AI_API_KEY AI_PROVIDER AI_MODEL AI_CLEAR DEBUG)};
    ai::spew("$tmp/input", "/model fake-2\n/pwd\nplease run it\n/exit\nnot reached\n");
    my $out = `$^X $TestAI::ROOT/ai.pl < $tmp/input 2>&1`;
    is($?, 0, "ai.pl: exit 0");
    like($out, qr/Switched model to 'fake-2'/, "ai.pl: command ran");
    (my $plain = $out) =~ s/\e\[[0-9;]*m//g;
    like($plain, qr/The tool said: e2e-42 \(messages: 4, model: fake-2, auth: none\)/, "ai.pl: agent loop end to end");
    local $ai::STATUS_FILE = "$tmp/e2e/sessions/e2e/chat";
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,assistant", "ai.pl: conversation saved, commands are not in it");
    is($msgs[1]{content}, "please run it\n", "ai.pl: the user input");
    unlike($out, qr/not reached/, "ai.pl: /exit ends it");
}

FakeLLM::stop();
done_testing();
