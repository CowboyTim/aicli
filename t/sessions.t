#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

my $tmp = tempdir(CLEANUP => 1);
$ENV{AI_DIR} = "$tmp/.aicli";
$ENV{AI_CONFIG} = "$tmp/config";
$ENV{AI_API_KEY} = "sk-test";
$ENV{AI_PROMPT_TEMPLATE_FILE} = "t/resources/default";

# Create dummy config
open(my $fh, '>', $ENV{AI_CONFIG});
print $fh "AI_API_KEY=sk-test\n";
close $fh;

# Test session list
print "Testing /session list...\n";
my $out = `echo "/session list" | ./ai.pl 2>&1`;
like($out, qr/\* session-/, "Should show current session in list");

# Test session create
print "Testing /session create...\n";
$out = `echo "/session create test-session" | ./ai.pl 2>&1`;
ok(-d "$ENV{AI_DIR}/sessions/test-session", "test-session directory should exist");
like($out, qr/Created session 'test-session'/, "Output should confirm creation");
like($out, qr/Switched to session: test-session/, "Output should confirm switch");

# Test session rename
print "Testing /session rename...\n";
$out = `echo "/session rename test-session renamed-session" | ./ai.pl 2>&1`;
ok(!-d "$ENV{AI_DIR}/sessions/test-session", "old directory should not exist");
ok(-d "$ENV{AI_DIR}/sessions/renamed-session", "new directory should exist");
like($out, qr/Renamed session 'test-session' to 'renamed-session'/, "Output should confirm rename");

# Test session delete
print "Testing /session delete...\n";
# First create another session to switch to, because we can't delete current
`echo "/session create another" | ./ai.pl 2>&1`;
$out = `echo "/session delete renamed-session" | ./ai.pl 2>&1`;
ok(!-d "$ENV{AI_DIR}/sessions/renamed-session", "deleted session directory should not exist");
like($out, qr/Deleted session 'renamed-session'/, "Output should confirm deletion");

done_testing();
