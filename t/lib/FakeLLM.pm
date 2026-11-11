package FakeLLM;
# A tiny OpenAI compatible server in a forked child, for end-to-end tests.
# What it answers depends on the last message of the conversation:
#   "fail..."          HTTP 429 with a JSON error
#   "slow..."          starts to think, then hangs
#   a tool result      the final answer, quoting the result
#   anything else      thinks, then calls the bash tool

use strict; use warnings;

use IO::Socket::INET ();
use JSON::XS ();
use POSIX ();
use Time::HiRes ();

my $pid;

sub start {
    my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        or die "cannot listen: $!\n";
    my $port = $srv->sockport();
    $pid = fork() // die "fork: $!\n";
    if(!$pid){
        POSIX::setsid();
        $SIG{PIPE} = 'IGNORE';
        # a connection may hang ("slow"): one child per connection
        $SIG{CHLD} = 'IGNORE';
        while(my $c = $srv->accept()){
            my $kid = fork();
            if(defined $kid and !$kid){
                close($srv);
                eval {serve($c)};
                close($c);
                POSIX::_exit(0);
            }
            close($c);
        }
        POSIX::_exit(0);
    }
    close($srv);
    return "http://127.0.0.1:$port";
}

sub stop {
    return unless $pid;
    kill('TERM', -$pid, $pid);
    waitpid($pid, 0);
    $pid = undef;
    return;
}

sub sse {
    my ($delta) = @_;
    return "data: ".JSON::XS::encode_json({choices => [{delta => $delta}]})."\n\n";
}

sub serve {
    my ($c) = @_;
    $c->autoflush(1);
    my ($request, %h) = (scalar <$c>);
    while(defined(my $l = <$c>)){
        $l =~ s/\r?\n\z//;
        last unless length($l);
        my ($k, $v) = split m/:\s*/, $l, 2;
        $h{lc $k} = $v;
    }
    my $body = '';
    read($c, $body, $h{'content-length'}) if $h{'content-length'};
    my ($method, $path) = split m/ /, $request // '';

    if($method eq 'GET' and $path eq '/v1/models'){
        return reply($c, 200, 'application/json', '{"object":"list","data":[{"id":"fake-1"},{"id":"fake-2"}]}');
    }
    if($method ne 'POST' or $path ne '/v1/chat/completions'){
        return reply($c, 404, 'application/json', '{"error":{"message":"no such endpoint '.$path.'"}}');
    }
    my $req  = JSON::XS::decode_json($body);
    my $msgs = $req->{messages};
    my $last = $msgs->[-1]{content};
    if($last =~ m/^fail/){
        return reply($c, 429, 'application/json', '{"error":{"code":429,"message":"rate limit of the fake"}}');
    }
    print {$c} "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
    my @events;
    if($last =~ m/^slow/){
        print {$c} sse({reasoning_content => "let me think for a long time"});
        sleep 60;
        return;
    } elsif($last =~ m/RESULT_d170\n(.*?)\n/s){
        @events = map {sse({content => $_})} "The tool said: $1", " (messages: ".scalar(@$msgs),
            ", model: ".($req->{model} // 'none'), ", auth: ".($h{authorization} // 'none').")";
    } else {
        my $call = "I will run it.\n///BASH_7c48+EO_dfd7\necho e2e-\$((6*7))\nEO_dfd7\nBASH_7c48\n";
        @events = ((map {sse({reasoning_content => $_})} "The user wants ", "a command."),
            map {sse({content => $_})} unpack("(a11)*", $call));
    }
    # send it in pieces that don't respect the event boundaries
    foreach my $piece (unpack("(a37)*", join('', @events, "data: [DONE]\n\n"))){
        print {$c} $piece;
        Time::HiRes::sleep(0.005);
    }
    return;
}

sub reply {
    my ($c, $code, $type, $body) = @_;
    print {$c} "HTTP/1.1 $code X\r\nContent-Type: $type\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n$body";
    return;
}

END {
    stop();
}

1;
