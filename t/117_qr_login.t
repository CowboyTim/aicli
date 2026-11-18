#!/usr/bin/perl
# auth.pl: the login from another device. A ticket is made for a live session only, lasts
# QR_TTL, is used once, is kept as a hash, and at most QR_MAX are open per user; peek uses
# nothing; redeem gives the phone its own session. The QR code is an SVG (qrencode).
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();

require "$FindBin::Bin/../auth.pl";
no strict 'vars'; no warnings 'once'; # the globals of auth.pl (%QR, $QR_TTL, $JSON)

my $COOKIE = 'aicli_jwt';
my $dir = File::Temp::tempdir("aicli_qr_XXXXXX", TMPDIR => 1, CLEANUP => 1);
local $ENV{AI_AUTH_REVOKED} = "$dir/revoked.json";
my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $now = time();

sub req_with_cookie {
    my ($t, $method, $path, $body) = @_;
    $body //= '';
    my $h = "$method $path HTTP/1.1\r\nHost: ai.example.test\r\nX-Forwarded-Proto: https\r\n";
    $h .= "Cookie: $COOKIE=$t\r\n" if defined $t;
    $h .= "Content-Length: ".length($body)."\r\n\r\n$body";
    return parse_request($h);
}

my $live = jwt_create($rsa, 'nobody', ['aicli-user'], 3600, $now);

# the tickets
my $t1 = qr_issue('nobody', $now);
ok(defined $t1 && length $t1 >= 40, "a ticket is made");
ok(!exists $QR{$t1}, "the ticket itself is not kept (its hash is)");
is(qr_peek($t1, $now), 'nobody', "peek gives the user of the ticket");
is(qr_peek($t1, $now), 'nobody', "and peek uses nothing: it still works");
is(qr_redeem($t1, $now), 'nobody', "redeem gives the user");
is(qr_redeem($t1, $now), undef, "a second redeem of the same ticket is refused");
is(qr_peek($t1, $now), undef, "and peek after the use is refused");

my $old = qr_issue('nobody', $now - 500);
is(qr_redeem($old, $now), undef, "a ticket past its time is refused");
is(qr_peek('not-a-ticket', $now), undef, "an unknown ticket is refused");

my @many = map { qr_issue('nobody', $now) } 1 .. 3;
ok(!grep({ !defined } @many), "three tickets of one user are open");
is(qr_issue('nobody', $now), undef, "a fourth is refused");
ok(defined qr_issue('nobody', $now + $QR_TTL + 1), "after the time the old ones are gone");

# the QR code: an SVG
my $svg = qr_svg('https://ai.example.test/login.html#qr=abc');
ok(defined $svg && $svg =~ m/<svg/, "the QR code is an SVG");

# the routes
my $r = handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/new'), $now);
is($r->[0], 401, "a ticket needs a live session (no token: 401)");
$r = handle($rsa, req_with_cookie($live, 'POST', '/auth/qr/new'), $now);
is($r->[0], 200, "a ticket for a live session: 200");
my $answer = $JSON->decode($r->[2]);
like($answer->{svg}, qr/<svg/, "with the QR code");
is($answer->{ttl}, $QR_TTL, "and its time");
my $body = $JSON->encode({ ticket => $t1 });
is(handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/peek', $body), $now)->[0], 401, "peek of a used ticket: 401");

my $t2 = qr_issue('nobody', $now);
$body = $JSON->encode({ ticket => $t2 });
$r = handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/peek', $body), $now);
is($r->[0], 200, "peek of a ticket: 200");
is($JSON->decode($r->[2])->{user}, 'nobody', "with the user, and nothing else");
$r = handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/redeem', $body), $now);
is($r->[0], 200, "redeem: 200");
my %h = map { $_->[0] => $_->[1] } @{ $r->[1] };
like($h{'Set-Cookie'} // '', qr/\A\Q$COOKIE\E=[^;]+; Path=\/; HttpOnly; Secure; SameSite=Lax/, "with the cookie of a new session");
my ($claims) = jwt_verify($rsa, ($h{'Set-Cookie'} =~ m/\Q$COOKIE\E=([^;]*)/)[0], $now);
ok(defined $claims && $claims->{sub} eq 'nobody', "the cookie is the user's");
my ($live_claims) = jwt_verify($rsa, $live, $now);
isnt($claims->{sid}, $live_claims->{sid}, "in a session of its own");
$r = handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/redeem', $body), $now);
is($r->[0], 401, "the same ticket again: 401");

my $bad = qr_issue('no-such-user-xyz', $now);
$body = $JSON->encode({ ticket => $bad });
is(handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/redeem', $body), $now)->[0], 401, "a ticket of an account that is gone: 401");
is(handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/redeem', 'not json'), $now)->[0], 400, "a body that is not JSON: 400");
is(handle($rsa, req_with_cookie(undef, 'POST', '/auth/qr/peek', '{"ticket":{"a":1}}'), $now)->[0], 400, "a ticket that is no string: 400");

done_testing();
