package worker;
# A session worker: one chat, in a process of its own, served over a socket by
# the master (the web interface, ui.pm). The master forks it and keeps one socket
# per worker. The worker runs the same chat loop as the web interface: its input
# comes from the socket instead of the HTTP routes, its events go back over it.
#
# The socket carries one JSON object per line:
#   master -> worker: {"text": "..."}, {"audio": "base64 WAV"}, {"model": "provider/id"},
#                     {"models": 1}, {"state": 1}, {"abort": 1}
#   worker -> master: {"event": "text", "data": {"text": "..."}}, ...
# The events are the ones of the web page (ui::publish). The worker ends when
# the master closes the socket: after its turn, or at once when a turn runs.

use strict; use warnings;

use utils;
use ai;
use ui;

our ($sock, $inbuf);

# Serve one session on $fd (a connected socket); returns when the chat ends.
sub serve {
    my ($fh, %o) = @_;
    $sock = $fh;
    $inbuf = '';
    $sock->autoflush(1);
    local $SIG{PIPE} = 'IGNORE'; # a master that went away is an EOF, not a signal
    $::UI = 1; # the web page's chat: the web prompt context, no status line, no terminal
    ai::use_session($o{session}) if defined $o{session};
    # ctrl-C stops the turn that runs; the worker goes on (the master ends it)
    $SIG{INT}  = sub { $::ABORT = 1 if $ai::BUSY };
    $SIG{TERM} = sub { $::ABORT = 1 if $ai::BUSY };
    $ui::RELAY = \&_relay;
    $ai::EVENT_SINK = \&ui::publish;
    $log::on_error = sub { ui::publish(failed => {text => ai::web_text($_[0])}) };
    loop::watch($sock, \&_readable);
    _relay(state => ui::_state());
    ai::chat_loop();
    ai::cleanup_chat();
    loop::unwatch($sock);
    return 0;
}

sub _relay {
    my ($type, $data) = @_;
    print {$sock} $::JSON->encode({event => $type, data => $data})."\n";
    return;
}

sub _readable {
    my $n = sysread($sock, my $buf, 65536);
    if (!$n) {
        # the master closed the socket: no more input, and a running turn stops
        loop::unwatch($sock);
        $::ABORT = 1 if $ai::BUSY;
        $::LOOP = 0;
        return;
    }
    $inbuf .= $buf;
    while ($inbuf =~ s/^([^\n]*)\n//) {
        my $m = eval {$::JSON->decode($1)};
        _message($m) if ref($m) eq 'HASH';
    }
    return;
}

sub _message {
    my ($m) = @_;
    if (exists $m->{text}) {
        my $text = $m->{text};
        return unless defined $text and !ref $text and $text =~ m/\S/;
        if ($text =~ m{^\s*/}) {
            ui::publish(failed => {text => "slash commands come with the next step"});
            return;
        }
        push @ui::queue, $text;
    } elsif (exists $m->{model}) {
        push @ui::queue, {model => $m->{model}};
    } elsif ($m->{models}) {
        push @ui::queue, {models => 1};
    } elsif (exists $m->{audio}) {
        require MIME::Base64;
        push @ui::queue, {audio => MIME::Base64::decode_base64($m->{audio})};
    } elsif ($m->{state}) {
        ui::publish(state => ui::_state());
    } elsif ($m->{abort}) {
        $::ABORT = 1 if $ai::BUSY;
    }
    return;
}

1;
