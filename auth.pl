#!/usr/bin/perl
# The auth service: the logins of the web interface, and the check of their JWT for nginx
# (auth_request). It runs in a container of its own, with the local accounts of that
# container (PAM, service aicli-auth). Its endpoints:
#   POST /auth/login             user=...&password=... -> 200 and the cookie aicli_jwt, or 401
#   POST /auth/logout            the cookie cleared
#   GET  /auth/verify[?role=R]   nginx's check: 200 with X-User and X-Roles (the claims of the
#                                JWT in the cookie aicli_jwt or a Bearer token), 401 when there
#                                is no valid JWT, 403 when the user has not the role R
# The login page is a static file (ai/ui/login.html, served by nginx). The JWT is RS256, signed with the RSA key of AI_AUTH_KEY (made at the first start, kept in
# the volume). Its claims: sub (the user), roles (the groups of the user that start with
# aicli-), iat, exp, iss. Passwords are never logged, nor the tokens.
#
# The service is one select() loop with timeouts, one request at a time per connection, and
# it does no work for a chat: the pieces that check a request (handle()) are plain functions.
#
# Environment:
#   AI_AUTH_LISTEN    host:port to listen on (default 0.0.0.0:9000)
#   AI_AUTH_KEY       the RSA key file (default /var/lib/aicli-auth/jwt-rsa.pem)
#   AI_AUTH_LIFETIME     seconds a token lasts; renewed in its second half (default 86400: a day idle)
#   AI_AUTH_SESSION_MAX  seconds from a login to the end of its session (default 2592000: a month)
#   AI_AUTH_REVOKED      the revocation list (default /var/lib/aicli-auth/revoked.json)
#   AI_AUTH_PAM_SERVICE  the PAM service (default aicli-auth, /etc/pam.d/aicli-auth)
#
# Usage: auth.pl            serve (the accounts of the state are made again first)
#        auth.pl --check   check that the key and PAM are usable, then exit
#        auth.pl user add NAME [ROLE...] | passwd NAME | del NAME | list
#        auth.pl user role add|remove NAME ROLE
#   (in the container: docker compose exec -it auth perl /usr/local/lib/aicli/auth.pl user add NAME aicli-user)

use strict; use warnings;
use IO::Socket::IP ();
use IO::Select ();
use JSON::XS ();
use MIME::Base64 ();
use Digest::SHA ();
use Crypt::OpenSSL::RSA ();
use Authen::PAM ();
use Fcntl ();

our $JSON = JSON::XS->new->canonical->allow_nonref;
our $ISSUER = 'aicli-auth';
our $ROLE_PREFIX = 'aicli-';
our $COOKIE = 'aicli_jwt';
our $MAX_REQUEST = 8192;

# --- accounts ---------------------------------------------------------------------------------

# a login name, also the name of the Linux account and of the user's directory: lowercase
# letters, digits, and . _ @ + - (an e-mail address is one); it starts with a letter or digit
# (so no "..", no leading dash); never a slash, a colon or a comma (the account files' separators)
sub valid_user {
    my ($name) = @_;
    return defined $name && $name =~ m/\A[a-z0-9][a-z0-9._\@+-]{0,63}\z/ && $name ne 'root';
}

# the roles of a user: the groups that start with aicli- and have the user as a member
sub roles_of {
    my ($user) = @_;
    my %roles;
    my (undef, undef, undef, $pgid) = getpwnam($user);
    if (defined $pgid) {
        my $pname = getgrgid($pgid);
        $roles{$pname} = 1 if defined $pname and index($pname, $ROLE_PREFIX) == 0;
    }
    setgrent();
    while (my ($gname, undef, undef, $members) = getgrent()) {
        next unless index($gname, $ROLE_PREFIX) == 0;
        my %m = map { $_ => 1 } grep { length } split /[ ,]+/, $members // '';
        $roles{$gname} = 1 if $m{$user};
    }
    endgrent();
    return sort keys %roles;
}

