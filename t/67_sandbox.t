#!/usr/bin/perl
# the kernel (landlock) keeps the forked tools in the workspace
use strict; use warnings;

use Test::More;
use FindBin;
use Cwd ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

# what does not need the kernel
my $tmp = Cwd::realpath(TestAI::setup());
{
    is(ai::sandbox_state(), 'off', "no sandbox for the workspace /");
    is_deeply([ai::sandbox_policy()], [], "and no policy");
}
# everything of the test is below /tmp: the temp directory of the tools has
# to be somewhere else, or "outside" would be allowed
mkdir "$tmp/$_" or die $! for qw(ws ws/sub outside extra t);
$::ORIG_ENV{TMPDIR} = "$tmp/t";
ai::spew("$tmp/ws/in.txt", "inside\n");
ai::spew("$tmp/outside/secret.txt", "secret\n");
chdir("$tmp/ws") or die $!;
ai::set_workspace("$tmp/ws");
{
    my %p = ai::sandbox_policy();
    is_deeply([@{$p{write}}[0, 1]], ["$tmp/ws", "$tmp/t"], "policy: write in the workspace and the temp directory");
    ok(scalar(grep {$_ eq '/dev/null'} @{$p{write}}), "policy: and /dev/null");
    ok(!$p{read}, "policy: reading is free by default");
    {
        local $::ORIG_ENV{AI_SANDBOX_WRITE} = "/dev/ttyACM0, /sys:/proc $tmp/extra";
        local $::ORIG_ENV{AI_WORKSPACE_ALLOW} = "$tmp/extra";
        ai::set_workspace("$tmp/ws");
        %p = ai::sandbox_policy();
        is_deeply([@{$p{write}}[-4 .. -1]], ["/dev/ttyACM0", "/sys", "/proc", "$tmp/extra"], "policy: AI_SANDBOX_WRITE adds paths");
        is($p{write}[1], "$tmp/extra", "policy: AI_WORKSPACE_ALLOW is writable too");
    }
    ai::set_workspace("$tmp/ws");
    {
        local $::ORIG_ENV{AI_SANDBOX_READ} = "system";
        %p = ai::sandbox_policy();
        ok(scalar(grep {$_ eq '/usr'} @{$p{read}}) && !grep({$_ eq 'system'} @{$p{read}}), "policy: AI_SANDBOX_READ=system limits reading to the system");
        local $::ORIG_ENV{AI_SANDBOX_READ} = "/srv/data";
        %p = ai::sandbox_policy();
        is($p{read}[-1], "/srv/data", "policy: or to the system and what it names");
    }
    {
        local $::ORIG_ENV{AI_SANDBOX} = "off";
        is(ai::sandbox_state(), 'off', "policy: AI_SANDBOX=off");
    }
    {
        local $sandbox::ABI = 0;
        is(ai::sandbox_state(), 'unavailable', "state: a kernel without landlock");
        unlike(ai::system_prompt(), qr/bash, perl and grep can/, "state: then the prompt does not promise it");
    }
}

plan(skip_all => "this kernel has no landlock") unless do {local $sandbox::ABI; sandbox::abi()};
undef $sandbox::ABI;

sub tool {
    my ($name, @args) = @_;
    my @r = ai::execute_tool($name, uc($name), \@args);
    @tools::CHANGES = ();
    return @r;
}

is(ai::sandbox_state(), 'on', "the sandbox is on (kernel ABI ".sandbox::abi().")");
like(ai::system_prompt(), qr/The file tools only work inside this directory\.\nbash, perl and grep can read everything, but only write in this directory and in \Q$tmp\E\/t\.\n/, "the model is told");

