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
    like((tool("write", "sub/new/../w.txt", "w"))[1], qr/outside of the workspace/, ".. after a directory that does not exist is refused, to be safe");
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
