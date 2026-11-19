#!/usr/bin/perl
# The broker: it starts the dev pods of the projects for the agent, and nothing
# else. It runs in a container of its own, the only one with the rootless Podman
# socket of the host mounted; the agent talks to it over a Unix socket in a volume
# that only the agent and the broker share. A request is one JSON line, the answer
# one JSON line:
#   {"op":"open","project":"alpha","pod":"arduino"}   start the pod of a kind (base by default)
#   {"op":"close","project":"alpha","pod":"arduino"}  stop and remove it
#   {"op":"list"}                                  the pods the engine has
#   {"op":"projects"}                              the projects, their pods, the kinds
#   {"op":"exec","project":"alpha","pod":"base","argv":["grep","-rn","x","."]}
# A pod kind is a name of the config ("pods": image, programs, note): base for the
# basic tools (bash, perl, grep), and others for a toolchain. A kind with "tags" runs on an
# agent that has them (remote_hub.pm): the agent calls in, the broker never starts it (it has
# no devices). Its exec waits for the agent's answer; open and close refuse it.
# An exec runs only a program its kind lists, and opens the pod first when it is
# closed. Nothing else is done. What a request names reaches the engine only as the
# project's name (a directory directly under the root), its pod kind (of the config),
# and the limits of the config: never a privileged mode, a host network, a socket,
# a path outside the root, or an image the config does not name.
#
# Usage:
#   broker.pl                      serve (AI_BROKER_CONFIG, a JSON file)
#   broker.pl open NAME [KIND]     ask a running broker (AI_BROKER_SOCKET), print the answer
#   broker.pl close NAME [KIND] | list

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
    my $regs = _registries_config(\%c);
    die "broker: host_root (the host path of the projects) is needed\n" unless length($c{host_root} // '');
    my $self = bless {
        root      => $c{root} // '/projects',
        host_root => $c{host_root},
        engine    => $c{engine} // '/run/engine/podman.sock',
        pods      => _pods_config(\%c, $regs),
        registries => $regs,
        memory    => _bytes($c{memory} // '2g'),
        pids      => $c{pids} // 512,
        userns    => $c{userns} // 'keep-id',
        socket    => $c{socket} // '/run/aicli-broker/broker.sock',
        remote    => [ref($c{remote}) eq 'ARRAY' ? @{$c{remote}} : ('podman-remote')],
        max_pods  => $c{max_pods} // 4,                              # open pods at once, all kinds
        idle      => ($c{idle_minutes} // 30) * 60,                  # seconds unused before a close
        tls_verify => $c{tls_verify} // 1,                           # the registry's certificate is checked
        dev_root  => $c{dev_root} // '/dev',                         # where the host's devices are (tests)
        sys_root  => $c{sys_root} // '/sys',                         # where the host's usb devices are (tests)
        last      => {},                                             # "kind/project" => time of its last open or exec
        hub       => remote_hub->new(agents => $c{agents}),
        agent_listen => $c{agent_listen},                            # host:port of the agents (nginx passes them on)
    }, $class;
    return $self;
}

# the pod kinds of the config: kind => {image, programs, list, note}. Without "pods"
# the one kind is base, with the first image and the basic programs (older configs).
sub _pods_config {
    my ($c, $regs) = @_;
    my %pods;
    if (ref($c->{pods}) eq 'HASH') {
        for my $kind (sort keys %{$c->{pods}}) {
            die "broker: a pod kind is a short lower-case name, not '$kind'\n" unless $kind =~ m/\A[a-z][a-z0-9]{0,15}\z/;
            my $p = $c->{pods}{$kind};
            die "broker: pod $kind needs an image or tags (an agent)\n"
                unless ref($p) eq 'HASH' and (length($p->{image} // '') or ref($p->{tags}) eq 'ARRAY');
            my @programs = ref($p->{programs}) eq 'ARRAY' ? @{$p->{programs}} : ();
            die "broker: pod $kind needs its programs\n" unless @programs;
            my %x = _pod_extras($kind, $p);
            my $image = length($p->{image} // '') ? _checked_image($kind, $p->{image}, $regs) : undef;
            die "broker: pod $kind runs on an agent (tags): it has no image, and no devices here\n"
                if $x{tags} and (defined $image or @{$x{devices}} or @{$x{usb_ids}});
            $pods{$kind} = {image => $image, list => [@programs], programs => {map {($_ => 1)} @programs},
                note => $p->{note} // '', %x};
        }
    } elsif (ref($c->{images}) eq 'ARRAY' and @{$c->{images}}) {
        my @basic = qw(bash perl grep);
        $pods{base} = {image => $c->{images}[0], list => [@basic], programs => {map {($_ => 1)} @basic},
            note => ref($c->{image_notes}) eq 'HASH' ? ($c->{image_notes}{$c->{images}[0]} // '') : ''};
    }
    die "broker: no pod is configured (pods in the config)\n" unless %pods;
    return \%pods;
}

# 2g, 512m, 4096k or bytes
sub _bytes {
    my ($v) = @_;
    return $v if $v =~ m/\A\d+\z/;
    my ($n, $u) = $v =~ m/\A(\d+)([kmg])\z/i or die "broker: a memory size is wanted (2g, 512m): $v\n";
    my %m = (k => 1024, m => 1024**2, g => 1024**3);
    return $n * $m{lc $u};
}

# the output of a program run in a pod (no shell: argv is a list), at most this many bytes
our $EXEC_MAX = 1024 * 1024;

# the escaping of a path segment or a query value (an image reference has / and :)
sub _escape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

# the answer to one request (a JSON text), as a hash; every request is logged
# $send (optional) gets the answer when it is not there yet (a job on an agent)
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
    return $self->_open($req) if $op eq 'open';
    return $self->_close($req) if $op eq 'close';
    return $self->_list() if $op eq 'list';
    return $self->_projects() if $op eq 'projects';
    return $self->_exec($req, $send) if $op eq 'exec';
    return {ok => JSON::XS::false(), error => "unknown request '$op' (open, close, list or projects)"};
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

# the engine's name of a project's pod of a kind: aicli-<kind>-<project> (a kind has no dash)
sub _pod_name { my ($kind, $name) = @_; return "aicli-$kind-$name" }

sub _open {
    my ($self, $req) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project"};
    my $kind = $req->{pod} // 'base';
    my $spec = $self->{pods}{$kind}
        or return {ok => JSON::XS::false(), error => "no such pod: '$kind' (pods lists them)"};
    return {ok => JSON::XS::false(), error => "the $kind kind runs on an agent (tags: @{$spec->{tags}}): there is no pod to open"}
        if $spec->{tags};
    my $key = "$kind/$name";
    my $image = $spec->{image};
    my $pod = _pod_name($kind, $name);
    my ($code, $pods) = $self->_engine('GET', '/libpod/pods/json');
    return $self->_failed("the engine did not list the pods", $code, $pods) unless $code == 200;
    my %running = _running($pods);
    return {ok => JSON::XS::false(), error => "$self->{max_pods} pods are open already: close one first (projects lists them)"}
        if !$running{$key} and keys(%running) >= $self->{max_pods};
    my $pulled = $self->_image($image);
    return $pulled if $pulled;
    my %have = map {($_->{Name} // '') => 1} @{$self->_decoded($pods) // []};
    my $made = 0;
    if (!$have{$pod}) {
        my ($c1, $b1) = $self->_engine('POST', '/libpod/pods/create', {name => $pod});
        return $self->_failed("the pod could not be made", $c1, $b1) unless $c1 == 201 or $c1 == 409;
        $made = 1 if $c1 == 201;
    }
    # the container is asked for every time: a pod can be there without it (a failed open)
    # the devices the kind passes (the ones that exist now) and the groups: the config's and the owners'
    my ($devs, $dgids) = $self->_device_specs($spec);
    my %seen;
    my @groups = grep {!$seen{$_}++} (@{$spec->{groups}}, @$dgids);
    my $x = {devices => $devs, groups => \@groups, env => $spec->{env}, seccomp => $spec->{seccomp}, ipc => $spec->{ipc}};
    my ($code2, $body2) = $self->_engine('POST', '/libpod/containers/create', $self->_container_spec($name, $pod, $image, $x));
    # a name in use is the container of an earlier open: the engine says so with 409, or 500 (storage)
    my $exists = $code2 == 409 || ($code2 == 500 && ($body2 // '') =~ m/already in use/);
    return $self->_failed("the dev container could not be made", $code2, $body2) unless $code2 == 201 or $exists;
    $made = 1 if $code2 == 201;
    my ($c2, $b2) = $self->_engine('POST', "/libpod/pods/$pod/start");
    return $self->_failed("the pod could not be started", $c2, $b2) unless $c2 == 200 or $c2 == 304;
    $self->{last}{$key} = time;
    return {ok => JSON::XS::true(), project => $name, kind => $kind, pod => $pod,
        created => $made ? JSON::XS::true() : JSON::XS::false(),
        devices => [map {$_->{path}} @$devs]};
}

# the image of a pod: pulled from its registry when the engine does not have it yet
# (a local registry or a remote one, as the reference says). undef when it is there.
sub _image {
    my ($self, $ref) = @_;
    my ($code) = $self->_engine('GET', '/libpod/images/'._escape($ref).'/json');
    return undef if $code == 200;
    my $tls = $self->{tls_verify} ? 'true' : 'false';
    my ($auth, $why) = $self->_auth_header($ref);
    return {ok => JSON::XS::false(), error => "the login of the registry of $ref is not set: $why"} if defined $why;
    my @headers = defined $auth ? (['X-Registry-Auth', $auth]) : ();
    my ($c, $body) = $self->_engine('POST', '/libpod/images/pull?reference='._escape($ref)."&tlsVerify=$tls", undef, \@headers);
    return $self->_failed("the image $ref could not be pulled", $c, $body)
        unless $c == 200 and ($body // '') !~ m/"error"/;
    return undef;
}

# the registries of the config: host => {username_env, password_env}. The login is not in
# the config, only the names of the variables that hold it (the broker's environment).
sub _registries_config {
    my ($c) = @_;
    my $in = ref($c->{registries}) eq 'HASH' ? $c->{registries} : {};
    my %r;
    for my $key (sort keys %$in) {
        # the host may name a variable (${AICLI_REGISTRY_HOST}), as the images do
        my $host = $key;
        $host =~ s{\$\{(\w+)\}}{ defined $ENV{$1} ? $ENV{$1} : die "broker: the variable $1 of registry $key is not set\n" }ge;
        next if $host eq ''; # not set (the pods of this registry cannot be pulled, and nothing else fails)
        die "broker: a registry is a host name, '$host'\n" unless $host =~ m/\A[a-z0-9][a-z0-9.:-]*\z/;
        my $e = $in->{$key};
        die "broker: registry $host needs username_env and password_env\n" unless ref($e) eq 'HASH';
        for my $k (qw(username_env password_env)) {
            die "broker: registry $host: $k is the name of a variable (capitals)\n"
                unless defined $e->{$k} and !ref($e->{$k}) and $e->{$k} =~ m/\A[A-Z_][A-Z0-9_]*\z/;
        }
        $r{$host} = {username_env => $e->{username_env}, password_env => $e->{password_env}};
    }
    return \%r;
}

# the registry host of an image reference: the first part when it looks like a host, else docker.io
sub _registry_of {
    my ($ref) = @_;
    return 'docker.io' unless $ref =~ m{/};
    my ($first) = split m{/}, $ref, 2;
    return ($first =~ m{[.:]} or $first eq 'localhost') ? $first : 'docker.io';
}

# an image of the config, with its ${NAME}s from the environment; when the config lists
# registries, the image must be from one of them
sub _checked_image {
    my ($kind, $ref, $regs) = @_;
    my $image = _expand_image($kind, $ref);
    if (ref($regs) eq 'HASH' and %$regs) {
        my $reg = _registry_of($image);
        die "broker: pod $kind: the image $image is from $reg, which is not a registry of the config\n"
            unless $regs->{$reg};
    }
    return $image;
}

# the login for the registry of an image, as the engine takes it (X-Registry-Auth, base64 of
# the JSON). Sent to that registry only. (undef, undef): no login for it; (undef, why): its
# variables are not set
sub _auth_header {
    my ($self, $ref) = @_;
    my $reg = _registry_of($ref);
    my $r = $self->{registries}{$reg} or return (undef, undef);
    my ($user, $pass) = map {$ENV{$r->{$_}}} qw(username_env password_env);
    return (undef, "$r->{username_env} and $r->{password_env} (for $reg)")
        unless length($user // '') and length($pass // '');
    return (MIME::Base64::encode_base64($JSON->encode({username => $user, password => $pass, serveraddress => $reg}), ''), undef);
}

# an image reference of the config, with ${NAME} taken from the environment (the registry of the
# pods is the domain of the stack, AICLI_POD_REGISTRY); a variable that is not set is refused
sub _expand_image {
    my ($kind, $ref) = @_;
    my $missing;
    $ref =~ s{\$\{(\w+)\}}{ defined $ENV{$1} ? $ENV{$1} : do { $missing //= $1;  } }ge;
    die "broker: pod $kind: the variable \${$missing} of its image is not set\n" if defined $missing;
    return $ref;
}

# what a kind adds to its container, from its config: devices (paths under /dev, globs,
# passed when they exist at open), usb_ids (vid:pid, resolved to /dev/bus/usb nodes at
# open), groups (numeric gids), env (names in capitals), seccomp ('unconfined') and ipc
# ('host'). Anything else in a kind is refused: privileged, mounts, sockets, networks.
my %POD_KEYS = map {($_ => 1)} qw(image programs note tags devices usb_ids groups env seccomp ipc);
sub _pod_extras {
    my ($kind, $p) = @_;
    for my $k (sort keys %$p) {
        die "broker: pod $kind: '$k' is not a setting of a pod (image, programs, note, tags, devices, usb_ids, groups, env, seccomp, ipc)\n"
            unless $POD_KEYS{$k};
    }
    my %x = (devices => [], usb_ids => [], groups => [], env => {}, seccomp => undef, ipc => undef, tags => undef);
    if (defined $p->{tags}) {
        die "broker: pod $kind: tags are a list of short lower-case words\n" unless ref($p->{tags}) eq 'ARRAY' and @{$p->{tags}};
        for my $t (@{$p->{tags}}) {
            die "broker: pod $kind: a tag is a short lower-case word, '$t'\n"
                unless !ref($t) and $t =~ m/\A[a-z][a-z0-9-]{0,31}\z/;
        }
        $x{tags} = [@{$p->{tags}}];
    }
    for my $d (ref($p->{devices}) eq 'ARRAY' ? @{$p->{devices}} : ()) {
        die "broker: pod $kind: a device is a path under /dev, '$d'\n"
            unless !ref($d) and $d =~ m{\A/dev/[A-Za-z0-9_./*-]+\z} and $d !~ m{\.\.};
        push @{$x{devices}}, $d;
    }
    for my $id (ref($p->{usb_ids}) eq 'ARRAY' ? @{$p->{usb_ids}} : ()) {
        die "broker: pod $kind: a usb id is vid:pid in hex, '$id'\n"
            unless !ref($id) and $id =~ m/\A[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\z/;
        push @{$x{usb_ids}}, lc($id);
    }
    for my $g (ref($p->{groups}) eq 'ARRAY' ? @{$p->{groups}} : ()) {
        die "broker: pod $kind: a group is a gid (a number)\n" unless !ref($g) and $g =~ m/\A\d+\z/;
        push @{$x{groups}}, $g + 0;
    }
    if (ref($p->{env}) eq 'HASH') {
        for my $k (sort keys %{$p->{env}}) {
            my $v = $p->{env}{$k};
            die "broker: pod $kind: env '$k' must be a name in capitals with a plain value\n"
                unless $k =~ m/\A[A-Z_][A-Z0-9_]*\z/ and !ref($v) and defined($v) and $v !~ m/[\n\0]/;
            $x{env}{$k} = $v;
        }
    } elsif (defined $p->{env}) {
        die "broker: pod $kind: env is a hash of names and values\n";
    }
    if (defined $p->{seccomp}) {
        die "broker: pod $kind: seccomp is 'unconfined' or nothing\n" unless $p->{seccomp} eq 'unconfined';
        $x{seccomp} = 'unconfined';
    }
    if (defined $p->{ipc}) {
        die "broker: pod $kind: ipc is 'host' or nothing\n" unless $p->{ipc} eq 'host';
        $x{ipc} = 'host';
    }
    return %x;
}

# the file's first line in a sysfs (or other) directory, or undef
sub _file {
    my ($dir, $name) = @_;
    open(my $fh, '<', "$dir/$name") or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless defined $line;
    $line =~ s/\s+\z//;
    return $line;
}

# the devices a kind passes at open: its device paths that exist now (globs, so a
# board plugged in later is found by the next open), the usb nodes of its usb ids
# (from sysfs: a meter replugged gets a new number, found the same way), and the gids
# that own them, which the container gets as groups.
# Returns (the devices as libpod's LinuxDevice, the gids).
sub _device_specs {
    my ($self, $spec) = @_;
    my $dev_root = $self->{dev_root};
    my @found;   # [path in the container, path on the host]
    for my $pat (@{$spec->{devices}}) {
        for my $h (sort glob($dev_root.substr($pat, length('/dev')))) {
            push @found, ['/dev'.substr($h, length($dev_root)), $h];
        }
    }
    for my $id (@{$spec->{usb_ids}}) {
        my ($vid, $pid) = split /:/, $id;
        for my $dir (sort glob("$self->{sys_root}/bus/usb/devices/*")) {
            next unless lc(_file($dir, 'idVendor') // '') eq $vid and lc(_file($dir, 'idProduct') // '') eq $pid;
            my ($bus, $num) = (_file($dir, 'busnum'), _file($dir, 'devnum'));
            next unless defined $bus and defined $num;
            my $node = sprintf('/bus/usb/%03d/%03d', $bus, $num);
            push @found, ["/dev$node", "$dev_root$node"];
        }
    }
    my (@devices, %gids);
    for my $f (@found) {
        my ($cpath, $host) = @$f;
        next unless -c $host;
        my @st = stat($host);
        my $rdev = $st[6];
        push @devices, {path => $cpath, type => 'c',
            major => ($rdev >> 8) & 0xfff,
            minor => ($rdev & 0xff) | (($rdev >> 12) & 0xfff00),
            fileMode => $st[2] & 07777};
        $gids{$st[5]} = 1 if $st[5] != 0;
    }
    return (\@devices, [sort {$a <=> $b} keys %gids]);
}

# the container of a project: its directory is the only host path it gets, and
# nothing is privileged; the limits are the config's. $x: what the kind adds (_pod_extras,
# _device_specs), see below
sub _container_spec {
    my ($self, $name, $pod, $image, $x) = @_;
    $x //= {};
    my $c = {
        name           => "$pod-dev",
        pod            => $pod,
        image          => $image,
        # the pod runs nothing but waits: the broker's exec runs the programs in it
        command        => ['sleep', 'infinity'],
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
    # what the kind adds: the devices (LinuxDevice), the groups that own them and the
    # config's, the variables, seccomp and ipc. Never privileged, never a cgroup rule.
    $c->{devices} = $x->{devices} if @{$x->{devices} // []};
    $c->{groups} = [map {"$_"} @{$x->{groups} // []}] if @{$x->{groups} // []};
    $c->{env} = $x->{env} if %{$x->{env} // {}};
    $c->{seccomp_profile_path} = 'unconfined' if $x->{seccomp};
    $c->{ipc} = {nsmode => 'host'} if $x->{ipc};
    return $c;
}

sub _close {
    my ($self, $req) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project"};
    my $kind = $req->{pod} // 'base';
    return {ok => JSON::XS::false(), error => "no such pod: '$kind' (pods lists them)"} unless $self->{pods}{$kind};
    my $pod = _pod_name($kind, $name);
    my ($code, $body) = $self->_engine('POST', "/libpod/pods/$pod/stop");
    return $self->_failed("the pod could not be stopped", $code, $body) unless $code == 200 or $code == 304 or $code == 404;
    ($code, $body) = $self->_engine('DELETE', "/libpod/pods/$pod?force=true");
    return $self->_failed("the pod could not be removed", $code, $body) unless $code == 200 or $code == 404;
    delete $self->{last}{"$kind/$name"};
    return {ok => JSON::XS::true(), project => $name, kind => $kind, pod => $pod};
}

# the projects under the root with their pods (open or closed), the pod kinds (with
# their programs and notes), and the cap: what the model reads to choose before it opens a pod
sub _projects {
    my ($self) = @_;
    my ($code, $body) = $self->_engine('GET', '/libpod/pods/json');
    return $self->_failed("the engine did not list the pods", $code, $body) unless $code == 200;
    my %running = _running($body);
    opendir(my $dh, $self->{root}) or return {ok => JSON::XS::false(), error => "the root cannot be read: $!"};
    my @names = sort grep {!m/\A\./} readdir($dh);
    closedir($dh);
    my @projects;
    for my $p (grep {defined $self->project_name($_)} @names) {
        my %pods = map {($_ => ($running{"$_/$p"} ? JSON::XS::true() : JSON::XS::false()))} sort keys %{$self->{pods}};
        push @projects, {name => $p, pods => \%pods};
    }
    my @kinds = map {{name => $_, programs => $self->{pods}{$_}{list}, note => $self->{pods}{$_}{note}}}
        sort keys %{$self->{pods}};
    return {ok => JSON::XS::true(), projects => \@projects, pods => \@kinds,
        open_count => scalar(keys %running), max_pods => $self->{max_pods}};
}

# the running pods among the engine's pods, as "kind/project" => 1
sub _running {
    my ($body) = @_;
    my $list = eval { $JSON->decode($body // '[]') };
    my %run;
    for my $p (ref($list) eq 'ARRAY' ? @$list : ()) {
        next unless ($p->{Status} // '') eq 'Running';
        next unless ($p->{Name} // '') =~ m/\Aaicli-([a-z][a-z0-9]{0,15})-(.+)\z/;
        $run{"$1/$2"} = 1;
    }
    return %run;
}

# the pods nobody has used for the idle time are closed. A pod this process has not
# seen used (one open before a restart) counts from now, so it is not closed at once.
sub _reap {
    my ($self) = @_;
    my ($code, $body) = $self->_engine('GET', '/libpod/pods/json');
    return unless $code == 200;
    my $now = time;
    my %running = _running($body);
    for my $key (sort keys %running) {
        my ($kind, $name) = split m{/}, $key, 2;
        $self->{last}{$key} //= $now;
        next if $now - $self->{last}{$key} < $self->{idle};
        my $r = $self->_close({project => $name, pod => $kind});
        _log("idle: pod $key closed".($r->{ok} ? '' : ": $r->{error}"));
    }
    return;
}

sub _list {
    my ($self) = @_;
    my ($code, $body) = $self->_engine('GET', '/libpod/pods/json');
    return $self->_failed("the engine did not list the pods", $code, $body) unless $code == 200;
    my @pods = map {{name => $_->{Name}, status => $_->{Status}}}
        grep {($_->{Name} // '') =~ m/\Aaicli-/} @{$self->_decoded($body) // []};
    return {ok => JSON::XS::true(), pods => \@pods};
}

# run a program in the dev container of an open project: argv is a list of the
# program and its arguments (no shell), its working directory is /work (the
# project). The engine's own client (podman-remote, the config's remote) runs it.
# Answers the output (base64, as the bytes were) and the exit code.
# the time an agent has to run a program (the same as a pod's exec)
our $AGENT_EXEC_TIMEOUT = 120;

sub _exec {
    my ($self, $req, $send) = @_;
    my $name = $self->project_name($req->{project})
        or return {ok => JSON::XS::false(), error => "no such project"};
    my $kind = $req->{pod} // 'base';
    my $spec = $self->{pods}{$kind}
        or return {ok => JSON::XS::false(), error => "no such pod: '$kind' (pods lists them)"};
    my $argv = $req->{argv};
    return {ok => JSON::XS::false(), error => "a list of the program and its arguments is wanted"}
        unless ref($argv) eq 'ARRAY' and @$argv and @$argv <= 8 and !grep {ref($_) or !defined($_)} @$argv;
    return {ok => JSON::XS::false(), error => "that program is not in the $kind pod (its programs: ".join(', ', @{$spec->{list}}).")"}
        unless $spec->{programs}{$argv->[0]};
    my $size = 0;
    $size += length($_) for @$argv;
    return {ok => JSON::XS::false(), error => "the command is too long"} if $size > 256 * 1024;
    if ($spec->{tags}) {
        # a kind on an agent: the answer comes when the agent has run it (or it is refused now)
        return {ok => JSON::XS::false(), error => "the $kind kind runs on an agent, and this call cannot wait for one"}
            unless $send;
        $self->{hub}->submit(project => $name, tags => $spec->{tags}, argv => $argv, timeout => $AGENT_EXEC_TIMEOUT,
            done => sub {
                my ($r) = @_;
                _log("exec project=$name pod=$kind program=$argv->[0] on an agent -> "
                    .($r->{ok} ? "exit $r->{exit}" : "refused: $r->{error}"));
                $r->{output} = MIME::Base64::encode_base64($r->{output} // '', '') if $r->{ok};
                $send->($r);
            });
        return undef; # answered through $send
    }
    my $ctr = _pod_name($kind, $name).'-dev';
    my $state = $self->_container_state($ctr);
    if (!$state or !$state->{State}{Running}) {
        # a call opens its pod when it is closed (the cap applies, as for an open)
        my $o = $self->_open({project => $name, pod => $kind});
        return $o unless $o->{ok};
        $state = $self->_container_state($ctr);
    }
    return {ok => JSON::XS::false(), error => "the $kind pod of the project is not running"}
        unless $state and $state->{State}{Running};
    _log("exec project=$name pod=$kind program=$argv->[0]");
    $self->{last}{"$kind/$name"} = time;
    my ($out, $exit) = _capture([@{$self->{remote}}, 'exec', '--workdir', '/work', $ctr, @$argv], $EXEC_MAX, 120);
    _log("exec project=$name pod=$kind program=$argv->[0] -> exit $exit");
    return {ok => JSON::XS::true(), exit => $exit, output => MIME::Base64::encode_base64($out // '', '')};
}

# a program's output (stdout and stderr together), at most $max bytes, and its exit code
sub _capture {
    my ($cmd, $max, $timeout) = @_;
    my $pid = open(my $fh, '-|');
    return ('cannot start the engine client', 127) unless defined $pid;
    if (!$pid) {
        open(STDERR, '>&', \*STDOUT);
        exec {$cmd->[0]} @$cmd or POSIX::_exit(127); # the program did not start
    }
    my $out = '';
    my $killed = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        while (read($fh, my $buf, 65536)) {
            $out .= $buf;
            if (length($out) > $max) { $out = substr($out, 0, $max)."\n[output cut]\n"; last }
        }
        alarm 0;
        1;
    } or do { $killed = 124 };
    alarm 0;
    if ($killed or length($out) > $max) {
        kill 'KILL', $pid;
    }
    close($fh);
    my $status = $?;
    return ($out, $killed ? 124 : ($status >> 8));
}

sub _failed {
    my ($self, $what, $code, $body) = @_;
    my $why = $self->_decoded($body);
    # libpod: "cause" or "message"; a pod start that fails lists "Errs" (one per container)
    my $msg = ref($why) eq 'HASH'
        ? join('; ', grep {length} ($why->{cause} // (), $why->{message} // (), ref($why->{Errs}) eq 'ARRAY' ? @{$why->{Errs}} : ()))
        : substr($body // '', 0, 200); # the broker's own reasons (not reachable, no answer) are plain text
    return {ok => JSON::XS::false(), error => "$what (engine answered $code".(length($msg) ? ": $msg" : '').")"};
}

sub _decoded {
    my ($self, $text) = @_;
    return eval {$JSON->decode($text // '')};
}

# the engine's state of a container (its State hash), or undef when there is none
sub _container_state {
    my ($self, $ctr) = @_;
    my ($code, $body) = $self->_engine('GET', "/libpod/containers/$ctr/json");
    return undef unless $code == 200;
    my $s = $self->_decoded($body);
    return ref($s) eq 'HASH' && ref($s->{State}) eq 'HASH' ? $s : undef;
}

# One request to the engine, HTTP/1.1 over its Unix socket. Returns (code, body).
sub _engine {
    my ($self, $method, $path, $data, $headers) = @_;
    # Podman serves the libpod API under a version; the unversioned paths answer 404
    $path = "/v4.0.0$path" if $path =~ m{\A/libpod/};
    my $sock = IO::Socket::UNIX->new(Peer => $self->{engine}, Type => Socket::SOCK_STREAM())
        or return (503, "the engine is not reachable: $!");
    my $json = defined $data ? $JSON->encode($data) : '';
    my $extra = join('', map {"$_->[0]: $_->[1]\r\n"} @{$headers // []}); # e.g. X-Registry-Auth, never logged
    print {$sock} "$method $path HTTP/1.1\r\nHost: engine\r\nContent-Type: application/json\r\n$extra"
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

# the reasons of the statuses of the agent listener
our %HTTP_REASON = (200 => 'OK', 204 => 'No Content', 400 => 'Bad Request', 403 => 'Forbidden',
    404 => 'Not Found', 409 => 'Conflict', 413 => 'Payload Too Large');

# the listener of the agents (TCP, behind nginx), or undef when there are none
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

# one request of a client (the agent's tools, the web interface): one JSON line. A job on an
# agent is answered later, when the agent has run it; the connection stays open until then.
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
# time is up, and closes the idle pods (once a minute).
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
    my $reaped = 0;
    while (1) {
        # the idle pods are closed once a minute, whether or not requests come (a failure is logged)
        if (time - $reaped >= 60) {
            $reaped = time;
            eval { $self->_reap(); 1 } or _log("idle check failed: ".($@ =~ s/\s+\z//r));
        }
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
        my $r = ask($socket, {op => $cmd, project => $args[1] // '', pod => $args[2] // 'base'});
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
    $cfg->{agent_listen} = $ENV{AI_BROKER_AGENT_LISTEN} if length($ENV{AI_BROKER_AGENT_LISTEN} // '');
    my $b = broker->new(%$cfg);
    broker::_log(sprintf("starting: root=%s host_root=%s engine=%s pods=%s memory=%s pids=%s",
        $b->{root}, $b->{host_root}, $b->{engine}, join(',', map {"$_=$b->{pods}{$_}{image}"} sort keys %{$b->{pods}}),
        $b->{memory}, $b->{pids}));
    $b->serve();
    return 0;
}

exit(main(@ARGV)) unless caller;
1;
