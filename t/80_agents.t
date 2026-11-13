#!/usr/bin/perl
# sub-agents in the event loop, and the status line
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $agent = sub {"///AGENT_f2a8+EO_9d31\n$_[0]\nEO_9d31\nAGENT_f2a8\n"};
my $bash  = sub {"///BASH_7c48+EO_dfd7\n$_[0]\nEO_dfd7\nBASH_7c48\n"};
my $say   = sub {[TestAI::content($_[0]), TestAI::usage(50, 5), TestAI::done()]};
sub run_calls {
    my ($text) = @_;
    my ($n, $p, $r, @printed);
    ($n, $p, $r) = ai::handle_llm_response(\$text, sub {push @printed, $_[0]});
    return ($r, \@printed);
}

# one sub-agent: its own conversation, its own tool loop
{
    my $tmp = TestAI::setup();
    chdir($tmp) or die $!;
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return $say->("<think>plan</think>First.\n///WRITE_edf5+EO_d068+EO_ecde\nsub.txt\nEO_d068\nfrom the agent\nEO_ecde\nWRITE_edf5\n".$bash->('echo "bash:$(cat sub.txt)"'))
            if @$msgs == 2;
        return $say->("The file says: ".($msgs->[-1]{content} =~ m/bash:(.*)/)[0]);
    });
    my ($r, $printed) = run_calls("I delegate.\n".$agent->("write sub.txt and read it back"));
    is(scalar(@$r), 1, "one: one result");
    is($r->[0]{content}, "[AGENT_f2a8 RESULT_d170\nThe file says: from the agent\nRESULT_d170]", "one: the final answer of the agent is the tool result");
    is(ai::slurp("sub.txt"), "from the agent", "one: its tools really ran");
    is(scalar(@TestAI::AGENT_REQUESTS), 2, "one: two requests of its own");
    my $m = $TestAI::AGENT_REQUESTS[0]{messages};
    is(TestAI::roles(@$m), "system,user", "one: starts with system + task");
    is($m->[1]{content}, "write sub.txt and read it back", "one: the task");
    like($m->[0]{content}, qr/You are a master developer.*LIST OF TOOLS.*You are a sub-agent/s, "one: prompt of the session, tools, its role");
    like($m->[0]{content}, qr/^name: bash$/m, "one: has the tools");
    unlike($m->[0]{content}, qr/AGENT_f2a8/, "one: but not the agent tool");
    $m = $TestAI::AGENT_REQUESTS[1]{messages};
    is(TestAI::roles(@$m), "system,user,assistant,user,user", "one: both tool results went back to the model");
    unlike($m->[2]{content}, qr/think/, "one: thinking is not kept");
    like($m->[4]{content}, qr/\A\[BASH_7c48 RESULT_d170\nbash:from the agent/, "one: forked tool result");
    is($printed->[0], "${colors::yellow_color1}[TOOL AGENT_f2a8(...))]${colors::reset_color}\n", "one: announced like a tool");
    is(scalar(@$printed), 2, "one: nothing of the agent itself is printed");
    is(TestAI::roles(ai::load_messages()), "system", "one: its conversation is not in the chat of the session");
    my ($t) = glob("$tmp/aicli/sessions/test/agents/*.chat");
    ok($t, "one: transcript saved");
    is(scalar(() = ai::slurp($t) =~ m/^\{/mg), 6, "one: transcript has the whole conversation");
    is(ai::load_usage()->{requests}, 2, "one: its tokens count for the session");
    is(ai::load_usage()->{total_tokens}, 110, "one: usage as reported");
    is(scalar(keys %agent::RUNNING), 0, "one: no agent left running");
    is(loop::pending(), 0, "one: nothing left in the event loop");
}

# several: at the same time, as many as AI_MAX_AGENTS, results in call order
{
    my $tmp = TestAI::setup(AI_MAX_AGENTS => 2);
    chdir($tmp) or die $!;
    my %delay = (alpha => 0.3, beta => 0.1, gamma => 0.05);
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        my $task = $msgs->[1]{content};
        return $say->($bash->("sleep $delay{$task}; echo $task ran")) if @$msgs == 2;
        return $say->("$task: ".($msgs->[-1]{content} =~ m/\n(.*)\n/)[0]);
    });
    my $t0 = Time::HiRes::time();
    my ($r, $printed) = run_calls(join("and\n", map {$agent->($_)} qw(alpha beta gamma)));
    my $took = Time::HiRes::time() - $t0;
    is_deeply([map {($_->{content} =~ m/\n(.*)\n/)[0]} @$r], ["alpha: alpha ran", "beta: beta ran", "gamma: gamma ran"], "many: results in the order of the calls");
    is($TestAI::MAX_INFLIGHT, 2, "many: AI_MAX_AGENTS at a time");
    is(scalar(@TestAI::AGENT_REQUESTS), 6, "many: all asked twice");
    is($TestAI::AGENT_REQUESTS[1]{messages}[1]{content}, "beta", "many: the 2nd started before the 1st was done");
    ok($took < 0.3 + 0.1 + 0.05 + 0.25, "many: faster than one after the other (".sprintf("%.2fs", $took).")");
    like($printed->[0].$printed->[1].$printed->[2], qr/(?:TOOL AGENT_f2a8.*){3}/s, "many: all announced first");
    is(scalar(@agent::QUEUE), 0, "many: queue empty");
}

