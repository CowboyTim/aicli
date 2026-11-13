#!/usr/bin/perl
# the tools and how they run: fork, exec in the fork, eval/Safe in the fork
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = TestAI::setup(AI_API_KEY => 'sk-very-secret', GIT_AUTHOR_NAME => 'Test Er', MY_VAR => 'mine');
chdir($tmp) or die $!;

sub tool {
    my ($name, @args) = @_;
    return ai::execute_tool($name, uc($name), \@args);
}

# the tool table is consistent
{
    foreach my $name (sort keys %$tools::TOOLS){
        my $t = $tools::TOOLS->{$name};
        like($t->{tag}, qr/^\U$name\E_[0-9a-f]{4}$/, "$name: tag $t->{tag}");
        ok(tools->can(lc $t->{tag}), "$name: implemented");
        is(scalar(@{$t->{sentinels}}), scalar(keys %{$t->{properties}}), "$name: a sentinel per argument");
        ok(length($t->{description}), "$name: described");
    }
    is_deeply([ai::execute_tool("nope", "NOPE_1", [])], ["", "[ERROR] Unknown tool 'NOPE_1'"], "unknown tool: error");
}

# utils::fork_run
{
    my ($out, $exit, $sig, $why) = utils::fork_run(sub {print "out\n"; print STDERR "err\n"});
    is($out, "out\nerr\n", "fork_run: stdout and stderr captured, in order");
    is_deeply([$exit, $sig, $why], [0, 0, ""], "fork_run: clean end");
    is(scalar(utils::fork_run(sub {print "x"})), "x", "fork_run: scalar context gives the output");

    ($out, $exit, $sig, $why) = utils::fork_run(sub {exec "sh", "-c", "echo sh; exit 7"});
    is_deeply([$out, $exit, $sig], ["sh\n", 7, 0], "fork_run: exec in the fork, exit code");

    ($out, $exit, $sig, $why) = utils::fork_run(sub {die "oops\n"});
    is_deeply([$out, $exit, $sig], ["oops\n", 255, 0], "fork_run: die in the worker");

    ($out, $exit, $sig, $why) = utils::fork_run(sub {kill 'KILL', $$; sleep 5});
    is($sig, 9, "fork_run: signal reported");

    ($out) = utils::fork_run(sub {print "pid=$$ sid=".POSIX::getpgrp()." stdin=".(defined(scalar <STDIN>) ? "data" : "eof")});
    like($out, qr/^pid=(\d+) sid=\1 stdin=eof$/, "fork_run: own session/process group, stdin is /dev/null");
    unlike($out, qr/^pid=$$ /, "fork_run: not this process");

    my $marker = "$tmp/end-block-ran";
    ($out, $exit) = utils::fork_run(sub {eval 'END { open(my $f, ">", $marker) }'; print "bye"});
    ok(!-e $marker, "fork_run: END blocks don't run in the child");

    # the big one: more than a pipe buffer
    ($out, $exit) = utils::fork_run(sub {print "0123456789abcdef" x 65536});
    is(length($out), 1048576, "fork_run: 1MB of output");

    # timeout: the whole process group goes, also what bash left behind
    my $t0 = Time::HiRes::time();
    ($out, $exit, $sig, $why) = utils::fork_run(sub {exec "sh", "-c", 'echo started; sleep 60 & sleep 60'}, timeout => 1);
    my $took = Time::HiRes::time() - $t0;
    is($out, "started\n", "timeout: output so far is kept");
    is($why, "timeout after 1s", "timeout: reason");
    ok($took < 5, "timeout: back in ".sprintf("%.1fs", $took));

    # a child that ignores TERM is killed
    $t0 = Time::HiRes::time();
    ($out, $exit, $sig, $why) = utils::fork_run(sub {$SIG{TERM} = 'IGNORE'; print "stubborn\n"; sleep 60}, timeout => 1);
    is($sig, 9, "timeout: KILL after an ignored TERM");
    ok(Time::HiRes::time() - $t0 < 8, "timeout: stubborn child gone in time");

    # user abort (ctrl-C sets $::ABORT)
    $t0 = Time::HiRes::time();
    local $SIG{ALRM} = sub {$::ABORT = 1};
    alarm(1);
    ($out, $exit, $sig, $why) = utils::fork_run(sub {print "working\n"; sleep 60});
    alarm(0);
    $::ABORT = 0;
    is($why, "interrupted by user", "abort: reason");
    ok(Time::HiRes::time() - $t0 < 5, "abort: stopped at once");
}

