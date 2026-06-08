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
sub http {
    my ($m, $full_url, $data, $api_key, $read_handle_sub) = @_;
    $data //= "";
    log::info("RSUB: ".((defined $read_handle_sub and ref($read_handle_sub) eq 'CODE')?1:0));
    log::info("URL: $full_url");
    log::info("DATA: $data");
    $$response = "";
    $curl_handle //= do {
        my $ch = curl->new();
        $ch->setopt(curl::CURLOPT_IPRESOLVE(), curl::CURL_IPRESOLVE_V6());
        $ch->setopt(curl::CURLOPT_VERBOSE(), $::DEBUG?1:0);
        $ch->setopt(curl::CURLOPT_HTTPHEADER(), [
            "Accept: application/json",
            "Content-Type: application/json",
            "User-Agent: AI Chat/0.1",
            "Connection: Keep-Alive",
            "Keep-Alive: max=100",
            ($api_key ?(
                "Authorization: Bearer $api_key",
            ):()),
        ]);
        if(my $proxy = $::ORIG_ENV{AI_PROXY} // $::ORIG_ENV{HTTPS_PROXY} // $::ORIG_ENV{HTTP_PROXY}){
            $ch->setopt(curl::CURLOPT_PROXY(), $proxy);
        }
        $ch;
    };
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
    $curl_handle->perform();
    my $r_code = $curl_handle->getinfo(curl::CURLINFO_HTTP_CODE());
    if($r_code != 200){
        log::info("ERROR: $r_code");
        return;
    }
    log::info("OK: $r_code");
    log::info("RESPONSE:\n$$response");
    return $$response;
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

sub daemon {
    my ($worker_sub) = @_;
    $worker_sub //= sub {die "need a valid worker\n"};
    local $SIG{HUP}  = 'IGNORE';
    local $SIG{INT}  = 'DEFAULT';
    local $SIG{TERM} = 'DEFAULT';
    local $SIG{QUIT} = 'DEFAULT';
    local $SIG{CHLD} = 'IGNORE';
    local $SIG{ALRM} = 'IGNORE';
    pipe(my $read_pipe_fh, my $write_pipe_fh)
        or die "Error setting up pipe(): $!\n";
    my $c_pid = fork() // return "[ERROR] couldn't run the perl program, fork error: $!\n";
    if($c_pid){
        close($write_pipe_fh);
        # here we need to catch the output and watch the process
        log::info("worker $c_pid forked, getting output");
        my $buf = "";
        {
            local $/;
            $buf = <$read_pipe_fh>;
        }
        log::info("now waitpid for $c_pid");
        my $r = waitpid($c_pid, 0);
        if($r == -1){
            # no such process
            log::info("no process with $c_pid");
        } elsif($r == 0){
            log::info("no processes"); # only WNOHANG, and we didn't enable that yet
        } elsif($r == $c_pid){
            my $e_v = $? << 8;
            my $s_v = $? & 127;
            if($e_v != 0 or !$s_v){
                log::error("$c_pid exited: $e_v, signal: $s_v");
                $buf = "[ERROR] PERL exit: $e_v, signal: $s_v, output: $buf";
            } else {
                log::info("$c_pid exited: $e_v, signal: $s_v");
            }
        } else {
            log::info("waitpid undef");
        }
        return $buf;
    }

    # worker sub-process
    eval {
        $0 = "aicli:daemon";
        close($read_pipe_fh);
        {
            my %OE = %ENV;
            %ENV = ();
            $ENV{PATH}    //= $OE{PATH}    // $::ORIG_ENV{PATH};
            $ENV{HOME}    //= $OE{HOME}    // $::ORIG_ENV{HOME};
            $ENV{LOGNAME} //= $OE{LOGNAME} // $::ORIG_ENV{LOGNAME};
            $ENV{TMPDIR}  //= $OE{TMPDIR}  // "/tmp";
            $ENV{LANG}    //= $OE{LANG}    // "en_US.UTF-8";
            %::ORIG_ENV = ();
        }

        POSIX::setsid() != -1
            or (!$!{EPERM} and die "problem making new session/process group: $!\n");
        open(STDOUT, '>&', $write_pipe_fh)
            or die "Can't dup STDOUT to PIPE: $!\n";
        *STDOUT->autoflush();
        *STDERR->autoflush();
        open(STDERR, '>&STDOUT')
            or die "Can't dup STDERR to STDOUT: $!\n";
        open(STDIN,  '</dev/null')
            or die "Can't read /dev/null: $!\n";
        # dup() sets $! as ioctl() is done in perl, so reset ERRNO
        $! = 0;
        &{$worker_sub}();
    };
    if($@){
        # there are cases that we get here, mostly signals and/or die/eval
        # caches (not the case here), also, "exit" handles END blocks, which
        # can do nasty stuff. As we really don't want this worker process to
        # continue, we use POSIX _exit
        chomp(my $err = $@);
        print "[ERROR] problem setting up forked process for running the perl program: $err\n";
        POSIX::_exit(1);
    }
    POSIX::_exit(0);
}

1;