# together with other tools
{
    my $tmp = TestAI::setup();
    chdir($tmp) or die $!;
    TestAI::mock_agent_http(sub {$say->("agent answer")});
    my ($r) = run_calls($bash->('echo first').$agent->("x").$bash->('echo last'));
    is_deeply([map {($_->{content} =~ m/\A\[(\w+) \w+\n(.*?)\n/)} @$r], [BASH_7c48 => "first", AGENT_f2a8 => "agent answer", BASH_7c48 => "last"], "mixed: results stay in call order");

    # one alone through execute_tool
    is_deeply([ai::execute_tool("agent", "AGENT_f2a8", ["solo"])], ["agent answer", undef], "solo: as a plain tool");
    like((ai::execute_tool("agent", "AGENT_f2a8", [" "]))[1], qr/no task/, "solo: needs a task");
}

# what can go wrong
{
    my $tmp = TestAI::setup(AI_RETRIES => 2, AI_RETRY_DELAY => 0.01, AI_AGENT_MAX_TURNS => 3);
    chdir($tmp) or die $!;

    # an agent cannot start agents
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return $say->($agent->("deeper")) if @$msgs == 2;
        return $say->("told: ".($msgs->[-1]{content} =~ m/\n(.*)\n/)[0]);
    });
    my ($r) = run_calls($agent->("nest"));
    is($r->[0]{content}, "[AGENT_f2a8 RESULT_d170\ntold: [ERROR] a sub-agent cannot start agents\nRESULT_d170]", "nesting: refused, the agent is told");

    # API errors: retried, then reported
    my $n = 0;
    TestAI::mock_agent_http(sub {$n++ < 2 ? {code => 503, body => '{"error":{"message":"busy"}}'} : $say->("after retries")});
    ($r) = run_calls($agent->("flaky"));
    is($r->[0]{content}, "[AGENT_f2a8 RESULT_d170\nafter retries\nRESULT_d170]", "retry: the agent retries on its own");
    is(scalar(@TestAI::AGENT_REQUESTS), 3, "retry: 3 requests");

    TestAI::mock_agent_http(sub {{code => 401, body => '{"error":{"message":"bad key"}}'}});
    ($r) = run_calls($agent->("denied"));
    like($r->[0]{content}, qr/\A\[AGENT_f2a8 ERROR_9a78\n\[ERROR\] agent \d+ failed: ERROR: bad key\nERROR_9a78\]\z/, "error: reported as tool error");
    is(scalar(@TestAI::AGENT_REQUESTS), 1, "error: 401 is not retried");

    TestAI::mock_agent_http(sub {{code => 500}});
    ($r) = run_calls($agent->("down"));
    is(scalar(@TestAI::AGENT_REQUESTS), 3, "error: 1 + AI_RETRIES attempts");
    like($r->[0]{content}, qr/agent \d+ failed: ERROR: HTTP status 500/, "error: then given up");

    # one fails, the other one is fine
    TestAI::mock_agent_http(sub {$_[0][1]{content} eq 'bad' ? {code => 400, body => '{"error":{"message":"nope"}}'} : $say->("good one")});
    ($r) = run_calls($agent->("bad").$agent->("good"));
    like($r->[0]{content}, qr/ERROR_9a78/, "partial: the failed one is an error");
    like($r->[1]{content}, qr/RESULT_d170\ngood one/, "partial: the other one still answers");

    # never ending tool loop
    TestAI::mock_agent_http(sub {$say->("still busy\n".$bash->('true'))});
    ($r) = run_calls($agent->("forever"));
    is(scalar(@TestAI::AGENT_REQUESTS), 3, "turns: stopped at AI_AGENT_MAX_TURNS");
    like($r->[0]{content}, qr/failed: stopped after 3 tool turns.*Its last answer was:\nstill busy/s, "turns: says so, with the last answer");

    # the transcript is on disk while the agent is still running
    my ($seen, $sent) = (-1, -1);
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        if(@$msgs == 2){
            return $say->("working\n".$bash->('true'));
        }
        my ($t) = (sort glob("$tmp/aicli/sessions/test/agents/*.chat"))[-1]; # the newest agent
        if($seen < 0){
            $seen = $t ? scalar(() = ai::slurp($t) =~ m/^\{/mg) : -1;
            $sent = scalar(@$msgs);
        }
        return $say->("done");
    });
    ($r) = run_calls($agent->("visible"));
    is($seen, $sent, "transcript: as long as the conversation, before the agent is done");

    # a malformed tool call of the agent goes back to the agent
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return $say->("///WRITE_edf5+EO_d068+EO_ecde\nbroken") if @$msgs == 2;
        return $say->(($msgs->[-1]{content} =~ m/malformed tool call/) ? "saw the error" : "saw nothing");
    });
    ($r) = run_calls($agent->("sloppy"));
    like($r->[0]{content}, qr/saw the error/, "malformed: the agent is told");

    # budget
    {
        local $::ORIG_ENV{AI_TOKEN_BUDGET} = 1;
        ai::save_usage({total_tokens => 5});
        TestAI::mock_agent_http(sub {$say->("should not be asked")});
        ($r) = run_calls($agent->("expensive"));
        like($r->[0]{content}, qr/token budget used up/, "budget: no request without budget");
        is(scalar(@TestAI::AGENT_REQUESTS), 0, "budget: nothing asked");
    }
}

