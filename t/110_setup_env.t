#!/usr/bin/perl
# setup-env.sh: the .env and agent.env of the stack, from the environment and the files:
# the secrets are made once and kept, a required value is refused when missing, the
# stale address of the broker is dropped
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();

my $script = Cwd::abs_path("$FindBin::Bin/../setup-env.sh");
my $dir = File::Temp::tempdir("aicli_setup_XXXXXX", TMPDIR => 1, CLEANUP => 1);

sub run_setup {
    my (%env) = @_;
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        %ENV = (PATH => $ENV{PATH}, HOME => $dir, %env);
        exec('bash', $script, $dir) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    return $? >> 8;
}
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $d = <$h>; close $h; return $d // '' }
sub value { my ($f, $k) = @_; my ($v) = slurp($f) =~ m/^\Q$k\E=(.*)$/m; return $v }

my %in = (
    PUBLIC_DOMAIN => 'ai.example.org', CERTBOT_EMAIL => 'me@example.org',
    AI_PROJECTS => '/home/me/projects',
);

is(run_setup(%in), 0, "the first run with what it needs");
my $env_f = "$dir/.env";
my $agent_f = "$dir/agent.env";
is(value($env_f, 'PUBLIC_DOMAIN'), 'ai.example.org', "the domain is written");
like(value($env_f, 'SEARXNG_SECRET'), qr/\A[0-9a-f]{64}\z/, "a secret is made");
like(value($env_f, 'SEARXNG_API_TOKEN'), qr/\A[0-9a-f]{64}\z/, "and the token of searxng");
is(value($env_f, 'IPV6_SUBNET'), '2a02:a03f:8789:e700:c::8:0/120', "the subnet of the default prefix");
is(value($env_f, 'IPV6_GATEWAY'), '2a02:a03f:8789:e700:c::8:1', "and its gateway");
ok(value($env_f, 'BROKER_UID') =~ m/^\d+$/, "the id of the user");
is(value($agent_f, 'AI_LOCAL_SERVER'), 'http://[2a02:a03f:8789:e700::20]:8000/rocm/v1', "agent: the model server");
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
open(my $fh, '>>', $env_f) or die $!; print {$fh} "IPV6_ADDRESS=2001:db8::2\n"; close $fh;
is(run_setup(%in), 0, "a run with an old address in the file");
is(value($env_f, 'IPV6_ADDRESS'), undef, "the old address is dropped (deploy.sh looks it up)");

# a required value that is nowhere
my %missing = %in; delete $missing{PUBLIC_DOMAIN};
my $other = File::Temp::tempdir("aicli_setup2_XXXXXX", TMPDIR => 1, CLEANUP => 1);
{
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        %ENV = (PATH => $ENV{PATH}, HOME => $other, %missing);
        open(STDERR, '>', "$other/err") or POSIX::_exit(9);
        exec('bash', $script, $other) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    isnt($? >> 8, 0, "without the domain the setup stops");
    like(slurp("$other/err"), qr/PUBLIC_DOMAIN is needed/, "and says which setting is missing");
}

done_testing();