# bash
{
    my ($out, $err) = tool("bash", "echo new > made.txt && cat made.txt && mkdir d && mv made.txt d/ && rm -r d && echo all-ok");
    is_deeply([$out, $err], ["new\nall-ok\n", undef], "bash: works in the workspace (write, mkdir, rename, remove)");
    ($out, $err) = tool("bash", "cat $tmp/outside/secret.txt; ls / >/dev/null && echo ls-ok; perl -e 'print qq{perl-ok\\n}'");
    is($out, "secret\nls-ok\nperl-ok\n", "bash: reads and runs everything");
    ($out, $err) = tool("bash", "echo x > $tmp/outside/new.txt");
    like($err, qr/exit code: 1, output: .*outside\/new\.txt: Permission denied/, "bash: cannot create a file outside");
    ($out, $err) = tool("bash", "echo x >> $tmp/outside/secret.txt; rm -f $tmp/outside/secret.txt; mv $tmp/outside/secret.txt .; mkdir $tmp/outside/d; ln -s /x $tmp/outside/l; echo tried");
    is(scalar(() = $out =~ m/Permission denied/g), 5, "bash: cannot append, remove, move away, mkdir or link outside");
    is(ai::slurp("$tmp/outside/secret.txt"), "secret\n", "bash: the file outside is as it was");
    is_deeply([map {s{.*/}{}r} glob("$tmp/outside/*")], ["secret.txt"], "bash: nothing new outside");
    ($out, $err) = tool("bash", "cd $tmp/outside && cp secret.txt copy.txt; cd $tmp/ws && cp $tmp/outside/secret.txt got.txt && cat got.txt");
    like($out, qr/Permission denied\nsecret\n\z/, "bash: copying in works, copying within the outside does not");
    ($out, $err) = tool("bash", 'f=$(mktemp) && echo t > $f && cat $f && rm $f; echo n > /dev/null; echo o > /dev/stdout; echo e >&2');
    is_deeply([$out, $err], ["t\no\ne\n", undef], "bash: temp files, /dev/null, stdout and stderr work");
    like((tool("bash", "echo x > /tmp/aicli-sandbox-test-$$ || echo denied"))[0], qr/denied/, "bash: the temp directory is the one of the tools, not /tmp as such");
    ok(!-e "/tmp/aicli-sandbox-test-$$", "bash: and nothing is there");

    # whatever the tool starts is in there too, also when it outlives the tool
    ($out, $err) = tool("bash", "sh -c \"sh -c 'echo x > $tmp/outside/deep.txt' 2>&1\"; (sleep 0.3; echo late > $tmp/outside/late.txt) >/dev/null 2>&1 & echo started");
    like($out, qr/Permission denied\nstarted\n/, "bash: processes it starts are confined too");
    select(undef, undef, undef, 0.8);
    ok(!-e "$tmp/outside/late.txt" && !-e "$tmp/outside/deep.txt", "bash: also what it leaves running");
    ($out, $err) = tool("bash", "ln -s $tmp/outside link && echo y > link/via-link.txt; echo y > ../outside/dotdot.txt; echo done");
    is(scalar(() = $out =~ m/Permission denied/g), 2, "bash: links and .. do not get around it");
    is_deeply([map {s{.*/}{}r} glob("$tmp/outside/*")], ["secret.txt"], "bash: still nothing new outside");
}

# perl, grep, sub-agents
{
    my ($out, $err) = tool("perl", 'open(my $f, ">", "p.txt") or die "in: $!"; print $f "x"; close $f; print -s "p.txt";');
    is_deeply([$out, $err], ["1", undef], "perl: writes in the workspace");
    ($out, $err) = tool("perl", "open(my \$f, '<', '$tmp/outside/secret.txt') or die; print scalar <\$f>; open(my \$g, '>', '$tmp/outside/p.txt') or print \"write: \$!\\n\"; unlink('$tmp/outside/secret.txt') or print \"unlink: \$!\\n\"; print `echo z 2>&1 > $tmp/outside/q.txt`;");
    like($out, qr/\Asecret\nwrite: Permission denied\nunlink: Permission denied\n.*Permission denied/s, "perl: reads outside, cannot write or delete there, nor can what it runs");
    {
        local $::ORIG_ENV{AI_PERL_SAFE} = 1;
        is((tool("perl", 'print 6 * 7'))[0], "42", "perl: the Safe compartment still works in the sandbox");
    }
    is((tool("grep", "$tmp/ws/in.txt", "inside"))[0], "1:inside\n", "grep: runs");
    my @got;
    ai::execute_tool_async("bash", "BASH_7c48", ["echo x > $tmp/outside/agent.txt || echo denied"], sub {@got = @_});
    loop::run(sub {scalar(@got)});
    like($got[0], qr/Permission denied\ndenied\n/, "sub-agents: their tools are confined the same way");
    is_deeply([map {s{.*/}{}r} glob("$tmp/outside/*")], ["secret.txt"], "nothing new outside");

    # this process is not confined, only the children were
    ai::spew("$tmp/outside/by-the-chat.txt", "ok");
    ok(-e "$tmp/outside/by-the-chat.txt", "the chat process itself is not restricted");
    unlink("$tmp/outside/by-the-chat.txt");
}