# an agent watches its own context window, and counts its tokens
{
    my $tmp = TestAI::setup(AI_CONTEXT_TOKENS => 6000, AI_MAX_TURNS => 20);
    chdir($tmp) or die $!;
    my (@sizes, @status, $spent);
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        push @sizes, ai::estimate_tokens(@$msgs);
        push @status, (values %agent::RUNNING)[0]->status();
        # the API reports what the request really is, like a real one
        $spent += $sizes[-1] + 5;
        my $reply = @sizes > 8 ? "all read" : "step ".scalar(@sizes)."\n".$bash->("seq 1 600");
        return [TestAI::content($reply), TestAI::usage($sizes[-1], 5), TestAI::done()];
    });
    my ($r) = run_calls($agent->("read a lot"));
    is($r->[0]{content}, "[AGENT_f2a8 RESULT_d170\nall read\nRESULT_d170]", "context: the agent gets to the end");
    is(scalar(@sizes), 9, "context: 9 requests");
    ok(!grep({$_ > 6000 * 0.8} @sizes), "context: no request over the threshold (biggest: ".(sort {$b <=> $a} @sizes)[0]." of 6000)");
    my $last = $TestAI::AGENT_REQUESTS[-1]{messages};
    is($last->[0]{role}, "system", "context: the system prompt stays");
    is($last->[1]{content}, "read a lot", "context: the task stays");
    my $all = join("\n", map {$_->{content}} @$last);
    like($all, qr/characters of old tool output removed to save context|earlier steps of your work on this task were removed/, "context: old tool output was cut or old steps dropped");
    like($last->[-1]{content}, qr/\A\[BASH_7c48 RESULT_d170\n1\n2\n.*\n600\n/s, "context: the newest result is whole");
    unlike($status[0], qr/tok/, "tokens: nothing yet at the first request");
    my $first = $sizes[0] + 5;
    my $shown = sprintf("%.1fk", $first / 1000);
    like($status[1], qr/, turn 1, \Q$shown\E tok\z/, "tokens: counted in the status line after the first answer");
    like($status[-1], qr/, turn 8, \d+k tok\z/, "tokens: and summed up");
    is(ai::load_usage()->{total_tokens}, $spent, "tokens: all of it is in the usage of the session");

    my $a = agent->new("x");
    is($a->compact(), 0, "compact: nothing to do for a new agent");
    is($a->compact(1), 0, "compact: also not when forced, with only the task there");
    $a->{tokens} = 1234;
    like($a->status(), qr/1\.2k tok/, "tokens: thousands");
    $a->{tokens} = 45_678;
    like($a->status(), qr/45k tok/, "tokens: many thousands");
}
{
    # the size of the window is not known: the error of the API starts it
    my $tmp = TestAI::setup(AI_MAX_TURNS => 20);
    chdir($tmp) or die $!;
    my $refused = 0;
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        my $turns = grep {$_->{role} eq 'assistant'} @$msgs;
        return $say->("step\n".$bash->("seq 1 400")) if $turns < 3 and !$refused;
        return {code => 400, body => '{"error":{"message":"the request exceeds the available context size"}}'} unless $refused++;
        return $say->("done with ".scalar(@$msgs)." messages");
    });
    my ($r) = run_calls($agent->("too much"));
    like($r->[0]{content}, qr/RESULT_d170\ndone with \d+ messages/, "context error: the agent makes room and goes on");
    my ($before, $after) = map {ai::estimate_tokens(@{$_->{messages}})} @TestAI::AGENT_REQUESTS[-2, -1];
    ok($after < $before, "context error: the next request is smaller ($before -> $after tokens)");
    TestAI::mock_agent_http(sub {{code => 400, body => '{"error":{"message":"maximum context length is 5 tokens"}}'}});
    ($r) = run_calls($agent->("hopeless"));
    like($r->[0]{content}, qr/agent \d+ failed: ERROR: maximum context length/, "context error: with nothing to remove it is an error");
    is(scalar(@TestAI::AGENT_REQUESTS), 1, "context error: and not asked again");
}

