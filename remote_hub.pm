package remote_hub;
# The broker's side of the remote agents (see PLAN.md, "remote agents"): the agents that call
# in, the jobs for their tags, and the answers. No sockets here: broker.pl takes the requests
# from its agent listener and gives the hub a send closure per connection.
#
# Enrollment: a logged-in user gets an enrollment token from the web interface (issue_enroll: the
# broker keeps its SHA-256, the token is shown once). An agent enrolls with it:
#   POST /agents/enroll           {"token": T, "name": N, "tags": [...]} -> 200 {"token": agent token}
# The token is reusable (every agent of the user enrolls with it) until the user makes a new one.
# The agent's token is shown to the agent once, and the broker keeps its SHA-256 with the agent's
# name, tags and user. enroll/revoke/agents_of are the broker's; the state file keeps them
# (state_file, JSON), and the agents of broker.json stay as they are.
#
# The protocol, over HTTPS (nginx passes it on; the agent checks nginx's certificate as any
# client does):
#   GET  /agents/poll             the agent asks for a job. 200 with the job (JSON), 204 when no
#                                 job came in POLL_WAIT seconds (then it asks again), 409 when the
#                                 agent has a job already.
#   POST /agents/result/<id>      the answer to a job: {"exit": N, "output": "<base64>"}.
# Every request carries the agent's token: "Authorization: Bearer <token>". The broker keeps
# only the SHA-256 of each agent's token (agents in broker.json, "token_sha256"); a request
# without the token of a configured agent is 403. The token is the agent's whole credential.
#
# A job is a program and its arguments for a kind's tags (an agent has the tags, the broker
# sends it to one of them that is not busy). One job per agent at a time. A job waits JOB_WAIT
# seconds for an agent; an agent that takes it has timeout + GRACE seconds to answer.

use strict; use warnings;
use JSON::XS ();
use MIME::Base64 ();
use Digest::SHA ();

my $JSON = JSON::XS->new->canonical(1)->utf8;

our $POLL_WAIT = 20;        # seconds a poll is held before the 204
our $JOB_WAIT  = 120;       # seconds a job waits for an agent with its tags
our $GRACE     = 10;        # seconds an agent has to answer beyond the job's timeout
our $ONLINE    = 60;        # an agent polled this recently counts as connected
our $MAX_OUT   = 1024 * 1024;
our $MAX_BODY  = 64 * 1024;

