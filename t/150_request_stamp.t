#!/usr/bin/perl
# every request to the model is stamped in the log (UTC time, the user, a checksum of the body), and in the web
# interface the retries of a request go to the server's log, not to the page; the page's error names the request
use strict; use warnings;

use Test::More;
use FindBin;
use Digest::SHA ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $ok = sub {[TestAI::content($_[0] // "fine"), TestAI::done()]};

# the stamp: UTC time, the user, the first 16 hex digits of the SHA-256 of the body
my $tmp = TestAI::setup();
my $body = '{"model":"x","messages":[]}';
my $stamp = ai::request_stamp($body);
like($stamp, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ user=\S+ sum=[0-9a-f]{16}\z/, "stamp: UTC time, user, checksum ($stamp)");
my ($sum) = $stamp =~ m/sum=(\S+)/;
is($sum, substr(Digest::SHA::sha256_hex($body), 0, 16), "stamp: the checksum is the body's SHA-256");
my ($again) = ai::request_stamp($body) =~ m/sum=(\S+)/;
is($again, $sum, "stamp: the same body, the same checksum");
like($stamp, qr/ user=local /, "stamp: the terminal chat's user is 'local'");

# in a web project the user is the account the project is under
{
    local $ai::ROOT = "$tmp/root";
    my $dir = "$ai::SESSIONS_DIR/$ai::AI_SESSION";
    mkdir $dir unless -d $dir;
    open(my $fh, '>', "$dir/cwd") or die "cwd: $!";
    print {$fh} "$ai::ROOT/0123abcd/proj\n";
    close($fh);
    like(ai::request_stamp($body), qr/ user=0123abcd /, "stamp: the user is the account of the session's project");
    unlink "$dir/cwd";
}

# web mode: the retries are in the server's log, stamped, and the page gets no retry event
{
    TestAI::setup(AI_RETRIES => 2, AI_RETRY_DELAY => 0.01, AI_SUMMARY_CHUNKS => 1);
    TestAI::mock_http(TestAI::fail(503, '{"error":{"message":"busy"}}'), $ok->("at last"));
    my @events;
    local $::UI = 1;
    local $ai::EVENT_SINK = sub { push @events, [@_] };
    my $out = TestAI::capture {ai::chat_completion("hi")};
    like($out, qr/REQUEST \S+ user=\S+ sum=[0-9a-f]{16} attempt 1 to /, "web: the first try is in the log, stamped");
    like($out, qr/REQUEST \S+ user=\S+ sum=[0-9a-f]{16} attempt 2 to /, "web: the second try too");
    like($out, qr/retry 1 of 2 in [\d.]+s after: .*busy/, "web: the retry is in the log");
    ok(!(grep {$_->[0] eq 'failed' or $_->[0] eq 'status'} @events), "web: the page gets no retry event");
    is(scalar(@TestAI::REQUESTS), 2, "web: the request was sent twice");
}

# web mode: when the request fails for good, the page's error names the request by its stamp
{
    TestAI::setup(AI_RETRIES => 1, AI_RETRY_DELAY => 0.01, AI_SUMMARY_CHUNKS => 1);
    TestAI::mock_http(TestAI::fail(500), TestAI::fail(500));
    my @page;
    local $::UI = 1;
    local $ai::EVENT_SINK = sub {};
    local $log::on_error = sub { push @page, @_ };
    my $out = TestAI::capture {ai::chat_completion("again")};
    like(join("\n", @page), qr/HTTP status 500.* \(request \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ user=\S+ sum=[0-9a-f]{16}\)/,
        "web: the page's error names the request");
    like($out, qr/REQUEST \S+ user=\S+ sum=[0-9a-f]{16} attempt 2: error: /, "web: the log has the failed try with its stamp");
}

done_testing();