# ctrl-C: requests, tools and queued agents all stop
{
    my $tmp = TestAI::setup(AI_MAX_AGENTS => 2);
    chdir($tmp) or die $!;
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return 60 if $msgs->[1]{content} eq 'hangs';                            # a request that hangs
        return $say->($bash->('echo $$ > tool.pid; exec sleep 60')) if @$msgs == 2; # a tool that hangs
        return $say->("not reached");
    });
    local $SIG{ALRM} = sub {$::ABORT = 1};
    my $t0 = Time::HiRes::time();
    alarm(1);
    my ($r) = run_calls($agent->("hangs").$agent->("tool").$agent->("queued"));
    alarm(0);
    my $took = Time::HiRes::time() - $t0;
    $::ABORT = 0;
    ok($took < 5, "abort: back in ".sprintf("%.1fs", $took));
    like($r->[$_]{content}, qr/ERROR_9a78\n\[ERROR\] agent \d+ failed: interrupted/, "abort: agent ".($_ + 1)." interrupted") for 0 .. 2;
    is(scalar(@TestAI::AGENT_REQUESTS), 2, "abort: the queued one never asked");
    is(loop::pending(), 0, "abort: event loop is empty");
    is(scalar(keys %agent::RUNNING) + scalar(@agent::QUEUE), 0, "abort: no agent left");
    my $pid = ai::slurp("$tmp/tool.pid") // '';
    like($pid, qr/^\d+$/, "abort: the tool was running");
    ok(!kill(0, $pid + 0), "abort: the tool process is gone");
}

