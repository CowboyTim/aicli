#!/usr/bin/perl
# a session worker is confined by the kernel: it writes in its workspace, the
# temp directory and its session, nowhere else; it reads everywhere; the tools'
# children inherit that limit. Checked in a forked worker (landlock).
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use POSIX ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use worker;
use TestAI;

{
    local $sandbox::ABI;
    plan(skip_all => "this kernel has no landlock") unless sandbox::abi();
}

TestAI::setup(AI_SANDBOX => 'auto');
my $tmp = $TestAI::TMP;
my $ws  = "$tmp/workspace";
mkdir $ws or die "mkdir: $!";
ai::init_session('s-conf');
ai::set_workspace($ws);

# outside everything the worker may write: the test directory, not under /tmp
my $outside = "$FindBin::Bin/sandbox-probe-$$";

pipe(my $rd, my $wr) or die "pipe: $!";
my $pid = fork() // die "fork: $!";
if (!$pid) {
    close $rd;
    ai::use_session('s-conf');
    my $confined = worker::confine();
    my $try = sub {
        my ($path) = @_;
        my $fh;
        return 0 unless open($fh, '>', $path);
        return close($fh) ? 1 : 0;
    };
    my $can_read = sub { my $fh; return open($fh, '<', $_[0]) ? 1 : 0 };
    my %r = (
        confined => $confined,
        ws       => $try->("$ws/inside.txt"),
        session  => $try->("$ai::AI_SESSION_DIR/probe.txt"),
        outside  => $try->($outside),
        read     => $can_read->('/etc/hosts'),
        child    => system('sh', '-c', "echo x > $outside 2>/dev/null") == 0 ? 1 : 0,
    );
    print {$wr} join(' ', map {"$_=$r{$_}"} sort keys %r)."\n";
    close $wr;
    POSIX::_exit(0);
}
close $wr;
my $line = do { local $/ = "\n"; <$rd> } // '';
waitpid($pid, 0);
my %r = map {split /=/, $_, 2} split ' ', $line;
unlink $outside;

is($r{confined}, 1, "the worker is confined");
is($r{ws}, 1, "it writes in its workspace");
is($r{session}, 1, "and in its session");
is($r{outside}, 0, "not outside them");
is($r{read}, 1, "it reads everywhere");
is($r{child}, 0, "and the tools' children cannot write outside either");
ok(!-e $outside, "the probe file was not made");

done_testing();
