#!/usr/bin/perl
# auth.pl: the RSA key and the JWT (create, verify, the refusals), the request and the
# form parsing, the roles, the login refusals, the verify answers (401, 403, 200 with the
# user and roles) and the HTTP service over a socket (one request per connection).
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use IO::Socket::INET ();
use Socket ();
use POSIX ();
use JSON::XS ();
use MIME::Base64 ();
use Crypt::OpenSSL::RSA ();

my $script = "$FindBin::Bin/../auth.pl";
require $script;

my $COOKIE = "aicli_jwt";
my $JSON = JSON::XS->new->canonical->allow_nonref;

my $dir = File::Temp::tempdir("aicli_auth_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $key_file = "$dir/jwt-rsa.pem";
local $ENV{AI_AUTH_KEY} = $key_file;

# the key: made once, kept, mode 0600
my $rsa = load_key($key_file);
ok(-e $key_file, "the key is written");
is((stat $key_file)[2] & 0777, 0600, "with mode 0600");
my $again = load_key($key_file);
is($again->get_private_key_string(), $rsa->get_private_key_string(), "and read back at the next start");

# the JWT
my $now = 1_800_000_000;
my $t = jwt_create($rsa, 'alice', ['aicli-user'], 600, $now);
my ($claims, $why) = jwt_verify($rsa, $t, $now + 10);
is($why, undef, "a fresh token verifies");
is($claims->{sub}, 'alice', "the user is the subject");
is_deeply($claims->{roles}, ['aicli-user'], "with the roles");
is($claims->{iss}, 'aicli-auth', "and the issuer");

(undef, $why) = jwt_verify($rsa, $t, $now + 601);
is($why, 'expired', "a token past its expiry is refused");

my ($h, $p, $s) = split /\./, $t;
my $forged = MIME::Base64::encode_base64url($JSON->encode({ iss => 'aicli-auth', sub => 'root', roles => ['aicli-admin'], iat => $now, exp => $now + 600 }));
(undef, $why) = jwt_verify($rsa, "$h.$forged.$s", $now + 10);
is($why, 'bad signature', "a changed payload is refused");

my $none = MIME::Base64::encode_base64url($JSON->encode({ alg => 'none', typ => 'JWT' }));
(undef, $why) = jwt_verify($rsa, "$none.$p.$s", $now + 10);
is($why, 'algorithm not RS256', "alg none is refused");

my $other_key = Crypt::OpenSSL::RSA->generate_key(2048);
(undef, $why) = jwt_verify($other_key, $t, $now + 10);
is($why, 'bad signature', "a token of another key is refused");

(undef, $why) = jwt_verify($rsa, undef, $now);
is($why, 'no token', "no token");
(undef, $why) = jwt_verify($rsa, 'a.b', $now);
is($why, 'not a compact JWS', "not a compact JWS");

# the accounts and the roles
ok(valid_user('alice'), "a plain account name");
ok(valid_user('dev-2_x'), "with a dash and an underscore");
ok(!valid_user('../etc'), "a path is no account");
ok(!valid_user('Alice'), "upper case is no account");
ok(!valid_user('root'), "root is no account of the web");
ok(!valid_user('a' x 33), "too long");
ok(!valid_user(undef), "undef is no account");
is_deeply([roles_of('no-such-user-xyz')], [], "an unknown user has no roles");
ok(!pam_ok('no-such-user-xyz', 'wrong'), "an unknown user is not logged in (PAM)");
ok(!pam_ok('root', ''), "an empty password is refused without asking PAM");

# the request and the form
my $raw = "POST /auth/login HTTP/1.1\r\nHost: x\r\nContent-Length: 27\r\n\r\nuser=alice&password=a%2Bb+c";
my $req = parse_request($raw);
ok($req, "a whole request parses");
is($req->{method}, 'POST', "the method");
is($req->{path}, '/auth/login', "the path");
is(parse_form($req->{body})->{password}, 'a+b c', "the form is decoded (%2B and +)");
ok(!parse_request(substr($raw, 0, 40)), "a part of a request is not a request yet");
ok(!parse_request("GET /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"), "a body that is not all there is not a request");

my $vreq = parse_request("GET /auth/verify?role=aicli-admin HTTP/1.1\r\nCookie: a=1; $COOKIE=$t; b=2\r\n\r\n");
is(token_of($vreq), $t, "the token of the cookie");
my $breq = parse_request("GET /x HTTP/1.1\r\nAuthorization: Bearer $t\r\n\r\n");
is(token_of($breq), $t, "the token of a Bearer header");

# the answers of verify
my $resp = handle($rsa, $vreq, $now + 10);
is($resp->[0], 403, "a user without the role gets 403");
my $ok = handle($rsa, parse_request("GET /auth/verify HTTP/1.1\r\nCookie: $COOKIE=$t\r\n\r\n"), $now + 10);
is($ok->[0], 200, "a valid token gets 200");
my %hdr = map { $_->[0] => $_->[1] } @{ $ok->[1] };
is($hdr{'X-User'}, 'alice', "with X-User");
is($hdr{'X-Roles'}, 'aicli-user', "and X-Roles");
my $none_resp = handle($rsa, parse_request("GET /auth/verify HTTP/1.1\r\n\r\n"), $now);
is($none_resp->[0], 401, "no token: 401");
my $exp_resp = handle($rsa, parse_request("GET /auth/verify HTTP/1.1\r\nCookie: $COOKIE=$t\r\n\r\n"), $now + 700);
is($exp_resp->[0], 401, "an expired token: 401");
my $role_ok = handle($rsa, parse_request("GET /auth/verify?role=aicli-user HTTP/1.1\r\nCookie: $COOKIE=$t\r\n\r\n"), $now + 10);
is($role_ok->[0], 200, "the role the user has: 200");

# the login refusals (no account, no password) and the cookie that logout clears
my $bad_body = "user=no-such-user-xyz&password=x";
my $bad = handle($rsa, parse_request("POST /auth/login HTTP/1.1\r\nContent-Length: ".length($bad_body)."\r\n\r\n$bad_body"), $now);
is($bad->[0], 401, "a login that PAM refuses: 401");
my $login_page = handle($rsa, parse_request("GET /auth/login HTTP/1.1\r\n\r\n"), $now);
is($login_page->[0], 200, "the login page");
like($login_page->[2], qr{action="/auth/login"}, "with the form");
my $logout = handle($rsa, parse_request("POST /auth/logout HTTP/1.1\r\n\r\n"), $now);
like(join(' ', map { $_->[1] } @{ $logout->[1] }), qr/Max-Age=0/, "logout clears the cookie");
is(handle($rsa, parse_request("GET /nothing HTTP/1.1\r\n\r\n"), $now)->[0], 404, "other paths: 404");

# the service over a socket: one request per connection, verify answers
my $probe = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp') or die "probe: $!";
my $port = $probe->sockport;
$probe->close;
my $pid = fork() // die "fork: $!";
if (!$pid) {
    serve($rsa, "127.0.0.1:$port");
    POSIX::_exit(0);
}
my $live = jwt_create($rsa, 'alice', ['aicli-user'], 600); # the service reads the real clock
my $got;
for (1 .. 50) {
    $got = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    last if $got;
    select(undef, undef, undef, 0.1);
}
ok($got, "the service listens");
sub ask {
    my ($raw) = @_;
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp') or return '';
    print {$c} $raw;
    local $/;
    my $answer = <$c>;
    close $c;
    return $answer // '';
}
like(ask("GET /auth/verify HTTP/1.1\r\nHost: x\r\n\r\n"), qr{\AHTTP/1\.1 401 }, "over the socket: no token, 401");
like(ask("GET /auth/verify HTTP/1.1\r\nHost: x\r\nCookie: $COOKIE=$live\r\n\r\n"), qr{\AHTTP/1\.1 200 .*X-User: alice}s, "over the socket: the token, 200 with the user");
like(ask("GET /auth/verify HTTP/1.1\r\nCookie: $COOKIE=$live\r\n\r\n"), qr{X-Roles: aicli-user}, "and the roles");
like(ask("POST /auth/login HTTP/1.1\r\nHost: x\r\nContent-Length: ".length("user=no-such&password=x")."\r\n\r\nuser=no-such&password=x"), qr{\AHTTP/1\.1 401 }, "a login over the socket");
kill 'TERM', $pid;
waitpid($pid, 0);

done_testing();
