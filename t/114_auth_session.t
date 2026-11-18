#!/usr/bin/perl
# auth.pl: the sessions. A token is renewed in its second half (a new cookie, the roles read
# again); a session ends a month after its login; logout revokes the session (every token of
# it); deleting a user or changing its password revokes the user's sessions. The revocation list
# is a file of the test.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();

require "$FindBin::Bin/../auth.pl";

my $COOKIE = 'aicli_jwt';

my $dir = File::Temp::tempdir("aicli_session_XXXXXX", TMPDIR => 1, CLEANUP => 1);
local $ENV{AI_AUTH_REVOKED} = "$dir/revoked.json";
local $ENV{AI_AUTH_LIFETIME} = 3600;
local $ENV{AI_AUTH_SESSION_MAX} = 2592000;

my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $now = time();

sub cookie_req {
    my ($t, $method, $path) = @_;
    $method //= 'GET';
    $path //= '/auth/verify';
    return parse_request("$method $path HTTP/1.1\r\nCookie: $COOKIE=$t\r\n\r\n");
}
sub set_cookie_of {
    my ($resp) = @_;
    for my $h (@{ $resp->[1] }) { return $1 if $h->[0] eq 'Set-Cookie' and $h->[1] =~ m/\A\Q$COOKIE\E=([^;]*)/ }
    return undef;
}

# the claims carry the session
my $t1 = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now);
my ($c1) = jwt_verify($rsa, $t1, $now);
ok(defined $c1->{sid} && length $c1->{sid} >= 20, "a token carries its session id");
is($c1->{ses}, $now, "and the time of the login");
my $t2 = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now);
my ($c2) = jwt_verify($rsa, $t2, $now);
isnt($c1->{sid}, $c2->{sid}, "each login has its own session id");

# a token in its first half is not renewed
my $fresh = handle($rsa, cookie_req($t1), $now + 100);
is($fresh->[0], 200, "a fresh token is accepted");
ok(!defined set_cookie_of($fresh), "and not renewed");

# a token in its second half is renewed: a new cookie, the same session
my $old = jwt_create($rsa, 'nobody', ['aicli-user'], 3600, $now - 2000, $now - 2000, 'sid-renew-test'); # an account of the system
my $renewed = handle($rsa, cookie_req($old), $now);
is($renewed->[0], 200, "a token past half its life is accepted");
my $new = set_cookie_of($renewed);
ok(defined $new, "and renewed: a new cookie");
isnt($new, $old, "the new token is another token");
my ($nc) = jwt_verify($rsa, $new, $now);
is($nc->{sid}, 'sid-renew-test', "in the same session");
is($nc->{ses}, $now - 2000, "which began at the login");

# a session older than a month needs a login again
my $ended = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now, $now - 2592001, 'sid-old');
is(handle($rsa, cookie_req($ended), $now)->[0], 401, "a session older than a month: 401");

# logout revokes the session, every token of it
my $logged = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now, $now, 'sid-logout');
is(handle($rsa, cookie_req($logged), $now)->[0], 200, "before the logout the token works");
my $out = handle($rsa, cookie_req($logged, 'POST', '/auth/logout'), $now);
is($out->[0], 200, "logout answers");
is(handle($rsa, cookie_req($logged), $now)->[0], 401, "after the logout the token is refused");
my $other = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now, $now, 'sid-logout');
is(handle($rsa, cookie_req($other), $now)->[0], 401, "and another token of the same session too");
my $second = jwt_create($rsa, 'alice', ['aicli-user'], 3600, $now, $now, 'sid-still-fine');
is(handle($rsa, cookie_req($second), $now)->[0], 200, "another session of the user is not touched");

# a deleted user: the sessions that began before the deletion are refused
my $before = jwt_create($rsa, 'bob', ['aicli-user'], 3600, $now - 10, $now - 10, 'sid-bob');
my $r_before = handle($rsa, cookie_req($before), $now);
is($r_before->[0], 200, "bob's session before the change works");
revoke_user('bob', $now);
is(handle($rsa, cookie_req($before), $now)->[0], 401, "after the revocation of bob, that session is refused");
my $after = jwt_create($rsa, 'bob', ['aicli-user'], 3600, $now + 5, $now + 5, 'sid-bob-2');
is(handle($rsa, cookie_req($after), $now + 5)->[0], 200, "a session that began after it is fine");

# a renewal for an account that is gone: refused
my $gone = jwt_create($rsa, 'no-such-user-xyz', ['aicli-user'], 3600, $now - 2000, $now - 2000, 'sid-gone');
is(handle($rsa, cookie_req($gone), $now)->[0], 401, "a renewal of an account that does not exist: 401");

# the list: the file is private, and the sessions that have ended leave it
ok(-e "$dir/revoked.json", "the revocation list is a file");
is((stat "$dir/revoked.json")[2] & 0777, 0600, "with mode 0600");
my $r = load_revoked();
ok(exists $r->{sessions}{'sid-logout'}, "the revoked session is in the list");
save_revoked($r, $now + 2592000 + 10);
ok(!exists load_revoked()->{sessions}{'sid-logout'}, "and gone once the session has ended");

done_testing();
