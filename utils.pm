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
    my ($m, $full_url, $data, $api_key, $read_handle_sub, $headers) = @_;
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
        ($headers ? (headers => $headers) : ()),
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

# The proxy for a kind of request, undef for none:
#   'ai'   the LLM API:           AI_PROXY,     else HTTPS_PROXY / HTTP_PROXY
#   'web'  the web tools (fetch): AI_WEB_PROXY, else HTTPS_PROXY / HTTP_PROXY
# "none" (or empty) in the AI_* variable means no proxy, whatever the
# environment says. Anything curl takes: http://, socks5h://, user:pass@.
sub proxy_for {
    my ($kind) = @_;
    my $own = $kind eq 'web' ? 'AI_WEB_PROXY' : 'AI_PROXY';
    my ($p) = grep {defined} @::ORIG_ENV{$own, qw(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy)};
    return if !defined $p or $p =~ m/^(?:|none|off|direct|no)$/i;
    return $p;
}

# Who to run as when started as root (in docker): the user, group and
# supplementary groups the environment names, so that files in a mounted
# project belong to who started the container.
#   user:   AI_UID, else UID, else 1000
#   group:  AI_GID, else GID, else 1000
#   groups: AI_GROUPS (numbers), else the groups the process has now
#           (docker --group-add), without root's
# Root is never an answer: 0 and what is not a number are ignored.
sub privilege_plan {
    my ($env, $current_groups) = @_;
    my $id = sub {
        my ($v) = @_;
        return (defined $v and $v =~ m/\A\d+\z/ and $v > 0) ? $v + 0 : undef;
    };
    my $uid = $id->($env->{AI_UID}) // $id->($env->{UID}) // 1000;
    my $gid = $id->($env->{AI_GID}) // $id->($env->{GID}) // 1000;
    my @groups = defined $env->{AI_GROUPS}
        ? split(m/[\s,:]+/, $env->{AI_GROUPS})
        : @{$current_groups // []};
    my %seen = ($gid => 1);
    @groups = grep {defined $id->($_) and !$seen{$_}++} @groups;
    return {uid => $uid, gid => $gid, groups => [map {$_ + 0} @groups]};
}

# give a directory and all in it to a user; links are left alone, what cannot
# be changed (a read-only mount) is skipped
sub chown_tree {
    my ($dir, $uid, $gid) = @_;
    load_cpan("File::Find");
    File::Find::find({no_chdir => 1, wanted => sub {
        return if -l $File::Find::name;
        chown($uid, $gid, $File::Find::name);
    }}, $dir);
    return;
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
# The easy handles of one curl family: Net::Curl (preferred) or WWW::Curl.
# The multi handle (utils::_multi) comes from the same family. When neither
# loads, the start stops with the errors of both, not with a missing method
# later on.

use strict; use warnings;

our $FAMILY; # 'Net::Curl' or 'WWW::Curl'
our @LOAD_ERRORS;

BEGIN {
    for my $family (qw(Net::Curl WWW::Curl)) {
        my $ok = eval {
            utils::load_cpan("${family}::Easy");
            utils::load_cpan("${family}::Multi");
            1;
        };
        if($ok){
            $FAMILY = $family;
            last;
        }
        (my $err = $@ // 'unknown error') =~ s/\s+\z//;
        push @LOAD_ERRORS, "$family: $err";
    }
    die "no curl module can be loaded (".join("; ", @LOAD_ERRORS).")\n" unless $FAMILY;
    no strict 'refs';
    *AUTOLOAD = *{"${FAMILY}::Easy::AUTOLOAD"};
    foreach my $k (keys %{"${FAMILY}::Easy::"}){
        next unless $k =~ /^CURL/ and defined &{"${FAMILY}::Easy::${k}"}; # curl constants/options, the subs
        *{"curl::${k}"} = \&{"${FAMILY}::Easy::${k}"};
    }
}

# a new easy handle, of the family that loaded
sub new {
    my ($class, @args) = @_;
    return "${FAMILY}::Easy"->new(@args);
}


package log;
# Messages for the person at the terminal, never part of the answer: they go
# to stderr, so that stdout is the conversation and nothing else (ai.pl -p in
# a pipe). Debug messages (info) go to the file AI_LOG instead when that is
# set, errors go to stderr and to that file.

use strict; use warnings;

our $before_print; # called before something is written to the terminal (status line)

sub _write {
    my ($line, $to_terminal) = @_;
    my $file = $::ORIG_ENV{AI_LOG};
    if(length($file // '')){
        if(open(my $lfh, '>>', $file)){
            print {$lfh} $line;
            close($lfh);
        } else {
            $to_terminal = 1; # better there than nowhere
        }
    } else {
        $to_terminal = 1;
    }
    return unless $to_terminal;
    $before_print->() if $before_print;
    STDOUT->flush(); # keep the order with what was printed before
    print STDERR $line;
    return;
}

sub info {
    my ($message) = @_;
    return unless $::DEBUG;
    _write("INFO: [$$]: ".scalar(localtime()).": $message\n", 0);
    return;
}

sub error {
    my ($message) = @_;
    _write("ERROR: [$$]: ".scalar(localtime()).": $message\n", 1);
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
            # the hooks still see the settings, the tool will not; what they
            # complain about is output of the tool
            $_->() for @CHILD_INIT;
            %::ORIG_ENV = ();
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


package sandbox;
# Landlock: a process tells the kernel which parts of the filesystem it may
# still use, for itself and for everything it starts, for good. No root is
# needed and nothing is mounted: it is not a namespace, the process sees
# everything as before, what is not allowed fails with "permission denied".
# Linux 5.13 or newer; done with three system calls, from the forked child of
# a tool, before the tool runs. The chat process itself is never restricted.

use strict; use warnings;

use POSIX ();

# access rights for the filesystem, the kernel has them as bits
my %FS = (
    execute => 1 << 0, write_file => 1 << 1, read_file => 1 << 2, read_dir => 1 << 3,
    remove_dir => 1 << 4, remove_file => 1 << 5, make_char => 1 << 6, make_dir => 1 << 7,
    make_reg => 1 << 8, make_sock => 1 << 9, make_fifo => 1 << 10, make_block => 1 << 11,
    make_sym => 1 << 12,
    refer    => 1 << 13, # rename/link to another directory: kernel ABI 2
    truncate => 1 << 14, # ABI 3
);
my @WRITE = qw(write_file remove_dir remove_file make_char make_dir make_reg make_sock make_fifo make_block make_sym);
my @READ  = qw(execute read_file read_dir);
# what makes sense for a single file, the rest is for directories
my $FILE_RIGHTS = $FS{execute} | $FS{write_file} | $FS{read_file} | $FS{truncate};

my ($SYS_CREATE, $SYS_ADD_RULE, $SYS_RESTRICT) = (444, 445, 446); # the same on every architecture
my %SYS_PRCTL = (x86_64 => 157, aarch64 => 167, riscv64 => 167, armv7l => 172, i686 => 172);
my $PR_SET_NO_NEW_PRIVS = 38;
my $O_PATH_CLOEXEC = 0x200000 | 0x80000;

our $ABI;

# the Landlock version of this kernel, 0 when there is none (or it is off)
sub abi {
    return $ABI if defined $ABI;
    my $v = defined $SYS_PRCTL{(POSIX::uname())[4]} ? syscall($SYS_CREATE, 0, 0, 1) : -1;
    return $ABI = $v > 0 ? $v : 0;
}

# Confine this process: write => [paths that may be written to], and with
# read => [paths] reading and executing is limited to those too (else it is
# free). Paths that do not exist are skipped. Returns true when confined,
# false when the kernel cannot do it, dies when it can but something failed:
# a tool is not run half confined.
sub confine {
    my (%o) = @_;
    my $abi = abi()
        or return 0;
    my $write = 0;
    $write |= $FS{$_} for @WRITE, ($abi >= 2 ? 'refer' : ()), ($abi >= 3 ? 'truncate' : ());
    my $read = 0;
    $read |= $FS{$_} for @READ;
    my $handled = $write | ($o{read} ? $read : 0);

    my $attr = pack("Q", $handled);
    my $ruleset = syscall($SYS_CREATE, $attr, length($attr), 0);
    die "landlock: cannot create a ruleset: $!\n" if $ruleset < 0;
    my $allow = sub {
        my ($path, $rights) = @_;
        sysopen(my $fh, $path, $O_PATH_CLOEXEC)
            or return; # not there, nothing to allow
        $rights &= $FILE_RIGHTS unless -d $fh;
        return unless $rights;
        my $rule = pack("Q l", $rights, fileno($fh));
        syscall($SYS_ADD_RULE, $ruleset, 1, $rule, 0) == 0
            or die "landlock: cannot allow $path: $!\n";
        close($fh);
    };
    my %seen;
    &{$allow}($_, $handled) for grep {defined and length and !$seen{"w$_"}++} @{$o{write} // []};
    &{$allow}($_, $handled & $read) for grep {defined and length and !$seen{"r$_"}++} @{$o{read} // []};

    # without this the kernel refuses: no setuid program may gain rights anymore
    syscall($SYS_PRCTL{(POSIX::uname())[4]}, $PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0
        or die "landlock: cannot set no_new_privs: $!\n";
    syscall($SYS_RESTRICT, $ruleset, 0) == 0
        or die "landlock: cannot restrict this process: $!\n";
    POSIX::close($ruleset);
    return 1;
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
our $on_tick;           # called every round, before the wait (status line)
our $on_idle;           # called when run() returns

sub _multi {
    return $multi if $multi;
    # the same family as the easy handles (curl::FAMILY)
    $net   = $curl::FAMILY eq 'Net::Curl' ? 1 : 0;
    $multi = eval {"${curl::FAMILY}::Multi"->new()};
    return $multi;
}

# Start an HTTP request: method, url, data, api_key
#   on_data: curl write callback for the body (else it is kept in {body})
#   on_done: called with the request when it is over; then {code} is the HTTP
#            status, {headers} the response headers (lowercased names),
#            {url_final} where redirects ended and {error} is set unless it
#            was a 200
#   proxy:   the proxy to use, '' for none; without it: utils::proxy_for('ai')
#   headers: request headers, instead of the ones for the JSON API
#   timeout, connect_timeout: in seconds, default none
#   follow:  follow that many redirects
#   max_size: stop when the body gets bigger ({too_big} is set, {body} has
#            what came until then)
sub http {
    my (%r) = @_;
    my $req = {%r, code => 0, error => undef, headers => {}, body => ''};
    $req->{data} //= '';
    my $ch = $req->{ch} = curl->new();
    $ch->setopt(curl::CURLOPT_VERBOSE(), $::DEBUG?1:0);
    # the proxy is always set here, also to "none": libcurl would look at the
    # environment itself otherwise
    my $proxy = exists $r{proxy} ? $r{proxy} : utils::proxy_for('ai');
    $ch->setopt(curl::CURLOPT_PROXY(), $proxy // '');
    if(length($proxy // '') and defined(my $no_proxy = $::ORIG_ENV{NO_PROXY} // $::ORIG_ENV{no_proxy})){
        eval {$ch->setopt(curl::CURLOPT_NOPROXY(), $no_proxy)};
    }
    $ch->setopt(curl::CURLOPT_HTTPHEADER(), $req->{headers_out} = $r{headers} // [
        "Accept: application/json",
        "Content-Type: application/json",
        "User-Agent: AI Chat/0.1",
        "Connection: Keep-Alive",
        "Keep-Alive: max=100",
        ($req->{api_key} ?(
            "Authorization: Bearer $req->{api_key}",
        ):())
    ]);
    $req->{headers} = {};
    eval {$ch->setopt(curl::CURLOPT_TIMEOUT(), $r{timeout})} if $r{timeout};
    eval {$ch->setopt(curl::CURLOPT_CONNECTTIMEOUT(), $r{connect_timeout})} if $r{connect_timeout};
    if($r{follow}){
        eval {
            $ch->setopt(curl::CURLOPT_FOLLOWLOCATION(), 1);
            $ch->setopt(curl::CURLOPT_MAXREDIRS(), $r{follow});
        };
    }
    $ch->setopt(curl::CURLOPT_WRITEFUNCTION(), $req->{on_data} // sub {
        my ($h, $chunk) = @_;
        $chunk //= $h; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
        $req->{body} .= $chunk;
        if($r{max_size} and length($req->{body}) > $r{max_size}){
            $req->{too_big} = 1;
            return 0; # ends the transfer
        }
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
    $req->{url_final} = eval {$req->{ch}->getinfo(curl::CURLINFO_EFFECTIVE_URL())} // $req->{url};
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
    $fh->blocking(0); # the loop must never hang in a read
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
    # only what is waited for here may be read below: a child that a callback
    # starts in this round can get the file descriptor number of a socket
    # that was just closed, and that one is still marked readable
    my @jobs = values %child;
    vec($rin, fileno($_->{fh}), 1) = 1 for @jobs;
    foreach my $due ((map {$_->[0]} @timers), (map {grep {$_} @{$_}{qw(deadline kill_at giveup_at)}} values %child)){
        $t = $due - $now if $due - $now < $t;
    }
    $t = 0 if $t < 0;
    # show where things are (status line), then wait
    $on_tick->() if $on_tick;
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
    foreach my $job (@jobs){
        next unless $child{$job->{pid}};
        if(vec($rout // '', fileno($job->{fh}), 1)){
            my $got = sysread($job->{fh}, $job->{buf}, 65536, length($job->{buf}));
            next if !defined $got and ($!{EINTR} or $!{EAGAIN});
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
