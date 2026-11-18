package ui;
# The web interface (ai.pl --ui): a small HTTP/1.1 server on the event loop,
# headless. Input comes in as POST /message and goes into the queue that
# chat_loop reads (input()); the output of the chat goes out as server-sent
# events (GET /events) through $ai::EVENT_SINK. No thread, no fork, no blocking
# call in a callback: a request is parsed, answered and the connection closed
# (or kept open for the stream), and the turn runs in the main flow.
#
# Every route needs the token that start() makes, in the cookie aicli_token
# (set by GET /?token=...) or in an Authorization: Bearer header. The listen
# address is 127.0.0.1 unless the caller asks for another one.

use strict; use warnings;
no warnings "once"; # the chat variables ($ai::AI_SESSION, $::ABORT) are set by ai.pm
use IO::Socket::IP; # IPv4 and IPv6 (a core module)
use POSIX ();
use File::Basename ();
use Errno ();
use Socket ();
use IO::Socket::UNIX ();
use MIME::Base64 ();

our ($listen, $token, $port, $bind, $html_file, $theme_file, $gate);
our $tls_ctx;  # the TLS context, when the interface is https (--tls-cert and --tls-key)
our $voice;     # the speech recognizer: undef (not checked yet), 'ok', 'none' (AI_ASR_URL unset), 'unreachable'
our %conn;      # fileno => connection
our @clients;   # connections that read the event stream
our @queue;     # messages waiting for chat_loop
our ($active, %worker, %model_of, $models, $OUTBOX, $IDLE, $last_error, $BROKER_SOCKET, $BROKER_ASK); # the master, see below
$IDLE = 900;
$last_error = '';
our $MAX_BODY    = 1_000_000; # bytes of a request body
our $MAX_VOICE   = 20_000_000; # bytes of a recording (16 kHz mono WAV: about 2 minutes)
our $MAX_QUEUE   = 20;        # messages waiting at once
our $MAX_PENDING = 1_000_000; # bytes not yet sent to a client before it is dropped

my %STATUS = (
    200 => 'OK', 202 => 'Accepted', 303 => 'See Other', 400 => 'Bad Request',
    401 => 'Unauthorized', 403 => 'Forbidden', 404 => 'Not Found',
    405 => 'Method Not Allowed', 413 => 'Payload Too Large', 415 => 'Unsupported Media Type',
    429 => 'Too Many Requests', 500 => 'Internal Server Error',
    431 => 'Request Header Fields Too Large', 501 => 'Not Implemented',
);

sub _new_token {
    open(my $fh, '<:raw', '/dev/urandom') or die "ui: no /dev/urandom: $!\n";
    read($fh, my $raw, 16) == 16 or die "ui: short read from /dev/urandom\n";
    close($fh);
    return unpack('H*', $raw);
}