# more places to write, reading limited, off
{
    local $::ORIG_ENV{AI_SANDBOX_WRITE} = "$tmp/extra $tmp/outside/secret.txt /no/such/place";
    my ($out, $err) = tool("bash", "echo e > $tmp/extra/e.txt && echo more >> $tmp/outside/secret.txt && echo ok; echo n > $tmp/outside/n.txt || echo denied");
    like($out, qr/\Aok\n.*n\.txt: Permission denied\ndenied\n/s, "AI_SANDBOX_WRITE: a directory and a single file are writable, the rest is not");
    is(ai::slurp("$tmp/outside/secret.txt"), "secret\nmore\n", "AI_SANDBOX_WRITE: the single file was written");
}
{
    local $::ORIG_ENV{AI_SANDBOX_READ} = "system";
    my ($out, $err) = tool("bash", "cat in.txt; cat $tmp/outside/secret.txt; ls $tmp/outside; echo w > w.txt && echo wrote");
    like($out, qr/\Ainside\ncat: .*secret\.txt: Permission denied\nls: .*Permission denied\nwrote\n\z/, "AI_SANDBOX_READ: reads the workspace, not the outside; bash itself still runs");
    like(ai::system_prompt(), qr/can only read the system and this directory, but only write/, "AI_SANDBOX_READ: the model is told");
    local $::ORIG_ENV{AI_SANDBOX_READ} = "$tmp/outside";
    is((tool("bash", "cat $tmp/outside/secret.txt | head -1"))[0], "secret\n", "AI_SANDBOX_READ: a path it names is readable");
    like((tool("bash", "echo x > $tmp/outside/r.txt || echo denied"))[0], qr/denied/, "AI_SANDBOX_READ: readable is not writable");
}
{
    local $::ORIG_ENV{AI_SANDBOX} = "off";
    is((tool("bash", "echo free > $tmp/outside/free.txt && cat $tmp/outside/free.txt"))[0], "free\n", "AI_SANDBOX=off: no limit");
    unlink("$tmp/outside/free.txt");
}
{
    ai::set_workspace("none");
    is((tool("bash", "echo free > $tmp/outside/free.txt && cat $tmp/outside/free.txt"))[0], "free\n", "no workspace: no sandbox");
    unlink("$tmp/outside/free.txt");
    ai::set_workspace("$tmp/ws");
}

# a kernel that cannot
{
    local $sandbox::ABI = 0;
    is((tool("bash", "echo free > $tmp/outside/free.txt && cat $tmp/outside/free.txt"))[0], "free\n", "no landlock: the tools run without it");
    unlink("$tmp/outside/free.txt");
    local $::ORIG_ENV{AI_SANDBOX} = "on";
    my ($out, $err) = tool("bash", "echo free > $tmp/outside/free.txt");
    like($err, qr/no sandbox: this kernel has no landlock \(AI_SANDBOX=on\)/, "AI_SANDBOX=on: without landlock no tool runs");
    ok(!-e "$tmp/outside/free.txt", "AI_SANDBOX=on: nothing happened");
}

# /workspace shows it
{
    my $out = TestAI::capture {ai::handle_command("/workspace")};
    like($out, qr/^Workspace: \Q$tmp\E\/ws\nSandbox for bash, perl, grep: landlock \(kernel ABI \d+\)\n  write: \Q$tmp\E\/ws \Q$tmp\E\/t \/dev\/null.*\n  read:  everything\n/, "/workspace: shows the sandbox");
    local $::ORIG_ENV{AI_SANDBOX} = "off";
    $out = TestAI::capture {ai::handle_command("/workspace")};
    like($out, qr/Sandbox for bash, perl, grep: off/, "/workspace: off");
}

chdir("/");
done_testing();