# agents: name => {tags => [...], token_sha256 => hex} (from the config and the state file)
sub new {
    my ($class, %c) = @_;
    my (%agents, %enroll);
    my %by_token;
    my $file = $c{state_file};
    if (defined $file and -f $file) {
        open(my $fh, '<', $file) or die "remote agents: cannot read $file: $!\n";
        my $st = eval { JSON::XS->new->decode(do { local $/; <$fh> }) };
        close($fh);
        die "remote agents: $file is not the state of the agents\n" unless ref($st) eq 'HASH';
        %enroll = %{$st->{enroll} // {}};
        for my $name (sort keys %{$st->{agents} // {}}) {
            my $a = $st->{agents}{$name};
            die "remote agents: $file has a bad agent '$name'\n"
                unless ref($a) eq 'HASH' and ref($a->{tags}) eq 'ARRAY' and defined $a->{token_sha256};
            $agents{$name} = {tags => [@{$a->{tags}}], token_sha256 => $a->{token_sha256},
                user => $a->{user}, enrolled => $a->{enrolled} // 0};
            $by_token{$a->{token_sha256}}++;
        }
    }
    for my $name (sort keys %{$c{agents} // {}}) {
        my $a = $c{agents}{$name};
        die "remote agents: an agent is a name, its tags and the sha256 of its token, '$name'\n"
            unless ref($a) eq 'HASH' and ref($a->{tags}) eq 'ARRAY'
            and defined $a->{token_sha256} and $a->{token_sha256} =~ m/\A[0-9a-f]{64}\z/;
        die "remote agents: two agents have the same token, '$name'\n" if $by_token{$a->{token_sha256}}++;
        die "remote agents: agent '$name' is in the config and in the state\n" if $agents{$name};
        die "remote agents: an agent's name is letters, digits, '.', '_' or '-': '$name'\n"
            unless $name =~ m/\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/;
        my @tags = @{$a->{tags}};
        for my $t (@tags) {
            die "remote agents: a tag is a short lower-case word, '$t'\n"
                unless !ref($t) and $t =~ m/\A[a-z][a-z0-9-]{0,31}\z/;
        }
        $agents{$name} = {tags => [@tags], token_sha256 => $a->{token_sha256}, user => undef, enrolled => 0};
    }
    return bless {
        file    => $file,
        enroll  => \%enroll,
        agents  => \%agents,
        seen    => {},     # name => last poll time
        busy    => {},     # name => job id
        pollers => [],     # {name, send, deadline} of the held polls, in order
        queue   => [],     # job ids waiting for an agent, in order
        jobs    => {},     # job id => job (queued or assigned)
    }, $class;
}

# the listener is for the agents, and their enrollment: always on when the broker has one
sub enabled { return 1 }

sub _save {
    my ($self) = @_;
    return unless defined $self->{file};
    my $tmp = "$self->{file}.tmp$$";
    my $ok = open(my $fh, '>', $tmp);
    if ($ok) {
        chmod(0600, $tmp);
        print {$fh} $JSON->encode({enroll => $self->{enroll}, agents => {map {($_ => $self->{agents}{$_})}
            grep {defined $self->{agents}{$_}{user}} keys %{$self->{agents}}}});
        $ok = close($fh) && rename($tmp, $self->{file});
    }
    die "remote agents: cannot save the state to $self->{file}: $!\n" unless $ok;
    return;
}

sub _random_token {
    my $raw = '';
    open(my $r, '<:raw', '/dev/urandom') or die "remote agents: no random source: $!\n";
    read($r, $raw, 32) == 32 or die "remote agents: no random source\n";
    close($r);
    (my $t = MIME::Base64::encode_base64($raw, '')) =~ tr{+/=}{-_}d;
    return $t;
}

# a new enrollment token for a user (replaces the earlier one of that user): the token, once
sub issue_enroll {
    my ($self, $user) = @_;
    die "remote agents: a user is needed\n" unless defined $user and length $user;
    my $token = _random_token();
    $self->{enroll}{$user} = Digest::SHA::sha256_hex($token);
    $self->_save();
    return $token;
}

# enroll an agent with a user's token: {ok, token, name, tags} or {ok => 0, status, error}
sub enroll {
    my ($self, $token, $name, $tags, $now) = @_;
    $now //= time;
    my $hash = defined $token && length $token ? Digest::SHA::sha256_hex($token) : '';
    my ($user) = grep {length($self->{enroll}{$_}) && $self->{enroll}{$_} eq $hash} sort keys %{$self->{enroll}};
    return {ok => 0, status => 403, error => 'the enrollment token is not any user\'s'} unless defined $user;
    return {ok => 0, status => 400, error => 'a name is letters, digits, "." "_" or "-"'}
        unless defined $name and !ref($name) and $name =~ m/\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/;
    return {ok => 0, status => 409, error => "the name '$name' is taken"} if $self->{agents}{$name};
    return {ok => 0, status => 400, error => 'the tags are a list of short lower-case words'}
        unless ref($tags) eq 'ARRAY' and @$tags and !grep {ref($_) or !/\A[a-z][a-z0-9-]{0,31}\z/} @$tags;
    my $agent_token = _random_token();
    $self->{agents}{$name} = {tags => [@$tags], token_sha256 => Digest::SHA::sha256_hex($agent_token),
        user => $user, enrolled => $now};
    $self->_save();
    return {ok => 1, token => $agent_token, name => $name, tags => [@$tags]};
}

# the agents a user enrolled: name, tags and when
sub agents_of {
    my ($self, $user) = @_;
    return [map {{name => $_, tags => [@{$self->{agents}{$_}{tags}}], enrolled => $self->{agents}{$_}{enrolled}}}
        grep {defined $self->{agents}{$_}{user} and $self->{agents}{$_}{user} eq ($user // '')} sort keys %{$self->{agents}}];
}

# remove an agent of a user: its token stops working, its held poll and its job are ended
sub revoke {
    my ($self, $user, $name) = @_;
    my $a = $self->{agents}{$name};
    return {ok => 0, error => "no agent '$name' of yours"} unless $a and defined $a->{user} and $a->{user} eq ($user // '');
    delete $self->{agents}{$name};
    @{$self->{pollers}} = grep {$_->{name} ne $name ? 1 : do {$_->{send}->(204, ''); 0}} @{$self->{pollers}};
    my $id = $self->{busy}{$name};
    $self->_finish($self->{jobs}{$id}, {ok => JSON::XS::false(), error => 'the agent was revoked'})
        if defined $id and $self->{jobs}{$id};
    $self->_save();
    return {ok => 1};
}


# the name of the agent whose token this is, or undef
sub agent_of_token {
    my ($self, $token) = @_;
    return undef unless defined $token and length $token;
    my $hash = Digest::SHA::sha256_hex($token);
    for my $name (sort keys %{$self->{agents}}) {
        return $name if $self->{agents}{$name}{token_sha256} eq $hash;
    }
    return undef;
}

sub _has_tags {
    my ($have, $need) = @_;
    my %h = map {($_ => 1)} @$have;
    return !grep {!$h{$_}} @$need;
}

# one request of the agent listener: $req = {method, path, headers (lower-case names), body};
# $send->($status, $body) answers it (now, or later for a held poll)
sub http {
    my ($self, $req, $send, $now) = @_;
    $now //= time;
    my $method = $req->{method} // '';
    my $path = $req->{path} // '';
    if ($method eq 'POST' and $path eq '/agents/enroll') {
        my $r = eval {$JSON->decode($req->{body} // '')};
        return $send->(400, _err('an enrollment is {"token", "name", "tags"}')) unless ref($r) eq 'HASH';
        my $e = $self->enroll($r->{token}, $r->{name}, $r->{tags}, $now);
        return $send->($e->{status} // 200, $e->{ok} ? $JSON->encode({ok => JSON::XS::true(), token => $e->{token},
            name => $e->{name}, tags => $e->{tags}}) : _err($e->{error}));
    }
    my $h = $req->{headers} // {};
    my ($token) = (($h->{authorization} // '') =~ m/\ABearer ([A-Za-z0-9_-]{16,128})\z/);
    my $name = $self->agent_of_token($token);
    return $send->(403, _err('forbidden')) unless defined $name;
    $self->{seen}{$name} = $now;
    if ($method eq 'GET' and $path eq '/agents/poll') {
        return $send->(409, _err('the agent has a job already')) if $self->{busy}{$name};
        # an earlier poll of the same agent is answered as done
        for my $p (grep {$_->{name} eq $name} @{$self->{pollers}}) {
            $p->{send}->(204, '');
        }
        @{$self->{pollers}} = grep {$_->{name} ne $name} @{$self->{pollers}};
        push @{$self->{pollers}}, {name => $name, send => $send, deadline => $now + $POLL_WAIT};
        $self->_match($now);
        return;
    }
    if ($method eq 'POST' and $path =~ m{\A/agents/result/([0-9a-f]{24})\z}) {
        my $id = $1;
        my $job = $self->{jobs}{$id};
        return $send->(404, _err('no such job')) unless $job and $job->{state} eq 'assigned' and $job->{agent} eq $name;
        my $r = eval {$JSON->decode($req->{body} // '')};
        return $send->(400, _err('a result is {"exit": N, "output": base64}'))
            unless ref($r) eq 'HASH' and defined $r->{exit} and $r->{exit} =~ m/\A-?\d+\z/;
        my $out = defined $r->{output} ? (eval {MIME::Base64::decode_base64($r->{output})} // '') : '';
        $out = substr($out, 0, $MAX_OUT)."\n[output cut]\n" if length($out) > $MAX_OUT;
        $self->_finish($job, {ok => JSON::XS::true(), exit => $r->{exit} + 0, output => $out});
        $send->(200, $JSON->encode({ok => JSON::XS::true()}));
        $self->_match($now);
        return;
    }
    return $send->(404, _err('no such path'));
}

# a job for an agent with these tags: $done->($result) when it is answered, refused or late
# returns nothing; a job that cannot run now is answered at once
sub submit {
    my ($self, %j) = @_;
    my $now = $j{now} // time;
    my $need = $j{tags} // [];
    my $done = $j{done};
    my @able = grep {_has_tags($self->{agents}{$_}{tags}, $need)} sort keys %{$self->{agents}};
    if (!@able) {
        $done->({ok => JSON::XS::false(), error => "no agent with the tags (@$need) is configured"});
        return;
    }
    my @online = grep {$self->_online($_, $now)} @able;
    if (!@online) {
        $done->({ok => JSON::XS::false(), error => "no agent with the tags (@$need) is connected"});
        return;
    }
    my $id = join('', map {sprintf('%02x', int(rand(256)))} 1 .. 12);
    my $job = {id => $id, project => $j{project}, tags => [@$need], argv => $j{argv}, timeout => $j{timeout} // 120,
        state => 'queued', submitted => $now, done => $done};
    $self->{jobs}{$id} = $job;
    push @{$self->{queue}}, $id;
    $self->_match($now);
    return $id;
}

# an agent that has a poll held, or polled lately
sub _online {
    my ($self, $name, $now) = @_;
    return 1 if grep {$_->{name} eq $name} @{$self->{pollers}};
    return ($self->{seen}{$name} // 0) >= $now - $ONLINE;
}

# the queued jobs go to the held polls of agents that are free and have their tags
sub _match {
    my ($self, $now) = @_;
    my @queue = @{$self->{queue}};
    for my $id (@queue) {
        my $job = $self->{jobs}{$id} or next;
        my ($p) = grep {!$self->{busy}{$_->{name}} && _has_tags($self->{agents}{$_->{name}}{tags}, $job->{tags})}
            @{$self->{pollers}};
        next unless $p;
        $self->_assign($job, $p, $now);
    }
    return;
}

sub _assign {
    my ($self, $job, $p, $now) = @_;
    @{$self->{queue}} = grep {$_ ne $job->{id}} @{$self->{queue}};
    @{$self->{pollers}} = grep {$_ != $p} @{$self->{pollers}};
    $job->{state} = 'assigned';
    $job->{agent} = $p->{name};
    $job->{deadline} = $now + $job->{timeout} + $GRACE;
    $self->{busy}{$p->{name}} = $job->{id};
    $p->{send}->(200, $JSON->encode({id => $job->{id}, project => $job->{project},
        argv => $job->{argv}, timeout => $job->{timeout}}));
    return;
}

sub _finish {
    my ($self, $job, $res) = @_;
    delete $self->{jobs}{$job->{id}};
    delete $self->{busy}{$job->{agent}} if defined $job->{agent} and ($self->{busy}{$job->{agent}} // '') eq $job->{id};
    $job->{state} = 'done';
    $job->{done}->($res) if $job->{done};
    return;
}

# the time passes: held polls end (204), jobs that waited too long are refused, an agent that
# does not answer loses its job
sub tick {
    my ($self, $now) = @_;
    $now //= time;
    for my $p (grep {$_->{deadline} <= $now} @{$self->{pollers}}) {
        $p->{send}->(204, '');
    }
    @{$self->{pollers}} = grep {$_->{deadline} > $now} @{$self->{pollers}};
    for my $id (@{[@{$self->{queue}}]}) {
        my $job = $self->{jobs}{$id} or next;
        next unless $now - $job->{submitted} >= $JOB_WAIT;
        @{$self->{queue}} = grep {$_ ne $id} @{$self->{queue}};
        delete $self->{jobs}{$id};
        $job->{done}->({ok => JSON::XS::false(), error => "no agent took the job in $JOB_WAIT s"}) if $job->{done};
    }
    for my $job (grep {$_->{state} eq 'assigned' and $_->{deadline} <= $now} values %{$self->{jobs}}) {
        $self->_finish($job, {ok => JSON::XS::false(), error => "the agent did not answer in time"});
    }
    $self->_match($now);
    return;
}

sub _err { my ($msg) = @_; return $JSON->encode({ok => JSON::XS::false(), error => $msg}) }

1;
