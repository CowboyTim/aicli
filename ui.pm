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

our ($listen, $token, $port, $bind, $html_file);
our %conn;      # fileno => connection
our @clients;   # connections that read the event stream
our @queue;     # messages waiting for chat_loop
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
    # an IPv6 address is in brackets in a URL; "::" is any IPv6 address
    $listen = IO::Socket::IP->new(
        LocalHost => $bind, LocalPort => ($o{port} // 8080), Listen => 16,
        ReuseAddr => 1, Proto => 'tcp',
    ) or die "ui: cannot listen on $bind:".($o{port} // 8080).": $!\n";
    $listen->blocking(0);
    $port = $listen->sockport;
    $html_file = File::Basename::dirname(__FILE__)."/ai/ui/index.html";
    loop::watch($listen, \&_accept);
    loop::timer(15, \&_ping);
    $ai::EVENT_SINK = \&publish;
    $log::on_error = sub { publish(failed => {text => ai::web_text($_[0])}) };
    # "any" addresses (0.0.0.0, ::) are not a place to open: the loopback is
    my $shown = ($bind eq '0.0.0.0' or $bind eq '::') ? 'localhost' : $bind;
    my $host = $shown =~ m/:/ ? "[$shown]" : $shown;
    print STDERR "aicli web interface: http://$host:$port/?token=$token\n";
    # the phone: an address of this machine it can reach, and a QR code for it
    my $phone = $bind eq '0.0.0.0' ? (_lan_address(4) // '127.0.0.1')
              : $bind eq '::'      ? (_lan_address(6) // '::1') # no global IPv6: the loopback
              : $bind;
    my $phone_host = $phone =~ m/:/ ? "[$phone]" : $phone;
    my $phone_url = "http://$phone_host:$port/?token=$token";
    print STDERR "aicli web interface on the phone: $phone_url\n" if $phone ne $shown;
    _qr($phone_url);
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
    $ai::EVENT_SINK = undef;
    $log::on_error = undef;
    return;
}

# The next message for chat_loop: waits in the loop until one is queued or the
# chat ends. A "/" line is refused for now, commands come with the next step.
# The next input for chat_loop: a text message as it is, a recording first
# written down and recognized (here, in the main flow: the recognizer is waited
# for, a request must not wait). The text goes to the chat as soon as it is ready.
sub input {
    return sub {
        while(1){
            loop::run(sub { @queue or !$::LOOP });
            return unless $::LOOP;
            my $item = shift @queue;
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
    return $text;
}

sub queued { return scalar @queue }

# --- the event stream -------------------------------------------------------

# Send one event to all clients that read the stream.
sub publish {
    my ($type, $data) = @_;
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
        model   => $ai::SESSION_MODEL // '',
        busy    => $ai::BUSY ? \1 : \0,
        queued  => scalar(@queue),
    };
}

# --- sockets ----------------------------------------------------------------

sub _accept {
    while(my $fh = $listen->accept){
        $fh->blocking(0);
        my $cn = {fh => $fh, in => '', out => ''};
        $conn{fileno($fh)} = $cn;
        loop::watch($fh, sub { _read($cn) });
    }
    return;
}

sub _read {
    my ($cn) = @_;
    return if $cn->{closed};
    my $n = sysread($cn->{fh}, my $buf, 65536);
    if(!defined $n){
        return if $!{EAGAIN} or $!{EWOULDBLOCK} or $!{EINTR};
        return _close($cn);
    }
    return _close($cn) if $n == 0;
    return if $cn->{streaming} or $cn->{handled}; # nothing more is read from them
    _feed($cn, $buf);
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
        my $n = syswrite($cn->{fh}, $cn->{out}, 65536);
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
    my $fh = $cn->{fh};
    loop::unwatch($fh);
    delete $conn{fileno($fh)};
    @clients = grep {$_ != $cn} @clients;
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

    if($p eq '/' and $m eq 'GET'){
        my ($given) = $q =~ m/(?:^|&)token=([0-9a-f]+)/;
        if(defined $given and $given eq $token){
            return _respond($cn, 303, 'text/plain', "see /\n", "Location: /",
                "Set-Cookie: aicli_token=$token; Path=/; HttpOnly; SameSite=Strict");
        }
        return _respond($cn, 401, 'text/plain', "open the address aicli printed at start (it has the token)\n")
            unless _authed($h);
        open(my $fh, '<:raw', $html_file) or return _respond($cn, 500, 'text/plain', "no page\n");
        local $/;
        my $html = <$fh>;
        close($fh);
        return _respond($cn, 200, 'text/html; charset=utf-8', $html);
    }

    return _respond($cn, 401, 'text/plain', "not signed in\n") unless _authed($h);

    # a page of another site may not post here (the cookie would go with it)
    if($m eq 'POST' and defined $h->{origin}){
        return _respond($cn, 403, 'text/plain', "wrong origin\n")
            unless $h->{origin} eq "http://".($h->{host} // '');
    }

    if($p eq '/events' and $m eq 'GET'){
        $cn->{streaming} = 1;
        $cn->{handled} = 1;
        $cn->{out} .= "HTTP/1.1 200 OK\r\n"
            ."Content-Type: text/event-stream; charset=utf-8\r\n"
            ."Cache-Control: no-cache\r\n"
            ."X-Accel-Buffering: no\r\n"
            ."Connection: keep-alive\r\n\r\n";
        push @clients, $cn;
        _queue($cn, "event: state\ndata: ".$::JSON->encode(_state())."\n\n");
        return;
    }
    if($p eq '/message' and $m eq 'POST'){
        my $d = eval {$::JSON->decode($body)};
        my $text = ref($d) eq 'HASH' ? $d->{text} : undef;
        return _json($cn, 400, {error => "a JSON object with text is wanted"})
            unless defined $text and !ref($text) and $text =~ m/\S/;
        return _json($cn, 400, {error => "slash commands come with the next step"})
            if $text =~ m{^\s*/};
        return _json($cn, 429, {error => "too many messages waiting"})
            if @queue >= $MAX_QUEUE;
        push @queue, $text;
        return _json($cn, 202, {queued => scalar @queue});
    }
    if($p eq '/voice' and $m eq 'POST'){
        my $type = $h->{'content-type'} // '';
        return _json($cn, 415, {error => "a recording (audio/wav) is wanted"})
            unless $type =~ m{^audio/(?:wav|x-wav|wave)\b}i;
        return _json($cn, 400, {error => "an empty recording"}) unless length $body;
        return _json($cn, 429, {error => "too many messages waiting"})
            if @queue >= $MAX_QUEUE;
        push @queue, {audio => $body};
        return _json($cn, 202, {queued => scalar @queue});
    }
    if($p eq '/abort' and $m eq 'POST'){
        $::ABORT = 1 if $ai::BUSY;
        return _json($cn, 200, {ok => \1});
    }
    if($p eq '/state' and $m eq 'GET'){
        return _json($cn, 200, _state());
    }
    return _respond($cn, 405, 'text/plain', "method not allowed\n") if $p =~ m{^/(events|message|voice|abort|state)$};
    return _respond($cn, 404, 'text/plain', "not found\n");
}

1;
