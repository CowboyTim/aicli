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
our ($active, %worker, %model_of, %pending_rename, %pending_switch, $models, $OUTBOX, $IDLE, $last_error, $BROKER_SOCKET, $BROKER_ASK); # the master, see below

# a project's name in its account's directory: a letter or digit, then letters, digits, '.', '_' or '-'
our $PROJECT_RE = qr/[A-Za-z0-9][A-Za-z0-9._-]{0,62}/;
our $ACCOUNT_RE = qr/[A-Za-z0-9][A-Za-z0-9_]{0,95}/; # an account: a directory of the root (an account ID is a UUID without its dashes, see auth.pl)
# dash, so no dash in it (an account ID is a UUID without its dashes, see auth.pl)

$IDLE = 900;
$last_error = '';
our $MAX_BODY    = 1_000_000; # bytes of a request body
our $MAX_VOICE   = 20_000_000; # bytes of a recording (16 kHz mono WAV: about 2 minutes)
our $MAX_QUEUE   = 20;        # messages waiting at once
our $MAX_PENDING = 1_000_000; # bytes not yet sent to a client before it is dropped

my %STATUS = (
    200 => 'OK', 201 => 'Created', 202 => 'Accepted', 303 => 'See Other', 400 => 'Bad Request',
    401 => 'Unauthorized', 403 => 'Forbidden', 404 => 'Not Found',
    405 => 'Method Not Allowed', 413 => 'Payload Too Large', 415 => 'Unsupported Media Type',
    429 => 'Too Many Requests', 500 => 'Internal Server Error', 502 => 'Bad Gateway',
    409 => 'Conflict', 503 => 'Service Unavailable',
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
    log::notice("web interface listening on $bind port $port");
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

# --- the broker (broker.pl): the agents of the users (remote_hub.pm) ---
# The master asks the broker over its socket, in a child of the loop (the request waits for
# the broker's answer: the loop must not). The answer comes to a callback.

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
# the tool calls of a session and the seconds they took, from its usage file (see ai::tool_stat)
sub _tool_totals {
    my ($name) = @_;
    my ($calls, $secs) = (0, 0);
    if (length($name // '') and open(my $fh, '<:raw', "$ai::SESSIONS_DIR/$name/usage")) {
        local $/;
        my $u = eval {JSON::XS::decode_json(scalar <$fh>)};
        close($fh);
        for my $t (ref($u) eq 'HASH' && ref($u->{tools}) eq 'HASH' ? values %{$u->{tools}} : ()) {
            $calls += $t->{calls} // 0;
            $secs  += $t->{seconds} // 0;
        }
    }
    return {tools => $calls, seconds => $secs + 0};
}

sub _master_state {
    my ($acct) = @_;
    # another account's session is not named to this one
    if (!_visible($acct, _active_rel())) {
        return {session => '', project => '', model => '', busy => \0, queued => 0, voice => $voice // 'unknown'};
    }
    my $name = $active // '';
    my $w = $worker{$name};
    return {
        session => $name,
        project => (length($name) ? (ai::session_project($name) // '') : ''), # account/project, for the page's line
        model   => $model_of{$name} // '',
        tools   => _tool_totals($name), # the session's tool calls and their time (the page's header)
        busy    => ($w && $w->{busy}) ? \1 : \0,
        queued  => $w ? $w->{pending} : 0,
        voice   => $voice // 'unknown',
        # a rename the model asked for, done when its answer is over (the page shows it at a refresh)
        (defined $pending_rename{$name} ? (rename => $pending_rename{$name}) : ()),
        (defined $pending_switch{$name} ? (switch => $pending_switch{$name}) : ()),
    };
}

sub _busy_list {
    my ($acct) = @_;
    return [sort grep {$worker{$_}{busy} and _visible($acct, ai::session_project($_))} keys %worker];
}

sub _models_out {
    return {current => $model_of{$active // ''} // '', list => $models // []};
}

# the sessions to choose from: the list, the active one, the busy ones
sub _sessions_data {
    my ($acct) = @_;
    my $seen = _visible($acct, _active_rel());
    return {
        current  => $seen ? ($active // '') : '',
        list     => [grep {_visible($acct, $_->{project})} @{ai::session_choices()}],
        busy     => _busy_list($acct),
        project  => ($seen && defined $active) ? ai::session_project($active) : '',
        # the root first, for the local operator only
        projects => [(defined $acct ? () : ('')), grep {_visible($acct, $_)} @{ai::project_dirs()}],
    };
}

# the conversation of a session as the page shows it: what the user typed and what
# the model answered (not tool calls, results or summaries), the last $HISTORY_MAX
our $HISTORY_MAX = 200;
our $HISTORY_BYTES = 400 * 1024; # what the history may take in the page's stream
our $ITEM_TEXT_MAX = 65536;      # characters of one text of the history (the chat keeps the rest)
our $EVENT_MAX = 500_000;        # bytes of an event sent to the page before its long texts are cut
our $EVENT_TEXT_MAX = 200_000;   # characters kept of such a text

# a text of the history that is too long for the page is cut
sub _clip_history_item {
    my ($item) = @_;
    for my $key (qw(text result full)) {
        next unless defined $item->{$key} and length($item->{$key}) > $ITEM_TEXT_MAX;
        $item->{$key} = substr($item->{$key}, 0, $ITEM_TEXT_MAX)."\n(cut: the chat has the rest)";
    }
    return;
}

sub _history_data {
    my ($name) = @_;
    my $dir = "$ai::SESSIONS_DIR/".($name // '');
    my $file = "$dir/chat";
    my @all = (defined $name and -f $file) ? eval {ai::load_messages($file)} : ();
    my %meta = (defined $name and @all) ? ai::meta_of($dir, \@all) : ();
    my $root = defined $name ? _project_dir($name) : undef; # the workspace of the session: its files
    # the results of the server's tool calls, by the call's id: the tool messages that follow the answer
    # that made the calls. An id may come again in a later answer, so the results are kept per answer.
    my %result_of;   # the index of an answer => {id => content}
    my $scope;
    for my $i (0 .. $#all) {
        my $m = $all[$i];
        if (($m->{role} // '') eq 'assistant') { $scope = $result_of{$i} = {}; next }
        next unless ($m->{role} // '') eq 'tool' and defined $m->{tool_call_id} and $scope;
        $scope->{$m->{tool_call_id}} = $m->{content} // '';
    }
    # what the page shows, in order: what the user said, the answers, and the tool calls with
    # their results (drawn as the live page draws them: a tool line, then its result)
    my @items;
    for my $i (0 .. $#all) {
        my $m = $all[$i];
        if (ai::is_user_input($m)) {
            push @items, {role => 'user', text => $m->{content}};
            next;
        }
        next unless ($m->{role} // '') eq 'assistant';
        if (length($m->{content} // '')) {
            my $out = {role => 'assistant', text => $m->{content}};
            if ($meta{$i}) {
                $out->{thinking} = $meta{$i}{thinking} if length $meta{$i}{thinking};
                $out->{usage} = $meta{$i}{usage} if length $meta{$i}{usage};
            }
            push @items, $out;
        }
        for my $tc (@{$m->{tool_calls} // []}) {
            push @items, _tool_item($tc, ($result_of{$i} // {})->{$tc->{id} // ''}, $root);
        }
    }
    # the newest exchanges that fit in HISTORY_BYTES (the stream closes a client that is sent more than
    # 1 MB unread, see _queue): the older ones are not shown, as after HISTORY_MAX
    my ($used, $from) = (0, scalar @items);
    for (my $k = $#items; $k >= 0; $k--) {
        last if $#items - $k >= $HISTORY_MAX;
        _clip_history_item($items[$k]);
        my $n = length($::JSON->encode($items[$k]));
        last if $used + $n > $HISTORY_BYTES and $from < @items;
        ($used, $from) = ($used + $n, $k);
    }
    my $more = $from > 0 ? 1 : 0;
    splice(@items, 0, $from) if $more;
    return {
        session  => $name // '',
        more     => $more ? \1 : \0,
        messages => \@items,
    };
}

# a tool call of the chat as the page shows it: its line (the name and the first line of its
# arguments, as the live line), and its result (clipped as the live one is), when there is one.
# A call that wrote a file (not an error) has the file in its `files`, as the live page shows it.
sub _tool_item {
    my ($tc, $result, $root) = @_;
    my $fn = $tc->{function} // {};
    my $c = eval { ai::native_call({id => $tc->{id}, name => $fn->{name} // '', arguments => $fn->{arguments}}) } // {};
    my $line = ai::web_text("\x{e2}\x{97}\x{8f} ".($c->{k} // $fn->{name} // '?')." ".(eval { ai::tool_summary($c) } // ''));
    my $item = {role => 'tool', text => $line};
    my $full = eval { ai::call_full($c) } // '';
    $item->{full} = ai::web_text($full) if length $full; # the whole call, when the page opens the line
    if (defined $result) {
        my $max = $::ORIG_ENV{AI_TOOL_LINES} // 8;
        $item->{result} = ai::web_text(ai::clip_lines(ai::to_bytes(tools::without_result_files($result)), $max, "  "));
        if (defined $root and $result !~ m/\A\[ERROR\]/) {
            my $k = $c->{k} // '';
            my @files = ($k eq 'bash') ? tools::result_files($result) : do {
                my $f = eval { tools::offered_file($k, $c->{args}, $root, $result) };
                defined $f ? ($f) : ();
            };
            my @there = grep {-f "$root/$_"} @files;
            $item->{files} = [map {+{path => $_, v => tools::file_version($root, $_)}} @there] if @there;
        }
    }
    return $item;
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
    return (defined $dir and -d $dir) ? $dir : $ai::ROOT;
}

# A login's page starts in its own work: when the active session is not the account's (the last
# login's, or none), the account's newest session becomes the active one, or a new session is made in
# its first project. With no project of its own the page stays empty: its project menu makes one.
# The local operator (no account) keeps what it had.
sub _home {
    my ($acct) = @_;
    return unless defined $acct;
    return if defined $active and _owns($acct, _active_rel());
    my ($newest) = grep {_owns($acct, $_->{project})} @{ai::session_choices()};
    return _activate($newest->{name}) if $newest;
    my ($first) = grep {_owns($acct, $_)} @{ai::project_dirs()};
    return _project($first) if defined $first;
    return;
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
    if ($type eq 'create') {
        # the model's new session in its project: made now (the name is the worker's)
        _create_session($name, $data->{name} // '');
        return;
    }
    if ($type eq 'switch') {
        # the model's switch of the page to another session of its project, done when the turn is over
        my $to = $data->{to} // '';
        $pending_switch{$name} = $to if length $to;
        publish(state => _master_state()) if $is_active;
        return;
    }
    if ($type eq 'rename') {
        # the model's rename: kept until the session's turn is over (see _apply_rename)
        my $to = $data->{to} // '';
        $pending_rename{$name} = $to if length $to;
        publish(state => _master_state()) if $is_active;
        return;
    }
    if ($type eq 'file') {
        # a file a tool wrote: the page offers it (a download, a picture or a sound inline), by its session
        publish(file => {path => $data->{path} // '', session => $name,
                (length($data->{v} // '') ? (v => $data->{v}) : ())})
            if $is_active and length($data->{path} // '');
        return;
    }
    if ($type eq 'turn') {
        my $start = ($data->{state} // '') eq 'start';
        $w->{busy} = $start ? 1 : 0;
        $w->{pending}-- if $start and $w->{pending} > 0;
        publish_each(busy => sub { {list => _busy_list($_[0])} });
        _apply_pending($name) if !$start and !$w->{pending};
    } elsif ($type eq 'state') {
        $model_of{$name} = $data->{model} // '';
    } elsif ($type eq 'model') {
        $model_of{$name} = $data->{text} // '';
    } elsif ($type eq 'models') {
        $models = $data->{list} // [];
        publish(models => _models_out()) if $is_active;
        return;
    }
    return publish(failed => $data, session => $name) if $type eq 'failed'; # a session's failure: its account
    return unless $is_active;
    return publish(state => _master_state()) if $type eq 'state';
    return publish($type => $data);
}

# a worker is gone: its socket reached the end. A turn that was running ends on the page.
sub _worker_gone {
    my ($name) = @_;
    my $w = delete $worker{$name} or return;
    _apply_pending($name) unless $w->{closing};
    if ($w->{fh}) {
        loop::unwatch($w->{fh});
        close($w->{fh});
    }
    waitpid($w->{pid}, 0) if $w->{pid};
    my $is_active = defined $active && $name eq $active;
    publish(turn => {state => 'end'}) if $w->{busy} and $is_active;
    publish(failed => {text => "the session '$name' stopped"}, session => $name) unless $w->{closing};
    publish_each(busy => sub { {list => _busy_list($_[0])} });
    return;
}

# a session the model asked for: made in the project of the session that asked, with the
# project's files as a new session has them (the name is checked; a taken one is refused)
sub _create_session {
    my ($from, $new) = @_;
    my $rel = ai::session_project($from) // '';
    if (!ai::valid_session_name($new) or -e "$ai::SESSIONS_DIR/$new") {
        log::audit("session $from: making a session '$new' refused (the name is not free)");
        return 0;
    }
    my $dir = ai::project_path($rel);
    $ai::AUTO_SESSION{$new} = 1; # ours: removed at the end when nothing was said
    ai::in_project($dir, sub { ai::init_session($new) });
    ai::spew("$ai::SESSIONS_DIR/$new/cwd", "$dir\n");
    log::audit("session $from: made $new in ".(length($rel) ? $rel : 'the root'));
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return 1;
}

# what the model asked for its session, when the session's turn is over: the page switches to
# the other session if the page is still on this one; then the rename (the page follows it)
sub _apply_pending {
    my ($name) = @_;
    if (defined(my $to = delete $pending_switch{$name})) {
        if (defined $active and $name eq $active) {
            if (_activate($to)) {
                log::audit("session $name: the page switched to $to");
            } else {
                log::audit("session $name: switch to $to refused ($last_error)");
                publish(failed => {text => "the switch to $to did not happen: $last_error"}, session => $name);
            }
        }
    }
    _apply_rename($name);
}

# the model's rename of its session, when the session has no turn and no queued input: the
# session is renamed (the worker is ended first; the page follows). A refusal is a failure
# of the session, shown on the page and kept in the audit lines.
sub _apply_rename {
    my ($name) = @_;
    my $to = delete $pending_rename{$name};
    return unless defined $to;
    my $err = _rename_session($name, $to);
    if (defined $err) {
        log::audit("session $name: rename to $to refused ($err)");
        publish(failed => {text => "the rename to $to did not happen: $err"}, session => $name);
        return;
    }
    log::audit("session $name renamed to $to");
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
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return 1;
}

# a worker that is asked to stop, and the workers still there after a while, killed
# a session is removed with its conversation, its archive and its meta. A busy one is refused
# (the caller says so); an idle worker is stopped first (its socket closes, it ends). When the
# session is the active one, a new session is made, as /session {new: true} does.
sub _delete_session {
    my ($name) = @_;
    my $rel = ai::session_project($name); # the new session of the page stays in this project
    _stop_worker($name) if $worker{$name};
    delete $model_of{$name};
    require File::Path;
    my $err;
    File::Path::remove_tree("$ai::SESSIONS_DIR/$name", {error => \$err});
    return "could not remove the session: ".join('; ', map { (values %$_)[0] } @$err) if @$err;
    if (defined $active and $active eq $name) {
        $active = undef;
        return ($last_error || 'no session could be made') unless _activate(undef, new => 1, project => $rel);
    }
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return undef;
}

# a session gets another name: its idle worker is stopped first (the directory moves under it),
# and the active one is opened under the new name. Returns the new name, or an error text.
# the sessions of a project (their names), from the session directories
sub _project_sessions {
    my ($rel) = @_;
    return [grep {(ai::session_project($_) // '') eq $rel} @{ai::get_sessions()}];
}

# audit line for a project request: who (the account, or the local operator), what, the project,
# and the answer (a refusal with its reason too)
sub _audit_project {
    my ($acct, $action, $name, $code, $err) = @_;
    my $who = defined $acct ? "account $acct" : 'local operator';
    my $what = $name // '-';
    log::audit("project $action $what by $who: ".($code == 200 ? 'ok' : "refused $code".(defined $err ? " ($err)" : '')));
    return $code;
}

# is there a project of this name (a directory of the root, an account's project)?
sub _is_project {
    my ($rel) = @_;
    return defined $rel && defined $ai::ROOT && $rel =~ m{\A$ACCOUNT_RE/$PROJECT_RE\z} && -d "$ai::ROOT/$rel" && !-l "$ai::ROOT/$rel";
}

# another project of an account, for the page to move to when its own project is deleted: the one of
# the newest session, else the first project; undef when the account has no other project
sub _other_project {
    my ($rel, $acct) = @_;
    my ($newest) = grep {$_->{project} ne $rel and _owns($acct, $_->{project})} @{ai::session_choices()};
    return $newest->{project} if $newest;
    my ($first) = grep {$_ ne $rel and _owns($acct, $_)} @{ai::project_dirs()};
    return $first;
}

# delete a project: its sessions go with it and its files. Refused while a session of it is busy,
# and with files or sessions in it only when $force (the page asks first). When the page is on one of
# its sessions, the page moves to another project of the account first (with none, the page has no project until one is made).
# Answers (status, error): 200 and no error when it is gone.
sub _delete_project {
    my ($rel, $force, $acct) = @_;
    my $sessions = _project_sessions($rel);
    for my $s (@$sessions) {
        return (409, "a session of '$rel' is busy: wait for its answer first") if $worker{$s} and $worker{$s}{busy};
    }
    opendir(my $dh, "$ai::ROOT/$rel") or return (500, "cannot read the project: $!");
    my @files = grep {!m/\A\.\.?\z/} readdir($dh);
    closedir($dh);
    if ((@$sessions or @files) and !$force) {
        return (409, "'$rel' has ".scalar(@$sessions)." sessions and ".scalar(@files)." files in it: it is deleted with them when you confirm");
    }
    # the page leaves the project before its sessions go: deleting the page's session would make a
    # new one in the project, which would stay behind when the directory is removed
    if (defined $active and (ai::session_project($active) // '') eq $rel) {
        my $other = _other_project($rel, $acct);
        if (defined $other) {
            _project($other) or return (500, $last_error || "could not switch the page to '$other'");
        } else {
            # the account's last project: the page has none until one is made
            $active = undef;
            publish_each(state => sub { _master_state($_[0]) });
        }
    }
    for my $s (@$sessions) {
        my $err = _delete_session($s);
        return (500, $err) if defined $err;
    }
    require File::Path;
    my $err;
    File::Path::remove_tree("$ai::ROOT/$rel", {error => \$err});
    return (500, "could not remove '$rel': ".join('; ', map { (values %$_)[0] } @$err)) if @$err;
    log::info("project $rel deleted");
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return (200, undef);
}

# rename a project in its account. Its sessions come along: their workers are stopped (a busy one
# refuses the rename), each session's cwd file is pointed at the new directory, and the page
# goes back to its session when that one was in the project. A session's stored system prompt
# keeps the old name: a conversation's start is never rewritten (the prompt cache).
sub _rename_project {
    my ($old, $new) = @_;
    my $sessions = _project_sessions($old);
    for my $s (@$sessions) {
        return (409, "a session of '$old' is busy: wait for its answer first") if $worker{$s} and $worker{$s}{busy};
    }
    return (409, "there is a project '$new' already") if -e "$ai::ROOT/$new";
    my $was_active = (defined $active and grep {$_ eq $active} @$sessions) ? $active : undef;
    for my $s (@$sessions) { _stop_worker($s) }
    if (!rename("$ai::ROOT/$old", "$ai::ROOT/$new")) {
        return (500, "could not rename '$old': $!");
    }
    for my $s (@$sessions) {
        my $file = "$ai::SESSIONS_DIR/$s/cwd";
        if (open(my $fh, '>', $file)) { print {$fh} "$ai::ROOT/$new\n"; close($fh) }
        else { log::error("cannot point session $s at $new: $!") }
    }
    if (defined $was_active) {
        $active = undef;
        _activate($was_active) or return (500, $last_error || "the page could not go back to '$was_active'");
    }
    log::info("project $old renamed to $new");
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return (200, undef);
}

sub _rename_session {
    my ($old, $new) = @_;
    return "there is no such session" unless -d "$ai::SESSIONS_DIR/$old";
    return "the session '$new' exists" if -e "$ai::SESSIONS_DIR/$new";
    _stop_worker($old) if $worker{$old};
    if (!rename("$ai::SESSIONS_DIR/$old", "$ai::SESSIONS_DIR/$new")) {
        return "could not rename the session: $!";
    }
    delete $model_of{$old};
    if (defined $active and $active eq $old) {
        $active = undef;
        return ($last_error || 'the session could not be opened under its new name') unless _activate($new);
    }
    publish_each(sessions => sub { _sessions_data($_[0]) });
    return undef;
}

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

# The account of a request: the login's account ID (nginx sends it, with the gate secret). undef is the
# local operator (the token without nginx, e.g. a local ai.pl --ui): every session and project.
# A login without a usable name is '': it owns nothing.
sub _account {
    my ($h) = @_;
    return undef unless defined $gate and length($gate) and ($h->{'x-aicli-gate'} // '') eq $gate;
    # the account ID nginx sends (a UUID without its dashes, from the login's passwd comment)
    my $a = $h->{'x-aicli-account'} // '';
    return $a =~ m/\A[0-9a-f]{32}\z/ ? $a : '';
}


# the account of a project (account/project): its first part, or undef for the root and others
sub _project_account {
    my ($rel) = @_;
    return undef unless defined $rel and $rel =~ m{\A([^/]+)/};
    return $1;
}

# may an account see a project's events and lists? the local operator may see all; no project
# (nothing is active) is seen by all
sub _visible {
    my ($acct, $rel) = @_;
    return 1 unless defined $acct;
    return 1 unless defined $rel;
    my $owner = _project_account($rel);
    return defined $owner && $owner eq $acct ? 1 : 0;
}

# may an account use a project (make or switch its sessions)? Nothing is used
# for the root or for a project that is not there
sub _owns {
    my ($acct, $rel) = @_;
    return 1 unless defined $acct;
    my $owner = _project_account($rel);
    return defined $owner && $owner eq $acct ? 1 : 0;
}

# the name of the active session for an account: '' when it may not see it
sub _shown_active { my ($acct) = @_; return _visible($acct, _active_rel()) ? $active : undef }

# the project of the active session, or undef when none is active
sub _active_rel { return defined $active ? ai::session_project($active) : undef }

sub publish {
    my ($type, $data, %o) = @_;
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
    # what the event is about: a project (broker answers), a session, else the active session.
    # The models of the provider are for all.
    my $rel;
    if (exists $o{project}) { $rel = $o{project} }
    elsif (exists $o{session}) { $rel = defined $o{session} ? ai::session_project($o{session}) : undef }
    elsif ($type ne 'models') { $rel = _active_rel() }
    my $json = $::JSON->encode($data // {});
    if (length($json) > $EVENT_MAX and ref($data) eq 'HASH') {
        # an event this big would close the clients (see _queue): its long texts are cut
        my %cut = %$data;
        for my $key (grep {defined $cut{$_} and !ref $cut{$_} and length($cut{$_}) > $EVENT_TEXT_MAX} keys %cut) {
            $cut{$key} = substr($cut{$key}, 0, $EVENT_TEXT_MAX)."\n(cut: the chat has the rest)";
        }
        $json = $::JSON->encode(\%cut);
    }
    my $msg = "event: $type\ndata: ".$json."\n\n";
    for my $c (@{[@clients]}) {
        next unless _visible($c->{account}, $rel);
        _queue($c, $msg);
    }
    return;
}

# an event whose data is made for each client (the account's sessions, projects)
sub publish_each {
    my ($type, $make) = @_;
    return unless @clients;
    for my $c (@{[@clients]}) {
        my $d = $make->($c->{account});
        next unless defined $d;
        _queue($c, "event: $type\ndata: ".$::JSON->encode($d)."\n\n");
    }
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
                _voice_retry();
            }
            publish(state => _state());
        },
    );
    return;
}

# the recognizer may start after the agent (flm loads its model first): while it is unreachable,
# the check is made again every VOICE_RETRY seconds, once at a time
our $voice_retry_pending = 0;
our $VOICE_RETRY = 30;
sub _voice_retry {
    return if $voice_retry_pending;
    $voice_retry_pending = 1;
    loop::timer($VOICE_RETRY, sub {
        $voice_retry_pending = 0;
        check_voice() unless $_[0] or $voice eq 'ok';
    });
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
# a file for the project's uploads/ comes to POST /upload, with its own limit: any kind of file
our $MAX_UPLOAD = 50_000_000; # bytes of an uploaded file
my $p_is_upload = sub { my ($m, $path) = @_; return $m eq 'POST' && $path =~ m{^/upload(?:\?|$)} };

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
    my $cap = $p_is_voice->($m, $path) ? $MAX_VOICE : $p_is_upload->($m, $path) ? $MAX_UPLOAD : $MAX_BODY;
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

# A file of a session's project, for the page: a picture or a sound inline (the page shows it), any
# other file as a download. Only what really lies in the project: tools::_resolve gives where a path
# leads, so a link or '..' that leads out of it is refused.
our $MAX_FILE = 100_000_000; # bytes of a file sent to the page
our %FILE_TYPE = (
    png => ['image/png', 1], jpg => ['image/jpeg', 1], jpeg => ['image/jpeg', 1],
    gif => ['image/gif', 1], webp => ['image/webp', 1],
    wav => ['audio/wav', 1], mp3 => ['audio/mpeg', 1], ogg => ['audio/ogg', 1],
    txt => ['text/plain; charset=utf-8', 0], md => ['text/plain; charset=utf-8', 0],
    csv => ['text/csv; charset=utf-8', 0], json => ['application/json', 0], pdf => ['application/pdf', 0],
);

# the query of a request as name => value (the values unescaped, as the bytes they are)
sub _query {
    my ($q) = @_;
    my %a;
    foreach my $kv (split /&/, $q // '') {
        my ($k, $v) = split /=/, $kv, 2;
        next unless defined $k and length $k;
        $v //= '';
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $a{$k} = $v;
    }
    return %a;
}

sub _file {
    my ($cn, $acct, $q) = @_;
    my %a = _query($q);
    my ($name, $rel) = ($a{session} // '', $a{path} // '');
    return _respond($cn, 400, 'text/plain', "a session and the path of a file in its project are wanted\n")
        unless ai::valid_session_name($name) and length($rel) and $rel !~ m{\A/} and $rel !~ m/\x00/;
    return _respond($cn, 404, 'text/plain', "no such session of yours\n")
        unless -d "$ai::SESSIONS_DIR/$name" and _owns($acct, ai::session_project($name));
    my $root = _project_dir($name);
    my $base = eval {tools::_resolve($root)} // '';
    my $real = eval {tools::_resolve("$root/$rel")} // '';
    return _respond($cn, 404, 'text/plain', "no such file in the project\n")
        unless length($base) and length($real) and index($real, "$base/") == 0 and -f $real;
    return _respond($cn, 413, 'text/plain', "the file is bigger than $MAX_FILE bytes\n")
        if -s $real > $MAX_FILE;
    open(my $fh, '<:raw', $real) or return _respond($cn, 404, 'text/plain', "no such file in the project\n");
    local $/;
    my $bytes = <$fh>;
    close($fh);
    my ($leaf) = $real =~ m{([^/]+)\z};
    my ($ext) = $leaf =~ m/\.([A-Za-z0-9]+)\z/;
    my ($type, $inline) = @{$FILE_TYPE{lc($ext // '')} // ['application/octet-stream', 0]};
    (my $file = $leaf) =~ s/[^A-Za-z0-9._-]/_/g;
    my $view = ($inline and !$a{download}) ? 'inline' : 'attachment';
    return _respond($cn, 200, $type, $bytes,
        "Content-Disposition: $view; filename=\"$file\"",
        "Content-Security-Policy: sandbox");
}

# the name of an uploaded file, as it is kept in uploads/: its last part, with the characters of a normal name
# (any extension goes); undef when nothing is left
sub _upload_name {
    my ($n) = @_;
    return undef unless defined $n;
    $n =~ s{\A.*[/\\]}{}s;
    $n =~ s/[^A-Za-z0-9._ -]/_/g;
    $n =~ s/\A[. ]+//;
    $n =~ s/\s+\z//;
    $n = substr($n, 0, 200) if length($n) > 200;
    return length($n) ? $n : undef;
}

sub _dispatch {
    my ($cn, $m, $path, $h, $body) = @_;
    my ($p, $q) = split /\?/, $path, 2;
    $q //= '';
    $cn->{req} = "$m $p";

    # the icon (behind nginx it is served there, public; this is the local interface's copy)
    if($m eq 'GET' and ($p eq '/favicon.ico' or $p eq '/favicon.svg')){
        my $file = File::Basename::dirname($html_file)."/$p";
        open(my $ifh, '<:raw', $file) or return _respond($cn, 404, 'text/plain', "no icon\n");
        local $/;
        my $bytes = <$ifh>;
        close($ifh);
        return _respond($cn, 200, $p =~ /\.svg\z/ ? 'image/svg+xml' : 'image/x-icon', $bytes);
    }
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
    $cn->{account} = _account($h); # the login's account (undef: the local operator)
    my $acct = $cn->{account};

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
        # a login's page starts in its own work, before it is sent the state (see _home)
        _home($acct);
        push @clients, $cn;
        _queue($cn, _frame(state => _master_state($acct)));
        _queue($cn, _frame(history => _history_data($active))) if _visible($acct, _active_rel());
        _queue($cn, _frame(sessions => _sessions_data($acct)));
        # the models: the list of the last time, or asked for now
        if (defined $models) {
            _queue($cn, _frame(models => _models_out()));
        } else {
            _ask_models();
        }
        return;
    }
    if($p eq '/models' and $m eq 'POST'){
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
        my $q = _ask_models();
        return _json($cn, 503, {error => "no session to ask"}) unless defined $q;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/model' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $id = ref($d) eq 'HASH' ? $d->{id} : undef;
        return _json($cn, 400, {error => 'a JSON object with the id of the model is wanted'})
            unless defined $id and !ref($id) and $id =~ m/\S/ and length($id) <= 300;
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
        my $q = _to_active({model => $id});
        return _json($cn, 503, {error => "no session to switch the model of"}) unless defined $q;
        return _json($cn, 202, {queued => $q});
    }
    # a file for the active session's project, kept in its uploads/ (a new name when that one is taken): the
    # page names it in the next message, and the model reads it from the project
    if($p eq '/upload' and $m eq 'POST'){
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'})
            unless _owns($acct, _active_rel());
        return _json($cn, 503, {error => 'no session to put the file in'}) unless defined $active;
        my %a = _query($q);
        my $name = _upload_name($a{name});
        return _json($cn, 400, {error => 'a file name is wanted'}) unless defined $name;
        my $root = _project_dir($active);
        my $dir  = "$root/uploads";
        return _json($cn, 403, {error => 'uploads is a link, not a folder'}) if -l $dir;
        mkdir $dir unless -d $dir;
        my $base = eval {tools::_resolve($root)} // '';
        my $real = eval {tools::_resolve($dir)} // '';
        return _json($cn, 500, {error => 'the project has no uploads folder'})
            unless -d $dir and length($base) and length($real) and index($real, "$base/") == 0;
        my $file = tools::free_name("$dir/$name");
        my $part = "$file.part";
        open(my $fh, '>:raw', $part) or return _json($cn, 500, {error => "cannot write $name: $!"});
        print {$fh} $body;
        close($fh) or return _json($cn, 500, {error => "cannot write $name: $!"});
        rename($part, $file) or return _json($cn, 500, {error => "cannot keep $name: $!"});
        (my $leaf = $file) =~ s{\A.*/}{};
        log::audit("session $active: uploaded uploads/$leaf (".length($body)." bytes)");
        return _json($cn, 201, {path => "uploads/$leaf", session => $active, size => length($body)});
    }
    if($p eq '/message' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $text = ref($d) eq 'HASH' ? $d->{text} : undef;
        return _json($cn, 400, {error => "a JSON object with text is wanted"})
            unless defined $text and !ref($text) and $text =~ m/\S/;
        return _json($cn, 400, {error => "slash commands come with the next step"})
            if $text =~ m{^\s*/};
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
        my $q = _to_active({text => $text});
        return _json($cn, 503, {error => "no session to talk to"}) unless defined $q;
        return _json($cn, 429, {error => "too many messages waiting"}) if $q < 0;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/session/delete' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body // '')};
        my $name = ref($d) eq 'HASH' ? $d->{name} : undef;
        return _json($cn, 400, {error => 'a session name is wanted'})
            unless defined $name and !ref($name) and length($name);
        return _json($cn, 400, {error => 'not a session name'}) unless ai::valid_session_name($name);
        return _json($cn, 404, {error => 'there is no such session'})
            unless -d "$ai::SESSIONS_DIR/$name" and _owns($acct, ai::session_project($name));
        return _json($cn, 409, {error => 'the session is busy: wait for its answer, then delete it'})
            if $worker{$name} and $worker{$name}{busy};
        my $err = _delete_session($name);
        return _json($cn, 500, {error => $err}) if defined $err;
        return _json($cn, 200, {deleted => $name, session => _shown_active($acct) // ''});
    }
    if($p eq '/session/rename' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body // '')};
        my ($old, $new) = ref($d) eq 'HASH' ? ($d->{name}, $d->{to}) : ();
        return _json($cn, 400, {error => 'a session name and a new name are wanted'})
            unless defined $old and !ref($old) and length($old) and defined $new and !ref($new) and length($new);
        return _json($cn, 400, {error => 'not a session name'})
            unless ai::valid_session_name($old) and ai::valid_session_name($new);
        return _json($cn, 404, {error => 'there is no such session'})
            unless -d "$ai::SESSIONS_DIR/$old" and _owns($acct, ai::session_project($old));
        return _json($cn, 409, {error => 'the session is busy: wait for its answer, then rename it'})
            if $worker{$old} and $worker{$old}{busy};
        my $err = _rename_session($old, $new);
        return _json($cn, 409, {error => $err}) if defined $err and $err =~ m/exists/;
        return _json($cn, 500, {error => $err}) if defined $err;
        return _json($cn, 200, {session => _shown_active($acct) // ''});
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
        # a session of another account, or a new one in a project of another: refused
        my $rel = $new ? (ref($d->{project}) ? undef : $d->{project}) : ai::session_project($name // '');
        $rel = _active_rel() if $new and !defined $rel;
        return _json($cn, 403, {error => "there is no session or project of yours by that name"})
            unless _owns($acct, $rel);
        # a new session may be given a name (as a project is): it is made, then named
        my $want = $new && defined $name && !ref($name) && length($name) ? $name : undef;
        return _json($cn, 400, {error => 'not a session name'})
            if defined $want and !ai::valid_session_name($want);
        return _json($cn, 409, {error => "there is a session '$want' already"})
            if defined $want and -e "$ai::SESSIONS_DIR/$want";
        return _json($cn, 400, {error => ($last_error || 'the session cannot be used')})
            unless _activate($name, new => $new, project => (ref($d->{project}) ? undef : $d->{project}));
        if (defined $want) {
            my $err = _rename_session($active, $want);
            return _json($cn, 500, {error => $err}) if defined $err;
        }
        return _json($cn, 200, {session => _shown_active($acct)});
    }
    # the agents of the user (remote_hub.pm, through the broker): the enrollment token (shown
    # once), the list, a revocation. The user is the login's (nginx sends it as X-Aicli-User).
    if($p =~ m{\A/agent/(token|list|revoke)\z} and (($p eq '/agent/token' and $m eq 'POST') or ($p eq '/agent/list' and $m eq 'GET') or ($p eq '/agent/revoke' and $m eq 'POST'))){
        my $user = $acct // '';
        return _json($cn, 403, {ok => \0, error => 'agents need the login (through nginx), and its name is an account name'})
            unless length $user;
        my $req = {user => $user};
        if ($p eq '/agent/token') {
            $req->{op} = 'enroll_token';
        } elsif ($p eq '/agent/list') {
            $req->{op} = 'agents';
        } else {
            my $d = eval {$::JSON->decode($body // '')};
            return _json($cn, 400, {ok => \0, error => 'a JSON object with the name of the agent is wanted'})
                unless ref($d) eq 'HASH' and defined $d->{name} and !ref($d->{name}) and length($d->{name});
            $req->{op} = 'agent_revoke';
            $req->{name} = $d->{name};
        }
        _broker_ask($req, sub {
            my ($r) = @_;
            _json($cn, $r->{ok} ? 200 : 502, $r);
        });
        return;
    }
    # a job on one of the login's agents: a program (no shell: the words of the command) for the
    # project's tags; the broker sends it to an online agent of the account that has the tags, and
    # the answer (exit code, output) comes back here. Only the login's own projects.
    if($p eq '/agent/job' and $m eq 'POST'){
        my $user = $acct // '';
        return _json($cn, 403, {ok => \0, error => 'jobs need the login (through nginx)'}) unless length $user;
        my $d = eval {$::JSON->decode($body // '')};
        return _json($cn, 400, {ok => \0, error => 'a JSON object with project, tags, argv and timeout is wanted'})
            unless ref($d) eq 'HASH';
        return _json($cn, 403, {ok => \0, error => 'that project is not yours'})
            unless defined $d->{project} and !ref($d->{project}) and _owns($acct, $d->{project});
        my $timeout = $d->{timeout} // 60;
        return _json($cn, 400, {ok => \0, error => 'a timeout of 1 to 100 seconds is wanted'})
            unless "$timeout" =~ m/\A\d+\z/ and $timeout >= 1 and $timeout <= 100;
        _broker_ask({op => 'exec', project => $d->{project}, tags => $d->{tags}, argv => $d->{argv}, timeout => $timeout + 0}, sub {
            my ($r) = @_;
            if ($r->{ok} and defined $r->{output}) {
                $r->{output} = ai::to_text(MIME::Base64::decode_base64($r->{output}));
            }
            _json($cn, $r->{ok} ? 200 : 502, $r);
        });
        return;
    }
    # a new project: a directory of the login's account (the local operator names it
    # account/project), made here and switched to, so its session is the page's
    if($p eq '/project/new' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body // '')};
        my $name = ref($d) eq 'HASH' ? $d->{name} : undef;
        return _json($cn, 400, {error => 'a JSON object with the name of the project is wanted'})
            unless defined $name and !ref($name) and length($name);
        my $rel;
        if (!defined $acct) {
            # the local operator: account/project
            ($rel) = $name =~ m{\A($ACCOUNT_RE/$PROJECT_RE)\z};
            return _json($cn, 400, {error => 'the name is account/project (both letters, digits, "." "_" or "-")'})
                unless defined $rel;
        } else {
            return _json($cn, 403, {error => 'the login has no account name: no projects for it'})
                unless length $acct;
            return _json($cn, 400, {error => 'a project name is letters, digits, "." "_" or "-" (it starts with a letter or digit)'})
                unless $name =~ m/\A$PROJECT_RE\z/;
            $rel = "$acct/$name";
        }
        return _json($cn, 503, {error => 'no root for the projects'}) unless defined $ai::ROOT and -d $ai::ROOT;
        if (-e "$ai::ROOT/$rel") {
            _audit_project($acct, 'create', $rel, 409, 'exists');
            return _json($cn, 409, {error => "there is a project '$rel' already"});
        }
        my ($account) = $rel =~ m{\A([^/]+)/};
        if (!-d "$ai::ROOT/$account" and !mkdir("$ai::ROOT/$account")) {
            return _json($cn, 500, {error => "cannot make the account's directory: $!"});
        }
        if (!mkdir("$ai::ROOT/$rel")) {
            return _json($cn, 500, {error => "cannot make the project: $!"});
        }
        _audit_project($acct, 'create', $rel, 200);
        _project($rel); # the page switches to it: a session of its own (or the newest one)
        return _json($cn, 200, {project => $rel, session => _shown_active($acct) // ''});
    }
    if($p eq '/project/delete' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body // '')};
        my $rel = ref($d) eq 'HASH' ? $d->{name} : undef;
        return _json($cn, 400, {error => 'a project name is wanted'}) unless defined $rel and !ref($rel) and length $rel;
        unless (_owns($acct, $rel) and _is_project($rel)) {
            _audit_project($acct, 'delete', $rel, 404, 'no such project of this login');
            return _json($cn, 404, {error => 'there is no such project of yours'});
        }
        my $force = ref($d) eq 'HASH' && $d->{force} ? 1 : 0;
        my ($code, $err) = _delete_project($rel, $force, $acct);
        _audit_project($acct, $force ? 'delete (forced)' : 'delete', $rel, $code, $err);
        return _json($cn, $code, $code == 200 ? {deleted => $rel} : {error => $err});
    }
    if($p eq '/project/rename' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body // '')};
        my ($old, $to) = ref($d) eq 'HASH' ? ($d->{name}, $d->{to}) : ();
        return _json($cn, 400, {error => 'a project name and the new name are wanted'})
            unless defined $old and !ref($old) and length $old and defined $to and !ref($to) and length $to;
        unless (_owns($acct, $old) and _is_project($old)) {
            _audit_project($acct, 'rename', $old, 404, 'no such project of this login');
            return _json($cn, 404, {error => 'there is no such project of yours'});
        }
        my ($account) = $old =~ m{\A([^/]+)/};
        my $new;
        if (!defined $acct) {
            # the local operator: account/project, or a bare name kept in the project's account
            ($new) = $to =~ m{\A($ACCOUNT_RE/$PROJECT_RE)\z};
            ($new) = "$account/$to" =~ m{\A($ACCOUNT_RE/$PROJECT_RE)\z} unless defined $new;
            return _json($cn, 400, {error => 'the new name is a project name (or account/project)'}) unless defined $new;
        } else {
            return _json($cn, 400, {error => 'a project name is letters, digits, "." "_" or "-"'})
                unless $to =~ m/\A$PROJECT_RE\z/;
            $new = "$account/$to";
        }
        return _json($cn, 400, {error => 'a project keeps its account'})
            unless $new =~ m{\A\Q$account\E/};
        my ($code, $err) = _rename_project($old, $new);
        _audit_project($acct, "rename to $new", $old, $code, $err);
        return _json($cn, $code, $code == 200 ? {project => $new} : {error => $err});
    }
    if($p eq '/project' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $rel = ref($d) eq 'HASH' ? $d->{name} : undef;
        return _json($cn, 400, {error => 'a JSON object with the name of a project is wanted (empty for the root)'})
            unless defined $rel and !ref($rel);
        return _json($cn, 403, {error => "there is no project '$rel' of yours"}) unless _owns($acct, $rel);
        return _json($cn, 400, {error => ($last_error || 'the project cannot be used')}) unless _project($rel);
        return _json($cn, 200, {session => _shown_active($acct)});
    }
    if($p eq '/voice' and $m eq 'POST'){
        my $type = $h->{'content-type'} // '';
        return _json($cn, 415, {error => "a recording (audio/wav) is wanted"})
            unless $type =~ m{^audio/(?:wav|x-wav|wave)\b}i;
        return _json($cn, 400, {error => "an empty recording"}) unless length $body;
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
        my $q = _to_active({audio => MIME::Base64::encode_base64($body, '')});
        return _json($cn, 503, {error => "no session to talk to"}) unless defined $q;
        return _json($cn, 429, {error => "too many messages waiting"}) if $q < 0;
        return _json($cn, 202, {queued => $q});
    }
    if($p eq '/abort' and $m eq 'POST'){
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
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
        return _json($cn, 403, {error => 'the session of the page belongs to another account, or there is none'}) unless _owns($acct, _active_rel());
        _send_to($active, {rewind => 0 + $n});
        return _json($cn, 202, {ok => \1});
    }
    if($p eq '/state' and $m eq 'GET'){
        return _json($cn, 200, _master_state($acct));
    }
    if($p eq '/file' and $m eq 'GET'){
        return _file($cn, $acct, $q);
    }
    return _respond($cn, 405, 'text/plain', "method not allowed\n") if $p =~ m{^/(events|message|session|session/delete|session/rename|project|voice|abort|state|rewind|file)$};
    return _respond($cn, 404, 'text/plain', "not found\n");
}

1;
