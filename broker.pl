#!/usr/bin/perl
# The broker: the control plane of the remote agents. It keeps the agents of the users (their
# enrollment, their tags, the hashes of their tokens), gives a job to an agent of the job's
# account that has its tags, and gets the answer back. It runs no program and holds no
# project: a project's files are on the machine of its agent, where the job runs in the
# agent's container. A local ai.pl runs its tools in its own container, not here.
#
# A request on the broker's Unix socket is one JSON line, the answer one JSON line:
#   {"op":"exec","project":"acme/alpha","tags":["zigbee"],"argv":["grep","-rn","x","."],"timeout":60}
#   {"op":"enroll_token","user":"<account>"}        a user's enrollment token (shown once)
#   {"op":"agents","user":"<account>"}              the user's agents
#   {"op":"agent_revoke","user":"<account>","name":"pi"}
# The agents call in on the listener (AI_BROKER_AGENT_LISTEN, behind nginx's /agents/ route):
# GET /agents/poll, POST /agents/result/<id>, POST /agents/enroll (remote_hub.pm).
#
# An exec waits for the agent's answer, which is sent when the agent has run the job. The
# job's program is checked by the agent (its own list), and the account of the project must
# be the account of the agent. Nothing else is done here.
#
# Usage:
#   broker.pl            serve (AI_BROKER_CONFIG, a JSON file)

use strict; use warnings;
use IO::Socket::UNIX ();
use IO::Socket::IP ();
use IO::Select ();
use Socket ();
use JSON::XS ();
use POSIX ();
use MIME::Base64 ();
use FindBin ();
use lib $FindBin::Bin;
use remote_hub ();

package broker;

my $JSON = JSON::XS->new->canonical(1)->utf8;

# an account: the name of a login, a directory under the root, no dash (see auth.pl)
our $ACCOUNT_RE = qr/[A-Za-z0-9][A-Za-z0-9_]{0,95}/;

# the log: one line per event on stderr, which `docker logs` shows. Never a request's whole
# body, nor a job's output.
our $LOG = \*STDERR;
sub _log {
    my ($msg) = @_;
    my @t = localtime;
    printf {$LOG} "%04d-%02d-%02d %02d:%02d:%02d broker[%d]: %s\n",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $$, $msg;
    return;
}

sub new {
    my ($class, %c) = @_;
    my $self = bless {
        socket       => $c{socket} // '/run/aicli-broker/broker.sock',
        agent_listen => $c{agent_listen},                            # host:port of the agents (nginx passes them on)
        hub          => remote_hub->new(agents => $c{agents}, state_file => $c{state_file}),
    }, $class;
    return $self;
}

