#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use FindBin;

chdir("$FindBin::Bin/..") or die $!;

my $tmp = tempdir(CLEANUP => 1);
$ENV{AI_DIR} = "$tmp/.aicli";
$ENV{AI_CONFIG} = "$tmp/config";
$ENV{AI_PROMPT_TEMPLATE_FILE} = "t/resources/default";
# no server needed for session commands, nothing listens on the discard port
$ENV{AI_LOCAL_SERVER} = "http://127.0.0.1:9";
delete @ENV{qw(AI_API_KEY AI_PROVIDER AI_SESSION AI_CLEAR AI_PROXY HTTPS_PROXY HTTP_PROXY https_proxy http_proxy)};

# Create config: settings come from there too
open(my $fh, '>', $ENV{AI_CONFIG});
print $fh "AI_MODEL='from-config'\n";
close $fh;

# ai.pl as a process, commands on stdin
sub ai_pl {
    my (@lines) = @_;
    open(my $ifh, '>', "$tmp/input") or die $!;
    print {$ifh} map {"$_\n"} @lines;
    close $ifh;
    return scalar `$^X ./ai.pl < $tmp/input 2>&1`;
}

# Test session list
print "Testing /session list...\n";
my $out = ai_pl("/session list");
like($out, qr/\* session-/, "Should show current session in list");

# Test session create
print "Testing /session create...\n";
$out = ai_pl("/session create test-session");
ok(-d "$ENV{AI_DIR}/sessions/test-session", "test-session directory should exist");
like($out, qr/Created session 'test-session'/, "Output should confirm creation");
like($out, qr/Switched to session: test-session/, "Output should confirm switch");

# Test session rename
print "Testing /session rename...\n";
$out = ai_pl("/session rename test-session renamed-session");
ok(!-d "$ENV{AI_DIR}/sessions/test-session", "old directory should not exist");
ok(-d "$ENV{AI_DIR}/sessions/renamed-session", "new directory should exist");
like($out, qr/Renamed session 'test-session' to 'renamed-session'/, "Output should confirm rename");

# Test session delete
print "Testing /session delete...\n";
# First create another session to switch to, because we can't delete current
ai_pl("/session create another");
$out = ai_pl("/session delete renamed-session");
ok(!-d "$ENV{AI_DIR}/sessions/renamed-session", "deleted session directory should not exist");
like($out, qr/Deleted session 'renamed-session'/, "Output should confirm deletion");

# One process: the session survives between commands, the model is per session
print "Testing a session over several commands...\n";
$ENV{AI_SESSION} = "kept";
$out = ai_pl("/model my-model", "/session create other", "/session list", "/session kept", "/session delete other", "/session list");
like($out, qr/Switched model to 'my-model'/, "model switched");
like($out, qr/\* other.*Switched to session: kept.*Deleted session 'other'/s, "create, switch back, delete in one run");
$out = ai_pl("/session list");
like($out, qr/\* kept/, "AI_SESSION selects the session");
unlike($out, qr/^\s*other$/m, "deleted session is gone");
open(my $mfh, '<', "$ENV{AI_DIR}/sessions/kept/model") or die $!;
is(scalar(<$mfh>), "my-model", "model stored with the session");
ok(-s "$ENV{AI_DIR}/sessions/kept/chat", "session has its conversation file");

# bad session names and a missing key are refused at startup
$ENV{AI_SESSION} = "../escape";
$out = ai_pl("/session list");
like($out, qr/Invalid session name/, "invalid AI_SESSION refused");
ok(!-e "$ENV{AI_DIR}/escape", "nothing created outside of sessions/");
delete $ENV{AI_SESSION};
delete $ENV{AI_LOCAL_SERVER};
$out = ai_pl("/session list");
like($out, qr/Please set AI_API_KEY/, "no key and no local server: says what to do");
$ENV{AI_API_KEY} = "unknown-key-format";
$out = ai_pl("/session list");
like($out, qr/Unable to detect provider/, "unknown key prefix: says what to do");
$ENV{AI_API_KEY} = "csk-test";
$out = ai_pl("/session list");
like($out, qr/\* session-/, "provider detected from the key prefix");

# --help
$out = `$^X ./ai.pl --help 2>&1`;
is($?, 0, "--help: exit 0");
like($out, qr/Usage:.*ai\.pl \[options\]/s, "--help: usage shown");
$out = `$^X ./ai.pl -h 2>&1`;
is($?, 0, "-h: exit 0");
like($out, qr/Usage:.*ai\.pl \[options\]/s, "-h: usage shown");
$out = `$^X ./ai.pl --man 2>&1 < /dev/null`;
is($?, 0, "--man: exit 0");
like($out, qr/NAME.*SYNOPSIS.*OPTIONS.*ENVIRONMENT VARIABLES/s, "--man: the whole manual");
$out = `$^X ./ai.pl --no-such-option 2>&1`;
is($? >> 8, 2, "unknown option: exit 2");
like($out, qr/Unknown option.*Usage:/s, "unknown option: the usage is shown");

done_testing();