# environment of tools: an allow-list, no AI_* (API key)
{
    my %e = utils::tool_env();
    ok(!grep({m/^AI_/} keys %e), "tool_env: no AI_* variables");
    is($e{GIT_AUTHOR_NAME}, "Test Er", "tool_env: GIT_* passes");
    ok(!exists $e{MY_VAR}, "tool_env: unknown variables don't pass");
    ok(length($e{PATH}) && length($e{TMPDIR}) && length($e{LANG}), "tool_env: basics are set");
    {
        local $::ORIG_ENV{AI_TOOL_ENV} = "MY_VAR, AI_API_KEY";
        %e = utils::tool_env();
        is($e{MY_VAR}, "mine", "tool_env: AI_TOOL_ENV adds variables");
        ok(!exists $e{AI_API_KEY}, "tool_env: but never AI_*");
    }
    local $ai::api_key = 'sk-very-secret';
    my ($out, $err) = tool("bash", 'env; echo "key=[$AI_API_KEY]"');
    is($err, undef, "bash env: ran");
    like($out, qr/^key=\[\]$/m, "bash: no API key in the environment");
    unlike($out, qr/sk-very-secret/, "bash: API key nowhere in env");
    like($out, qr/^GIT_AUTHOR_NAME=Test Er$/m, "bash: git identity is there");
    ($out, $err) = tool("perl", 'print "key=[", $ai::api_key // "", "] env=[", join(",", grep {/^AI_/} keys %ENV, keys %::ORIG_ENV), "]"');
    is($out, "key=[] env=[]", "perl: API key not reachable from the eval");
    is($ai::api_key, 'sk-very-secret', "the chat itself still has its key");
}

