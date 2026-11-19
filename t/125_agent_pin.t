#!/usr/bin/perl
# the agent's optional pin of the broker's public key (sha256//BASE64, checked in the agent's
# arguments): the format, and the agent's start with a pin it can use. The pin itself is
# checked by libcurl on a TLS connection; no TLS server runs in this test.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";

use utils ();
use remote_agent;

my $KEY = 'A' x 43 . '=';   # 43 base64 characters and the padding: the shape of a SHA-256 digest
my $base = {url => 'https://example.org/agents', name => 'strix', programs => ['perl'], work => '/tmp', token => 'agent-token-0123456789abcdef'};

ok(remote_agent->new(%$base), "an agent without a pin");
ok(remote_agent->new(%$base, pin => "sha256//$KEY"), "an agent with a pin of the right shape");

for my $bad ('sha1//'.('A' x 27).'=', "sha256//$KEY;", 'sha256//short', "$KEY", "sha256//".('A' x 43)) {
    eval { remote_agent->new(%$base, pin => $bad) };
    like($@, qr/a pin is sha256\/\/BASE64/, "a pin of the wrong shape is refused: $bad");
}

eval { remote_agent->new(%$base, token => 'short') };
like($@, qr/a token is needed/, "a token that is too short is refused");
eval { remote_agent->new(%{{%$base, token => undef}}) };
like($@, qr/a token is needed/, "no token is refused");

done_testing();
