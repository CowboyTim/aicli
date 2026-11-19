#!/usr/bin/perl
# the registry's token protocol in auth.pl (what pull and push get, the credentials, the
# token's signature and claims), the certificate the registry checks tokens with, and the
# config texts: the registry only on the LAN (nginx-local), the public nginx refusing it.
use strict; use warnings;
no warnings "once";

use Test::More;
use FindBin;
use File::Temp ();
use Cwd ();
use MIME::Base64 ();
use JSON::XS ();
use Crypt::OpenSSL::RSA ();

require "$FindBin::Bin/../auth.pl";

my $tmp = Cwd::abs_path(File::Temp::tempdir("aicli_reg_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $J = JSON::XS->new->canonical(1)->utf8;
my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);

# the accounts: 'pusher' is in the role aicli-registry, 'reader' is not; 'secret' is the password
{
    no warnings 'redefine';
    *main::pam_ok = sub { my ($u, $p) = @_; return $p eq 'secret' && ($u eq 'pusher' || $u eq 'reader') };
    *main::roles_of = sub { my ($u) = @_; return $u eq 'pusher' ? ('aicli-registry') : ($u eq 'reader' ? ('aicli-user') : ()) };
    *main::valid_user = sub { my ($u) = @_; return defined $u && $u =~ m/\A[a-z][a-z0-9_-]*\z/ };
}

# --- which access a scope gets -------------------------------------------------------------

my @a = registry_access(undef, ['repository:aicli/pod-bash:pull,push']);
is_deeply([map {[$_->{name}, $_->{actions}]} @a], [['aicli/pod-bash', ['pull']]], "anonymous: pull of aicli/, no push");
@a = registry_access('reader', ['repository:aicli/pod-bash:pull,push']);
is_deeply([map {$_->{actions}} @a], [['pull']], "a login without the role: pull only");
@a = registry_access('pusher', ['repository:aicli/pod-bash:pull,push']);
is_deeply([map {$_->{actions}} @a], [['pull', 'push']], "the role aicli-registry: pull and push");
@a = registry_access('pusher', ['repository:other/thing:pull,push']);
is_deeply(\@a, [], "a repository outside aicli/ is granted nothing");
@a = registry_access('pusher', ['repository:aicli/../x:pull', 'repository:aicli/pod-x:delete', 'registry:catalog:*']);
is_deeply(\@a, [], "a path that is not a name, an action that is not pull or push, and another kind of scope: nothing");
@a = registry_access('pusher', ['repository:aicli/a:pull', 'repository:aicli/b/c:push']);
is_deeply([map {$_->{name}} @a], ['aicli/a', 'aicli/b/c'], "several scopes, each its own entry");

# --- the answer of the token route ---------------------------------------------------------

sub req {
    my (%o) = @_;
    my $raw = $o{raw} // '';
    my %q = map { my ($k, $v) = split /=/, $_, 2; ($k => url_decode($v // '')) } grep { length } split /&/, $raw;
    return { method => 'GET', path => '/auth/registry/token', query => \%q, qraw => $raw,
        headers => ($o{auth} ? { authorization => $o{auth} } : {}) };
}
sub basic { return 'Basic '.MIME::Base64::encode_base64("$_[0]:$_[1]", '') }
sub body_of { return JSON::XS->new->utf8->decode($_[0]->[2]) }
sub decoded {
    my ($token) = @_;
    my ($h, $p, $s) = split /\./, $token;
    my $claims = $J->decode(MIME::Base64::decode_base64url($p));
    my $pub = Crypt::OpenSSL::RSA->new_public_key($rsa->get_public_key_string());
    $pub->use_sha256_hash();
    $pub->use_pkcs1_padding() if $pub->can('use_pkcs1_padding');
    return ($claims, $pub->verify("$h.$p", MIME::Base64::decode_base64url($s)) ? 1 : 0);
}

my $now = 1_800_000_000;
my $scope = 'repository:aicli/pod-bash:pull,push';

my $anon = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope"), $now);
is($anon->[0], 200, "anonymous: a token");
my $tok = body_of($anon);
ok($tok->{token} && $tok->{token} eq $tok->{access_token}, "the token, as token and access_token");
is($tok->{expires_in}, 300, "five minutes");
my ($claims, $valid) = decoded($tok->{token});
ok($valid, "the signature checks with the key's public half");
is($claims->{iss}, 'aicli-auth', "the issuer the registry is told");
is($claims->{aud}, 'aicli-registry', "the service");
is($claims->{sub}, '', "no subject for an anonymous request");
is_deeply($claims->{access}, [{type => 'repository', name => 'aicli/pod-bash', actions => ['pull']}], "anonymous: pull only in the token");
ok(length($claims->{jti}) > 10, "a token id");

my $push = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope", auth => basic('pusher', 'secret')), $now);
is($push->[0], 200, "the role aicli-registry, with its password: a token");
my ($pc) = decoded(body_of($push)->{token});
is($pc->{sub}, 'pusher', "the subject is the account");
is_deeply($pc->{access}, [{type => 'repository', name => 'aicli/pod-bash', actions => ['pull', 'push']}], "push in the token");

my $reader = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope", auth => basic('reader', 'secret')), $now);
my ($rc) = decoded(body_of($reader)->{token});
is_deeply($rc->{access}, [{type => 'repository', name => 'aicli/pod-bash', actions => ['pull']}], "a login without the role: pull only");

my $bad = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope", auth => basic('pusher', 'wrong')), $now);
is($bad->[0], 401, "a wrong password: 401, not a token for anonymous");
like(join(' ', map {$_->[1]} @{ $bad->[1] }), qr/Basic realm="aicli-registry"/, "and the challenge says Basic");
my $nouser = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope", auth => basic('no-such-user', 'secret')), $now);
is($nouser->[0], 401, "a user name that is not valid: 401");
my $garbage = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=$scope", auth => 'Basic !!!'), $now);
is($garbage->[0], 401, "credentials that are not base64 of user:password: 401");

my $wrong_service = registry_token_answer($rsa, req(raw => "service=other&scope=$scope"), $now);
is($wrong_service->[0], 400, "another service than aicli-registry: 400");

my $two = registry_token_answer($rsa, req(raw => "service=aicli-registry&scope=repository:aicli/a:pull&scope=repository:aicli/b:pull"), $now);
my ($tc) = decoded(body_of($two)->{token});
is(scalar(@{ $tc->{access} }), 2, "two scope parameters, two entries");

# --- the certificate the registry checks the tokens with ------------------------------------

SKIP: {
    skip "no openssl program here", 5 unless `openssl version 2>/dev/null` =~ m/OpenSSL/;
    my $keyfile = "$tmp/jwt.pem";
    open(my $kf, '>', $keyfile) or die "key: $!";
    print {$kf} $rsa->get_private_key_string();
    close $kf;
    local $ENV{AI_AUTH_REGISTRY_CERT} = "$tmp/token.crt";
    my $cert = registry_cert($keyfile);
    is($cert, "$tmp/token.crt", "the certificate is made where the environment says");
    ok(-s $cert, "and it is there");
    my $text = `openssl x509 -noout -subject -in $cert 2>&1`;
    like($text, qr{CN\s*=\s*aicli-auth}, "for the issuer's name");
    my $pub_text = `openssl x509 -noout -pubkey -in $cert 2>/dev/null`;
    ok($pub_text =~ m/BEGIN PUBLIC KEY/, "with the public key (and no private key in it)");
    my $again = registry_cert($keyfile);
    is($again, $cert, "a second start keeps the certificate");
}

# --- the config texts ------------------------------------------------------------------------

sub slurp { my ($f) = @_; open(my $fh, '<', "$FindBin::Bin/../$f") or die "$f: $!"; local $/; return <$fh> }

my $public = slurp('nginx/nginx.conf.template');
like($public, qr{location = /auth/registry/token \{\s*return 404;}, "the public nginx refuses the token route");
like($public, qr{location /v2/ \{\s*return 404;}, "and the registry's /v2/");
unlike($public, qr{listen 80}, "no plain port here");

my $lan = slurp('nginx/registry.conf.template');
like($lan, qr{location /v2/ \{.*proxy_pass \$registry_upstream;}s, "nginx-local passes /v2/ to the registry");
like($lan, qr{location = /auth/registry/token \{.*proxy_pass \$auth_upstream;}s, "and the token route to the auth service");
like($lan, qr{client_max_body_size 0;}, "no size limit for image layers");
like($lan, qr{ssl_certificate /etc/nginx/certs/live/\$\{PUBLIC_DOMAIN\}/fullchain\.pem}, "TLS with the certificate of the public name");
unlike($lan, qr{location /searxng|location /auth/login|login\.html}, "nothing else is served on the LAN side");

my $compose = slurp('docker-compose.yaml');
my ($registry_svc) = $compose =~ m/\n  registry:\n(.*?)\n  \S/s;
ok(defined $registry_svc, "the registry service is in the compose file");
unlike($registry_svc // '', qr/^\s+ports:/m, "the registry publishes no port");
like($registry_svc // '', qr{REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE: /etc/registry-auth/token\.crt}, "it checks the tokens with the certificate");
my ($lan_svc) = $compose =~ m/\n  nginx-local:\n(.*?)\n  \S/s;
like($lan_svc // '', qr{"\$\{REGISTRY_LAN_ADDR:-127\.0\.0\.1\}:\$\{REGISTRY_PORT:-5443\}:443"}, "nginx-local is published on the LAN address, loopback by default");
like($compose, qr{AICLI_POD_REGISTRY: \$\{PUBLIC_DOMAIN:\?}, "the broker gets the registry name");

my $broker = slurp('broker.json');
like($broker, qr{"image": "\$\{AICLI_POD_REGISTRY\}/pod-bash:latest"}, "the pod images are named by the registry");

# the broker expands the name from its environment, and refuses an unset one
require "$FindBin::Bin/../broker.pl";
{
    local $ENV{AICLI_POD_REGISTRY} = 'example.test:5443/aicli';
    my $b = broker->new(root => $tmp, host_root => "$tmp/h", engine => "$tmp/none", pods => {
        bash => {image => '${AICLI_POD_REGISTRY}/pod-bash:latest', programs => ['bash']} });
    is($b->{pods}{bash}{image}, 'example.test:5443/aicli/pod-bash:latest', "the broker expands the image name from its environment");
}
{
    local $ENV{AICLI_POD_REGISTRY};
    delete $ENV{AICLI_POD_REGISTRY};
    my $ok = eval { broker->new(root => $tmp, host_root => "$tmp/h", engine => "$tmp/none", pods => {
        bash => {image => '${AICLI_POD_REGISTRY}/pod-bash:latest', programs => ['bash']} }); 1 };
    ok(!$ok, "an image variable that is not set is refused");
    like($@, qr/AICLI_POD_REGISTRY/, "and it is named");
}

done_testing();