# the status line
{
    my $tmp = TestAI::setup();
    my $fn = "$tmp/tty";
    my $screen = sub {my $s = ai::slurp($fn) // ''; utf8::decode($s); $s};
    open(my $fh, '>', $fn) or die $!;
    ok(!tui->new(fh => $fh)->enabled(), "tui: off when the output is not a terminal");
    my $tui = tui->new(fh => $fh, enabled => 1, width => 40, interval => 0);
    $tui->draw();
    is($screen->(), "", "tui: nothing to show, nothing drawn");
    $tui->set(model => "waiting for model");
    is($tui->line(), "\x{280B} waiting for model", "tui: spinner and text");
    $tui->draw();
    is($screen->(), "\r\e[2K\e[0;36m\x{280B} waiting for model\e[0m", "tui: drawn in place, in color, as UTF-8");
    $tui->tick();
    like($screen->(), qr/\x{2819} waiting for model\e\[0m\z/, "tui: tick animates the spinner");
    $tui->set("agent 1" => sub {"agent 1: thinking"});
    $tui->set("agent 2" => "agent 2: bash");
    is($tui->line(), "\x{2819} waiting for model \x{2502} agent 1: thinkin\x{2026}", "tui: items side by side, cut to the width");
    is(length($tui->line()), 39, "tui: never wraps");
    $tui->unset("model");
    $tui->{width} = 200;
    is($tui->line(), "\x{2819} agent 1: thinking \x{2502} agent 2: bash", "tui: item removed");
    $tui->{items}{"agent 1"}{since} -= 75;
    $tui->{items}{"agent 2"}{since} -= 5;
    like($tui->line(), qr/agent 1: thinking 1m15s \x{2502} agent 2: bash 5s/, "tui: how long an item is there");
    $tui->set("agent 2" => "caf\xc3\xa9 \n multi\tline");
    like($tui->line(), qr/caf\x{e9} multi line 5s/, "tui: bytes are decoded, whitespace is flattened, the clock goes on");
    $tui->draw();
    $tui->clear();
    like($screen->(), qr/\r\e\[2K\z/, "tui: clear wipes the line");
    my $size = -s $fn;
    $tui->clear();
    is(-s $fn, $size, "tui: clear does nothing when nothing is drawn");
    $tui->unset("agent 1");
    $tui->unset("agent 2");
    $tui->tick();
    is(-s $fn, $size, "tui: no items, no drawing");

    # agents show up in it while they work, and it is gone afterwards
    truncate($fh, 0);
    seek($fh, 0, 0);
    local $ai::TUI = tui->new(fh => $fh, enabled => 1, width => 200, interval => 0);
    local $loop::on_tick = sub {$ai::TUI->tick()};
    local $loop::on_idle = sub {$ai::TUI->clear()};
    chdir($tmp) or die $!;
    TestAI::mock_agent_http(sub {
        my ($msgs) = @_;
        return [TestAI::reasoning("hm"), TestAI::content($bash->('sleep 0.3')), TestAI::done()] if @$msgs == 2;
        return $say->("ok");
    }, delay => 0.15);
    run_calls($agent->("a").$agent->("b"));
    my $s = $screen->();
    like($s, qr/agent \d+: waiting for model \x{2502} agent \d+: waiting for model/, "status: both agents, waiting");
    like($s, qr/agent \d+: bash, turn 1/, "status: what an agent is doing");
    like($s, qr/\r\e\[2K\z/, "status: wiped when the agents are done");
    is(scalar(@{$ai::TUI->{order}}), 0, "status: no item left");
    unlike($s, qr/\n/, "status: never a newline, it stays on one line");
}

chdir("/");
done_testing();
