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
