#!/usr/bin/perl
# where messages go (stderr, AI_LOG), and who ai.pl becomes when started as root
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

use utils;

chdir("$FindBin::Bin/..") or die $!;
my $tmp = tempdir(CLEANUP => 1);
delete @ENV{grep {m/^AI_/} keys %ENV};
delete @ENV{qw(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy DEBUG)};
$ENV{AI_DIR} = "$tmp/aicli";
$ENV{AI_CONFIG} = "$tmp/noconfig";
$ENV{AI_LOCAL_SERVER} = "http://127.0.0.1:9"; # nothing listens there
$ENV{AI_SESSION} = "log";
$ENV{AI_RETRIES} = 0;

# ai.pl as a process: returns (stdout, stderr, exit code)
sub ai_pl {
    my ($args, $input, %env) = @_;
    local @ENV{keys %env} = values %env;
    open(my $ifh, '>', "$tmp/in") or die $!;
    print {$ifh} $input // '';
    close($ifh);
    system("$^X ./ai.pl $args < $tmp/in > $tmp/out 2> $tmp/err");
    my $rc = $? >> 8;
    return ((map {open(my $fh, '<', "$tmp/$_") or die $!; local $/; scalar(<$fh>) // ''} qw(out err)), $rc);
}

# stdout is the conversation, messages are for stderr
{
    my ($out, $err, $rc) = ai_pl("", "/pwd\n");
    like($out, qr/\A\S+\n\z/, "plain: the command output is on stdout");
    is($err, "", "plain: nothing on stderr");

    ($out, $err, $rc) = ai_pl("--debug", "/pwd\n");
    unlike($out, qr/INFO:/, "debug: no debug lines on stdout");
    like($out, qr/\A\S+\n\z/, "debug: stdout is the same as without");
    like($err, qr/^INFO: \[\d+\]: .*open config/m, "debug: the debug log is on stderr");
    ($out, $err, $rc) = ai_pl("", "/pwd\n", DEBUG => 1);
    like($err, qr/^INFO: /m, "debug: also with DEBUG=1");
    unlike($out, qr/INFO:/, "debug: stdout stays clean");

    # an error: stderr, and the exit code says so
    ($out, $err, $rc) = ai_pl("-p 'anyone there?'", "");
    is($rc, 1, "error: exit 1");
    like($err, qr/^ERROR: \[\d+\]: .*ERROR: \S/m, "error: the message is on stderr");
    unlike($out, qr/ERROR/, "error: not on stdout");

    # AI_LOG: the debug log goes to the file, errors to both
    ($out, $err, $rc) = ai_pl("--debug -p 'anyone there?'", "", AI_LOG => "$tmp/debug.log");
    my $log = do {open(my $fh, '<', "$tmp/debug.log") or die $!; local $/; <$fh>};
    like($log, qr/^INFO: .*User input: anyone there\?/m, "AI_LOG: debug lines are in the file");
    like($log, qr/^ERROR: /m, "AI_LOG: errors too");
    unlike($err, qr/^INFO: /m, "AI_LOG: debug lines are not on stderr then");
    like($err, qr/^ERROR: /m, "AI_LOG: errors are still shown");
    unlike($log.$err, qr/Authorization: Bearer \S|sk-/, "the log has no key in it");
    ($out, $err, $rc) = ai_pl("--debug", "/pwd\n", AI_LOG => "$tmp/no/such/dir/x.log");
    like($err, qr/^INFO: /m, "AI_LOG: a file that cannot be written falls back to stderr");
}

# the functions
{
    local %::ORIG_ENV = ();
    local $::DEBUG = 0;
    my $called = 0;
    local $log::before_print = sub {$called++};
    open(my $olderr, '>&', \*STDERR) or die $!;
    open(STDERR, '>', "$tmp/unit.err") or die $!;
    log::info("quiet");
    log::error("loud");
    $::DEBUG = 1;
    log::info("debug");
    open(STDERR, '>&', $olderr) or die $!;
    my $got = do {open(my $fh, '<', "$tmp/unit.err") or die $!; local $/; <$fh>};
    unlike($got, qr/quiet/, "info: nothing without debug");
    like($got, qr/^ERROR: \[$$\]: .*: loud\nINFO: \[$$\]: .*: debug\n\z/, "error and info: one line each, with pid and time");
    is($called, 2, "the status line is wiped before each line on the terminal");
}

# who to become when started as root
{
    my $plan = sub {utils::privilege_plan(@_)};
    is_deeply($plan->({}, []), {uid => 1000, gid => 1000, groups => []}, "plan: 1000:1000 when nothing is said");
    is_deeply($plan->({UID => 1001, GID => 1002}, []), {uid => 1001, gid => 1002, groups => []}, "plan: UID and GID of the environment (aicli.sh)");
    is_deeply($plan->({UID => 1001, GID => 1002, AI_UID => 2001, AI_GID => 2002}, []), {uid => 2001, gid => 2002, groups => []}, "plan: AI_UID and AI_GID win");
    is_deeply($plan->({UID => 1001}, []), {uid => 1001, gid => 1000, groups => []}, "plan: only UID given (as before GID existed)");
    is_deeply($plan->({}, [0, 0, 44, 986, 109, 44]), {uid => 1000, gid => 1000, groups => [44, 986, 109]}, "plan: the groups of the process are kept (docker --group-add), without root's, each once");
    is_deeply($plan->({AI_GROUPS => "983 986,992:109"}, [0, 44]), {uid => 1000, gid => 1000, groups => [983, 986, 992, 109]}, "plan: AI_GROUPS instead");
    is_deeply($plan->({AI_GROUPS => ""}, [0, 44]), {uid => 1000, gid => 1000, groups => []}, "plan: an empty AI_GROUPS means none");
    is_deeply($plan->({GID => 986, AI_GROUPS => "986 109"}, []), {uid => 1000, gid => 986, groups => [109]}, "plan: the group itself is not repeated");
    foreach my $bad (0, "0", "root", "-1", "1000; rm", "", " 1000", "1e3"){
        is_deeply($plan->({UID => $bad, GID => $bad, AI_UID => $bad, AI_GID => $bad, AI_GROUPS => "$bad 0 x"}, [0]),
            {uid => 1000, gid => 1000, groups => []}, "plan: '$bad' is never accepted, root least of all");
    }
    # what aicli.sh sends by default is what ai.pl did before
    is_deeply($plan->({UID => 1000, GID => 1000, AI_GROUPS => "983 986 992 109"}, [0, 44, 986, 109, 992]),
        {uid => 1000, gid => 1000, groups => [983, 986, 992, 109]}, "plan: the docker wrapper gets the same user and groups as before");
}

# a tree changes hands
SKIP: {
    mkdir "$tmp/tree" or die $!;
    mkdir "$tmp/tree/sub" or die $!;
    open(my $fh, '>', "$tmp/tree/sub/file") or die $!;
    close($fh);
    symlink("/etc/passwd", "$tmp/tree/link") or die $!;
    # to ourselves: allowed without being root, and changes nothing
    utils::chown_tree("$tmp/tree", $<, (split ' ', $()[0]);
    is((stat("$tmp/tree/sub/file"))[4], $<, "chown_tree: runs over the tree");
    is((stat("/etc/passwd"))[4], 0, "chown_tree: a link is not followed");
}

# not root here: nothing is dropped, nothing complains
{
    plan(skip_all => "this test runs as root") if $< == 0;
    my ($out, $err, $rc) = ai_pl("", "/pwd\n", UID => 4242, AI_UID => 4243, AI_GROUPS => "1 2 3");
    is($rc, 0, "as a normal user the settings for root do nothing");
    is($err, "", "and nothing is said about it");
}

done_testing();
