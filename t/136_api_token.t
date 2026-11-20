#!/usr/bin/perl
# auth.pl: the API tokens of the services behind nginx (/api/flm/). POST /auth/api/token gives a
# JWT with the service as its aud, from a live login only (never from an API token); /auth/verify
# takes it with ?aud=<service> and gives the user; an API token is no login, and a login is no
# API token. Logging out ends the API tokens of the session.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();

require "$FindBin::Bin/../auth.pl";
no strict 'vars'; no warnings 'once';

my $dir = File::Temp::tempdir("aicli_api_XXXXXX", TMPDIR => 1, CLEANUP => 1);
local $ENV{AI_AUTH_REVOKED} = "$dir/revoked.json";
my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $now = time();

# a request: a cookie (a login) or a Bearer token (an API token), a path with its query
sub request {
    my (%o) = @_;
    my $h = "$o{method} $o{path} HTTP/1.1\r\nHost: ai.example.test\r\n";
    $h .= "Cookie: aicli_jwt=$o{cookie}\r\n" if defined $o{cookie};
    $h .= "Authorization: Bearer $o{bearer}\r\n" if defined $o{bearer};
    $h .= "Content-Length: 0\r\n\r\n";
    return parse_request($h);
}
sub body_of { my ($r) = @_; return eval { $JSON->decode($r->[2]) } }

my $login = jwt_create($rsa, 'nobody', ['aicli-user'], 3600, $now, $now, 'sid-login');

# the token route: from a login
my $r = handle($rsa, request(method => 'POST', path => '/auth/api/token', cookie => $login), $now);
is($r->[0], 200, "a login gets an API token");
my $api = body_of($r)->{token};
ok(defined $api, "the answer has the token");
my ($c) = jwt_verify($rsa, $api, $now);
ok($c, "the token is a valid JWT of this server");
is($c->{aud}, 'flm', "for flm");
is($c->{sub}, 'nobody', "of the user of the login");
is($c->{sid}, 'sid-login', "in the login's session (its sid)");
is($c->{exp} - $c->{iat}, 604800, "a week by default");
is(body_of($r)->{expires_in}, 604800, "and says so");

is(handle($rsa, request(method => 'POST', path => '/auth/api/token'), $now)->[0], 401, "no login: no API token");
is(handle($rsa, request(method => 'POST', path => '/auth/api/token', cookie => $login, bearer => 'x.y.z'), $now)->[0], 401,
    "a Bearer that is not a token is the credential: no fallback to the login cookie");
is(handle($rsa, request(method => 'POST', path => '/auth/api/token?aud=nope', cookie => $login), $now)->[0], 400,
    "a service that takes no API token: refused");
is(handle($rsa, request(method => 'POST', path => '/auth/api/token', bearer => $api), $now)->[0], 401,
    "an API token makes no API token");
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', bearer => $api), $now)->[0], 200,
    "an API token: the user, with ?aud=flm");

# the verify rules
my $v = handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', bearer => $api), $now);
my %h = map {@$_} grep {ref eq 'ARRAY' and @$_ == 2} @{ $v->[1] };
is($h{'X-User'}, 'nobody', "the service gets the user (X-User)");
ok(!(grep { $_->[0] eq 'Set-Cookie' } @{ $v->[1] }), "no cookie is set for an API token (no renewal)");
is(handle($rsa, request(method => 'GET', path => '/auth/verify', bearer => $api), $now)->[0], 401,
    "an API token is no login: the page is refused");
is(handle($rsa, request(method => 'GET', path => '/auth/verify', cookie => $api), $now)->[0], 401,
    "an API token in the cookie is no login either");
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=other', bearer => $api), $now)->[0], 401,
    "a token of flm is not one of another service");
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', cookie => $login), $now)->[0], 401,
    "a login is not an API token: refused for flm");
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm'), $now)->[0], 401, "no token: refused");

# a token past its time, and for a user that is not an account
my $late = $now + 604800 + 10;
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', bearer => $api), $late)->[0], 401,
    "an API token past its time is refused");
my $ghost = jwt_create($rsa, 'nosuchuserhere', ['aicli-user'], 3600, $now, $now, 'sid-ghost', 'flm');
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', bearer => $ghost), $now)->[0], 401,
    "an API token of a user that is not an account: refused");

# logging out ends the session, and so its API tokens
my $logout = handle($rsa, request(method => 'POST', path => '/auth/logout', cookie => $login), $now);
is($logout->[0], 200, "logged out");
is(handle($rsa, request(method => 'GET', path => '/auth/verify?aud=flm', bearer => $api), $now)->[0], 401,
    "after the logout the API token is refused");

done_testing();
