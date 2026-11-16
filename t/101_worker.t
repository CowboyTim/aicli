#!/usr/bin/perl
# a session worker (worker.pm): one chat in a process of its own, served over a
# socket: messages in, the events of the web page out, the end when the socket closes
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use POSIX ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;

use ai;
use ui;
use worker;
use TestAI;
use FakeLLM;

my $llm = FakeLLM::start();
TestAI::setup(AI_LOCAL_SERVER => $llm, AI_API_KEY => 'sk-worker', AI_MODEL => 'fake-1');
ai::init_session('w-one');

socketpair(my $master, my $side, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC())
    or die "socketpair: $!";
my $pid = fork() // die "fork: $!";
if (!$pid) {
    close $master;
    local $SIG{__WARN__} = sub {};
    my $rc = eval {worker::serve($side, session => 'w-one')};
    POSIX::_exit(defined $rc && $rc == 0 && !$@ ? 0 : 1);
}
close $side;
$master->autoflush(1);

# read the events until the turn ends (or the time is up)
my (@events, $buf);
my $read_until = sub {
    my ($done) = @_;
    local $SIG{ALRM} = sub { die "timeout\n" };
    eval {
        alarm 30;
        while (!$done->()) {
            my $n = sysread($master, my $chunk, 65536);
            last unless $n;
            $buf .= $chunk;
            while ($buf =~ s/^([^\n]*)\n//) {
                push @events, $::JSON->decode($1);
            }
        }
        alarm 0;
    };
    alarm 0;
    diag("read: $@") if $@;
};
my $turn_end = sub { grep {$_->{event} eq 'turn' and $_->{data}{state} eq 'end'} @events };

print {$master} $::JSON->encode({text => 'hello there'})."\n";
$read_until->(sub { $turn_end->() });

is($events[0]{event}, 'state', "the worker starts with the state");
is($events[0]{data}{session}, 'w-one', "the state names the session it serves");
ok((grep {$_->{event} eq 'turn' and $_->{data}{state} eq 'start'} @events), "a turn starts");
ok($turn_end->(), "and ends");
ok((grep {$_->{event} eq 'text' or $_->{event} eq 'tool'} @events), "the answer comes as events");

my $chat = do { open(my $fh, '<', "$ai::SESSIONS_DIR/w-one/chat") or die $!; local $/; <$fh> } // '';
like($chat, qr/hello there/, "the message is in the session's chat file (the worker wrote it)");

# the model list is asked for and sent
print {$master} $::JSON->encode({models => 1})."\n";
@events = ();
$read_until->(sub { grep {$_->{event} eq 'models'} @events });
ok((grep {$_->{event} eq 'models'} @events), "a models request is answered with the list");

# a slash command is refused, not sent to the model
print {$master} $::JSON->encode({text => '/help'})."\n";
@events = ();
$read_until->(sub { grep {$_->{event} eq 'failed'} @events });
ok((grep {$_->{event} eq 'failed'} @events), "a slash command is refused");

# the master closes the socket: the worker ends with status 0
close $master;
my $waited = 0;
for (1 .. 100) {
    $waited = waitpid($pid, POSIX::WNOHANG());
    last if $waited == $pid;
    select(undef, undef, undef, 0.1);
}
is($waited, $pid, "the worker ends when the master closes the socket");
is($? >> 8, 0, "with status 0");

FakeLLM::stop();
done_testing();
