#!/usr/bin/perl
# The broker: it starts the dev pods of the projects for the agent, and nothing
# else. It runs in a container of its own, the only one with the rootless Podman
# socket of the host mounted; the agent talks to it over a Unix socket in a volume
# that only the agent and the broker share. A request is one JSON line, the answer
# one JSON line:
#   {"op":"open","project":"alpha"}   start the pod of the project (image optional)
#   {"op":"close","project":"alpha"}  stop and remove it
#   {"op":"list"}                     the project pods
# Nothing else is done. What a request names reaches the engine only as the
# project's name (a directory directly under the root), its host path (under the
# host root), an image of the allowlist, and the limits of the config: never a
# privileged mode, a host network, a socket, or a path outside the root.
#
# Usage:
#   broker.pl                 serve (AI_BROKER_CONFIG, a JSON file)
#   broker.pl open NAME       ask a running broker (AI_BROKER_SOCKET), print the answer
#   broker.pl close NAME | list

use strict; use warnings;
use IO::Socket::UNIX ();
use Socket ();
use JSON::XS ();
use POSIX ();

package broker;

my $JSON = JSON::XS->new->canonical(1)->utf8;

# the log: one line per event on stderr, which `docker logs` shows. Never a request's
# whole body, and nothing of the engine's answers but the status code.
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
    die "broker: host_root (the host path of the projects) is needed\n" unless length($c{host_root} // '');
    my $self = bless {
        root      => $c{root} // '/projects',
        host_root => $c{host_root},
        engine    => $c{engine} // '/run/engine/podman.sock',
        images    => [ref($c{images}) eq 'ARRAY' ? @{$c{images}} : ()],
        memory    => _bytes($c{memory} // '2g'),
        pids      => $c{pids} // 512,
        userns    => $c{userns} // 'keep-id',
        socket    => $c{socket} // '/run/aicli-broker/broker.sock',
    }, $class;
    die "broker: no image is allowed (images in the config)\n" unless @{$self->{images}};
    return $self;
}

# 2g, 512m, 4096k or bytes
sub _bytes {
    my ($v) = @_;
    return $v if $v =~ m/\A\d+\z/;
    my ($n, $u) = $v =~ m/\A(\d+)([kmg])\z/i or die "broker: a memory size is wanted (2g, 512m): $v\n";
    my %m = (k => 1024, m => 1024**2, g => 1024**3);
    return $n * $m{lc $u};
}

# the answer to one request (a JSON text), as a hash; every request is logged
sub handle {
    my ($self, $line) = @_;
    my $res = $self->_dispatch($line);
    my $req = eval {$JSON->decode($line)};
    my $what = ref($req) eq 'HASH'
        ? sprintf("op=%s project=%s", $req->{op} // '-', substr($req->{project} // '-', 0, 80))
        : 'not a JSON object: '.substr($line // '', 0, 60);
    _log("request $what -> ".($res->{ok} ? 'ok' : "refused: $res->{error}"));
    return $res;
}

sub _dispatch {
    my ($self, $line) = @_;
    my $req = eval {$JSON->decode($line)};
    return {ok => JSON::XS::false(), error => "a JSON object is wanted"} unless ref($req) eq 'HASH';
    my $op = $req->{op} // '';
    return $self->_open($req) if $op eq 'open';
    return $self->_close($req) if $op eq 'close';
    return $self->_list() if $op eq 'list';
    return {ok => JSON::XS::false(), error => "unknown request '$op' (open, close or list)"};
}

# a project's name: a directory directly under the root, not a link
sub project_name {
    my ($self, $name) = @_;
    return undef unless defined $name and !ref($name)
        and $name =~ m/\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/;
    my $dir = "$self->{root}/$name";
    return undef unless -d $dir and !-l $dir;
    return $name;
}

sub _pod_name { return "aicli-$_[0]" }

sub _open {
    my ($self, $req) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project"};
    my $image = $req->{image} // $self->{images}[0];
    return {ok => JSON::XS::false(), error => "that image is not allowed"}
        unless grep {$_ eq $image} @{$self->{images}};
    my $pod = _pod_name($name);
    my ($code, $pods) = $self->_engine('GET', '/libpod/pods/json');
    return $self->_failed("the engine did not list the pods", $code, $pods) unless $code == 200;
    my %have = map {($_->{Name} // '') => 1} @{$self->_decoded($pods) // []};
    if (!$have{$pod}) {
        my $spec = $self->_container_spec($name, $pod, $image);
        ($code, my $body) = $self->_engine('POST', '/libpod/pods/create', {name => $pod});
        return $self->_failed("the pod could not be made", $code, $body) unless $code == 201 or $code == 409;
        ($code, $body) = $self->_engine('POST', '/libpod/containers/create', $spec);
        return $self->_failed("the dev container could not be made", $code, $body) unless $code == 201 or $code == 409;
    }
    my ($c2, $b2) = $self->_engine('POST', "/libpod/pods/$pod/start");
    return $self->_failed("the pod could not be started", $c2, $b2) unless $c2 == 200 or $c2 == 304;
    return {ok => JSON::XS::true(), project => $name, pod => $pod, created => $have{$pod} ? JSON::XS::false() : JSON::XS::true()};
}

# the container of a project: its directory is the only host path it gets, and
# nothing is privileged; the limits are the config's
sub _container_spec {
    my ($self, $name, $pod, $image) = @_;
    return {
        name           => "$pod-dev",
        pod            => $pod,
        image          => $image,
        command        => ['sleep', 'infinity'], # the agent's worker is started in it later
        work_dir       => '/work',
        mounts         => [{type => 'bind', source => "$self->{host_root}/$name",
                            destination => '/work', options => ['rw', 'rbind']}],
        privileged     => JSON::XS::false(),
        cap_drop       => ['ALL'],
        no_new_privileges => JSON::XS::true(),
        userns         => {nsmode => $self->{userns}},
        # numbers, not text: a value used as text (in a log line) would be encoded as a string
        resource_limits => {memory => {limit => 0 + $self->{memory}}, pids => {limit => 0 + $self->{pids}}},
    };
}

sub _close {
    my ($self, $req) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project"};
    my $pod = _pod_name($name);
    my ($code, $body) = $self->_engine('POST', "/libpod/pods/$pod/stop");
    return $self->_failed("the pod could not be stopped", $code, $body) unless $code == 200 or $code == 304 or $code == 404;
    ($code, $body) = $self->_engine('DELETE', "/libpod/pods/$pod?force=true");
    return $self->_failed("the pod could not be removed", $code, $body) unless $code == 200 or $code == 404;
    return {ok => JSON::XS::true(), project => $name, pod => $pod};
}

sub _list {
    my ($self) = @_;
    my ($code, $body) = $self->_engine('GET', '/libpod/pods/json');
    return $self->_failed("the engine did not list the pods", $code, $body) unless $code == 200;
    my @pods = map {{name => $_->{Name}, status => $_->{Status}}}
        grep {($_->{Name} // '') =~ m/\Aaicli-/} @{$self->_decoded($body) // []};
    return {ok => JSON::XS::true(), pods => \@pods};
}

sub _failed {
    my ($self, $what, $code, $body) = @_;
    my $why = $self->_decoded($body);
    my $msg = ref($why) eq 'HASH'
        ? ($why->{cause} // $why->{message} // '')
        : substr($body // '', 0, 200); # the broker's own reasons (not reachable, no answer) are plain text
    return {ok => JSON::XS::false(), error => "$what (engine answered $code".(length($msg) ? ": $msg" : '').")"};
}

sub _decoded {
    my ($self, $text) = @_;
    return eval {$JSON->decode($text // '')};
}

# One request to the engine, HTTP/1.1 over its Unix socket. Returns (code, body).
sub _engine {
    my ($self, $method, $path, $data) = @_;
    # Podman serves the libpod API under a version; the unversioned paths answer 404
    $path = "/v4.0.0$path" if $path =~ m{\A/libpod/};
    my $sock = IO::Socket::UNIX->new(Peer => $self->{engine}, Type => Socket::SOCK_STREAM())
        or return (503, "the engine is not reachable: $!");
    my $json = defined $data ? $JSON->encode($data) : '';
    print {$sock} "$method $path HTTP/1.1\r\nHost: engine\r\nContent-Type: application/json\r\n"
        ."Content-Length: ".length($json)."\r\nConnection: close\r\n\r\n$json";
    my $raw = do { local $/; <$sock> } // '';
    close($sock);
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    my ($code) = ($head // '') =~ m{\AHTTP/1\.[01] (\d+)};
    _log("engine $method $path -> ".($code // 'no answer'));
    return (500, "no answer from the engine") unless defined $code;
    $body //= '';
    if (($head // '') =~ m/^Transfer-Encoding:\s*chunked/mi) {
        $body = _dechunk($body);
    }
    return ($code + 0, $body);
}

sub _dechunk {
    my ($in) = @_;
    my $out = '';
    while ($in =~ s/\A([0-9a-fA-F]+)\r\n//) {
        my $n = hex($1);
        last if $n == 0;
        $out .= substr($in, 0, $n);
        $in = substr($in, $n + 2);
    }
    return $out;
}

# the broker's socket: one request per connection
sub serve {
    my ($self) = @_;
    my $path = $self->{socket};
    unlink($path) if -S $path;
    my $srv = IO::Socket::UNIX->new(Local => $path, Type => Socket::SOCK_STREAM(), Listen => 8)
        or die "broker: cannot listen on $path: $!\n";
    chmod(0660, $path);
    my ($gid) = split ' ', $(;
    _log("listening on $path as uid $< gid ".($gid // '?'));
    local $SIG{PIPE} = 'IGNORE';
    while (my $c = $srv->accept) {
        my $line = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 10;
            my $l = <$c>;
            alarm 0;
            $l;
        };
        alarm 0;
        _log("a client sent no request in 10 s") unless defined $line;
        my $res = defined $line ? $self->handle($line) : {ok => JSON::XS::false(), error => "no request in time"};
        print {$c} $JSON->encode($res)."\n";
        close($c);
    }
    return;
}

package main;

# the client side: one request to a running broker
sub ask {
    my ($socket, $req) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $socket, Type => Socket::SOCK_STREAM())
        or die "broker: no broker at $socket: $!\n";
    print {$c} JSON::XS->new->canonical(1)->encode($req)."\n";
    my $line = <$c> // die "broker: no answer\n";
    close($c);
    return JSON::XS->new->decode($line);
}

sub main {
    my @args = @_;
    my $cmd = $args[0] // 'serve';
    if ($cmd =~ m/\A(?:open|close)\z/) {
        my $socket = $ENV{AI_BROKER_SOCKET} // '/run/aicli-broker/broker.sock';
        my $r = ask($socket, {op => $cmd, project => $args[1] // ''});
        print JSON::XS->new->canonical(1)->pretty->encode($r);
        return $r->{ok} ? 0 : 1;
    }
    if ($cmd eq 'list') {
        my $socket = $ENV{AI_BROKER_SOCKET} // '/run/aicli-broker/broker.sock';
        print JSON::XS->new->canonical(1)->pretty->encode(ask($socket, {op => 'list'}));
        return 0;
    }
    die "broker: serve, open NAME, close NAME or list\n" unless $cmd eq 'serve';
    my $cfg_file = $ENV{AI_BROKER_CONFIG} // '/etc/aicli/broker.json';
    open(my $fh, '<', $cfg_file) or die "broker: cannot read $cfg_file: $!\n";
    my $cfg = JSON::XS->new->decode(do { local $/; <$fh> });
    close($fh);
    $cfg->{host_root} = $ENV{AI_BROKER_HOST_ROOT} if length($ENV{AI_BROKER_HOST_ROOT} // '');
    $cfg->{socket}    = $ENV{AI_BROKER_SOCKET}    if length($ENV{AI_BROKER_SOCKET} // '');
    $cfg->{engine}    = $ENV{AI_BROKER_ENGINE}    if length($ENV{AI_BROKER_ENGINE} // '');
    my $b = broker->new(%$cfg);
    broker::_log(sprintf("starting: root=%s host_root=%s engine=%s images=%s memory=%s pids=%s",
        $b->{root}, $b->{host_root}, $b->{engine}, join(',', @{$b->{images}}), $b->{memory}, $b->{pids}));
    $b->serve();
    return 0;
}

exit(main(@ARGV)) unless caller;
1;
