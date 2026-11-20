#!/usr/bin/perl
# the docker wrapper (aicli.sh): --root mounts the root and starts in the current
# project; without it the current directory is mounted, as before. A fake docker
# records what the wrapper would run.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use POSIX ();

my $ROOT = "$FindBin::Bin/..";
my $tmp  = File::Temp::tempdir("aicli_wrap_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $fake = "$tmp/bin";
mkdir $fake or die "mkdir: $!";
open(my $fh, '>', "$fake/docker") or die "docker: $!";
print {$fh} qq{#!/bin/sh\nfor a in "\$@"; do printf '%s\\n' "\$a"; done > "$tmp/args"\n};
close $fh;
chmod 0755, "$fake/docker";

# the arguments the wrapper gave docker, as lines
sub run_wrapper {
    my ($dir, @args) = @_;
    unlink "$tmp/args";
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        chdir($dir) or POSIX::_exit(9);
        open(STDOUT, '>', "$tmp/out") or POSIX::_exit(9);
        open(STDERR, '>', "$tmp/err") or POSIX::_exit(9);
        $ENV{PATH} = "$fake:$ENV{PATH}";
        $ENV{DOCKER_IMAGE} = 'local/test:latest';
        $ENV{LOGNAME} = 'tester';
        exec('bash', "$ROOT/aicli.sh", @args) or POSIX::_exit(9);
    }
    waitpid($pid, 0);
    my $status = $? >> 8;
    my $args = -f "$tmp/args" ? do { local $/; open(my $a, '<', "$tmp/args") or die; <$a> } : '';
    my $err  = do { local $/; open(my $e, '<', "$tmp/err") or die; <$e> } // '';
    return ($status, [split /\n/, $args], $err);
}

my $root = Cwd::abs_path(File::Temp::tempdir("aicli_root_XXXXXX", TMPDIR => 1, CLEANUP => 1)) . "/master";
mkdir $root or die "mkdir: $!";
mkdir "$root/acme" unless -d "$root/acme"; mkdir "$root/acme/alpha" or die "mkdir: $!";
mkdir "$root/acme/alpha/src" or die "mkdir: $!";
mkdir "$root/acme" unless -d "$root/acme"; mkdir "$root/acme/beta" or die "mkdir: $!";

{
    my ($status, $args, $err) = run_wrapper("$root/acme/alpha/src", '--root', $root, '-c');
    is($status, 0, "--root from a project runs");
    ok((grep {$_ eq "$root:/workdir/master"} @$args), "the root is mounted at /workdir/master");
    my @w_index = grep {$args->[$_] eq '-w'} 0 .. $#$args;
    is($args->[$w_index[0] + 1], '/workdir/master/acme/alpha/src', "the container starts in the project");
    ok((grep {$_ eq "CDIR=/workdir/master/acme/alpha/src"} @$args), "and CDIR says so");
    ok((grep {$_ eq 'aicli-tester-root-master'} @$args), "the container is named for the root");
    unlike(join(' ', @$args), qr{$tmp/ }, "nothing of the temp directory is mounted");
}

{
    my ($status, $args) = run_wrapper($root, '--root', $root);
    is($status, 0, "--root from the root runs");
    my @w_index = grep {$args->[$_] eq '-w'} 0 .. $#$args;
    is($args->[$w_index[0] + 1], '/workdir/master', "and starts in the root");
}

{
    my ($status, $args, $err) = run_wrapper($tmp, '--root', $root);
    isnt($status, 0, "a directory outside the root is refused");
    like($err, qr/not inside the root/, "and it says why");
}

{
    my ($status, $args) = run_wrapper($root, '--root=' . $root);
    is($status, 0, "--root=DIR works too");
}

{
    my ($status, $args) = run_wrapper("$root/acme/beta");
    is($status, 0, "without --root the directory is mounted, as before");
    ok((grep {$_ eq "$root/acme/beta:/workdir/beta"} @$args), "the current directory at /workdir/<its name>");
    my @w_index = grep {$args->[$_] eq '-w'} 0 .. $#$args;
    is($args->[$w_index[0] + 1], '/workdir/beta', "and the container starts there");
}

{
    my ($status, $args) = run_wrapper($root, '--broker');
    is($status, 0, "--broker runs without --root (the broker is not the tools' host)");
    ok((grep {$_ eq 'aicli-broker:/run/aicli-broker'} @$args), "the broker's socket volume is mounted");
    ok(!(grep {/^AI_POD_ROOT=/} @$args), "and no pod root is given: there are no pods");
}

done_testing();