# bash
{
    my ($out, $err) = tool("bash", "echo hello\necho world >&2\ncat");
    is_deeply([$out, $err], ["hello\nworld\n", undef], "bash: multi line script, stderr included, no stdin");
    ($out, $err) = tool("bash", "echo before; false; echo \$?; exit 4");
    is($out, "", "bash failure: no result");
    is($err, "[ERROR] problem running tool 'BASH': exit code: 4, output: before\n1", "bash failure: exit code and output");
    ($out, $err) = tool("bash", "cd /tmp && pwd");
    is($out, "/tmp\n", "bash: runs");
    is(Cwd::cwd(), Cwd::realpath($tmp), "bash: cd does not move the chat");
    is(scalar(() = glob(($::ORIG_ENV{TMPDIR} // $ENV{TMPDIR} // "/tmp")."/aicli_bash_*")), 0, "bash: temp script removed");
    {
        local $::ORIG_ENV{AI_TOOL_TIMEOUT} = 1;
        ($out, $err) = tool("bash", "echo slow; sleep 60");
        like($err, qr/timeout after 1s, output: slow/, "bash: AI_TOOL_TIMEOUT");
    }
    {
        local $::ORIG_ENV{AI_TOOL_MAX_OUTPUT} = 1000;
        ($out, $err) = tool("bash", "printf 'START'; head -c 100000 /dev/zero | tr '\\0' x; printf 'END'");
        ok(length($out) < 1100, "bash: AI_TOOL_MAX_OUTPUT limits the result");
        like($out, qr/\ASTARTx+\n\[\.\.\. \d+ bytes truncated \.\.\.\]\nx+END\z/, "bash: head and tail kept");
    }
}

# perl: eval in a fork
{
    my ($out, $err) = tool("perl", 'use strict; my @a = map {$_ * 2} 1 .. 3; print "@a\n"; warn "w\n";');
    is_deeply([$out, $err], ["2 4 6\nw\n", undef], "perl: runs, stderr included");
    ($out, $err) = tool("perl", 'our $leak = 1; $ai::AI_SESSION = "changed"; chdir "/"; print "in ", __PACKAGE__;');
    is($out, "in aicli::tool", "perl: own package");
    is($ai::AI_SESSION, "test", "perl: can't change the chat, it is another process");
    is(Cwd::cwd(), Cwd::realpath($tmp), "perl: chdir stays in the child");
    ($out, $err) = tool("perl", 'print "a"; die "broken\n"');
    is($err, "[ERROR] problem running tool 'PERL': exit code: 255, output: abroken", "perl: die is an error, with output");
    ($out, $err) = tool("perl", 'print "syntax" if (');
    like($err, qr/exit code: 255, output: syntax error at/, "perl: syntax error is an error");
}

# the modules of the image for the perl tool (PDL for arrays and FFT, Audio::Wav
# for WAV files): the tool can use them; skipped where they are not installed
SKIP: {
    skip "PDL and Audio::Wav are not installed", 2 unless eval { require PDL; require Audio::Wav; 1 };
    my ($out, $err) = tool("perl", 'use PDL; use Audio::Wav; my $f = sequence(4) * 2; print "pdl ", $f->sum->sclr, " wav ", (Audio::Wav->can("write") ? "ok" : "no");');
    is($err, undef, "perl modules: PDL and Audio::Wav load in the tool");
    is($out, "pdl 12 wav ok", "perl modules: PDL arithmetic runs in the tool");
    ($out, $err) = tool("perl", 'print "x\n"; exit 0; print "not here"');
    is_deeply([$out, $err], ["x\n", undef], "perl: exit 0 is fine");
    ($out, $err) = tool("perl", 'print "x\n"; exit 3');
    like($err, qr/exit code: 3, output: x/, "perl: exit code is seen");
    ($out, $err) = tool("perl", '');
    like($err, qr/need an actual perl program/, "perl: empty program");
    ($out, $err) = tool("perl", 'my $pid = fork(); if(!$pid){print "kid\n"; exit 0} waitpid($pid, 0); print "parent\n"');
    is($out, "kid\nparent\n", "perl: may fork itself");
}

# perl with AI_PERL_SAFE: a Safe compartment in the fork
{
    local $::ORIG_ENV{AI_PERL_SAFE} = 1;
    my ($out, $err) = tool("perl", 'my $s = 0; $s += $_ for 1 .. 10; print "sum=$s\n";');
    is_deeply([$out, $err], ["sum=55\n", undef], "safe: plain computing works");
    ($out, $err) = tool("perl", 'system("echo pwned")');
    like($err, qr/'system' trapped by operation mask/, "safe: system is trapped");
    ($out, $err) = tool("perl", 'open(my $f, "<", "/etc/passwd") or die; print <$f>');
    like($err, qr/'open' trapped by operation mask/, "safe: open is trapped");
    ($out, $err) = tool("perl", 'print `id`');
    like($err, qr/trapped by operation mask/, "safe: backticks are trapped");
    ($out, $err) = tool("perl", 'print "key=", $ai::api_key // "none"');
    is($out, "key=none", "safe: other namespaces are not visible");

    local $::ORIG_ENV{AI_PERL_SAFE} = ":filesys_open :filesys_read";
    ai::spew("$tmp/safe.txt", "readable\n");
    ($out, $err) = tool("perl", 'opendir(my $d, ".") or die "no: $!"; print join(",", grep {/^safe/} readdir($d))');
    is_deeply([$out, $err], ["safe.txt", undef], "safe: extra opcodes can be permitted");
    ($out, $err) = tool("perl", 'unlink("safe.txt")');
    like($err, qr/'unlink' trapped/, "safe: the rest stays trapped");
    ok(-e "$tmp/safe.txt", "safe: file is still there");
}

# read, write, grep
{
    my ($out, $err) = tool("write", " dir.txt \n", "line one\nfoo bar\nline three\n");
    is_deeply([$out, $err], ["[OK] written to dir.txt", undef], "write: ok, path trimmed");
    ($out, $err) = tool("read", "dir.txt");
    is($out, "line one\nfoo bar\nline three\n", "read: content back");
    ($out, $err) = tool("write", "dir.txt", "");
    is(-s "dir.txt", 0, "write: empty content truncates");
    ($out, $err) = tool("write", "no/such/dir/x", "x");
    like($err, qr/^\[ERROR\] problem running tool 'WRITE': Cannot write to no\/such\/dir\/x: /, "write: failure is an error");
    ($out, $err) = tool("read", "missing.txt");
    like($err, qr/cannot read missing.txt: No such file/, "read: missing file is an error");
    ($out, $err) = tool("read", ".");
    like($err, qr/is a directory/, "read: directory is an error");

    mkdir "src" or die $!;
    ai::spew("src/one.pl", "my \$x = 1;\nsub foo { }\n");
    ai::spew("src/two.pl", "# nothing\nfoo();\n");
    ($out, $err) = tool("grep", "src/one.pl", "sub ");
    is_deeply([$out, $err], ["2:sub foo { }\n", undef], "grep: file, with line numbers");
    ($out, $err) = tool("grep", "src", "foo");
    is(join("", sort split m/^/, $out), "src/one.pl:2:sub foo { }\nsrc/two.pl:2:foo();\n", "grep: directory is searched recursively");
    ($out, $err) = tool("grep", "src", "no-such-thing");
    is_deeply([$out, $err], ["", undef], "grep: no match is not an error");
    ($out, $err) = tool("grep", "src", "-rf");
    is_deeply([$out, $err], ["", undef], "grep: a pattern is never an option");
    ($out, $err) = tool("grep", "nodir", "x");
    like($err, qr/exit code: 2, output: grep: nodir/, "grep: real errors are errors");
    ($out, $err) = tool("grep", "src", '$(touch pwned); `touch pwned`');
    ok(!-e "pwned" && !-e "src/pwned", "grep: no shell involved");
    ($out, $err) = tool("grep", "", "x");
    like($err, qr/not enough properties/, "grep: needs both arguments");
}

chdir("/");
done_testing();
