#!/usr/bin/perl
# ai.pl -p (one request, exit code) and -c (continue the session of this directory)
use strict; use warnings;

use Test::More;
use FindBin;
use POSIX ();
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;
use FakeLLM;

my $ok   = sub {[TestAI::content($_[0] // "fine"), TestAI::done()]};
my $bash = sub {"///BASH_7c48+EO_dfd7\n$_[0]\nEO_dfd7\nBASH_7c48\n"};

# chat_completion tells how it went
{
    TestAI::setup(AI_MAX_TURNS => 2);
    TestAI::mock_http($ok->());
    my $r;
    TestAI::capture {$r = ai::chat_completion("hi")};
    ok($r, "result: true after an answer");
    TestAI::mock_http(undef);
    TestAI::capture {$r = ai::chat_completion("hi")};
    ok(!$r, "result: false after an error");
    TestAI::mock_http(map {[TestAI::content($bash->('true')), TestAI::done()]} 1 .. 3);
    TestAI::capture {$r = ai::chat_completion("loop")};
    ok(!$r, "result: false when the turn limit stopped it");
    TestAI::mock_http([TestAI::content($bash->('echo x')), TestAI::done()], $ok->());
    TestAI::capture {$r = ai::chat_completion("tool")};
    ok($r, "result: true after tools and an answer");
    {
        local $::ORIG_ENV{AI_TOKEN_BUDGET} = 1;
        ai::save_usage({total_tokens => 5});
        TestAI::capture {$r = ai::chat_completion("no budget")};
        ok(!$r, "result: false without token budget");
    }

    # one_shot turns that into an exit code
    TestAI::mock_http($ok->("the answer"));
    my $out = TestAI::capture {$r = ai::one_shot("question")};
    is($r, 0, "one_shot: 0 for an answer");
    like($out, qr/the answer/, "one_shot: answer printed");
    TestAI::mock_http(undef);
    TestAI::capture {$r = ai::one_shot("question")};
    is($r, 1, "one_shot: 1 for an error");
    TestAI::mock_http();
    TestAI::capture {$r = ai::one_shot("  \n")};
    is($r, 1, "one_shot: 1 for an empty prompt");
    is(scalar(@TestAI::REQUESTS), 0, "one_shot: and nothing is asked");
    TestAI::mock_http(sub {$::ABORT = 1; $utils::http_error = "interrupted"; return});
    TestAI::capture {$r = ai::one_shot("stop")};
    is($r, 130, "one_shot: 130 when interrupted");
    $::ABORT = 0;
}

# which session belongs to a directory
{
    my $tmp = TestAI::setup();
    mkdir "$tmp/$_" or die $! for qw(p1 p2);
    is(ai::last_session("$tmp/p1"), undef, "last: no session used there yet");
    chdir("$tmp/p1") or die $!;
    TestAI::capture {ai::handle_command("/session create one")};
    TestAI::capture {ai::handle_command("/session create two")};
    utime(time() - 100, time() - 100, "$tmp/aicli/sessions/one/chat");
    is(ai::last_session(), "two", "last: the most recently used one of this directory");
    utime(time() + 100, time() + 100, "$tmp/aicli/sessions/one/chat");
    is(ai::last_session(), "one", "last: by the time of the conversation");
    chdir("$tmp/p2") or die $!;
    is(ai::last_session(), undef, "last: other directory, no session");
    TestAI::capture {ai::handle_command("/session two")};
    is(ai::last_session(), "two", "last: a session moves with where it is used");
    is(ai::last_session("$tmp/p1"), "one", "last: the other one stays");
    chdir("/");
}

# the real thing
SKIP: {
    skip "needs Net::Curl or WWW::Curl", 1
        unless Net::Curl::Easy->can('new') or WWW::Curl::Easy->can('new');
    my $tmp = TestAI::setup();
    my $url = FakeLLM::start();
    mkdir "$tmp/$_" or die $! for qw(proj other);
    delete local @ENV{qw(AI_PROXY HTTPS_PROXY HTTP_PROXY https_proxy http_proxy AI_API_KEY AI_PROVIDER AI_MODEL AI_CLEAR AI_SESSION DEBUG)};
    local $ENV{AI_DIR} = "$tmp/cli";
    local $ENV{AI_CONFIG} = "$tmp/noconfig";
    local $ENV{AI_LOCAL_SERVER} = $url;
    local $ENV{AI_PROMPT_TEMPLATE} = "coder";
    local $ENV{AI_PROJECT_FILE} = "";
    local $ENV{AI_RETRIES} = 0; # the failing request would be retried for half a minute
    my $sessions = sub {scalar(() = glob("$tmp/cli/sessions/*"))};
    my $ai = sub {
        my ($dir, $args, $stdin) = @_;
        ai::spew("$tmp/stdin", $stdin // '');
        my $out = `cd $tmp/$dir && $^X $TestAI::ROOT/ai.pl $args < $tmp/stdin 2>&1`;
        my $rc = $? >> 8;
        $out =~ s/\e\[[0-9;]*m//g;
        return ($out, $rc);
    };

    my ($out, $rc) = $ai->("proj", "-p 'go'");
    is($rc, 0, "-p: exit 0");
    like($out, qr/bash echo e2e.*\n  e2e-42\n.*The tool said: e2e-42 \(messages: 4,/s, "-p: the whole turn ran, tools included");
    is($sessions->(), 1, "-p: one session");

    ($out, $rc) = $ai->("proj", "-p 'fail please'");
    is($rc, 1, "-p: exit 1 when the request fails");
    like($out, qr/ERROR: 429: rate limit of the fake/, "-p: with the error");
    is($sessions->(), 2, "-p: without -c every run is a new session");

    ($out, $rc) = $ai->("proj", "--prompt -", "go\nfrom stdin\n");
    is($rc, 0, "-p -: prompt from stdin");
    like($out, qr/The tool said: e2e-42/, "-p -: answered");
    my ($last) = sort {(stat($b))[9] <=> (stat($a))[9]} glob("$tmp/cli/sessions/*/chat");
    local $ai::STATUS_FILE = $last;
    is((ai::load_messages())[1]{content}, "go\nfrom stdin\n", "-p -: all of stdin is one request");

    # -c goes on with the last session of the directory
    ($out, $rc) = $ai->("proj", "-c -p 'go'");
    is($rc, 0, "-c: exit 0");
    is($sessions->(), 3, "-c: no new session");
    like($out, qr/The tool said: e2e-42 \(messages: 8,/, "-c: the conversation went on (more messages)");
    ($out, $rc) = $ai->("proj", "--continue -p 'go'");
    like($out, qr/\(messages: 12,/, "-c: and again");

    # interactive commands see the same session
    ($out, $rc) = $ai->("proj", "-c", "/session list\n/exit\n");
    my ($current) = $out =~ m/^\* (\S+)/m;
    like($last, qr{/\Q$current\E/chat$}, "-c: also without -p");

    # another directory has its own
    ($out, $rc) = $ai->("other", "-c -p 'go'");
    like($out, qr/\(messages: 4,/, "-c: new conversation in another directory");
    is($sessions->(), 4, "-c: as a new session");
    ($out, $rc) = $ai->("other", "-c -p 'go'");
    like($out, qr/\(messages: 8,/, "-c: which is then continued there");
    is($sessions->(), 4, "-c: still 4 sessions");

    # AI_SESSION wins
    {
        local $ENV{AI_SESSION} = "named";
        ($out, $rc) = $ai->("proj", "-c -p 'go'");
        like($out, qr/\(messages: 4,/, "AI_SESSION: wins over -c");
        ok(-d "$tmp/cli/sessions/named", "AI_SESSION: that session");
    }

    # input from a pipe: ctrl-C stops the turn, not the program
    {
        my $run = sub {
            my ($script) = @_; # sub($to_ai, $pid)
            pipe(my $rd, my $wr) or die $!;
            my $pid = fork() // die $!;
            if(!$pid){
                close($wr);
                open(STDIN, '<&', $rd) or die $!;
                open(STDOUT, '>', "$tmp/int.out") or die $!;
                open(STDERR, '>&', \*STDOUT) or die $!;
                chdir("$tmp/proj") or die $!;
                exec($^X, "$TestAI::ROOT/ai.pl") or POSIX::_exit(127);
            }
            close($rd);
            $wr->autoflush(1);
            $script->($wr, $pid);
            close($wr);
            local $SIG{ALRM} = sub {kill('KILL', $pid)};
            alarm(20);
            waitpid($pid, 0);
            alarm(0);
            my $status = $?;
            my $text = ai::slurp("$tmp/int.out") =~ s/\e\[[0-9;]*m//gr;
            return ($text, $status >> 8, $status & 127);
        };
        my $t0 = Time::HiRes::time();
        my ($text, $code, $sig) = $run->(sub {
            my ($to, $pid) = @_;
            print {$to} "slow please\n";
            select(undef, undef, undef, 1.5);
            kill('INT', $pid);
            select(undef, undef, undef, 0.5);
            print {$to} "go\n";
        });
        like($text, qr/let me think for a long time\n?\[interrupted\]/, "pipe: ctrl-C stops the turn that runs");
        like($text, qr/\[interrupted\].*The tool said: e2e-42/s, "pipe: and the next line is read and answered");
        is_deeply([$code, $sig], [0, 0], "pipe: the program ends normally");
        ok(Time::HiRes::time() - $t0 < 15, "pipe: without waiting for the slow answer");

        ($text, $code, $sig) = $run->(sub {
            my ($to, $pid) = @_;
            select(undef, undef, undef, 1.5);
            kill('INT', $pid);
            select(undef, undef, undef, 1);
        });
        is_deeply([$code, $sig], [130, 0], "pipe: ctrl-C while nothing runs ends the program, exit 130");

        ($text, $code, $sig) = $run->(sub {
            my ($to, $pid) = @_;
            print {$to} "slow please\nnever read\n";
            select(undef, undef, undef, 1.5);
            kill('TERM', $pid);
            select(undef, undef, undef, 1);
        });
        like($text, qr/\[interrupted\]/, "pipe: TERM stops the turn");
        unlike($text, qr/never read|e2e-42/, "pipe: and reads no more");
        is($sig, 0, "pipe: TERM is not a crash");

        ($text, $code, $sig) = $run->(sub {
            my ($to, $pid) = @_;
            print {$to} "slow please\n";
            select(undef, undef, undef, 1.5);
            kill('INT', $pid);
            kill('INT', $pid);
            select(undef, undef, undef, 1);
        });
        ok($code == 130 || $text =~ m/\[interrupted\]/, "pipe: ctrl-C twice gets out for sure");
    }

    ($out, $rc) = $ai->("proj", "-p ''");
    is($rc, 1, "-p '': exit 1");
    ($out, $rc) = $ai->("proj", "--help");
    like($out, qr/-c, -continue.*-p, -prompt TEXT/s, "--help: shows the options");
    FakeLLM::stop();
}

chdir("/");
done_testing();
