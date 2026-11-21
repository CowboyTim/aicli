package remote_agent;
# The agent side of the remote agents (see PLAN.md, "remote agents"): `ai.pl --agent` on a
# machine that has devices. It asks the broker for a job (a long poll), runs the job's program
# in its own working directory, and posts the answer. No chat, no model, no API key here.
#
# The agent's credential is its token (from its enrollment; the broker keeps only its SHA-256).
# The broker is reached over HTTPS and its certificate is checked as any client checks it (the
# public CA). No certificate of the agent's own. A pin (--pin) is optional: the public key of the
# server must be that one as well (it breaks at a renewal with a new key, so only when wanted).
#
# A job is a program and its arguments, never a shell. The agent runs only the programs of
# its own --programs list, whatever the broker sends: a second check in front of the broker's.
# Everything waits in the event loop (utils.pm): a poll, a job, a post.

use strict; use warnings;
use JSON::XS ();
use MIME::Base64 ();
use File::Path ();
use POSIX ();
use utils ();

my $JSON = JSON::XS->new->canonical(1)->utf8;

our $MAX_OUT = 1024 * 1024;   # the output of a job that is posted, at most this many bytes
our $RETRY   = 5;             # seconds before the next poll after an error

sub new {
    my ($class, %a) = @_;
    my $url = $a{url} // die "remote agent: the broker's URL is needed (https://...)\n";
    $url =~ s{/+\z}{};
    my $name = $a{name} // die "remote agent: a name is needed\n";
    die "remote agent: a name is letters, digits, '.', '_' or '-': '$name'\n"
        unless $name =~ m/\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/;
    my @programs = @{$a{programs} // []};
    die "remote agent: the programs it may run are a list (--programs bash,perl)\n" unless @programs;
    my $work = $a{work} // die "remote agent: a working directory is needed (--work DIR)\n";
    my $pin = $a{pin};
    if (defined $pin) {
        die "remote agent: a pin is sha256//BASE64 of the server's public key, '$pin'\n"
            unless $pin =~ m{\Asha256//[A-Za-z0-9+/]{43}=\z};
        die "remote agent: this curl cannot pin a public key (no CURLOPT_PINNEDPUBLICKEY)\n"
            unless defined eval { curl::CURLOPT_PINNEDPUBLICKEY() };
    }
    my $token = $a{token} // '';
    die "remote agent: a token is needed (--token, or AI_AGENT_TOKEN)\n"
        unless $token =~ m/\A[A-Za-z0-9_-]{16,128}\z/;
    return bless {
        url       => $url,
        name      => $name,
        programs  => {map {($_ => 1)} @programs},
        work      => $work,
        token     => $token,
        pin       => $pin,
        headers   => $a{headers} // [],   # extra request headers (tests)
        poll_wait => $a{poll_wait} // 30,
        jobs      => 0,
    }, $class;
}

sub _say { my ($msg) = @_; log::info("remote agent: $msg"); return }

# the first poll; then one after each job and each error
sub start {
    my ($self) = @_;
    mkdir($self->{work}) unless -d $self->{work};
    _say("agent $self->{name} asks $self->{url}");
    $self->_poll();
    return $self;
}

sub _headers {
    my ($self, @extra) = @_;
    return [@extra, "Authorization: Bearer $self->{token}", "Accept: application/json", @{$self->{headers}}];
}

sub _poll {
    my ($self) = @_;
    loop::http(method => 'GET', url => $self->{url} . '/agents/poll', data => '',
        headers => $self->_headers(), timeout => $self->{poll_wait} + 10, pin => $self->{pin},
        on_done => sub { $self->_polled(@_) });
    return;
}

sub _polled {
    my ($self, $req) = @_;
    if (defined $req->{error} and $req->{code} != 204) {
        log::error("remote agent: the broker did not answer the poll: ".($req->{error} // $req->{code}));
        return $self->_later();
    }
    return $self->_poll() if $req->{code} == 204;
    my $job = eval {$JSON->decode($req->{body} // '')};
    if (ref($job) ne 'HASH' or !defined $job->{id}) {
        log::error("remote agent: a job the broker sent is not a job");
        return $self->_later();
    }
    $self->_run($job);
    return;
}

sub _later {
    my ($self) = @_;
    loop::timer($RETRY, sub { $self->_poll() });
    return;
}

sub _run {
    my ($self, $job) = @_;
    my $id = $job->{id};
    my $argv = $job->{argv};
    my $project = $job->{project} // '';
    $self->{jobs}++;
    if ($id !~ m/\A[0-9a-f]{24}\z/ or ref($argv) ne 'ARRAY' or !@$argv or grep {ref($_) or !defined $_} @$argv) {
        _say("job $id: not a job");
        return $self->_result($id, 2, "the job is not a program and its arguments\n");
    }
    if (!$self->{programs}{$argv->[0]}) {
        _say("job $id: refused, $argv->[0] is not in this agent's programs");
        return $self->_result($id, 126, "refused: $argv->[0] is not a program of this agent (its programs: "
            .join(', ', sort keys %{$self->{programs}}).")\n");
    }
    # account/project: the broker's names (its accounts have no dash, see broker.pl)
    if ($project !~ m{\A[A-Za-z0-9][A-Za-z0-9_]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z}) {
        return $self->_result($id, 2, "no such project\n");
    }
    my $dir = "$self->{work}/$project";
    eval { File::Path::make_path($dir); 1 } or return $self->_result($id, 1, "cannot make $dir\n");
    _say("job $id: $argv->[0] in $project");
    loop::spawn(sub {
        chdir($dir) or die "cannot enter $dir: $!\n";
        exec {$argv->[0]} @$argv;
        die "cannot run $argv->[0]: $!\n";
    }, timeout => $job->{timeout} // 120, on_done => sub {
        my ($out, $exit, $sig, $why) = @_;
        $out //= '';
        $out .= "[stopped: $why]\n" if length($why // '');
        my $code = length($why // '') ? 124 : $exit;
        _say("job $id: exit $code");
        $self->_result($id, $code, $out);
    });
    return;
}

# the answer of a job: exit code and output (base64, at most MAX_OUT bytes); then the next poll
sub _result {
    my ($self, $id, $exit, $out) = @_;
    $out = substr($out, 0, $MAX_OUT)."\n[output cut]\n" if length($out) > $MAX_OUT;
    my $body = $JSON->encode({exit => $exit + 0, output => MIME::Base64::encode_base64($out, '')});
    loop::http(method => 'POST', url => $self->{url} . "/agents/result/$id", data => $body,
        headers => $self->_headers("Content-Type: application/json"), timeout => 60, pin => $self->{pin}, on_done => sub {
            my ($req) = @_;
            log::error("remote agent: the broker did not take the result: ".($req->{error} // $req->{code}))
                if defined $req->{error} or $req->{code} != 200;
            $self->_poll();
        });
    return;
}

# a name for an agent that was not given one: a random UUID (version 4), e.g. 3f0c…-…
sub new_name {
    open(my $fh, '<:raw', '/dev/urandom') or die "remote agent: no random source: $!\n";
    my $n = read($fh, my $b, 16);
    close($fh);
    die "remote agent: no random source\n" unless defined $n and $n == 16;
    vec($b, 6, 8) = (ord(substr($b, 6, 1)) & 0x0f) | 0x40;   # version 4
    vec($b, 8, 8) = (ord(substr($b, 8, 1)) & 0x3f) | 0x80;   # variant 10
    my $h = unpack('H*', $b);
    return join '-', substr($h, 0, 8), substr($h, 8, 4), substr($h, 12, 4), substr($h, 16, 4), substr($h, 20, 12);
}

# tags that name what an agent can do, from its programs: the program's name (its last path part)
# when it is a short lower-case word, each once
sub tags_of_programs {
    my @tags;
    my %seen;
    for my $p (@_) {
        my ($base) = $p =~ m{([^/]+)\z};
        next unless defined $base and $base =~ m/\A[a-z][a-z0-9-]{0,31}\z/;
        push @tags, $base unless $seen{$base}++;
    }
    return @tags;
}

# Enrollment (once per machine): the user's enrollment token and the agent's name and tags go to
# the broker, which answers the agent's own token. Synchronous: it runs before the agent's loop.
# Dies with the broker's reason when it refuses.
sub enroll {
    my (%a) = @_;
    my $url = ($a{url} // die "enroll: the broker's URL is needed\n");
    $url =~ s{/+\z}{};
    my $body = $JSON->encode({token => $a{token}, name => $a{name}, tags => $a{tags}});
    my $done = 0;
    my $req = loop::http(method => 'POST', url => "$url/agents/enroll", data => $body,
        headers => ["Content-Type: application/json", "Accept: application/json"],
        timeout => 60, pin => $a{pin}, on_done => sub {$done = 1});
    loop::run(sub {$done});
    my $r = eval {$JSON->decode($req->{body} // '')};
    if (defined $req->{error} and ref($r) ne 'HASH') {
        die "enroll: the broker did not answer: ".($req->{error})."\n";
    }
    die "enroll: ".($r->{error} // "the broker refused (HTTP $req->{code})")."\n" unless ref($r) eq 'HASH' and $r->{ok};
    return {token => $r->{token}, name => $r->{name}, tags => $r->{tags}};
}

# the agent's credentials, kept in its own file (mode 0600): the broker's URL, the name, the token
sub save_credentials {
    my ($file, %c) = @_;
    my $tmp = "$file.tmp$$";
    umask(077);
    open(my $fh, '>', $tmp) or die "cannot write $tmp: $!\n";
    print {$fh} $JSON->encode({url => $c{url}, name => $c{name}, token => $c{token}});
    close($fh) or die "cannot write $tmp: $!\n";
    rename($tmp, $file) or die "cannot write $file: $!\n";
    return;
}

sub load_credentials {
    my ($file) = @_;
    return undef unless -f $file;
    open(my $fh, '<', $file) or die "cannot read $file: $!\n";
    my $c = eval {$JSON->decode(do { local $/; <$fh> })};
    close($fh);
    die "$file is not the credentials of an agent\n" unless ref($c) eq 'HASH';
    return $c;
}

1;