# PAM: the password of the user, checked by the account's PAM service. The conversation
# answers the user name and the password, nothing else.
sub pam_ok {
    my ($user, $password) = @_;
    return 0 unless valid_user($user) and defined $password and length $password;
    my $service = $ENV{AI_AUTH_PAM_SERVICE} // 'aicli-auth';
    my $conv = sub {
        my @stack = @_;
        my @resp;
        while (@stack) {
            my $code = shift @stack;
            shift @stack;
            my $answer;
            $answer = $user if $code == Authen::PAM::PAM_PROMPT_ECHO_ON();
            $answer = $password if $code == Authen::PAM::PAM_PROMPT_ECHO_OFF();
            push @resp, Authen::PAM::PAM_SUCCESS(), $answer;
        }
        return @resp, Authen::PAM::PAM_SUCCESS();
    };
    my $pamh;
    my $rc = Authen::PAM::pam_start($service, $user, $conv, $pamh);
    return 0 unless $rc == Authen::PAM::PAM_SUCCESS();
    my $ok = Authen::PAM::pam_authenticate($pamh, Authen::PAM::PAM_SILENT() | Authen::PAM::PAM_DISALLOW_NULL_AUTHTOK()) == Authen::PAM::PAM_SUCCESS()
        && Authen::PAM::pam_acct_mgmt($pamh, Authen::PAM::PAM_SILENT()) == Authen::PAM::PAM_SUCCESS();
    Authen::PAM::pam_end($pamh, 0);
    return $ok ? 1 : 0;
}

# --- the accounts, kept in the volume ----------------------------------------------------------
# PAM reads /etc/passwd and /etc/shadow, which a container rebuild throws away. A bind mount
# over those files does not work: useradd and passwd replace them by a rename, which a mount
# point refuses. So the files themselves are kept: a copy of the four account files is in
# AI_AUTH_STATE (the volume), copied in at every start and copied out after every admin change.
# The copy is the whole file: a system account that a newer image adds is missing from the copy
# until the copy is removed (then the image's files are taken again, and the accounts of the
# admin are gone too: they are kept only in the copy).

our $ETC_DEFAULT = '/etc';
our $STATE_DEFAULT = '/var/lib/aicli-auth/etc';
our @ACCOUNT_FILES = (
    [ 'passwd', 0644 ], [ 'group', 0644 ], [ 'shadow', 0640 ], [ 'gshadow', 0640 ],
);

# the commands that change the system; a test replaces it
our $RUN = sub {
    my @cmd = @_;
    system { $cmd[0] } @cmd;
    return $? == 0;
};

# a command that reads its input from standard input (the hash for chpasswd): no shell, the
# input is written to it
our $RUN_IN = sub {
    my ($input, @cmd) = @_;
    open(my $pipe, '|-', @cmd) or return 0;
    print {$pipe} $input;
    close($pipe);
    return $? == 0;
};

sub valid_role {
    my ($name) = @_;
    return defined $name && $name =~ m/\Aaicli-[a-z0-9_-]{1,27}\z/;
}

