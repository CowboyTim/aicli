#!/usr/bin/perl
# the file tools stay inside the workspace
use strict; use warnings;

use Test::More;
use FindBin;
use Cwd ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = Cwd::realpath(TestAI::setup());
mkdir "$tmp/$_" or die $! for qw(ws ws/sub outside extra);
ai::spew("$tmp/ws/in.txt", "inside\n");
ai::spew("$tmp/ws/sub/deep.txt", "deep\n");
ai::spew("$tmp/outside/secret.txt", "secret\n");
ai::spew("$tmp/extra/ok.txt", "extra\n");
symlink("$tmp/outside", "$tmp/ws/link_out") or die $!;
symlink("$tmp/outside/secret.txt", "$tmp/ws/link_file") or die $!;
symlink("sub/deep.txt", "$tmp/ws/link_in") or die $!;
symlink("$tmp/outside/not-there", "$tmp/ws/link_nowhere") or die $!;
chdir("$tmp/ws") or die $!;

sub tool {
    my ($name, @args) = @_;
    my @r = ai::execute_tool($name, uc($name), \@args);
    @tools::CHANGES = ();
    return @r;
}
my $out_rx = qr/outside of the workspace \(\Q$tmp\E\/ws\): /;

# the workspace: the start directory by default
{
    is($ai::WORKSPACE, "/", "tests run with the workspace of their start directory (/)");
    is(ai::set_workspace(undef), "$tmp/ws", "default: the current directory");
    is(ai::set_workspace("$tmp/ws/sub/.."), "$tmp/ws", "set: resolved to the real path");
    eval {ai::set_workspace("$tmp/nope")};
    like($@, qr/workspace is not a directory/, "set: must be a directory");
    is($ai::WORKSPACE, "$tmp/ws", "set: a failed set changes nothing");
    like(ai::system_prompt(), qr/\n\nWorkspace: \Q$tmp\E\/ws\nThe file tools only work inside this directory\.\n/, "the model is told where it is");
}

