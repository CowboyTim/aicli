#!/usr/bin/perl
# The auth service: the logins of the web interface, and the check of their JWT for nginx
# (auth_request). It runs in a container of its own, with the local accounts of that
# container (PAM, service aicli-auth). Its endpoints:
#   GET  /auth/login             the login page (a form)
#   POST /auth/login             user=...&password=... -> 200 and the cookie aicli_jwt, or 401
#   POST /auth/logout            the cookie cleared
#   GET  /auth/verify[?role=R]   nginx's check: 200 with X-User and X-Roles (the claims of the
#                                JWT in the cookie aicli_jwt or a Bearer token), 401 when there
#                                is no valid JWT, 403 when the user has not the role R
# The JWT is RS256, signed with the RSA key of AI_AUTH_KEY (made at the first start, kept in
# the volume). Its claims: sub (the user), roles (the groups of the user that start with
# aicli-), iat, exp, iss. Passwords are never logged, nor the tokens.
#
# The service is one select() loop with timeouts, one request at a time per connection, and
# it does no work for a chat: the pieces that check a request (handle()) are plain functions.
#
# Environment:
#   AI_AUTH_LISTEN    host:port to listen on (default 0.0.0.0:9000)
#   AI_AUTH_KEY       the RSA key file (default /var/lib/aicli-auth/jwt-rsa.pem)
#   AI_AUTH_LIFETIME  seconds a login lasts (default 43200)
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

# a Linux account name, as a directory name too: lowercase, no dots or slashes
sub valid_user {
    my ($name) = @_;
    return defined $name && $name =~ m/\A[a-z_][a-z0-9_-]{0,31}\z/ && $name ne 'root';
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
sub user_command {
    my (@args) = @_;
    my $cmd = shift(@args) // '';
    if ($cmd eq 'add') {
        my ($name, @roles) = @args;
        die "auth: a user name: lowercase letters, digits, - and _\n" unless valid_user($name);
        die "auth: $name exists\n" if getpwnam($name);
        for my $r (@roles) { die "auth: $r is no role (aicli-...)\n" unless valid_role($r) }
        $RUN->('useradd', '-M', '-s', '/usr/sbin/nologin', '-U', $name) or die "auth: useradd failed\n";
        for my $r (@roles) {
            $RUN->('groupadd', '-f', $r) or die "auth: groupadd $r failed\n";
            $RUN->('gpasswd', '-a', $name, $r) or die "auth: gpasswd failed\n";
        }
        $RUN->('passwd', $name) or die "auth: no password set for $name\n";
        save_accounts();
        print "auth: $name added (roles: @roles)\n";
    } elsif ($cmd eq 'passwd') {
        my ($name) = @args;
        die "auth: no account ".($name // '')."\n" unless $name and getpwnam($name);
        $RUN->('passwd', $name) or die "auth: passwd failed\n";
        save_accounts();
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
sub jwt_create {
    my ($rsa, $user, $roles, $lifetime, $now) = @_;
    $now //= time();
    my $header = MIME::Base64::encode_base64url($JSON->encode({ alg => 'RS256', typ => 'JWT' }));
    my $payload = MIME::Base64::encode_base64url($JSON->encode({
        iss => $ISSUER, sub => $user, roles => [ @$roles ], iat => $now, exp => $now + $lifetime,
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
        method => $method, path => $path, query => parse_form($query),
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

my $LOGIN_PAGE = <<'HTML';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>aicli login</title>
<style>
body { font-family: system-ui, sans-serif; margin: 0; padding: 16px; background: #fff; color: #111; }
form { max-width: 320px; margin: 10vh auto; display: grid; gap: 10px; }
input, button { font: inherit; padding: 8px; }
#err { color: #b00020; min-height: 1.2em; }
</style></head>
<body><form id="f" method="post" action="/auth/login">
<label>User <input name="user" autocomplete="username" required autofocus></label>
<label>Password <input name="password" type="password" autocomplete="current-password" required></label>
<button>Log in</button><div id="err"></div>
</form>
<script>
document.getElementById("f").addEventListener("submit", function (ev) {
  ev.preventDefault();
  var d = new URLSearchParams(new FormData(ev.target));
  fetch("/auth/login", { method: "POST", body: d, credentials: "same-origin" }).then(function (r) {
    if (r.ok) { location.href = "/"; } else { document.getElementById("err").textContent = "wrong user or password"; }
  });
});
</script></body></html>
HTML

# the answer to a request: [status, [headers], body]. $rsa is the key of the tokens; $now the time.
sub handle {
    my ($rsa, $req, $now) = @_;
    $now //= time();
    my $path = $req->{path} // '';
    my $m = $req->{method} // '';
    my $lifetime = $ENV{AI_AUTH_LIFETIME} // 43200;

    if ($path eq '/auth/login' and $m eq 'GET') {
        return _response(200, '', headers => [['Content-Type', 'text/html; charset=utf-8']], body => $LOGIN_PAGE);
    }
    if ($path eq '/auth/login' and $m eq 'POST') {
        my $f = parse_form($req->{body});
        my ($user, $password) = ($f->{user} // '', $f->{password} // '');
        if (valid_user($user) and pam_ok($user, $password)) {
            my @roles = roles_of($user);
            my $token = jwt_create($rsa, $user, \@roles, $lifetime, $now);
            print STDERR "auth: login $user, roles @roles\n";
            return _response(200, '', headers => [
                ['Content-Type', 'application/json'], ['Set-Cookie', _cookie($token, $lifetime)],
            ], body => $JSON->encode({ user => $user, roles => \@roles })."\n");
        }
        print STDERR "auth: login refused for ".(valid_user($user) ? $user : '(not a user name)')."\n";
        return _response(401, 'unauthorized');
    }
    if ($path eq '/auth/logout' and $m eq 'POST') {
        return _response(200, 'logged out', headers => [['Set-Cookie', _cookie('', 0)]]);
    }
    if ($path eq '/auth/verify' and ($m eq 'GET' or $m eq 'HEAD')) {
        my ($claims, $why) = jwt_verify($rsa, token_of($req), $now);
        if (!$claims) {
            print STDERR "auth: verify refused: $why\n";
            return _response(401, 'unauthorized');
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
            ['X-User', $claims->{sub}], ['X-Roles', join(',', @{ $claims->{roles} // [] })],
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