sub etc_dir { return $ENV{AI_AUTH_ETC} // $ETC_DEFAULT }
sub state_dir { return $ENV{AI_AUTH_STATE} // $STATE_DEFAULT }

# the bytes of a file, or undef
sub _slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# write FILE with DATA and MODE, through a temp name in the same directory (so it is one rename)
sub _replace {
    my ($file, $data, $mode, $owner_group) = @_;
    my $tmp = "$file.new";
    unlink $tmp;
    sysopen(my $fh, $tmp, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), $mode)
        or die "auth: cannot write $tmp: $!\n";
    binmode $fh;
    print {$fh} $data;
    close $fh or die "auth: cannot write $tmp: $!\n";
    if (defined $owner_group and $> == 0) { # the group of shadow: root only
        chown(0, $owner_group, $tmp) or die "auth: cannot chown $tmp: $!\n";
    }
    chmod($mode, $tmp);
    rename($tmp, $file) or die "auth: cannot replace $file: $!\n";
    return;
}

# copy the account files of /etc to the state
sub save_accounts {
    my $dir = state_dir();
    if (!-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
    }
    for my $f (@ACCOUNT_FILES) {
        my $data = _slurp(etc_dir()."/$f->[0]");
        die "auth: cannot read ".etc_dir()."/$f->[0]\n" unless defined $data;
        _replace("$dir/$f->[0]", $data, 0600);
    }
    return;
}

# copy the state back to /etc at a start, when the state has the files
sub restore_accounts {
    my $dir = state_dir();
    my @have = grep { -f "$dir/$_->[0]" } @ACCOUNT_FILES;
    return 0 unless @have == @ACCOUNT_FILES;
    my $shadow_gid = (getgrnam('shadow'))[2];
    for my $f (@ACCOUNT_FILES) {
        my $data = _slurp("$dir/$f->[0]");
        die "auth: cannot read $dir/$f->[0]\n" unless defined $data;
        my $owner = $f->[0] =~ m/shadow/ ? $shadow_gid : undef;
        _replace(etc_dir()."/$f->[0]", $data, $f->[1], $owner);
    }
    print STDERR "auth: accounts restored from $dir\n";
    return 1;
}

# the admin commands: user add|passwd|del|list, role add|remove
# --- passwords: the rules of this app and the hash are here, not in the system's passwd (which
# has rules of its own). The password is read here, checked here, hashed here (SHA-512 crypt,
# AI_AUTH_ROUNDS rounds, the length AI_AUTH_MINLEN); chpasswd -e only stores the hash.
our $PW_ALPHABET = join '', ('.', '/', 0 .. 9, 'A' .. 'Z', 'a' .. 'z');
sub min_password { return $ENV{AI_AUTH_MINLEN} // 10 }
sub hash_rounds  { return $ENV{AI_AUTH_ROUNDS} // 100000 }

# the reason a password is no good for an account, or undef
sub password_problem {
    my ($name, $pw) = @_;
    return 'a password is wanted' unless defined $pw and length $pw;
    return 'the password is shorter than '.min_password().' characters' if length($pw) < min_password();
    return 'the password is printable ASCII (no control characters)' unless $pw =~ m/\A[\x20-\x7e]+\z/;
    return 'the password is the account name' if lc($pw) eq lc($name // '');
    return undef;
}

# a SHA-512 crypt hash ($6$) of the password, with a random salt
sub hash_password {
    my ($pw) = @_;
    open(my $fh, '<:raw', '/dev/urandom') or die "auth: no /dev/urandom: $!\n";
    my $got = read($fh, my $bytes, 16);
    close $fh;
    die "auth: no random bytes\n" unless defined $got and $got == 16;
    my $salt = join '', map { substr($PW_ALPHABET, ord(substr($bytes, $_, 1)) % 64, 1) } 0 .. 15;
    my $hash = crypt($pw, sprintf('$6$rounds=%d$%s', hash_rounds(), $salt));
    die "auth: this system cannot make a SHA-512 hash\n" unless defined $hash and $hash =~ m/\A\$6\$/;
    return $hash;
}

# one line from the terminal with the echo off, or from the input when there is no terminal
sub read_password {
    my ($prompt) = @_;
    print STDERR $prompt;
    my $tty = -t STDIN;
    my ($termios, $lflag);
    if ($tty) {
        require POSIX;
        $termios = POSIX::Termios->new;
        $termios->getattr(0);
        $lflag = $termios->getlflag;
        $termios->setlflag($lflag & ~POSIX::ECHO());
        $termios->setattr(0, POSIX::TCSANOW());
    }
    my $line = <STDIN>;
    if ($tty) {
        $termios->setlflag($lflag);
        $termios->setattr(0, POSIX::TCSANOW());
        print STDERR "\n";
    }
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    return $line;
}

# the password of an account: asked twice, kept to the rules, stored as its hash
sub set_password {
    my ($name) = @_;
    my $first = read_password("new password for $name: ");
    my $again = read_password("again: ");
    die "auth: the two passwords differ\n" unless defined $first and defined $again and $first eq $again;
    if (defined(my $why = password_problem($name, $first))) { die "auth: $why\n" }
    $RUN_IN->("$name:".hash_password($first)."\n", 'chpasswd', '-e')
        or die "auth: could not store the password of $name\n";
    return 1;
}

sub user_command {
    my (@args) = @_;
    my $cmd = shift(@args) // '';
    if ($cmd eq 'add') {
        my ($name, @roles) = @args;
        die "auth: a user name: lowercase letters, digits and . _ @ + - (an e-mail address is one), up to 64\n" unless valid_user($name);
        die "auth: $name exists\n" if getpwnam($name);
        for my $r (@roles) { die "auth: $r is no role (aicli-...)\n" unless valid_role($r) }
        $RUN->('useradd', '-M', '-s', '/usr/sbin/nologin', '-U', $name) or die "auth: useradd failed\n";
        for my $r (@roles) {
            $RUN->('groupadd', '-f', $r) or die "auth: groupadd $r failed\n";
            $RUN->('gpasswd', '-a', $name, $r) or die "auth: gpasswd failed\n";
        }
        set_password($name);
        save_accounts();
        print "auth: $name added (roles: @roles)\n";
    } elsif ($cmd eq 'passwd') {
        my ($name) = @args;
        die "auth: no account ".($name // '')."\n" unless $name and getpwnam($name);
        set_password($name);
        save_accounts();
        revoke_user($name, time());
    } elsif ($cmd eq 'role') {
        my ($op, $name, $r) = @args;
        die "auth: no account ".($name // '')."\n" unless $name and getpwnam($name);
        die "auth: ".($r // '')." is no role (aicli-...)\n" unless valid_role($r);
        if (($op // '') eq 'add') {
            $RUN->('groupadd', '-f', $r) or die "auth: groupadd $r failed\n";
            $RUN->('gpasswd', '-a', $name, $r) or die "auth: gpasswd failed\n";
        } elsif (($op // '') eq 'remove') {
            $RUN->('gpasswd', '-d', $name, $r) or die "auth: gpasswd failed\n";
        } else {
            die "auth: role add|remove NAME ROLE\n";
        }
        save_accounts();
    } elsif ($cmd eq 'del') {
        my ($name) = @args;
        die "auth: no account ".($name // '')."\n" unless $name and getpwnam($name);
        $RUN->('userdel', $name) or die "auth: userdel failed\n";
        save_accounts();
        revoke_user($name, time());
        print "auth: $name deleted\n";
    } elsif ($cmd eq 'list') {
        setpwent();
        while (my ($name) = getpwent()) {
            my @roles = roles_of($name);
            print "$name  roles: @roles\n" if @roles;
        }
        endpwent();
    } else {
        die "auth: user add NAME [ROLE...] | passwd NAME | del NAME | list\n        role add|remove NAME ROLE\n";
    }
    return 0;
}

# --- the key and the JWT -----------------------------------------------------------------------

# the RSA key of the tokens: read from the file, or made (2048 bits) and written with mode 0600
sub load_key {
    my ($file) = @_;
    if (-e $file) {
        open(my $fh, '<', $file) or die "auth: cannot read $file: $!\n";
        local $/;
        my $pem = <$fh>;
        close $fh;
        my $rsa = Crypt::OpenSSL::RSA->new_private_key($pem)
            or die "auth: $file is not an RSA private key\n";
        return $rsa;
    }
    my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
    sysopen(my $fh, $file, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)
        or die "auth: cannot write $file: $!\n";
    print {$fh} $rsa->get_private_key_string();
    close $fh;
    return $rsa;
}

sub _sign_rs256 {
    my ($rsa, $data) = @_;
    $rsa->use_sha256_hash();
    $rsa->use_pkcs1_padding() if $rsa->can('use_pkcs1_padding');
    return $rsa->sign($data);
}

# a token for the user; the claims are the given ones, plus iss, iat and exp
# a token: sid is the login (kept by every renewal, revoked by logout), ses the time of the
# login (the session ends session_max seconds after it), iat and exp the token's own life
sub jwt_create {
    my ($rsa, $user, $roles, $lifetime, $now, $ses, $sid) = @_;
    $now //= time();
    $ses //= $now;
    $sid //= new_sid();
    my $header = MIME::Base64::encode_base64url($JSON->encode({ alg => 'RS256', typ => 'JWT' }));
    my $payload = MIME::Base64::encode_base64url($JSON->encode({
        iss => $ISSUER, sub => $user, roles => [ @$roles ], sid => $sid, ses => $ses,
        iat => $now, exp => $now + $lifetime,
    }));
    my $signed = "$header.$payload";
    my $sig = _sign_rs256($rsa, $signed);
    return "$signed." . MIME::Base64::encode_base64url($sig);
}

# the claims of a valid token, or undef (the reason goes to the log by the caller)
sub jwt_verify {
    my ($rsa, $token, $now) = @_;
    $now //= time();
    return (undef, 'no token') unless defined $token and length $token;
    my ($h, $p, $s, @rest) = split /\./, $token, -1;
    return (undef, 'not a compact JWS') if @rest or !defined $s or !length $s;
    my $head = eval { $JSON->decode(MIME::Base64::decode_base64url($h)) };
    return (undef, 'bad header') unless ref $head eq 'HASH';
    return (undef, 'algorithm not RS256') unless ($head->{alg} // '') eq 'RS256';
    my $sig = MIME::Base64::decode_base64url($s);
    $rsa->use_sha256_hash();
    $rsa->use_pkcs1_padding() if $rsa->can('use_pkcs1_padding');
    return (undef, 'bad signature') unless $rsa->verify("$h.$p", $sig);
    my $claims = eval { $JSON->decode(MIME::Base64::decode_base64url($p)) };
    return (undef, 'bad payload') unless ref $claims eq 'HASH';
    return (undef, 'wrong issuer') unless ($claims->{iss} // '') eq $ISSUER;
    return (undef, 'no user') unless valid_user($claims->{sub});
    return (undef, 'expired') unless defined $claims->{exp} and $claims->{exp} > $now;
    return (undef, 'issued in the future') if ($claims->{iat} // 0) > $now + 60;
    return ($claims, undef);
}

# --- sessions: renewal and the revocation list --------------------------------------------------
# A login lasts token_lifetime() seconds; a request in the second half of that gets a new token
# (the roles read again, the account must still exist), so the user stays logged in while in use.
# The session as a whole ends session_max() seconds after the login: then a login is needed.
# Revoked: a session (logout), or every session of a user before a time (user del, passwd).
# The list is a JSON file in the volume, entries are dropped when their session has ended.

our $REVOKED_DEFAULT = '/var/lib/aicli-auth/revoked.json';

sub token_lifetime { return $ENV{AI_AUTH_LIFETIME} // 86400 }
sub session_max    { return $ENV{AI_AUTH_SESSION_MAX} // 2592000 }
sub revoked_file   { return $ENV{AI_AUTH_REVOKED} // $REVOKED_DEFAULT }

# a random id of 16 bytes, base64url
sub new_sid {
    open(my $fh, '<:raw', '/dev/urandom') or die "auth: no /dev/urandom: $!\n";
    my $n = read($fh, my $bytes, 16);
    close $fh;
    die "auth: no random bytes\n" unless defined $n and $n == 16;
    return MIME::Base64::encode_base64url($bytes);
}

sub load_revoked {
    my $file = revoked_file();
    return { sessions => {}, users => {} } unless -e $file;
    my $data = _slurp($file);
    my $r = defined $data ? eval { $JSON->decode($data) } : undef;
    return { sessions => {}, users => {} } unless ref $r eq 'HASH';
    $r->{sessions} //= {};
    $r->{users} //= {};
    return $r;
}

sub save_revoked {
    my ($r, $now) = @_;
    # the sessions that have ended are not needed any more
    for my $sid (keys %{ $r->{sessions} }) {
        delete $r->{sessions}{$sid} if $r->{sessions}{$sid} < $now;
    }
    my $file = revoked_file();
    my ($dir) = $file =~ m{\A(.*)/[^/]*\z};
    if (defined $dir and length $dir and !-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
    }
    _replace($file, $JSON->encode($r), 0600);
    return;
}

# the session of the claims is over for good (logout)
sub revoke_session {
    my ($claims, $now) = @_;
    my $r = load_revoked();
    $r->{sessions}{$claims->{sid}} = ($claims->{ses} // $claims->{iat}) + session_max();
    save_revoked($r, $now);
    return;
}

# every session of the user that began before now is over (the account was deleted or its
# password changed)
sub revoke_user {
    my ($name, $now) = @_;
    my $r = load_revoked();
    $r->{users}{$name} = $now;
    save_revoked($r, $now);
    return;
}

sub is_revoked {
    my ($claims, $r) = @_;
    return 1 if defined $claims->{sid} and exists $r->{sessions}{$claims->{sid}};
    my $since = $r->{users}{$claims->{sub}};
    return 1 if defined $since and ($claims->{ses} // $claims->{iat}) <= $since;
    return 0;
}

# --- the login from another device (a QR code) ---------------------------------------------------
# A logged-in user asks for a ticket: a random 256-bit value, valid for QR_TTL seconds, once, at
# most QR_MAX open per user. It is shown as a QR code of the URL .../login.html#qr=TICKET (the
# fragment is not sent to a server, nor logged). The phone opens the page, which asks the
# service about the ticket (peek: the user, nothing used) and, when the user confirms, redeems it
# (the ticket is used, the phone gets its own session). Only a hash of a ticket is kept, in memory:
# a restart of the service ends the open tickets.

our $QR_TTL = 120;
our $QR_MAX = 3;
our %QR; # sha256 hex of a ticket => { sub, exp }

sub random_b64 {
    my ($n) = @_;
    open(my $fh, '<:raw', '/dev/urandom') or die "auth: no /dev/urandom: $!\n";
    my $got = read($fh, my $bytes, $n);
    close $fh;
    die "auth: no random bytes\n" unless defined $got and $got == $n;
    return MIME::Base64::encode_base64url($bytes);
}

sub _ticket_key { return Digest::SHA::sha256_hex($_[0] // '') }

sub qr_issue {
    my ($user, $now) = @_;
    for my $k (keys %QR) { delete $QR{$k} if $QR{$k}{exp} < $now }
    my $open = grep { $QR{$_}{sub} eq $user } keys %QR;
    return undef if $open >= $QR_MAX;
    my $t = random_b64(32);
    $QR{_ticket_key($t)} = { sub => $user, exp => $now + $QR_TTL };
    return $t;
}

# the user of a ticket that is valid now (nothing is used), or undef
sub qr_peek {
    my ($t, $now) = @_;
    my $e = $QR{_ticket_key($t)} or return undef;
    return $e->{exp} >= $now ? $e->{sub} : undef;
}

# the user of a valid ticket, and the ticket is used: it is not valid again
sub qr_redeem {
    my ($t, $now) = @_;
    my $user = qr_peek($t, $now);
    delete $QR{_ticket_key($t)} if defined $t;
    return $user;
}

# the QR code of a text, as SVG (qrencode, a list: no shell)
sub qr_svg {
    my ($text) = @_;
    open(my $fh, '-|', 'qrencode', '-t', 'SVG', '-m', '2', '-o', '-', $text) or return undef;
    local $/;
    my $svg = <$fh>;
    close $fh;
    return ($? == 0 and defined $svg and $svg =~ m/<svg/) ? $svg : undef;
}

# the claims of the request's token when it is a live session (not revoked, not too old), or undef
sub current_claims {
    my ($rsa, $req, $now) = @_;
    my ($c) = jwt_verify($rsa, token_of($req), $now);
    return undef unless $c;
    return undef if is_revoked($c, load_revoked());
    return undef if $now - ($c->{ses} // $c->{iat}) > session_max();
    return $c;
}

# the JSON object of a request body with a ticket, or undef
sub _ticket_body {
    my ($req) = @_;
    my $d = eval { $JSON->decode($req->{body} // '') };
    return undef unless ref $d eq 'HASH' and defined $d->{ticket} and !ref $d->{ticket};
    return $d->{ticket};
}

# --- HTTP ---------------------------------------------------------------------------------------

sub url_decode {
    my ($s) = @_;
    $s =~ tr/+/ /;
    $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $s;
}

sub parse_form {
    my ($s) = @_;
    my %f;
    for my $pair (split /&/, $s // '') {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k and length $k;
        $f{url_decode($k)} = url_decode($v // '');
    }
    return \%f;
}

# a request out of the bytes read so far: undef while it is not all there
sub parse_request {
    my ($buf) = @_;
    my $end = index($buf, "\r\n\r\n");
    return undef if $end < 0;
    my $head = substr($buf, 0, $end);
    my @lines = split /\r\n/, $head;
    my ($method, $target) = split / /, shift(@lines) // '';
    return undef unless defined $target;
    my %h;
    for my $l (@lines) {
        my ($k, $v) = split /:\s*/, $l, 2;
        $h{lc $k} = $v // '' if defined $k;
    }
    my $len = $h{'content-length'} // 0;
    return undef if length($buf) < $end + 4 + $len;
    my ($path, $query) = split /\?/, $target, 2;
    return {
        method => $method, path => $path, query => parse_form($query), qraw => $query // '',
        headers => \%h, body => substr($buf, $end + 4, $len),
    };
}

sub cookie_of {
    my ($req, $name) = @_;
    for my $c (split /;\s*/, $req->{headers}{cookie} // '') {
        my ($k, $v) = split /=/, $c, 2;
        return $v if defined $k and $k eq $name;
    }
    return undef;
}

sub token_of {
    my ($req) = @_;
    my $auth = $req->{headers}{authorization} // '';
    return $1 if $auth =~ m/\ABearer\s+(\S+)\z/;
    return cookie_of($req, $COOKIE);
}

sub _response {
    my ($status, $text, %o) = @_;
    return [$status, [ @{ $o{headers} // [] } ], $o{body} // "$text\n"];
}

sub _cookie {
    my ($value, $max_age) = @_;
    return join('; ', "$COOKIE=$value", 'Path=/', 'HttpOnly', 'Secure', 'SameSite=Lax', "Max-Age=$max_age");
}


# the answer to a request: [status, [headers], body]. $rsa is the key of the tokens; $now the time.
sub handle {
    my ($rsa, $req, $now) = @_;
    $now //= time();
    my $path = $req->{path} // '';
    my $m = $req->{method} // '';

    if ($path eq '/auth/login' and $m eq 'POST') {
        my $f = parse_form($req->{body});
        my ($user, $password) = ($f->{user} // '', $f->{password} // '');
        if (valid_user($user) and pam_ok($user, $password)) {
            my @roles = roles_of($user);
            my $token = jwt_create($rsa, $user, \@roles, token_lifetime(), $now, $now, new_sid());
            print STDERR "auth: login $user, roles @roles\n";
            return _response(200, '', headers => [
                ['Content-Type', 'application/json'], ['Set-Cookie', _cookie($token, session_max())],
            ], body => $JSON->encode({ user => $user, roles => \@roles })."\n");
        }
        print STDERR "auth: login refused for ".(valid_user($user) ? $user : '(not a user name)')."\n";
        return _response(401, 'unauthorized');
    }
    if ($path eq '/auth/qr/new' and $m eq 'POST') {
        my $c = current_claims($rsa, $req, $now)
            or return _response(401, 'unauthorized');
        my $host = $req->{headers}{host} // '';
        return _response(400, 'no host') unless $host =~ m/\A[A-Za-z0-9.:\[\]-]{1,255}\z/;
        my $proto = ($req->{headers}{'x-forwarded-proto'} // '') eq 'http' ? 'http' : 'https';
        my $t = qr_issue($c->{sub}, $now)
            or return _response(429, 'too many open tickets: use one of them, or wait');
        my $svg = qr_svg("$proto://$host/login.html#qr=$t")
            or return _response(500, 'no QR code (qrencode)');
        print STDERR "auth: qr ticket for $c->{sub} (valid $QR_TTL s)\n";
        return _response(200, '', headers => [['Content-Type', 'application/json']],
            body => $JSON->encode({ svg => $svg, ttl => $QR_TTL })."\n");
    }
    if ($path eq '/auth/qr/peek' and $m eq 'POST') {
        my $t = _ticket_body($req) or return _response(400, 'a ticket is wanted');
        my $user = qr_peek($t, $now) or return _response(401, 'unauthorized');
        return _response(200, '', headers => [['Content-Type', 'application/json']],
            body => $JSON->encode({ user => $user })."\n");
    }
    if ($path eq '/auth/qr/redeem' and $m eq 'POST') {
        my $t = _ticket_body($req) or return _response(400, 'a ticket is wanted');
        my $user = qr_redeem($t, $now);
        return _response(401, 'unauthorized') unless defined $user and getpwnam($user);
        my @roles = roles_of($user);
        my $token = jwt_create($rsa, $user, \@roles, token_lifetime(), $now, $now, new_sid());
        print STDERR "auth: login of $user from another device, roles @roles\n";
        return _response(200, '', headers => [
            ['Content-Type', 'application/json'], ['Set-Cookie', _cookie($token, session_max())],
        ], body => $JSON->encode({ user => $user, roles => \@roles })."\n");
    }
    if ($path eq '/auth/logout' and $m eq 'POST') {
        my ($claims) = jwt_verify($rsa, token_of($req), $now);
        revoke_session($claims, $now) if $claims;
        return _response(200, 'logged out', headers => [['Set-Cookie', _cookie('', 0)]]);
    }
    if ($path eq '/auth/verify') { # nginx's subrequest may use any method
        my ($claims, $why) = jwt_verify($rsa, token_of($req), $now);
        if (!$claims) {
            print STDERR "auth: verify refused: $why\n";
            return _response(401, 'unauthorized');
        }
        if (is_revoked($claims, load_revoked())) {
            print STDERR "auth: verify refused: session revoked ($claims->{sub})\n";
            return _response(401, 'unauthorized');
        }
        my $ses = $claims->{ses} // $claims->{iat};
        if ($now - $ses > session_max()) {
            print STDERR "auth: verify refused: session of $claims->{sub} is too old\n";
            return _response(401, 'unauthorized');
        }
        # the second half of the token's life: a new token, the roles read again
        my @set_cookie;
        if ($now - $claims->{iat} >= token_lifetime() / 2) {
            my $name = $claims->{sub};
            if (!getpwnam($name)) {
                print STDERR "auth: verify refused: no account $name\n";
                return _response(401, 'unauthorized');
            }
            my @roles = roles_of($name);
            my $token = jwt_create($rsa, $name, \@roles, token_lifetime(), $now, $ses, $claims->{sid});
            @set_cookie = (['Set-Cookie', _cookie($token, session_max())]);
            $claims = { sub => $name, roles => \@roles };
        }
        my $need = $req->{query}{role};
        if (defined $need and length $need) {
            my %have = map { $_ => 1 } @{ $claims->{roles} // [] };
            if (!$have{$need}) {
                print STDERR "auth: $claims->{sub} lacks $need\n";
                return _response(403, 'forbidden');
            }
        }
        return _response(200, 'ok', headers => [
            ['X-User', $claims->{sub}], ['X-Roles', join(',', @{ $claims->{roles} // [] })], @set_cookie,
        ]);
    }
    return _response(404, 'not found');
}

sub _send {
    my ($fh, $resp, $method) = @_;
    my ($status, $headers, $body) = @$resp;
    my %reason = (200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
                  404 => 'Not Found', 500 => 'Internal Server Error');
    my $out = "HTTP/1.1 $status ".($reason{$status} // 'Status')."\r\n";
    $out .= "$_->[0]: $_->[1]\r\n" for @$headers;
    $out .= "Content-Length: ".length($body)."\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    $out .= $body unless ($method // '') eq 'HEAD';
    syswrite($fh, $out);
    return;
}

# one select() loop: the listener and the connections; a request is answered when it is
# all there, a connection that sends nothing for ten seconds is dropped
sub serve {
    my ($rsa, $listen_addr) = @_;
    my $listen = IO::Socket::IP->new(
        LocalAddr => $listen_addr, Listen => 16, ReuseAddr => 1, Proto => 'tcp',
    ) or die "auth: cannot listen on $listen_addr: $!\n";
    $listen->blocking(0);
    my $sel = IO::Select->new($listen);
    my %conn; # client => { buf, since }
    my $drop = sub {
        my ($fh) = @_;
        $sel->remove($fh);
        delete $conn{$fh};
        close($fh);
    };
    print STDERR "auth: listening on $listen_addr\n";
    while (1) {
        for my $fh ($sel->can_read(0.5)) {
            if ($fh == $listen) {
                my $c = $listen->accept or next;
                $c->blocking(0);
                $sel->add($c);
                $conn{$c} = { buf => '', since => time() };
                next;
            }
            my $st = $conn{$fh} or next;
            my $n = sysread($fh, my $chunk, 4096);
            if (!$n) { $drop->($fh); next; }
            $st->{buf} .= $chunk;
            if (length($st->{buf}) > $MAX_REQUEST) {
                _send($fh, _response(400, 'bad request'));
                $drop->($fh);
                next;
            }
            my $req = parse_request($st->{buf});
            next unless $req; # not all there yet
            my $resp = eval { handle($rsa, $req) } // _response(500, 'error');
            _send($fh, $resp, $req->{method});
            $drop->($fh);
        }
        for my $fh (keys %conn) {
            $drop->($fh) if time() - $conn{$fh}{since} > 10;
        }
    }
}

sub main {
    my ($arg) = @ARGV;
    if (defined $arg and $arg eq 'user') {
        shift @ARGV;
        return user_command(@ARGV);
    }
    my $key_file = $ENV{AI_AUTH_KEY} // '/var/lib/aicli-auth/jwt-rsa.pem';
    my $rsa = load_key($key_file);
    if (defined $arg and $arg eq '--check') {
        my $t = jwt_create($rsa, 'check', [], 60);
        my ($claims) = jwt_verify($rsa, $t);
        die "auth: the key does not round-trip\n" unless $claims;
        print "auth: key ok ($key_file), PAM service ".($ENV{AI_AUTH_PAM_SERVICE} // 'aicli-auth')."\n";
        return 0;
    }
    restore_accounts();
    serve($rsa, $ENV{AI_AUTH_LISTEN} // '0.0.0.0:9000');
    return 0;
}

exit(main()) unless caller;
1;
