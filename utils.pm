package utils;

use strict; use warnings;

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

our $curl_handle;
our $response = \(my $buffer = "");
our ($http_error, $http_code);
sub http {
    my ($m, $full_url, $data, $api_key, $read_handle_sub) = @_;
    $data //= "";
    log::info("RSUB: ".((defined $read_handle_sub and ref($read_handle_sub) eq 'CODE')?1:0));
    log::info("URL: $full_url");
    log::info("DATA: $data");
    $$response = "";
    $curl_handle //= do {
        my $ch = curl->new();
        $ch->setopt(curl::CURLOPT_VERBOSE(), $::DEBUG?1:0);
        if(my $proxy = $::ORIG_ENV{AI_PROXY} // $::ORIG_ENV{HTTPS_PROXY} // $::ORIG_ENV{HTTP_PROXY}){
            $ch->setopt(curl::CURLOPT_PROXY(), $proxy);
            if(my $no_proxy = $::ORIG_ENV{NO_PROXY} // $::ORIG_ENV{no_proxy}){
                eval {$ch->setopt(curl::CURLOPT_NOPROXY(), $no_proxy)};
            }
        }
        $ch;
    };
    $curl_handle->setopt(curl::CURLOPT_HTTPHEADER(), [
        "Accept: application/json",
        "Content-Type: application/json",
        "User-Agent: AI Chat/0.1",
        "Connection: Keep-Alive",
        "Keep-Alive: max=100",
        ($api_key ?(
            "Authorization: Bearer $api_key",
        ):())
    ]);
    $curl_handle->setopt(curl::CURLOPT_WRITEFUNCTION(), $read_handle_sub // sub {
        my ($ch, $chunk) = @_;
        $chunk //= $ch; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
        log::info("WRITE SUB: ".length($chunk));
        $$response .= $chunk;
        return length($chunk);
    });
    $curl_handle->setopt(curl::CURLOPT_URL(), $full_url);
    if(lc($m) eq "post"){
        $curl_handle->setopt(curl::CURLOPT_POST(), 1);
        if(length($data)){
            $curl_handle->setopt(curl::CURLOPT_POSTFIELDS(), $data);
            $curl_handle->setopt(curl::CURLOPT_POSTFIELDSIZE_LARGE(), length($data));
        }
    }
    if(lc($m) eq "get"){
        $curl_handle->setopt(curl::CURLOPT_HTTPGET(), 1);
    }
    $http_error = undef;
    $http_code  = 0;
    if(!eval {_perform($curl_handle); 1}){
        chomp($http_error = "$@");
        $http_error ||= "unknown http error";
        log::info("HTTP ERROR: $http_error");
        return;
    }
    my $r_code = $http_code = $curl_handle->getinfo(curl::CURLINFO_HTTP_CODE());
    if($r_code != 200){
        $http_error = "HTTP status $r_code";
        log::info("ERROR: $r_code");
        return;
    }
    log::info("OK: $r_code");
    log::info("RESPONSE:\n$$response");
    return $$response;
}

# true when the user asked to stop the current turn (ctrl-C while busy)
sub aborted {
    return $::ABORT ? 1 : 0;
}

# Drive one transfer. No threads: with Net::Curl::Multi the transfer is driven
# from a select() loop, so an abort is noticed while the server is still
# silent. Without it (WWW::Curl) this falls back to a blocking perform().
# Dies on any transfer error.
sub _perform {
    my ($ch) = @_;
    my $multi = eval {Net::Curl::Multi->new()};
    if(!$multi){
        my $rc = $ch->perform();
        die $ch->strerror($rc)."\n" if $rc;
        return;
    }
    $multi->add_handle($ch);
    my $attached = 1;
    my $ok = eval {
        my $running = 1;
        while($running){
            die "interrupted\n" if aborted();
            my ($rin, $win, $ein) = $multi->fdset();
            my $t = $multi->timeout();
            $t = ($t < 0 or $t > 250) ? 0.25 : $t/1000;
            select($rin, $win, $ein, $t);
            $running = $multi->perform();
            while(my ($msg, $easy, $result) = $multi->info_read()){
                $multi->remove_handle($easy);
                $attached = 0;
                die "$result\n" if $result+0;
            }
        }
        1;
    };
    my $err = $@;
    eval {$multi->remove_handle($ch)} if $attached;
    die $err unless $ok;
    return;
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

# Run $worker_sub in a forked child (own session, clean environment, stdin
# from /dev/null, stdout+stderr captured through a pipe). The worker may
# exec(). The parent multiplexes with select(): it collects the output and
# watches for a timeout or a user abort, in which case the whole process group
# of the child is signalled.
#
# Returns the output in scalar context, or
#   ($output, $exit_code, $signal, $why)
# where $why is '' or the reason the child was stopped early.
sub fork_run {
    my ($worker_sub, %o) = @_;
    $worker_sub //= sub {die "need a valid worker\n"};
    my $timeout = $o{timeout} // 0;
    local $SIG{CHLD} = 'DEFAULT';
    local $SIG{PIPE} = 'IGNORE';
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
    log::info("worker $c_pid forked, getting output");
    my $buf = "";
    my $why = "";
    my $deadline = $timeout ? Time::HiRes::time() + $timeout : 0;
    my ($kill_at, $giveup_at) = (0, 0);
    my $rin = '';
    vec($rin, fileno($read_pipe_fh), 1) = 1;
    while(1){
        my $n = select(my $rout = $rin, undef, undef, 0.2);
        if(($n // 0) > 0){
            my $got = sysread($read_pipe_fh, $buf, 65536, length($buf));
            next if !defined $got and $!{EINTR};
            last unless $got; # EOF or error
        }
        my $now = Time::HiRes::time();
        if(!$why){
            if(aborted()){
                $why = "interrupted by user";
            } elsif($deadline and $now >= $deadline){
                $why = "timeout after ${timeout}s";
            }
            if($why){
                log::info("stopping $c_pid: $why");
                kill('TERM', -$c_pid, $c_pid);
                $kill_at = $now + 2;
            }
        } elsif($kill_at and $now >= $kill_at){
            kill('KILL', -$c_pid, $c_pid);
            $kill_at   = 0;
            $giveup_at = $now + 2;
        } elsif($giveup_at and $now >= $giveup_at){
            last; # something still holds the pipe, stop waiting for EOF
        }
    }
    close($read_pipe_fh);
    kill('KILL', -$c_pid, $c_pid) if $why;
    my $r = waitpid($c_pid, 0);
    my ($exit, $sig) = $r == $c_pid ? ($? >> 8, $? & 127) : (0, 0);
    log::info("$c_pid exited: $exit, signal: $sig".($why?", $why":""));
    return wantarray ? ($buf, $exit, $sig, $why) : $buf;
}

1;