# Listen and print the address with the token. port 0 takes a free port.
sub start {
    my (%o) = @_;
    $bind  = $o{bind} // '127.0.0.1';
    $token = $o{token} // _new_token();
    $gate = $::ORIG_ENV{AI_GATE_SECRET};
    $tls_ctx = $o{tls_cert} ? _tls_context($o{tls_cert}, $o{tls_key}) : undef;
    # an IPv6 address is in brackets in a URL; "::" is any IPv6 address
    $listen = IO::Socket::IP->new(
        LocalHost => $bind, LocalPort => ($o{port} // 8080), Listen => 16,
        ReuseAddr => 1, Proto => 'tcp',
    ) or die "ui: cannot listen on $bind:".($o{port} // 8080).": $!\n";
    $listen->blocking(0);
    $port = $listen->sockport;
    $html_file = File::Basename::dirname(__FILE__)."/ai/ui/index.html";
    $theme_file = File::Basename::dirname(__FILE__)."/ai/ui/theme.css";
    loop::watch($listen, \&_accept);
    loop::timer(15, \&_ping);
    $ai::EVENT_SINK = \&publish;
    $active = $ai::AI_SESSION;
    # the broker's socket: named by AI_BROKER_SOCKET, or the one aicli.sh --broker mounts
    $BROKER_SOCKET = $::ORIG_ENV{AI_BROKER_SOCKET} // (-S '/run/aicli-broker/broker.sock' ? '/run/aicli-broker/broker.sock' : undef);
    $SIG{PIPE} = 'IGNORE'; # a worker that went away is an end of file, not a signal
    _worker_for($active) if defined $active;
    loop::timer(60, \&_idle_check);
    check_voice();
    $log::on_error = sub { publish(failed => {text => ai::web_text($_[0])}) };
    # "any" addresses (0.0.0.0, ::) are not a place to open: the loopback is
    my $shown = ($bind eq '0.0.0.0' or $bind eq '::') ? 'localhost' : $bind;
    my $host = $shown =~ m/:/ ? "[$shown]" : $shown;
    my $scheme = $tls_ctx ? 'https' : 'http';
    print STDERR "aicli web interface: $scheme://$host:$port/?token=$token\n";
    # the phone: an address of this machine it can reach, and a QR code for it
    my $phone = $bind eq '0.0.0.0' ? (_lan_address(4) // '127.0.0.1')
              : $bind eq '::'      ? (_lan_address(6) // '::1') # no global IPv6: the loopback
              : $bind;
    my $phone_host = $phone =~ m/:/ ? "[$phone]" : $phone;
    my $phone_url = "$scheme://$phone_host:$port/?token=$token";
    # behind nginx (compose sets AI_PUBLIC_DOMAIN): the public address is the one to open
    my $public = $::ORIG_ENV{AI_PUBLIC_DOMAIN};
    my $public_url = defined $public && length $public ? "https://$public/?token=$token" : undef;
    print STDERR "aicli web interface (public): $public_url\n" if defined $public_url;
    print STDERR "aicli web interface on the phone: $phone_url\n" if !defined $public_url and $phone ne $shown;
    _qr($public_url // $phone_url);
    return $port;
}

# The address of this machine for a phone on the local network, of the family
# given (4 or 6): IPv4 from /proc/net/fib_trie, a private one first; IPv6 from
# /proc/net/if_inet6, a global one (not fe80::, not the loopback). undef when
# there is none (Linux only).
sub _lan_address {
    my ($family) = @_;
    $family //= 4;
    if($family == 6){
        open(my $fh, '<', '/proc/net/if_inet6') or return undef;
        my @addr;
        while(my $l = <$fh>){
            my ($hex) = $l =~ m/^([0-9a-f]{32})\s/ or next;
            my $a = join(':', $hex =~ m/(....)/g);
            next if $a =~ m/^fe80/i or $a eq '0000:0000:0000:0000:0000:0000:0000:0001';
            push @addr, $a;
        }
        close($fh);
        return $addr[0];
    }
    open(my $fh, '<', '/proc/net/fib_trie') or return undef;
    my ($prev, @addr, $private);
    while(my $l = <$fh>){
        if($l =~ m{/32 host LOCAL} and defined $prev and $prev =~ m/\|-- (\d+\.\d+\.\d+\.\d+)/){
            my $a = $1;
            next if $a =~ m/^127\./;
            push @addr, $a;
            $private //= $a if $a =~ m/^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/;
        }
        $prev = $l;
    }
    close($fh);
    return $private // $addr[0];
}

# The QR code of an address, in the terminal, from qrencode (the dev image has
# it). Run as a child through the loop, like any program.
sub _qr {
    my ($url) = @_;
    my ($out, $exit) = utils::fork_run(sub {
        exec('qrencode', '-t', 'ANSIUTF8', '-m', '2', $url) or POSIX::_exit(127);
    }, timeout => 10);
    if(defined $exit and $exit == 0 and length($out // '')){
        print STDERR $out;
    } else {
        print STDERR "(no QR code: qrencode is not installed or failed)\n";
    }
    return;
}

sub stop {
    for my $cn (values %conn) { _close($cn) }
    loop::unwatch($listen) if $listen;
    close($listen) if $listen;
    undef $listen;
    _stop_all();
    $ai::EVENT_SINK = undef;
    $log::on_error = undef;
    return;
}

# The worker side (worker.pm, one per session): the model list and the model choice
# are work for the chat's own flow, so they go through the queue like the messages
# and run where the HTTP waits are allowed.

# the models event of the list the chat has now (the data of the event)
sub _models_data {
    return {
        current => ai::current_label(),
        list    => [map {ai::model_label($_)} @ai::ALL_MODELS],
    };
}

# the models of every provider, to the page; refresh asks the providers again
sub _send_models {
    my ($refresh) = @_;
    my ($pairs, $errors);
    if($refresh or !@ai::ALL_MODELS){
        ($pairs, $errors) = ai::all_models();
    } else {
        ($pairs, $errors) = (\@ai::ALL_MODELS, []);
    }
    log::error("no model list from $_") for @$errors;
    publish(models => _models_data());
    return;
}

# the page chose a model: the provider and the model of the session change
sub _switch_model {
    my ($choice) = @_;
    my $ok = eval {
        my $pairs = @ai::ALL_MODELS ? \@ai::ALL_MODELS : (ai::all_models())[0];
        my $pair = ai::choice_pair($choice, $pairs);
        my $err = ai::set_model(@$pair);
        die $err if defined $err;
        1;
    };
    if(!$ok){
        my $msg = $@ // 'unknown error';
        $msg =~ s/\s+\z//;
        log::error("could not switch the model: $msg");
    }
    publish(state => _state());
    _send_models(0);
    return;
}

# The next input for chat_loop (the worker's): a text message as it is, a
# recording first written down and recognized (here, in the main flow: the
# recognizer is waited for, a request must not wait). The text goes to the chat
# as soon as it is ready. A "/" line is refused by the worker, not sent here.

sub input {
    return sub {
        while(1){
            loop::run(sub { @queue or !$::LOOP });
            return unless $::LOOP;
            my $item = shift @queue;
            if(ref $item eq 'HASH' and exists $item->{models}){
                _send_models(1);
                next;
            }
            if(ref $item eq 'HASH' and exists $item->{model}){
                _switch_model($item->{model});
                next;
            }
            return $item unless ref $item;
            my $text = _recognize($item->{audio});
            next unless defined $text and length $text;
            ai::emit(heard => {text => $text});
            return $text;
        }
    };
}

sub _recognize {
    my ($wav) = @_;
    my $file = "$ai::AI_SESSION_DIR/voice-web.wav";
    open(my $fh, '>:raw', $file) or do { log::error("cannot write $file: $!"); return undef };
    print {$fh} $wav;
    close($fh);
    my $text = ai::transcribe($file);
    unlink($file);
    check_voice() unless defined $text and length $text;
    return $text;
}

sub queued { return scalar @queue }

# --- the pods: the broker (broker.pl) starts and stops the dev pods of the projects ---
# The master asks the broker over its socket, in a child of the loop (the request
# waits for the engine: the loop must not). The answer comes to a callback.

sub _broker_ask {
    my ($req, $cb) = @_;
    return $BROKER_ASK->($req, $cb) if $BROKER_ASK; # tests
    my $socket = $BROKER_SOCKET;
    return $cb->({ok => JSON::XS::false(), error => "no broker: the web interface was started without one (aicli.sh --broker)"})
        unless length($socket // '');
    loop::spawn(sub {
        my $line = eval {
            my $c = IO::Socket::UNIX->new(Peer => $socket, Type => Socket::SOCK_STREAM())
                or die "the broker is not reachable: $!\n";
            print {$c} $::JSON->encode($req)."\n";
            my $l = <$c>;
            close($c);
            die "the broker gave no answer\n" unless defined $l;
            $l;
        };
        if (defined $line) {
            print $line;
        } else {
            my $why = $@ // 'unknown error';
            $why =~ s/\s+\z//;
            print $::JSON->encode({ok => JSON::XS::false(), error => $why});
        }
    }, timeout => 120, on_done => sub {
        my ($out) = @_;
        my $r = eval {$::JSON->decode($out // '')};
        $r = {ok => JSON::XS::false(), error => "the broker answered nothing usable"} unless ref($r) eq 'HASH';
        $cb->($r);
    });
    return;
}

# the projects, each with the state of its pod, from the broker's list
sub _pods_data {
    my ($r) = @_;
    my %pod = map {(substr($_->{name}, 6) => $_->{status} // '')} @{$r->{pods} // []}; # aicli-<project>
    return {
        ok       => $r->{ok} ? JSON::XS::true() : JSON::XS::false(),
        error    => $r->{error} // '',
        available => length($BROKER_SOCKET // '') || $BROKER_ASK ? JSON::XS::true() : JSON::XS::false(),
        projects => [map {{name => $_, open => exists $pod{$_} ? JSON::XS::true() : JSON::XS::false(),
                           status => $pod{$_} // 'not started'}} @{ai::project_dirs()}],
    };
}

sub _refresh_pods {
    _broker_ask({op => 'list'}, sub { publish(pods => _pods_data($_[0])) });
    return;
}

# the page asked for an open, close or list of a project's pod
sub _pod_request {
    my ($op, $project) = @_;
    _broker_ask({op => $op, project => $project}, sub {
        my ($r) = @_;
        publish(broker => {op => $op, project => $project, ok => $r->{ok} ? JSON::XS::true() : JSON::XS::false(),
                           error => $r->{error} // '', pod => $r->{pod} // ''});
        _refresh_pods();
    });
    return;
}

# --- the master: one worker process per session (worker.pm) --------------------
# This process is the master: the HTTP interface, the token and the event stream.
# Each session that is used has a worker, a process of its own with its chat
# (worker::serve), and a socket to the master. Messages go to the worker of the
# active session, the one the page shows. The others run on: a busy one shows as
# busy in the list, its failures reach the page, and its conversation is read back
# when the page switches to it.


# an event of the stream as text
sub _frame {
    my ($type, $data) = @_;
    return "event: $type\ndata: ".$::JSON->encode($data // {})."\n\n";
}

# the state of the page: the active session, and what its worker says
sub _master_state {
    my $name = $active // '';
    my $w = $worker{$name};
    return {
        session => $name,
        model   => $model_of{$name} // '',
        busy    => ($w && $w->{busy}) ? \1 : \0,
        queued  => $w ? $w->{pending} : 0,
        voice   => $voice // 'unknown',
    };
}

sub _busy_list { return [sort grep {$worker{$_}{busy}} keys %worker] }

sub _models_out {
    return {current => $model_of{$active // ''} // '', list => $models // []};
}

# the sessions to choose from: the list, the active one, the busy ones
sub _sessions_data {
    return {
        current  => $active // '',
        list     => ai::session_choices(),
        busy     => _busy_list(),
        project  => defined $active ? ai::session_project($active) : '',
        projects => ['', @{ai::project_dirs()}], # the root first
    };
}

# the conversation of a session as the page shows it: what the user typed and what
# the model answered (not tool calls, results or summaries), the last $HISTORY_MAX
our $HISTORY_MAX = 200;

sub _history_data {
    my ($name) = @_;
    my $file = "$ai::SESSIONS_DIR/".($name // '')."/chat";
    my @all = (defined $name and -f $file) ? eval {ai::load_messages($file)} : ();
    my @msgs = grep {ai::is_user_input($_) or (($_->{role} // '') eq 'assistant' and length($_->{content} // ''))} @all;
    my $more = @msgs > $HISTORY_MAX ? 1 : 0;
    splice(@msgs, 0, @msgs - $HISTORY_MAX) if $more;
    return {
        session  => $name // '',
        more     => $more ? \1 : \0,
        messages => [map {{role => ($_->{role} eq 'user' ? 'user' : 'assistant'), text => $_->{content}}} @msgs],
    };
}

# the worker of a session: started when it has none (a fork; the child is a
# worker, see worker.pm). undef when it cannot be started.
sub _worker_for {
    my ($name) = @_;
    return $worker{$name} if $worker{$name};
    if ($OUTBOX) {
        return $worker{$name} = {fake => 1, busy => 0, pending => 0, seen => time(), closing => 0};
    }
    return undef unless ai::valid_session_name($name // '') and -d "$ai::SESSIONS_DIR/$name";
    require worker;
    require Socket;
    socketpair(my $mine, my $theirs, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC())
        or do { log::error("no socket for session $name: $!"); return undef };
    my $project = _project_dir($name);
    my $pid = fork();
    if (!defined $pid) {
        log::error("cannot start the session $name: $!");
        close($mine);
        close($theirs);
        return undef;
    }
    if (!$pid) {
        # the worker: none of the master's sockets, timers or transfers
        loop::forget();
        close($mine);
        my $ok = eval {worker::serve($theirs, session => $name, project => $project); 1};
        print STDERR "session $name: $@" unless $ok;
        POSIX::_exit($ok ? 0 : 1);
    }
    close($theirs);
    $mine->autoflush(1);
    my $w = {pid => $pid, fh => $mine, buf => '', busy => 0, pending => 0, seen => time(), closing => 0};
    $worker{$name} = $w;
    loop::watch($mine, sub { _worker_read($name) });
    return $w;
}

# the directory of a session's project, when it is still there (else the root)
sub _project_dir {
    my ($name) = @_;
    my $dir = ai::project_path(ai::session_project($name));
    return -d $dir ? $dir : $ai::ROOT;
}

# the page chose a project: its newest session becomes the active one, or a new
# session is made in it. Returns 1, or 0 with the reason in $last_error.
sub _project {
    my ($rel) = @_;
    $last_error = '';
    if (length($rel) and !grep {$_ eq $rel} @{ai::project_dirs()}) {
        $last_error = "there is no project '$rel'";
        return 0;
    }
    my ($newest) = grep {$_->{project} eq $rel} @{ai::session_choices()};
    return _activate($newest->{name}) if $newest;
    return _activate(undef, new => 1, project => $rel);
}

# a message to the worker of a session
sub _send_to {
    my ($name, $msg) = @_;
    return push(@$OUTBOX, [$name, $msg]) if $OUTBOX;
    my $w = $worker{$name} or return 0;
    return 0 unless $w->{fh};
    return print({$w->{fh}} $::JSON->encode($msg)."\n") ? 1 : 0;
}

# a message for the active session's worker. Returns the number of messages it has
# waiting, undef when there is no worker, -1 when it is full (text and recordings).
sub _to_active {
    my ($msg) = @_;
    return undef unless defined $active;
    my $w = _worker_for($active) or return undef;
    my $counts = exists $msg->{text} || exists $msg->{audio};
    return -1 if $counts and $w->{pending} >= $MAX_QUEUE;
    _send_to($active, $msg) or return undef;
    $w->{pending}++ if $counts;
    return $w->{pending};
}

sub _ask_models {
    return _to_active({models => 1});
}

# bytes from a worker: one event per line
sub _worker_read {
    my ($name) = @_;
    my $w = $worker{$name} or return;
    my $n = sysread($w->{fh}, my $buf, 65536);
    if (!defined $n) {
        return if $!{EINTR};
        return _worker_gone($name);
    }
    return _worker_gone($name) unless $n;
    $w->{buf} .= $buf;
    $w->{seen} = time();
    while ($w->{buf} =~ s/^([^\n]*)\n//) {
        my $ev = eval {$::JSON->decode($1)};
        _worker_event($name, $ev) if ref($ev) eq 'HASH';
    }
    return;
}

# an event of a worker: what the page shows of it, and what the master keeps
sub _worker_event {
    my ($name, $ev) = @_;
    my $w = $worker{$name} or return;
    my $type = $ev->{event} // return;
    my $data = ref($ev->{data}) eq 'HASH' ? $ev->{data} : {};
    my $is_active = defined $active && $name eq $active;
    if ($type eq 'turn') {
        my $start = ($data->{state} // '') eq 'start';
        $w->{busy} = $start ? 1 : 0;
        $w->{pending}-- if $start and $w->{pending} > 0;
        publish(busy => {list => _busy_list()});
    } elsif ($type eq 'state') {
        $model_of{$name} = $data->{model} // '';
    } elsif ($type eq 'model') {
        $model_of{$name} = $data->{text} // '';
    } elsif ($type eq 'models') {
        $models = $data->{list} // [];
        publish(models => _models_out()) if $is_active;
        return;
    }
    return publish(failed => $data) if $type eq 'failed'; # any session's failure is shown
    return unless $is_active;
    return publish(state => _master_state()) if $type eq 'state';
    return publish($type => $data);
}

# a worker is gone: its socket reached the end. A turn that was running ends on the page.
sub _worker_gone {
    my ($name) = @_;
    my $w = delete $worker{$name} or return;
    if ($w->{fh}) {
        loop::unwatch($w->{fh});
        close($w->{fh});
    }
    waitpid($w->{pid}, 0) if $w->{pid};
    my $is_active = defined $active && $name eq $active;
    publish(turn => {state => 'end'}) if $w->{busy} and $is_active;
    publish(failed => {text => "the session '$name' stopped"}) unless $w->{closing};
    publish(busy => {list => _busy_list()});
    return;
}

# the worker ends: its socket is shut for writing (the end for it), after its turn
sub _stop_worker {
    my ($name) = @_;
    my $w = $worker{$name} or return;
    $w->{closing} = 1;
    shutdown($w->{fh}, 1) if $w->{fh};
    return;
}

# workers that sit idle for $IDLE seconds are stopped; the active one is kept
sub _idle_check {
    my $now = time();
    for my $name (keys %worker) {
        my $w = $worker{$name};
        next if $w->{busy} or $w->{closing} or $w->{fake};
        next if defined $active and $name eq $active;
        next if $now - $w->{seen} < $IDLE;
        _stop_worker($name);
    }
    loop::timer(60, \&_idle_check);
    return;
}

# the page chose a session, or a new one: it becomes the active one, its worker is
# started (or kept), and the page is sent its state, conversation and the list.
# Returns 1, or 0 with the reason in $last_error.
sub _activate {
    my ($name, %o) = @_;
    $last_error = '';
    my $ok = eval {
        if ($o{new}) {
            # a new session is made in a project: the one asked for, else the active one's
            my $rel = $o{project} // (defined $active ? ai::session_project($active) : '');
            die "there is no project '$rel'\n" if length($rel) and !grep {$_ eq $rel} @{ai::project_dirs()};
            my $dir = ai::project_path($rel);
            $name = "session-".ai::new_session_id();
            $ai::AUTO_SESSION{$name} = 1; # ours: removed at the end when nothing was said
            ai::in_project($dir, sub { ai::init_session($name) });
            ai::spew("$ai::SESSIONS_DIR/$name/cwd", "$dir\n");
        } elsif (!ai::valid_session_name($name // '') or !-d "$ai::SESSIONS_DIR/$name") {
            die "there is no session '".($name // '')."'\n";
        }
        my ($prev_provider, $prev_model) = ($ai::AI_PROVIDER, $ai::SESSION_MODEL);
        ai::use_session($name);
        # a session with no model of its own keeps the one the page was using
        if (!length($ai::SESSION_MODEL // '') and length($prev_model // '')) {
            my $err = ai::set_model($prev_provider, $prev_model);
            die $err if defined $err;
        }
        1;
    };
    if (!$ok) {
        my $msg = $@ // 'unknown error';
        $msg =~ s/\s+\z//;
        $last_error = $msg;
        log::error("could not switch the session: $msg");
        return 0;
    }
    $active = $name;
    $model_of{$name} = ai::current_label();
    if (!_worker_for($name)) {
        $last_error = "the session $name cannot be started";
        return 0;
    }
    _send_to($name, {state => 1});
    publish(state => _master_state());
    publish(history => _history_data($name));
    publish(sessions => _sessions_data());
    return 1;
}

# a worker that is asked to stop, and the workers still there after a while, killed
sub _stop_all {
    delete $worker{$_} for grep {$worker{$_}{fake}} keys %worker;
    _stop_worker($_) for keys %worker;
    my $t0 = time();
    loop::run(sub { !%worker or time() - $t0 > 10 });
    for my $name (keys %worker) {
        kill 'KILL', $worker{$name}{pid} if $worker{$name}{pid};
        _worker_gone($name);
    }
    return;
}

# --- the event stream -------------------------------------------------------

# Send one event to all clients that read the stream.
our $RELAY; # set by a session worker: called as ($type, $data) for each event

sub publish {
    my ($type, $data) = @_;
    if ($type eq 'tool' or $type eq 'failed') {
        my $first = (split /\n/, ($data->{text} // ''))[0] // '';
        ai::web_note(($type eq 'tool' ? "tool: " : "error: ").$first) if length $first;
    } elsif ($type eq 'turn') {
        ai::web_note("turn ".$data->{state});
    } elsif ($type eq 'heard') {
        ai::web_note("heard: ".$data->{text});
    }
    # a session worker (worker.pm) sends its events to the master instead
    return $RELAY->($type, $data // {}) if $RELAY;
    return unless @clients;
    my $msg = "event: $type\ndata: ".$::JSON->encode($data // {})."\n\n";
    _queue($_, $msg) for @{[@clients]};
    return;
}

sub _ping {
    _queue($_, ": ping\n\n") for @{[@clients]};
    loop::timer(15, \&_ping);
    return;
}

sub _state {
    return {
        session => $ai::AI_SESSION // '',
        model   => ai::current_label(),
        busy    => $ai::BUSY ? \1 : \0,
        queued  => scalar(@queue),
        voice   => $voice // 'unknown',
    };
}

# Is the speech recognizer there? A GET to its endpoint: any HTTP answer means
# it is reachable (the endpoint itself only takes POST). Asynchronous: the
# answer goes to the page's state and to stderr. Called at start and again
# after a recognition failed.
sub check_voice {
    my $url = $::ORIG_ENV{AI_ASR_URL};
    if(!length($url // '')){
        $voice = 'none';
        publish(state => _state());
        print STDERR "aicli speech: AI_ASR_URL is not set, the mic is not available\n";
        return;
    }
    loop::http(
        method => 'get', url => $url, timeout => 5, connect_timeout => 3,
        proxy => '', # the recognizer is local: no proxy
        on_done => sub {
            my ($req) = @_;
            if($req->{code} > 0){
                $voice = 'ok';
            } else {
                $voice = 'unreachable';
                print STDERR "aicli speech: the recognizer endpoint $url is not reachable: ".($req->{error} // 'no answer')."\n";
            }
            publish(state => _state());
        },
    );
    return;
}

# --- sockets ----------------------------------------------------------------

# TLS, through Net::SSLeay (CPAN, loaded only with --tls-cert). The sockets stay
# non-blocking and on the event loop: the handshake and every read and write
# are retried when the socket is ready, and the handshake has a time limit.
sub _tls_context {
    my ($cert, $key) = @_;
    $key //= $cert;
    require Net::SSLeay;
    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    my $ctx = Net::SSLeay::CTX_new() or die "ui: TLS: cannot make a context: "._ssl_error()."\n";
    Net::SSLeay::CTX_set_options($ctx, Net::SSLeay::OP_NO_SSLv2() | Net::SSLeay::OP_NO_SSLv3()
        | Net::SSLeay::OP_NO_TLSv1() | Net::SSLeay::OP_NO_TLSv1_1());
    Net::SSLeay::CTX_use_certificate_chain_file($ctx, $cert) == 1
        or die "ui: TLS: cannot read the certificate $cert: "._ssl_error()."\n";
    Net::SSLeay::CTX_use_PrivateKey_file($ctx, $key, Net::SSLeay::FILETYPE_PEM()) == 1
        or die "ui: TLS: cannot read the key $key: "._ssl_error()."\n";
    Net::SSLeay::CTX_check_private_key($ctx) == 1
        or die "ui: TLS: the key $key does not belong to the certificate $cert\n";
    return $ctx;
}

sub _ssl_error {
    my $e = Net::SSLeay::ERR_get_error();
    return $e ? Net::SSLeay::ERR_error_string($e) : 'no details';
}

sub _accept {
    while(my $fh = $listen->accept){
        $fh->blocking(0);
        my $cn = {fh => $fh, in => '', out => ''};
        $conn{fileno($fh)} = $cn;
        if($tls_ctx){
            $cn->{ssl} = Net::SSLeay::new($tls_ctx) or do { _close($cn); next };
            Net::SSLeay::set_fd($cn->{ssl}, fileno($fh));
            $cn->{hs_timer} = loop::timer(10, sub {
                delete $cn->{hs_timer};
                _close($cn) unless $cn->{hs_done} or $cn->{closed};
            });
            loop::watch($fh, sub { _handshake($cn) });
            next;
        }
        loop::watch($fh, sub { _read($cn) });
    }
    return;
}

# the TLS handshake, one step per time the socket is ready
sub _handshake {
    my ($cn) = @_;
    return if $cn->{closed} or $cn->{hs_done};
    my $r = Net::SSLeay::accept($cn->{ssl});
    if($r == 1){
        $cn->{hs_done} = 1;
        delete $cn->{hs_timer};
        loop::watch($cn->{fh}, sub { _read($cn) });
        return;
    }
    my $e = Net::SSLeay::get_error($cn->{ssl}, $r);
    if($e == Net::SSLeay::ERROR_WANT_READ()){
        return; # the socket is watched: the next data comes back here
    }
    if($e == Net::SSLeay::ERROR_WANT_WRITE()){
        loop::timer(0.05, sub { _handshake($cn) unless $cn->{closed} });
        return;
    }
    log::info("TLS handshake failed: "._ssl_error());
    return _close($cn);
}

# bytes from the socket: plain, or decrypted by TLS
sub _read_socket {
    my ($cn) = @_;
    if(!$cn->{ssl}){
        my $n = sysread($cn->{fh}, my $buf, 65536);
        return ($n, $buf);
    }
    my $buf = Net::SSLeay::read($cn->{ssl}, 65536);
    if(defined $buf and length $buf){
        return (length $buf, $buf);
    }
    my $e = Net::SSLeay::get_error($cn->{ssl}, -1);
    return (undef, undef) if $e == Net::SSLeay::ERROR_WANT_READ() or $e == Net::SSLeay::ERROR_WANT_WRITE();
    return (0, undef); # the peer closed (or the TLS layer failed): the end
}

sub _read {
    my ($cn) = @_;
    while(!$cn->{closed}){
        my ($n, $buf) = _read_socket($cn);
        if(!defined $n){
            return if $cn->{ssl}; # TLS wants more from the socket
            return if $!{EAGAIN} or $!{EWOULDBLOCK} or $!{EINTR};
            return _close($cn);
        }
        return _close($cn) if $n == 0;
        return if $cn->{streaming} or $cn->{handled}; # nothing more is read from them
        _feed($cn, $buf);
        # TLS can hold decrypted bytes the socket will not report again
        return unless $cn->{ssl} and Net::SSLeay::pending($cn->{ssl});
    }
    return;
}

sub _queue {
    my ($cn, $bytes) = @_;
    return if $cn->{closed};
    $cn->{out} .= $bytes;
    if(length($cn->{out}) > $MAX_PENDING){
        return _close($cn); # too slow to keep up: drop it, the chat goes on
    }
    _flush($cn);
    return;
}

sub _flush {
    my ($cn) = @_;
    while(length $cn->{out}){
        my $n;
        if($cn->{ssl}){
            $n = Net::SSLeay::write($cn->{ssl}, substr($cn->{out}, 0, 65536));
            if(!defined $n or $n <= 0){
                my $e = Net::SSLeay::get_error($cn->{ssl}, $n // -1);
                $n = undef;
                $! = Errno::EAGAIN() if $e == Net::SSLeay::ERROR_WANT_READ() or $e == Net::SSLeay::ERROR_WANT_WRITE();
            }
        } else {
            $n = syswrite($cn->{fh}, $cn->{out}, 65536);
        }
        if(!defined $n){
            if($!{EAGAIN} or $!{EWOULDBLOCK}){
                # try again in a moment, the loop goes on meanwhile
                $cn->{wait} //= loop::timer(0.05, sub {
                    delete $cn->{wait};
                    _flush($cn) unless $cn->{closed};
                });
                return;
            }
            return _close($cn);
        }
        substr($cn->{out}, 0, $n, '');
    }
    return _close($cn) if $cn->{close_after};
    return;
}

sub _close {
    my ($cn) = @_;
    return if $cn->{closed}++;
    ai::web_note("page left the stream") if $cn->{streaming};
    my $fh = $cn->{fh};
    loop::unwatch($fh);
    delete $conn{fileno($fh)};
    @clients = grep {$_ != $cn} @clients;
    delete $cn->{hs_timer};
    if($cn->{ssl}){
        # close_notify: the peer then knows the answer is complete (one try, the socket is not waited for)
        Net::SSLeay::shutdown($cn->{ssl}) if $cn->{hs_done};
        Net::SSLeay::free($cn->{ssl});
    }
    undef $cn->{ssl};
    close($fh);
    return;
}

# --- HTTP -------------------------------------------------------------------

# a recording comes to POST /voice, with a bigger limit than the JSON bodies
my $p_is_voice = sub { my ($m, $path) = @_; return $m eq 'POST' && $path =~ m{^/voice(?:\?|$)} };

sub _feed {
    my ($cn, $bytes) = @_;
    $cn->{in} .= $bytes;
    my $i = index($cn->{in}, "\r\n\r\n");
    if($i < 0){
        return _respond($cn, 431, 'text/plain', "request headers too big\n") if length($cn->{in}) > 16384;
        return;
    }
    my @lines = split /\r\n/, substr($cn->{in}, 0, $i);
    my ($m, $path) = (($lines[0] // '') =~ m{^([A-Z]+) (\S+) HTTP/1\.[01]$});
    return _respond($cn, 400, 'text/plain', "bad request line\n") unless defined $m;
    my %h;
    for my $l (@lines[1 .. $#lines]){
        next unless $l =~ m/^([^:\s]+):\s*(.*?)\s*$/;
        $h{lc $1} = $2;
    }
    return _respond($cn, 501, 'text/plain', "no chunked request bodies\n") if exists $h{'transfer-encoding'};
    my $cl = $h{'content-length'} // 0;
    return _respond($cn, 400, 'text/plain', "bad content-length\n") unless $cl =~ m/^\d+$/;
    my $cap = $p_is_voice->($m, $path) ? $MAX_VOICE : $MAX_BODY;
    return _respond($cn, 413, 'text/plain', "body too big\n") if $cl > $cap;
    my $start = $i + 4;
    return if length($cn->{in}) < $start + $cl; # the rest of the body is still coming
    my $body = substr($cn->{in}, $start, $cl);
    $cn->{handled} = 1;
    _dispatch($cn, $m, $path, \%h, $body);
    return;
}

sub _respond {
    my ($cn, $code, $type, $body, @extra) = @_;
    ai::web_note("$cn->{req} -> $code") if $cn->{req};
    my $head = "HTTP/1.1 $code $STATUS{$code}\r\n"
        ."Content-Type: $type\r\n"
        ."Content-Length: ".length($body)."\r\n"
        ."Cache-Control: no-store\r\n"
        ."X-Content-Type-Options: nosniff\r\n"
        ."Connection: close\r\n";
    $head .= "$_\r\n" for @extra;
    $cn->{handled} = 1;
    $cn->{close_after} = 1;
    $cn->{out} .= "$head\r\n$body";
    _flush($cn);
    return;
}

sub _json {
    my ($cn, $code, $data) = @_;
    return _respond($cn, $code, 'application/json; charset=utf-8', $::JSON->encode($data));
}

sub _cookie {
    my ($h, $name) = @_;
    return undef unless defined $h;
    return $1 if $h =~ m/(?:^|;\s*)\Q$name\E=([^;\s]*)/;
    return undef;
}

sub _authed {
    my ($h) = @_;
    # behind nginx: nginx has checked the login (auth_request) and sends the secret it shares
    # with the agent (AI_GATE_SECRET); nothing else on the network has it
    return 1 if defined $gate and length($gate) and ($h->{'x-aicli-gate'} // '') eq $gate;
    my $t = _cookie($h->{cookie}, 'aicli_token');
    if(!defined $t and ($h->{authorization} // '') =~ m/^Bearer\s+(\S+)/){
        $t = $1;
    }
    return defined $t && $t eq $token;
}

sub _dispatch {
    my ($cn, $m, $path, $h, $body) = @_;
    my ($p, $q) = split /\?/, $path, 2;
    $q //= '';
    $cn->{req} = "$m $p";

    if($p eq '/' and $m eq 'GET'){
        my ($given) = $q =~ m/(?:^|&)token=([0-9a-f]+)/;
        if(defined $given and $given eq $token){
            return _respond($cn, 303, 'text/plain', "see /\n", "Location: /",
                "Set-Cookie: aicli_token=$token; Path=/; HttpOnly; SameSite=Lax".($tls_ctx ? '; Secure' : ''));
        }
        return _respond($cn, 401, 'text/plain', "no valid token: open the address that aicli printed at this start (with ?token=). "
            ."A QR code or address of an earlier start has the token of that start, which is not kept (AI_UI_TOKEN sets one)\n")
            unless _authed($h);
        open(my $fh, '<:raw', $html_file) or return _respond($cn, 500, 'text/plain', "no page\n");
        local $/;
        my $html = <$fh>;
        close($fh);
        # the colours: theme.css, the file the login page links too, inline in the page
        my $theme = '';
        if(open(my $tfh, '<:raw', $theme_file)){
            local $/;
            $theme = <$tfh>;
            close($tfh);
        }
        $html =~ s{/\*theme\.css\*/}{$theme};
        return _respond($cn, 200, 'text/html; charset=utf-8', $html);
    }

    return _respond($cn, 401, 'text/plain', "not signed in\n") unless _authed($h);

    # a page of another site may not post here (the cookie would go with it)
    if($m eq 'POST' and defined $h->{origin}){
        # the host must be the one asked for; the scheme may be https (a proxy in front, see nginx)
        my ($origin_host) = $h->{origin} =~ m{\Ahttps?://(.+)\z};
        return _respond($cn, 403, 'text/plain', "wrong origin\n")
            unless defined $origin_host and $origin_host eq ($h->{host} // '');
    }

    if($p eq '/events' and $m eq 'GET'){
        ai::web_note("page connected to the stream");
        $cn->{streaming} = 1;
        $cn->{handled} = 1;
        $cn->{out} .= "HTTP/1.1 200 OK\r\n"
            ."Content-Type: text/event-stream; charset=utf-8\r\n"
            ."Cache-Control: no-cache\r\n"
            ."X-Accel-Buffering: no\r\n"
            ."Connection: keep-alive\r\n\r\n";
        push @clients, $cn;
        _queue($cn, _frame(state => _master_state()));
        _queue($cn, _frame(history => _history_data($active)));
        _queue($cn, _frame(sessions => _sessions_data()));
        _refresh_pods();
        # the models: the list of the last time, or asked for now
        if (defined $models) {
            _queue($cn, _frame(models => _models_out()));
        } else {
            _ask_models();
        }
        return;
    }
    if($p eq '/models' and $m eq 'POST'){
        my $q = _ask_models();
        return _json($cn, 503, {error => "no session to ask"}) unless defined $q;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/model' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $id = ref($d) eq 'HASH' ? $d->{id} : undef;
        return _json($cn, 400, {error => 'a JSON object with the id of the model is wanted'})
            unless defined $id and !ref($id) and $id =~ m/\S/ and length($id) <= 300;
        my $q = _to_active({model => $id});
        return _json($cn, 503, {error => "no session to switch the model of"}) unless defined $q;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/message' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $text = ref($d) eq 'HASH' ? $d->{text} : undef;
        return _json($cn, 400, {error => "a JSON object with text is wanted"})
            unless defined $text and !ref($text) and $text =~ m/\S/;
        return _json($cn, 400, {error => "slash commands come with the next step"})
            if $text =~ m{^\s*/};
        my $q = _to_active({text => $text});
        return _json($cn, 503, {error => "no session to talk to"}) unless defined $q;
        return _json($cn, 429, {error => "too many messages waiting"}) if $q < 0;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/session' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        return _json($cn, 400, {error => 'a JSON object with the name of a session, or "new": true, is wanted'})
            unless ref($d) eq 'HASH';
        my $new = $d->{new} ? 1 : 0;
        my $name = $d->{name};
        return _json($cn, 400, {error => 'a session name is wanted'})
            unless $new or (defined $name and !ref($name) and length($name));
        return _json($cn, 400, {error => 'not a session name'})
            unless $new or ai::valid_session_name($name);
        return _json($cn, 400, {error => ($last_error || 'the session cannot be used')})
            unless _activate($name, new => $new, project => (ref($d->{project}) ? undef : $d->{project}));
        return _json($cn, 200, {session => $active});
    }
    if($p eq '/pod' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my ($op, $project) = ref($d) eq 'HASH' ? ($d->{op}, $d->{project}) : ();
        return _json($cn, 400, {error => 'a JSON object with op (open, close or list) and project is wanted'})
            unless defined $op and $op =~ m/\A(?:open|close|list)\z/;
        return _json($cn, 400, {error => 'a project name is wanted'})
            if $op ne 'list' and (!defined $project or ref($project) or !length($project));
        if ($op eq 'list') { _refresh_pods() } else { _pod_request($op, $project) }
        return _json($cn, 202, {ok => \1});
    }
    if($p eq '/project' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $rel = ref($d) eq 'HASH' ? $d->{name} : undef;
        return _json($cn, 400, {error => 'a JSON object with the name of a project is wanted (empty for the root)'})
            unless defined $rel and !ref($rel);
        return _json($cn, 400, {error => ($last_error || 'the project cannot be used')}) unless _project($rel);
        return _json($cn, 200, {session => $active});
    }
    if($p eq '/voice' and $m eq 'POST'){
        my $type = $h->{'content-type'} // '';
        return _json($cn, 415, {error => "a recording (audio/wav) is wanted"})
            unless $type =~ m{^audio/(?:wav|x-wav|wave)\b}i;
        return _json($cn, 400, {error => "an empty recording"}) unless length $body;
        my $q = _to_active({audio => MIME::Base64::encode_base64($body, '')});
        return _json($cn, 503, {error => "no session to talk to"}) unless defined $q;
        return _json($cn, 429, {error => "too many messages waiting"}) if $q < 0;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/abort' and $m eq 'POST'){
        _send_to($active, {abort => 1}) if defined $active;
        return _json($cn, 200, {ok => \1});
    }
    # take the last n exchanges out of the chat of the active session (a revert in the page)
    if($p eq '/rewind' and $m eq 'POST'){
        my $d = eval { $::JSON->decode($body // '') };
        my $n = ref $d eq 'HASH' ? $d->{n} : undef;
        return _json($cn, 400, {error => "n: the number of exchanges, 1 to 999"})
            unless defined $n and "$n" =~ m/\A[1-9]\d{0,2}\z/;
        return _json($cn, 503, {error => "no session"}) unless defined $active;
        _send_to($active, {rewind => 0 + $n});
        return _json($cn, 202, {ok => \1});
    }
    if($p eq '/state' and $m eq 'GET'){
        return _json($cn, 200, _master_state());
    }
    return _respond($cn, 405, 'text/plain', "method not allowed\n") if $p =~ m{^/(events|message|session|project|pod|voice|abort|state|rewind)$};
    return _respond($cn, 404, 'text/plain', "not found\n");
}

1;
