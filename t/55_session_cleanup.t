#!/usr/bin/perl
# sessions do not pile up: empty ones go, old ones can be pruned
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $day = 86400;
sub cmd {
    my ($line) = @_;
    return TestAI::capture {ai::handle_command($line)};
}
sub age {
    my ($dir, $days) = @_;
    my $t = time() - $days * $day;
    utime($t, $t, "$dir/chat") or die "$dir/chat: $!";
}

# ai.pl as a process
{
    my $tmp = TestAI::setup();
    my $base = "$tmp/cli";
    delete local @ENV{grep {m/^AI_/} keys %ENV};
    delete local @ENV{qw(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy DEBUG)};
    local $ENV{AI_DIR} = $base;
    local $ENV{AI_CONFIG} = "$tmp/noconfig";
    local $ENV{AI_LOCAL_SERVER} = "http://127.0.0.1:9";
    local $ENV{AI_RETRIES} = 0;
    my $ai = sub {
        my ($args, $input, %env) = @_;
        local @ENV{keys %env} = values %env;
        ai::spew("$tmp/in", $input // '');
        my $out = `cd $tmp && $^X $TestAI::ROOT/ai.pl $args < $tmp/in 2>&1`;
        return $out =~ s/\e\[[0-9;]*m//gr;
    };
    my $sessions = sub {[sort map {s{.*/}{}r} glob("$base/sessions/*")]};

    my $out = $ai->("", "/session list\n/pwd\n");
    like($out, qr/^\* session-\S+  now$/m, "during the run the session is there");
    is_deeply($sessions->(), [], "nothing said: the made-up session is gone at the end");
    $ai->("-p ''");
    $ai->("", "/nope\n/help\n/exit\n");
    $ai->("", "");
    is_deeply($sessions->(), [], "also after -p '', only commands, or no input at all");

    $ai->("", "/system remember this\n");
    is(scalar(@{$sessions->()}), 1, "a /system message is something said: kept");
    $ai->("", "/model some-model\n");
    is(scalar(@{$sessions->()}), 2, "a model set for the session: kept");
    $ai->("-p 'hello?'");
    is(scalar(@{$sessions->()}), 3, "a request, even one that failed: kept");
    $ai->("", "/pwd\n", AI_SESSION => "mine");
    ok(-d "$base/sessions/mine", "a session the user named is kept, empty or not");
    $ai->("", "/session create project-x\n");
    is_deeply([grep {!m/^session-/} @{$sessions->()}], ["mine", "project-x"], "/session create: the named one stays, the made-up one it was created from goes");
    is(scalar(@{$sessions->()}), 5, "5 sessions now");
    $ai->("", "/session delete mine\n", AI_SESSION => "mine");
    is(scalar(@{$sessions->()}), 4, "deleting the current session leaves nothing behind either");

    # what a crash leaves: empty, made up, older than a day
    foreach my $name ("session-0000AAAA-1111-2222-3333-444455556666", "session-0000BBBB-1111-2222-3333-444455556666", "empty-but-named"){
        $ai->("", "/pwd\n", AI_SESSION => $name);
    }
    age("$base/sessions/session-0000AAAA-1111-2222-3333-444455556666", 2);
    age("$base/sessions/empty-but-named", 200);
    my ($talked) = grep {(ai::slurp("$base/sessions/$_/chat") // '') =~ m/remember this/} @{$sessions->()};
    age("$base/sessions/$talked", 300);
    $ai->("", "/pwd\n");
    ok(!-d "$base/sessions/session-0000AAAA-1111-2222-3333-444455556666", "start: an old empty made-up session is removed");
    ok(-d "$base/sessions/session-0000BBBB-1111-2222-3333-444455556666", "start: a young one is not (it may be in use right now)");
    ok(-d "$base/sessions/empty-but-named", "start: one with a name of the user is not");
    ok(-d "$base/sessions/$talked", "start: one with a conversation is not, however old");

    # AI_SESSION_KEEP_DAYS: at start, without asking
    age("$base/sessions/project-x", 40);
    $out = $ai->("", "/pwd\n", AI_SESSION_KEEP_DAYS => 400);
    ok(-d "$base/sessions/$talked", "AI_SESSION_KEEP_DAYS: younger than that stays");
    $out = $ai->("", "/session list\n", AI_SESSION_KEEP_DAYS => 30, AI_SESSION => "project-x");
    like($out, qr/^Removed 2 sessions not used for 30 days \(AI_SESSION_KEEP_DAYS\)\.$/m, "AI_SESSION_KEEP_DAYS: says what it removed");
    ok(!-d "$base/sessions/$talked" && !-d "$base/sessions/empty-but-named", "AI_SESSION_KEEP_DAYS: old sessions are removed, conversation or not");
    ok(-d "$base/sessions/project-x", "AI_SESSION_KEEP_DAYS: never the session that is being used");
    $out = $ai->("", "/pwd\n", AI_SESSION_KEEP_DAYS => "soon");
    unlike($out, qr/Removed/, "AI_SESSION_KEEP_DAYS: nonsense is ignored");
}

# what is known about a session, and the list
{
    my $tmp = TestAI::setup();
    my $dir = "$tmp/aicli/sessions";
    my $i = ai::session_info("test");
    ok($i->{empty}, "info: a new session is empty");
    is($i->{first}, "", "info: nothing said");
    ok($i->{size} > 100, "info: size on disk ($i->{size})");
    ok($i->{age} < 5, "info: just used");
    ai::append_messages({role => 'user', content => "[BASH_7c48 RESULT_d170\nx\nRESULT_d170]"},
        {role => 'user', content => "fix the   parser\nplease"}, {role => 'assistant', content => "ok"});
    $i = ai::session_info("test");
    ok(!$i->{empty}, "info: not empty with a conversation");
    is($i->{first}, "fix the   parser\nplease", "info: the first thing the user said, not a tool result");
    foreach my $what (qw(model usage chat.archive)){
        cmd("/session create e-$what");
        ok(ai::session_info("e-$what")->{empty}, "info: e-$what starts empty");
        ai::spew("$dir/e-$what/$what", "x");
        ok(!ai::session_info("e-$what")->{empty}, "info: a $what file is worth keeping");
    }
    cmd("/session create e-system");
    cmd("/system extra");
    ok(!ai::session_info("e-system")->{empty}, "info: a /system message too");
    cmd("/session test");

    is(ai::format_age($_->[0]), $_->[1], "age: $_->[1]") for [5, "now"], [59, "now"], [60, "1m"], [3599, "59m"], [7200, "2h"], [86400, "1d"], [86400 * 45.5, "45d"];
    ok(ai::is_auto_name("session-2A3FD0F6-DE25-11F1-8599-C582898A76D7"), "auto name: a uuid");
    ok(ai::is_auto_name("session-6736A1B2-1A2B-3C4D-5E6F-0A1B2C0D1E2F"), "auto name: the fallback id");
    ok(!ai::is_auto_name($_), "auto name: not '$_'") for "session-notes", "work", "session-", "my-session-2A3FD0F6-DE25-11F1-8599-C582898A76D7";

    age("$dir/e-model", 3);
    my $list = cmd("/session list") =~ s/\e\[[0-9;]*m//gr;
    like($list, qr/^\* test  now  fix the parser please$/m, "list: the current one, when it was used, what it is about");
    like($list, qr/^  e-model  3d$/m, "list: age of the others");
    cmd("/session create long");
    ai::append_messages({role => 'user', content => "a very long first message " x 10});
    cmd("/session test");
    like(cmd("/session list"), qr/^  long  now  a very long first message a very long first messa\xe2\x80\xa6$/m, "list: long first messages are cut");
}

# /session prune
{
    my $tmp = TestAI::setup();
    my $dir = "$tmp/aicli/sessions";
    ai::append_messages({role => 'user', content => "current work"});
    foreach my $s (["old-talk", 90, "an old conversation"], ["older-talk", 400, "from last year"], ["recent", 3, "last week"], ["old-empty", 50, undef]){
        cmd("/session create $s->[0]");
        ai::append_messages({role => 'user', content => $s->[2]}) if defined $s->[2];
        cmd("/session test");
        age("$dir/$s->[0]", $s->[1]);
    }
    age("$dir/test", 500); # the current one, old as it may be

    my $asked;
    no warnings 'redefine';
    local *ai::confirm = sub {$asked = $_[0]; 0};
    my $out = cmd("/session prune");
    like($out, qr/\A  older-talk  400d  \d+k  from last year\n  old-talk  90d  \d+k  an old conversation\n  old-empty  50d  \d+k  \(empty\)\n/, "prune: lists what was not used for 30 days, oldest first, with what it is");
    unlike($out, qr/recent|test/, "prune: not the recent one, never the current one");
    like($asked, qr/\ADelete 3 sessions not used for 30 days, \d+k\?\z/, "prune: asks");
    like($out, qr/Nothing deleted\.\n\z/, "prune: no means no");
    is(scalar(@{ai::get_sessions()}), 5, "prune: all still there");

    local *ai::confirm = sub {$asked = $_[0]; 1};
    $out = cmd("/session prune 100");
    like($out, qr/\A  older-talk  400d.*\nDeleted 1 session not used for 100 days, \d+k\.\n\z/, "prune 100: only what is older than that, after a yes");
    ok(!-d "$dir/older-talk" && -d "$dir/old-talk", "prune 100: on disk");
    $asked = undef;
    $out = cmd("/session prune 30 yes");
    is($asked, undef, "prune yes: does not ask");
    like($out, qr/Deleted 2 sessions not used for 30 days/, "prune yes: deletes");
    is_deeply(ai::get_sessions(), ["recent", "test"], "prune: the recent and the current session are left");
    like(cmd("/session prune"), qr/\ANo sessions that were not used for 30 days\.\n\z/, "prune: nothing left to do");
    {
        local $::ORIG_ENV{AI_SESSION_KEEP_DAYS} = 2;
        like(cmd("/session prune yes"), qr/Deleted 1 session not used for 2 days/, "prune: AI_SESSION_KEEP_DAYS is the default number of days");
    }
    like(cmd("/session prune soon"), qr{\AUsage: /session prune \[days\] \[yes\]}, "prune: usage");
    TestAI::mock_http();
    ai::setup_commands();
    my @c = ai::chat_word_completions_cli("", "/session ", 9, 9);
    ok(scalar(grep {$_ eq 'prune'} @c) && scalar(grep {$_ eq 'reset'} @c), "prune and reset are completed");
}

# the question itself
{
    my $tmp = TestAI::setup();
    foreach my $case (["y\n", 1], ["yes\n", 1], [" Y \n", 1], ["n\n", 0], ["\n", 0], ["yep\n", 0], ["", 0]){
        ai::spew("$tmp/answer", $case->[0]);
        open(my $old, '<&', \*STDIN) or die $!;
        open(STDIN, '<', "$tmp/answer") or die $!;
        my $r;
        my $out = TestAI::capture {$r = ai::confirm("Sure?")};
        open(STDIN, '<&', $old) or die $!;
        is($r, $case->[1], "confirm: '".($case->[0] =~ s/\n/\\n/r)."' is ".($case->[1] ? "yes" : "no"));
        is($out, "Sure? [y/N] ", "confirm: the question") if $case->[0] eq "y\n";
    }
}

# the made-up session of this process, as ai.pl would have it
{
    my $tmp = TestAI::setup(AI_SESSION => undef);
    my $name = $ai::AI_SESSION;
    ok(ai::is_auto_name($name) && $ai::AUTO_SESSION{$name}, "a session without a name is marked as made up ($name)");
    ai::drop_empty_sessions();
    ok(!-d "$tmp/aicli/sessions/$name", "drop: empty, so it goes");
    TestAI::setup(AI_SESSION => undef);
    $name = $ai::AI_SESSION;
    ai::append_messages({role => 'user', content => "something"});
    ai::drop_empty_sessions();
    ok(-d "$tmp/aicli/sessions/$name" || -d "$TestAI::TMP/aicli/sessions/$name", "drop: with something said it stays");
    %ai::AUTO_SESSION = ();
}

chdir("/");
done_testing();