# what is inside
{
    foreach my $p ("in.txt", "./in.txt", "sub/../in.txt", "$tmp/ws/in.txt", "sub/deep.txt", "link_in", " in.txt \n"){
        is(eval {tools::_path($p)}, ($p =~ s/^\s+|\s+$//gr), "inside: '".($p =~ s/\n/\\n/r)."'") or diag($@);
    }
    is(eval {tools::_path("new/dir/file.txt")}, "new/dir/file.txt", "inside: what does not exist yet");
    is(eval {tools::_path(".")}, ".", "inside: the workspace itself");
    is(eval {tools::_path("", default => ".")}, ".", "inside: default path");
    is(eval {tools::_path("")}, "", "empty stays empty (the tools complain themselves)");
}

# where a path leads: readlink by readlink
{
    my $r = sub {my $p = eval {tools::_resolve(@_)}; defined $p ? $p =~ s/^\Q$tmp\E//r : "died: $@"};
    is($r->("in.txt"), "/ws/in.txt", "resolve: relative to the current directory");
    is($r->("./sub//deep.txt"), "/ws/sub/deep.txt", "resolve: . and // are nothing");
    is($r->("sub/../in.txt"), "/ws/in.txt", "resolve: .. drops a name");
    is($r->("link_in"), "/ws/sub/deep.txt", "resolve: a relative link");
    is($r->("link_out/secret.txt"), "/outside/secret.txt", "resolve: an absolute link in the middle");
    is($r->("link_out/../ws/in.txt"), "/ws/in.txt", "resolve: .. after a link is the parent of where the link leads");
    is($r->("link_nowhere"), "/outside/not-there", "resolve: a link to nowhere says where it would be");
    is($r->("new/../link_out/z"), "/outside/z", "resolve: a link after names that do not exist");
    is($r->("no/such/dir/file"), "/ws/no/such/dir/file", "resolve: what does not exist is taken by its name");
    is($r->("link_file", 1), "/ws/link_file", "resolve: nofollow keeps the last name");
    is($r->("link_out/secret.txt", 1), "/outside/secret.txt", "resolve: nofollow still follows the directories");
    is(tools::_resolve("/../../etc/../tmp/."), "/tmp", "resolve: nothing is above /");
    is(tools::_resolve("/"), "/", "resolve: /");
    symlink("chain2", "chain1"); symlink("chain3", "chain2"); symlink("in.txt", "chain3");
    is($r->("chain1"), "/ws/in.txt", "resolve: a chain of links");
    symlink("loop_b", "loop_a"); symlink("loop_a", "loop_b");
    like($r->("loop_a/x"), qr/died: too many symbolic links/, "resolve: links in a circle end");
    eval {tools::_path("loop_a/x")};
    like($@, $out_rx, "a circle of links is outside");
    symlink("$tmp/ws/sub", "$tmp/outside/back_in");
    symlink("$tmp/outside/back_in", "via_outside");
    is($r->("via_outside/deep.txt"), "/ws/sub/deep.txt", "resolve: out and back in again");
    is(eval {tools::_path("via_outside/deep.txt")}, "via_outside/deep.txt", "what ends up inside is inside, whatever the way");
    symlink("$tmp/ws/fresh.txt", "link_new");
    is(eval {tools::_path("link_new")}, "link_new", "a link to a file inside that does not exist yet is fine");
    unlink(qw(chain1 chain2 chain3 loop_a loop_b via_outside link_new), "$tmp/outside/back_in");
}

# what is not
{
    foreach my $p ("..", "../outside/secret.txt", "/etc/passwd", "$tmp/outside/secret.txt", "sub/../../outside/secret.txt",
                   "/", "$tmp/ws/../outside", "link_out", "link_out/secret.txt", "link_out/new.txt", "link_file",
                   "link_nowhere", "new/../../outside/x", "nodir/../../x", "$tmp/ws-other", "$tmp/w"){
        eval {tools::_path($p)};
        like($@, $out_rx, "outside: '$p'");
    }
    # the entry itself, not where it points
    is(eval {tools::_path("link_file", nofollow => 1)}, "link_file", "nofollow: a link in the workspace is in the workspace");
    is(eval {tools::_path("link_nowhere", nofollow => 1)}, "link_nowhere", "nofollow: also one to nowhere");
    eval {tools::_path("link_out/secret.txt", nofollow => 1)};
    like($@, $out_rx, "nofollow: but not through a link to the outside");
    eval {tools::_path("..", nofollow => 1)};
    like($@, $out_rx, "nofollow: not ..");
}

# every file tool
{
    foreach my $case (
        [read => "../outside/secret.txt"], [read => "link_file"], [lines => "/etc/passwd", ""],
        [write => "../outside/new.txt", "x"], [write => "link_out/new.txt", "x"], [write => "link_file", "x"], [write => "link_nowhere", "x"],
        [replace => "link_file", "secret", "x"], [edit => "../outside/secret.txt", "1d"],
        [delete => "../outside/secret.txt"], [delete => "link_out/secret.txt"], [delete => "$tmp/outside"],
        [move => "in.txt", "../outside/moved.txt"], [move => "../outside/secret.txt", "stolen.txt"], [move => "in.txt", "link_out"],
        [mkdir => "../outside/newdir"], [mkdir => "link_out/newdir"], [list => ".."], [list => "link_out"], [list => "/"],
        [grep => "../outside", "secret"], [grep => "link_out", "secret"],
    ){
        my ($name, @args) = @$case;
        my ($out, $err) = tool($name, @args);
        like($err, qr/^\[ERROR\] problem running tool '\U$name\E': outside of the workspace/, "$name $args[0]: refused");
    }
    is(ai::slurp("$tmp/outside/secret.txt"), "secret\n", "outside: the file is untouched");
    is_deeply([sort map {s{.*/}{}r} glob("$tmp/outside/*")], ["secret.txt"], "outside: nothing was created or removed");
    ok(-e "in.txt", "inside: nothing was moved away");
    is(scalar(ai::undo_journal()), 0, "refused calls are not in the undo journal");

    # and inside everything works as before
    is((tool("read", "in.txt"))[0], "inside\n", "read inside");
    is((tool("read", "link_in"))[0], "deep\n", "read through a link that stays inside");
    # .. after names that do not exist is resolved as text
    is(eval {tools::_path($_)}, $_, "inside: '$_'") for "sub/new/../w.txt", "a/b/c/../../../in.txt", "new/..", "x/y/../../sub/z/../deep.txt";
    foreach my $p ("new/../..", "a/b/../../../outside/x", "x/../../ws-other/y", "new/../link_out/z", "new/../link_out", "a/b/../../link_file", "n/../sub/../link_out/x/../y",
                   "a/../../../../../../../../etc/passwd"){
        eval {tools::_path($p)};
        like($@, $out_rx, "outside: '$p'");
    }
    like((tool("mkdir", "new/../link_out/made"))[1], qr/outside of the workspace/, "mkdir cannot be talked through a link that way");
    ok(!-e "$tmp/outside/made" && !-e "new", "and nothing was created");
    like((tool("write", "sub/new/../w2.txt", "w"))[1], qr/Cannot write to sub\/new\/\.\.\/w2\.txt/, "such a path is judged right, the system then says the directory is missing");
    is((tool("write", "sub/w.txt", "w\n"))[1], undef, "write inside");
    is((tool("mkdir", "a/b"))[1], undef, "mkdir inside");
    is((tool("move", "sub/w.txt", "a/b"))[0], "[OK] moved sub/w.txt to a/b/w.txt", "move inside");
    like((tool("list", ""))[0], qr/^l +\d+ link_out$/m, "list inside shows the link");
    is((tool("delete", "link_file"))[0], "[OK] deleted link_file", "delete removes a link in the workspace");
    ok(-e "$tmp/outside/secret.txt", "its target outside stays");
    is((tool("grep", ".", "deep"))[1], undef, "grep inside");
    unlike((tool("grep", ".", "secret"))[0], qr/secret\.txt/, "grep does not follow links out of the workspace");
}

# more directories, no limit, commands
{
    like((tool("read", "$tmp/extra/ok.txt"))[1], qr/outside of the workspace/, "extra: not allowed by default");
    {
        local $::ORIG_ENV{AI_WORKSPACE_ALLOW} = "$tmp/extra, /nonexistent";
        ai::set_workspace("$tmp/ws");
        is_deeply(\@ai::WORKSPACE_ALLOW, ["$tmp/extra"], "allow: AI_WORKSPACE_ALLOW, what exists");
        is((tool("read", "$tmp/extra/ok.txt"))[0], "extra\n", "allow: readable now");
        like((tool("read", "$tmp/outside/secret.txt"))[1], qr/outside of the workspace/, "allow: the rest is still outside");
    }
    my $out = TestAI::capture {ai::handle_command("/workspace")};
    like($out, qr/^Workspace: \Q$tmp\E\/ws\nAlso allowed: \Q$tmp\E\/extra\n/, "/workspace: shows it");
    $out = TestAI::capture {ai::handle_command("/workspace $tmp/outside")};
    like($out, qr/^Workspace: \Q$tmp\E\/outside\n/, "/workspace dir: the user can move it");
    is((tool("read", "$tmp/outside/secret.txt"))[0], "secret\n", "/workspace dir: in effect");
    like((tool("read", "$tmp/ws/in.txt"))[1], qr/outside of the workspace/, "/workspace dir: the old one is outside now");
    $out = TestAI::capture {ai::handle_command("/workspace $tmp/nope")};
    like($out, qr/Cannot set the workspace: workspace is not a directory.*Workspace: \Q$tmp\E\/outside/s, "/workspace: a bad directory changes nothing");
    $out = TestAI::capture {ai::handle_command("/workspace none")};
    like($out, qr/Workspace: none, the file tools can go anywhere/, "/workspace none: no limit");
    is((tool("read", "$tmp/ws/in.txt"))[0], "inside\n", "/workspace none: in effect");
    unlike(ai::system_prompt(), qr/Workspace:/, "no workspace, no line in the prompt");

    # from the environment at start
    TestAI::setup(AI_WORKSPACE => "$tmp/ws", AI_WORKSPACE_ALLOW => "$tmp/extra");
    is($ai::WORKSPACE, "$tmp/ws", "AI_WORKSPACE at start");
    is_deeply(\@ai::WORKSPACE_ALLOW, ["$tmp/extra"], "AI_WORKSPACE_ALLOW at start");
    TestAI::setup(AI_WORKSPACE => "none");
    is($ai::WORKSPACE, undef, "AI_WORKSPACE=none at start");
    chdir("$tmp/ws") or die $!;
    TestAI::setup();
    is($ai::WORKSPACE, "/", "the helper starts every test in /");
}

chdir("/");
done_testing();
