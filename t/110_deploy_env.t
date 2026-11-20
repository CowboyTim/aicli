#!/usr/bin/perl
# deploy.sh (the part that writes): the .env and .agent.env of the stack, from the environment and the files:
# the secrets are made once and kept, a required value is refused when missing, the
# stale address of the broker is dropped
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use File::Copy ();

my $script = Cwd::abs_path("$FindBin::Bin/../deploy.sh");
sub stage { my ($d) = @_; File::Copy::copy($script, "$d/deploy.sh") or die "copy: $!"; return "$d/deploy.sh" }
my $dir = File::Temp::tempdir("aicli_setup_XXXXXX", TMPDIR => 1, CLEANUP => 1);

sub run_setup {
    my (%env) = @_;
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        %ENV = (PATH => $ENV{PATH}, HOME => $dir, AICLI_ENV_ONLY => 1, %env);
        exec("bash", stage($dir)) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    return $? >> 8;
}
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $d = <$h>; close $h; return $d // '' }
sub value { my ($f, $k) = @_; my ($v) = slurp($f) =~ m/^\Q$k\E=(.*)$/m; return $v }

my %in = (
    PUBLIC_DOMAIN => 'ai.example.org', CERTBOT_EMAIL => 'me@example.org',
    AI_PROJECTS => '/home/me/projects',
    IPV6_PREFIX => '2001:db8:1:2:c::8',
    AI_LOCAL_SERVER => 'http://[2001:db8:1:2::20]:8000/rocm/v1',
    AI_ASR_URL => 'http://[2001:db8:1:2::21]:52625/v1/audio/transcriptions',
);

is(run_setup(%in), 0, "the first run with what it needs");
my $env_f = "$dir/.env";
my $agent_f = "$dir/.agent.env";
is(value($env_f, 'PUBLIC_DOMAIN'), 'ai.example.org', "the domain is written");
ok(!defined value($env_f, 'AICLI_REGISTRY_HOST') && !defined value($env_f, 'PODMAN_SOCKET'),
    "no registry and no Podman socket: the broker starts no pods any more");
like(value($env_f, 'SEARXNG_SECRET'), qr/\A[0-9a-f]{64}\z/, "a secret is made");
like(value($env_f, 'SEARXNG_API_TOKEN'), qr/\A[0-9a-f]{64}\z/, "and the token of searxng");
is(value($env_f, 'IPV6_SUBNET'), '2001:db8:1:2:c::8:0/120', "the subnet of the default prefix");
is(value($env_f, 'IPV6_GATEWAY'), '2001:db8:1:2:c::8:1', "and its gateway");
ok(value($env_f, 'BROKER_UID') =~ m/^\d+$/, "the id of the user");
is(value($agent_f, 'AI_LOCAL_SERVER'), 'http://[2001:db8:1:2::20]:8000/rocm/v1', "agent: the model server, as given");
is(value($env_f, 'AI_ASR_URL'), 'http://[2001:db8:1:2::21]:52625/v1/audio/transcriptions', "the speech recognizer, as given: kept in .env, where compose reads it (its own address)");
ok(length value($agent_f, 'AI_MODEL'), "agent: a model");

my $secret = value($env_f, 'SEARXNG_SECRET');
my $stoken = value($env_f, 'SEARXNG_API_TOKEN');
is(run_setup(%in), 0, "a second run");
is(value($env_f, 'SEARXNG_SECRET'), $secret, "the secret stays the same");
is(value($env_f, 'SEARXNG_API_TOKEN'), $stoken, "and the token of searxng stays the same");
is(value($env_f, 'PUBLIC_DOMAIN'), 'ai.example.org', "one line per setting, not doubled");
is(scalar(() = slurp($env_f) =~ m/^PUBLIC_DOMAIN=/mg), 1, "the domain is written once");

# a setting in the environment replaces the file's, a setting in the file stays
is(run_setup(%in, CERTBOT_EMAIL => 'new@example.org'), 0, "a run with a changed email");
is(value($env_f, 'CERTBOT_EMAIL'), 'new@example.org', "the environment's email is written");

# a required value that is nowhere
my %missing = %in; delete $missing{PUBLIC_DOMAIN};
my $other = File::Temp::tempdir("aicli_setup2_XXXXXX", TMPDIR => 1, CLEANUP => 1);
{
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        %ENV = (PATH => $ENV{PATH}, HOME => $other, AICLI_ENV_ONLY => 1, %missing);
        open(STDERR, '>', "$other/err") or POSIX::_exit(9);
        exec("bash", stage($other)) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    isnt($? >> 8, 0, "without the domain the deploy.sh stops");
    like(slurp("$other/err"), qr/PUBLIC_DOMAIN is needed/, "and says which setting is missing");
}

# an agent.env of earlier versions moves to .agent.env with its settings
{
    my $old = File::Temp::tempdir("aicli_setup3_XXXXXX", TMPDIR => 1, CLEANUP => 1);
    open(my $o, '>', "$old/agent.env") or die $!; print {$o} "AI_UI_TOKEN=keep-me\n"; close $o;
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        %ENV = (PATH => $ENV{PATH}, HOME => $old, AICLI_ENV_ONLY => 1, %in);
        exec("bash", stage($old)) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    is($? >> 8, 0, "a run with an old agent.env");
    ok(!-e "$old/agent.env", "the old agent.env is gone");
    is(value("$old/.agent.env", 'AI_UI_TOKEN'), 'keep-me', "its settings are in .agent.env");
}

# AI_ASR_URL= (set and empty) clears the recognizer's URL from both files: the flm service is the default
is(run_setup(%in, AI_ASR_URL => ''), 0, "a second run with AI_ASR_URL cleared");
ok(!defined value($env_f, 'AI_ASR_URL'), "the URL is gone from .env");
ok(!defined value($agent_f, 'AI_ASR_URL'), "and from .agent.env");

done_testing();
