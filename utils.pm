package utils;

use strict; use warnings;

use Time::HiRes ();

sub load_cpan {
    my ($module) = @_;
    eval "require $module";
    die $@ if $@;
    return $module;
}

sub trim {
    my ($s) = @_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

our $response = \(my $buffer = "");
our ($http_error, $http_code, %http_headers);

# One HTTP request, waited for: returns the body, or undef on any error (see
# $http_error, $http_code, %http_headers). With $read_handle_sub the body is
# streamed to it. The request runs in the event loop (package loop), so
# everything else that is in there keeps going.
sub http {
    my ($m, $full_url, $data, $api_key, $read_handle_sub) = @_;
    $data //= "";
    log::info("RSUB: ".((defined $read_handle_sub and ref($read_handle_sub) eq 'CODE')?1:0));
    log::info("URL: $full_url");
    log::info("DATA: $data");
    $$response = "";
    $http_error = undef;
    $http_code  = 0;
    %http_headers = ();
    my $done = 0;
    my $req = loop::http(
        method  => $m,
        url     => $full_url,
        data    => $data,
        api_key => $api_key,
        on_data => $read_handle_sub,
        on_done => sub {$done = 1},
    );
    loop::run(sub {$done});
    $http_code    = $req->{code};
    %http_headers = %{$req->{headers}};
    if(defined $req->{error}){
        $http_error = $req->{error};
        log::info("HTTP ERROR: $http_error");
        return;
    }
    log::info("OK: $http_code");
    $$response = $req->{body};
    log::info("RESPONSE:\n$$response");
    return $$response;
}

# true when the user asked to stop the current turn (ctrl-C while busy)
sub aborted {
    return $::ABORT ? 1 : 0;
}

# Sleep, the async way: the event loop keeps running and notices an abort.
# Returns false when aborted.
sub wait_abortable {
    my ($seconds) = @_;
    my $done = 0;
    loop::timer($seconds // 0, sub {$done = 1});
    loop::run(sub {$done});
    return aborted() ? 0 : 1;
}

package curl;

use strict; use warnings;

BEGIN {
    die $@ if $@;
    eval {
        utils::load_cpan("Net::Curl");
    };
    eval {
        utils::load_cpan("Net::Curl::Easy");
        *AUTOLOAD = *Net::Curl::Easy::AUTOLOAD;
        utils::load_cpan("Net::Curl::Multi");
    };
    eval {
        utils::load_cpan("WWW::Curl::Easy");
        *AUTOLOAD = *WWW::Curl::Easy::AUTOLOAD;
        utils::load_cpan("WWW::Curl::Multi");
    };
    our @ISA = qw(Net::Curl::Easy WWW::Curl::Easy);
    foreach my $k (keys %Net::Curl::Easy::){
        next unless $k =~ /^CURL/; # Only grab curl constants/options
        no strict 'refs';
        *{"${k}"} = \&{"Net::Curl::Easy::${k}"};
    }
}


package log;

use strict; use warnings;

sub info {
    my ($message) = @_;
    return unless $::DEBUG;
    my $LOG_FILE = $::ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "INFO: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}

sub error {
    my ($message) = @_;
    my $LOG_FILE = $::ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "ERROR: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}

package utils;

use POSIX ();
use IO::Handle ();
use Time::HiRes ();

# hooks run in every forked tool process before the worker (e.g. drop secrets)
our @CHILD_INIT;

# Environment handed to tool processes: an allow-list, never the AI_* settings
# (API key!). AI_TOOL_ENV can name extra variables to pass through.
sub tool_env {
    my %src = (%ENV, %::ORIG_ENV);
    my @keep = (qw(PATH HOME LOGNAME USER SHELL TERM LANG LC_ALL TZ TMPDIR SSH_AUTH_SOCK),
        (grep {m/^GIT_/} keys %src),
        (grep {length} split m/[\s,]+/, $src{AI_TOOL_ENV} // ''));
    my %e = map {($_ => $src{$_})} grep {defined $src{$_} and !m/^AI_/} @keep;
    $e{PATH}   //= '/usr/local/bin:/usr/bin:/bin';
    $e{TMPDIR} //= '/tmp';
    $e{LANG}   //= 'C.UTF-8';
    return %e;
}

# Fork a child that runs $worker_sub: own session, clean environment, stdin
# from /dev/null, stdout+stderr into a pipe. The worker may exec().
# Returns ($pid, $read_fh) in the parent. The child never returns.
sub fork_child {
    my ($worker_sub) = @_;
    $worker_sub //= sub {die "need a valid worker\n"};
    pipe(my $read_pipe_fh, my $write_pipe_fh)
        or die "Error setting up pipe(): $!\n";
    # nothing buffered may be inherited (and printed twice) by the child
    STDOUT->flush();
    STDERR->flush();
    my $c_pid = fork() // die "fork error: $!\n";
    if(!$c_pid){
        # worker sub-process, never returns
        my $ok = eval {
            $0 = "aicli:tool";
            close($read_pipe_fh);
            $SIG{$_} = 'DEFAULT' for qw(INT TERM QUIT HUP PIPE CHLD ALRM WINCH);
            %ENV = tool_env();
            %::ORIG_ENV = ();
            $_->() for @CHILD_INIT;
            POSIX::setsid() != -1
                or (!$!{EPERM} and die "problem making new session/process group: $!\n");
            open(STDIN,  '<', '/dev/null')
                or die "Can't read /dev/null: $!\n";
            open(STDOUT, '>&', $write_pipe_fh)
                or die "Can't dup STDOUT to PIPE: $!\n";
            open(STDERR, '>&', \*STDOUT)
                or die "Can't dup STDERR to STDOUT: $!\n";
            close($write_pipe_fh);
            STDOUT->autoflush(1);
            STDERR->autoflush(1);
            # dup() sets $! as ioctl() is done in perl, so reset ERRNO
            $! = 0;
            &{$worker_sub}();
            1;
        };
        # "exit" would run END blocks and destructors of the parent (terminal
        # cleanup!), this process must never get there: POSIX _exit
        if(!$ok){
            chomp(my $err = $@ // '');
            print STDERR "$err\n";
            POSIX::_exit(255);
        }
        POSIX::_exit(0);
    }
    close($write_pipe_fh);
    log::info("worker $c_pid forked");
    return ($c_pid, $read_pipe_fh);
}

# Run $worker_sub in a forked child and wait for it, in the event loop: the
# output is collected, a timeout or a user abort stops the whole process
# group of the child.
#
# Returns the output in scalar context, or
#   ($output, $exit_code, $signal, $why)
# where $why is '' or the reason the child was stopped early.
sub fork_run {
    my ($worker_sub, %o) = @_;
    my @r;
    my $done = 0;
    loop::spawn($worker_sub, timeout => $o{timeout}, on_done => sub {@r = @_; $done = 1});
    loop::run(sub {$done});
    return wantarray ? @r : $r[0];
}


package loop;
# The event loop: one select() for everything that waits. HTTP transfers
# (curl multi), forked children (their output pipes) and timers are registered
# here with a callback, loop::run() drives them all until a condition holds.
# No threads, and nothing in here blocks longer than a tick, so several
# requests and tools can be in flight at once and ctrl-C is noticed at once.

use strict; use warnings;

use POSIX ();
use Scalar::Util ();
use Time::HiRes ();

our ($multi, $net);
our (%http, $http_seq); # running transfers
our %child;             # running children, by pid
our @timers;            # [time, callback]
our $on_tick;           # called after every round (status line)
our $on_idle;           # called when run() returns

sub _multi {
    return $multi if $multi;
    $net   = Net::Curl::Multi->can('new') ? 1 : 0;
    $multi = eval {($net ? 'Net::Curl::Multi' : 'WWW::Curl::Multi')->new()};
    return $multi;
}

# Start an HTTP request: method, url, data, api_key
#   on_data: curl write callback for the body (else it is kept in {body})
#   on_done: called with the request when it is over; then {code} is the HTTP
#            status, {headers} the response headers (lowercased names) and
#            {error} is set unless it was a 200
sub http {
    my (%r) = @_;
    my $req = {%r, code => 0, error => undef, headers => {}, body => ''};
    $req->{data} //= '';
    my $ch = $req->{ch} = curl->new();
    $ch->setopt(curl::CURLOPT_VERBOSE(), $::DEBUG?1:0);
    if(my $proxy = $::ORIG_ENV{AI_PROXY} // $::ORIG_ENV{HTTPS_PROXY} // $::ORIG_ENV{HTTP_PROXY}){
        $ch->setopt(curl::CURLOPT_PROXY(), $proxy);
        if(my $no_proxy = $::ORIG_ENV{NO_PROXY} // $::ORIG_ENV{no_proxy}){
            eval {$ch->setopt(curl::CURLOPT_NOPROXY(), $no_proxy)};
        }
    }
    $ch->setopt(curl::CURLOPT_HTTPHEADER(), [
        "Accept: application/json",
        "Content-Type: application/json",
        "User-Agent: AI Chat/0.1",
        "Connection: Keep-Alive",
        "Keep-Alive: max=100",
        ($req->{api_key} ?(
            "Authorization: Bearer $req->{api_key}",
        ):())
    ]);
    $ch->setopt(curl::CURLOPT_WRITEFUNCTION(), $req->{on_data} // sub {
        my ($h, $chunk) = @_;
        $chunk //= $h; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
        $req->{body} .= $chunk;
        return length($chunk);
    });
    # response headers, the rate limits are in there
    eval {
        $ch->setopt(curl::CURLOPT_HEADERFUNCTION(), sub {
            # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
            my $line = ref($_[0]) ? $_[1] : $_[0];
            %{$req->{headers}} = () if $line =~ m/^HTTP\//;
            $req->{headers}{lc $1} = $2 if $line =~ m/^([^:\s]+):\s*(.*?)\s*$/;
            return length($line);
        });
    };
    $ch->setopt(curl::CURLOPT_URL(), $req->{url});
    if(lc($req->{method} // 'get') eq "post"){
        $ch->setopt(curl::CURLOPT_POST(), 1);
        if(length($req->{data})){
            $ch->setopt(curl::CURLOPT_POSTFIELDS(), $req->{data});
            $ch->setopt(curl::CURLOPT_POSTFIELDSIZE_LARGE(), length($req->{data}));
        }
    } else {
        $ch->setopt(curl::CURLOPT_HTTPGET(), 1);
    }

    if(!_multi()){
        # no multi interface: one blocking transfer, reported by the loop
        my $rc = eval {$ch->perform()};
        my $err = $@ ? "$@" : $rc ? $ch->strerror($rc) : undef;
        timer(0, sub {_http_done($req, $err)});
        return $req;
    }
    # a finished transfer is found back by its key
    if($net){
        $req->{key} = Scalar::Util::refaddr($ch);
    } else {
        $req->{key} = ++$http_seq;
        $ch->setopt(curl::CURLOPT_PRIVATE(), $req->{key});
    }
    $multi->add_handle($ch);
    $http{$req->{key}} = $req;
    return $req;
}

sub _http_done {
    my ($req, $err) = @_;
    if(defined $req->{key} and delete $http{$req->{key}}){
        eval {$multi->remove_handle($req->{ch})};
    }
    chomp($err) if defined $err;
    $req->{code} = eval {$req->{ch}->getinfo(curl::CURLINFO_HTTP_CODE())} // 0;
    $req->{code} = 0 if defined $err;
    $req->{error} = $err // ($req->{code} != 200 ? "HTTP status $req->{code}" : undef);
    delete $req->{ch};
    $req->{on_done}->($req) if $req->{on_done};
    return;
}

# Run $worker_sub in a forked child (see utils::fork_child). timeout in
# seconds, on_done is called with ($output, $exit_code, $signal, $why).
sub spawn {
    my ($worker_sub, %o) = @_;
    my ($pid, $fh) = utils::fork_child($worker_sub);
    my $job = {
        pid      => $pid,
        fh       => $fh,
        buf      => '',
        why      => '',
        timeout  => $o{timeout} // 0,
        deadline => $o{timeout} ? Time::HiRes::time() + $o{timeout} : 0,
        on_done  => $o{on_done},
    };
    return $child{$pid} = $job;
}

sub _stop_child {
    my ($job, $why, $now) = @_;
    $job->{why} = $why;
    log::info("stopping $job->{pid}: $why");
    kill('TERM', -$job->{pid}, $job->{pid});
    $job->{kill_at} = $now + 2;
    return;
}

sub _child_done {
    my ($job) = @_;
    delete $child{$job->{pid}};
    close($job->{fh});
    kill('KILL', -$job->{pid}, $job->{pid}) if $job->{why};
    local $SIG{CHLD} = 'DEFAULT';
    my $r = waitpid($job->{pid}, 0);
    my ($exit, $sig) = $r == $job->{pid} ? ($? >> 8, $? & 127) : (0, 0);
    log::info("$job->{pid} exited: $exit, signal: $sig".($job->{why} ? ", $job->{why}" : ""));
    $job->{on_done}->($job->{buf}, $exit, $sig, $job->{why}) if $job->{on_done};
    return;
}

# call $cb in $delay seconds; it gets a true argument when the wait was cut
# short by an abort
sub timer {
    my ($delay, $cb) = @_;
    my $t = [Time::HiRes::time() + ($delay // 0), $cb];
    push @timers, $t;
    return $t;
}

sub pending {
    return scalar(keys %http) + scalar(keys %child) + scalar(@timers);
}

# one round: wait for whatever comes first, at most $max seconds, handle it
sub step {
    my ($max) = @_;
    $max //= 0.2;
    local $SIG{PIPE} = 'IGNORE';
    my $now = Time::HiRes::time();

    # abort: everything that waits is told to stop
    if(utils::aborted()){
        _http_done($_, "interrupted") for values %{{%http}};
        foreach my $job (values %child){
            _stop_child($job, "interrupted by user", $now) unless $job->{why};
        }
        my @t = splice(@timers);
        $_->[1]->(1) for @t;
    }

    # what to wait for, and how long
    my ($rin, $win, $ein) = ('', '', '');
    my $t = $max;
    if(%http){
        my @sets = $multi->fdset();
        if($net){
            ($rin, $win, $ein) = @sets;
            my $ct = $multi->timeout();
            $t = $ct / 1000 if $ct >= 0 and $ct / 1000 < $t;
        } else {
            # lists of file descriptors here, select() wants bit vectors
            ($rin, $win, $ein) = map {
                my $v = '';
                vec($v, $_, 1) = 1 for @{$_ // []};
                $v;
            } @sets[0 .. 2];
        }
    }
    vec($rin, fileno($_->{fh}), 1) = 1 for values %child;
    foreach my $due ((map {$_->[0]} @timers), (map {grep {$_} @{$_}{qw(deadline kill_at giveup_at)}} values %child)){
        $t = $due - $now if $due - $now < $t;
    }
    $t = 0 if $t < 0;
    my ($rout, $wout, $eout) = ($rin, $win, $ein);
    my $ready = select($rout, $wout, $eout, $t);
    # interrupted by a signal: nothing is readable, whatever the sets say
    $rout = '' if ($ready // -1) <= 0;
    $now = Time::HiRes::time();

    # transfers
    if(%http){
        $multi->perform();
        if($net){
            while(my ($msg, $easy, $result) = $multi->info_read()){
                my $req = $http{Scalar::Util::refaddr($easy)}
                    or next;
                _http_done($req, $result + 0 ? "$result" : undef);
            }
        } else {
            while(my ($id, $rc) = $multi->info_read()){
                last unless $id;
                my $req = $http{$id}
                    or next;
                _http_done($req, $rc ? $req->{ch}->strerror($rc) : undef);
            }
        }
    }

    # children: their output, their end, their deadlines
    foreach my $job (values %{{%child}}){
        if(vec($rout // '', fileno($job->{fh}), 1)){
            my $got = sysread($job->{fh}, $job->{buf}, 65536, length($job->{buf}));
            next if !defined $got and $!{EINTR};
            if(!$got){ # EOF or error
                _child_done($job);
                next;
            }
        }
        if(!$job->{why}){
            _stop_child($job, "timeout after $job->{timeout}s", $now)
                if $job->{deadline} and $now >= $job->{deadline};
        } elsif($job->{kill_at} and $now >= $job->{kill_at}){
            kill('KILL', -$job->{pid}, $job->{pid});
            $job->{kill_at}   = 0;
            $job->{giveup_at} = $now + 2;
        } elsif($job->{giveup_at} and $now >= $job->{giveup_at}){
            _child_done($job); # something still holds the pipe, stop waiting for EOF
        }
    }

    # timers
    my @due = grep {$_->[0] <= $now} @timers;
    if(@due){
        @timers = grep {$_->[0] > $now} @timers;
        $_->[1]->(0) for @due;
    }

    $on_tick->() if $on_tick;
    return;
}

# drive the loop until $until says so
sub run {
    my ($until) = @_;
    step() until $until->();
    $on_idle->() if $on_idle;
    return;
}

1;