# the answer to one request (a JSON text), as a hash; every request is logged. $send (optional)
# gets the answer when it is not there yet (a job on an agent)
sub handle {
    my ($self, $line, $send) = @_;
    my $res = $self->_dispatch($line, $send);
    return undef unless defined $res; # answered later, through $send
    my $req = eval {$JSON->decode($line)};
    my $what = ref($req) eq 'HASH'
        ? sprintf("op=%s project=%s", $req->{op} // '-', substr($req->{project} // '-', 0, 80))
        : 'not a JSON object: '.substr($line // '', 0, 60);
    _log("request $what -> ".($res->{ok} ? 'ok' : "refused: $res->{error}"));
    return $res;
}

sub _dispatch {
    my ($self, $line, $send) = @_;
    my $req = eval {$JSON->decode($line)};
    return {ok => JSON::XS::false(), error => "a JSON object is wanted"} unless ref($req) eq 'HASH';
    my $op = $req->{op} // '';
    return $self->_exec($req, $send) if $op eq 'exec';
    # the agents of a user, from the web interface (its user, from the login): an enrollment
    # token (shown once), the list, and a revocation
    if ($op eq 'enroll_token' or $op eq 'agents' or $op eq 'agent_revoke') {
        my $user = $req->{user};
        return {ok => JSON::XS::false(), error => "a user (an account name) is wanted"}
            unless defined $user and !ref($user) and $user =~ m/\A$ACCOUNT_RE\z/;
        return {ok => JSON::XS::true(), token => $self->{hub}->issue_enroll($user)} if $op eq 'enroll_token';
        return {ok => JSON::XS::true(), agents => $self->{hub}->agents_of($user)} if $op eq 'agents';
        return {ok => JSON::XS::false(), error => "a name of an agent is wanted"}
            unless defined $req->{name} and !ref($req->{name});
        return $self->{hub}->revoke($user, $req->{name});
    }
    return {ok => JSON::XS::false(), error => "unknown request '$op' (exec, enroll_token, agents or agent_revoke)"};
}

# a project's name: account/project, both parts of the shape the page uses (the directories
# are on the agents, not here)
sub project_name {
    my ($self, $name) = @_;
    return undef unless defined $name and !ref($name);
    my ($account, $project) = $name =~ m{\A($ACCOUNT_RE)/([A-Za-z0-9][A-Za-z0-9._-]{0,62})\z} or return undef;
    return $name;
}

# the account of a project name (the first part), or undef
sub account_of { my ($name) = @_; return undef unless defined $name; my ($a) = $name =~ m{\A([^/]+)/}; return $a }

our $AGENT_EXEC_TIMEOUT = 120;   # the most a job may take, the agent's own limit comes on top
our $ARGV_MAX = 256 * 1024;      # the bytes of a command

# a job for an agent: the project, the tags the agent must have, the program and its arguments
# (no shell). The answer comes when the agent has run it, or now when it cannot.
sub _exec {
    my ($self, $req, $send) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project (account/project)"};
    my $tags = $req->{tags};
    return {ok => JSON::XS::false(), error => "a list of tags is wanted (the agent's tags)"}
        unless ref($tags) eq 'ARRAY' and @$tags and @$tags <= 8
            and !grep {ref($_) or !defined($_) or !m/\A[a-z][a-z0-9-]{0,31}\z/} @$tags;
    my $argv = $req->{argv};
    return {ok => JSON::XS::false(), error => "a list of the program and its arguments is wanted"}
        unless ref($argv) eq 'ARRAY' and @$argv and @$argv <= 64 and !grep {ref($_) or !defined($_)} @$argv;
    my $size = 0;
    $size += length($_) for @$argv;
    return {ok => JSON::XS::false(), error => "the command is too long"} if $size > $ARGV_MAX;
    my $timeout = $req->{timeout} // $AGENT_EXEC_TIMEOUT;
    return {ok => JSON::XS::false(), error => "a timeout (seconds) is wanted, at most $AGENT_EXEC_TIMEOUT"}
        unless $timeout =~ m/\A\d+\z/ and $timeout >= 1 and $timeout <= $AGENT_EXEC_TIMEOUT;
    return {ok => JSON::XS::false(), error => "the job needs a connection to answer on"} unless $send;
    my $tagstr = join(' ', @$tags);
    $self->{hub}->submit(project => $name, account => account_of($name), tags => [@$tags], argv => $argv, timeout => $timeout,
        done => sub {
            my ($r) = @_;
            _log("exec project=$name tags=$tagstr program=$argv->[0] -> "
                .($r->{ok} ? "exit $r->{exit}" : "refused: $r->{error}"));
            $r->{output} = MIME::Base64::encode_base64($r->{output} // '', '') if $r->{ok};
            $send->($r);
        });
    return undef; # answered through $send
}

# the listener of the agents (TCP, behind nginx), or undef when there is none
sub _agent_listener {
    my ($self) = @_;
    return undef unless $self->{hub}->enabled and length($self->{agent_listen} // '');
    my ($host, $port) = $self->{agent_listen} =~ m/\A(.*):(\d+)\z/
        or die "broker: agent_listen is host:port, '$self->{agent_listen}'\n";
    my $srv = IO::Socket::IP->new(LocalAddr => $host, LocalPort => $port, Listen => 16, ReuseAddr => 1, V6Only => 0)
        or die "broker: cannot listen for agents on $self->{agent_listen}: $!\n";
    _log("listening for agents on $self->{agent_listen}");
    return $srv;
}

our %HTTP_REASON = (200 => 'OK', 204 => 'No Content', 400 => 'Bad Request', 403 => 'Forbidden',
    404 => 'Not Found', 409 => 'Conflict', 413 => 'Payload Too Large');

# one request of an agent: HTTP/1.1, the body by Content-Length; the hub answers it (later,
# for a held poll). The connection is closed after the answer.
sub _agent_request {
    my ($self, $c) = @_;
    my $send = sub {
        my ($status, $body) = @_;
        $body //= '';
        my $head = "HTTP/1.1 $status ".($HTTP_REASON{$status} // 'Unknown')."\r\n"
            ."Content-Type: application/json\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n";
        print {$c} $head.$body;
        close($c);
        return;
    };
    my $req = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10;
        my $line = <$c>;
        die "no request\n" unless defined $line;
        my ($method, $path) = $line =~ m{\A([A-Z]+) (\S+) HTTP/1\.[01]\r?\n\z} or die "bad request line\n";
        my %h;
        my $n = 0;
        while (defined(my $l = <$c>)) {
            $l =~ s/\r?\n\z//;
            last if $l eq '';
            die "too many headers\n" if ++$n > 100;
            my ($k, $v) = $l =~ m/\A([A-Za-z0-9-]+):\s*(.*)\z/ or die "bad header\n";
            $h{lc $k} = $v;
        }
        my $len = $h{'content-length'} // 0;
        die "body too big\n" if $len !~ m/\A\d+\z/ or $len > 64 * 1024;
        my $body = '';
        read($c, $body, $len) if $len;
        alarm 0;
        {method => $method, path => $path, headers => \%h, body => $body};
    };
    alarm 0;
    unless ($req) {
        my $why = $@ =~ s/\s+\z//r;
        _log("agent request refused: $why");
        return $send->(400, '{"ok":false,"error":"a request is wanted"}');
    }
    $self->{hub}->http($req, $send);
    return;
}

# one request of a client (the web interface, a local ai.pl): one JSON line. A job on an agent
# is answered later, when the agent has run it; the connection stays open until then.
sub _client_request {
    my ($self, $c) = @_;
    my $send = sub {
        my ($res) = @_;
        print {$c} $JSON->encode($res)."\n";
        close($c);
        return;
    };
    my $line = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10;
        my $l = <$c>;
        alarm 0;
        $l;
    };
    alarm 0;
    _log("a client sent no request in 10 s") unless defined $line;
    if (!defined $line) {
        $send->({ok => JSON::XS::false(), error => "no request in time"});
        return;
    }
    my $res = $self->handle($line, $send);
    $send->($res) if defined $res;
    return;
}

# the broker's sockets: the requests of the clients (the Unix socket) and of the agents (the
# listener, when there are agents). Every round also ends the held polls and the jobs whose
# time is up.
sub serve {
    my ($self) = @_;
    my $path = $self->{socket};
    unlink($path) if -S $path;
    my $srv = IO::Socket::UNIX->new(Local => $path, Type => Socket::SOCK_STREAM(), Listen => 8)
        or die "broker: cannot listen on $path: $!\n";
    chmod(0660, $path);
    my ($gid) = split ' ', $(;
    _log("listening on $path as uid $< gid ".($gid // '?'));
    my $agents = $self->_agent_listener();
    local $SIG{PIPE} = 'IGNORE';
    my $sel = IO::Select->new($srv);
    $sel->add($agents) if $agents;
    while (1) {
        eval { $self->{hub}->tick(time); 1 } or _log("agent check failed: ".($@ =~ s/\s+\z//r));
        for my $fh ($sel->can_read(1)) {
            if ($fh == $srv) {
                my $c = $srv->accept or next;
                $self->_client_request($c);
            } elsif ($agents and $fh == $agents) {
                my $c = $agents->accept or next;
                eval { $self->_agent_request($c); 1 } or do {
                    _log("agent request failed: ".($@ =~ s/\s+\z//r));
                    close($c);
                };
            }
        }
    }
    return;
}

package main;

sub main {
    my @args = @_;
    my $cmd = $args[0] // 'serve';
    die "broker: serve is the only command\n" unless $cmd eq 'serve';
    my $cfg_file = $ENV{AI_BROKER_CONFIG} // '/etc/aicli/broker.json';
    open(my $fh, '<', $cfg_file) or die "broker: cannot read $cfg_file: $!\n";
    my $cfg = JSON::XS->new->decode(do { local $/; <$fh> });
    close($fh);
    $cfg->{socket}       = $ENV{AI_BROKER_SOCKET}       if length($ENV{AI_BROKER_SOCKET} // '');
    $cfg->{agent_listen} = $ENV{AI_BROKER_AGENT_LISTEN} if length($ENV{AI_BROKER_AGENT_LISTEN} // '');
    $cfg->{state_file}   = $ENV{AI_BROKER_STATE}        if length($ENV{AI_BROKER_STATE} // '');
    my $b = broker->new(%$cfg);
    broker::_log(sprintf("starting: socket=%s agent_listen=%s", $b->{socket}, $b->{agent_listen} // 'none'));
    $b->serve();
    return 0;
}

exit(main(@ARGV)) unless caller;
1;
