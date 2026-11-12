#!/usr/bin/perl
# web tools (fetch, search) and which proxy is used for what; /retry, /rewind
use strict; use warnings;

use Test::More;
use FindBin;
use Time::HiRes ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;
use FakeLLM;

sub tool {
    my ($name, @args) = @_;
    return ai::execute_tool($name, uc($name), \@args);
}

# the HTTP layer replaced: answers come from %PAGES, by URL
my (@ASKED, %PAGES, $INFLIGHT, $MAX_INFLIGHT);
my $real_http = \&loop::http;
sub mock_web {
    %PAGES = @_;
    @ASKED = ();
    ($INFLIGHT, $MAX_INFLIGHT) = (0, 0);
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        push @ASKED, {%r};
        my $page = $PAGES{$r{url}} // {code => 404, body => "not found"};
        my $req = {%r, code => 0, error => undef, headers => {}, body => '', url_final => $page->{final} // $r{url}};
        $INFLIGHT++;
        $MAX_INFLIGHT = $INFLIGHT if $INFLIGHT > $MAX_INFLIGHT;
        loop::timer($page->{delay} // 0.01, sub {
            my ($aborted) = @_;
            $INFLIGHT--;
            $req->{code}    = $aborted ? 0 : ($page->{code} // 200);
            $req->{headers} = {'content-type' => $page->{type} // 'text/html; charset=utf-8'};
            $req->{body}    = $page->{body} // '';
            if($r{max_size} and length($req->{body}) > $r{max_size}){
                $req->{body} = substr($req->{body}, 0, $r{max_size});
                $req->{too_big} = 1;
            }
            $req->{error} = $aborted ? "interrupted" : $req->{too_big} ? "Failed writing received data" : $req->{code} != 200 ? "HTTP status $req->{code}" : undef;
            $r{on_done}->($req);
        });
        return $req;
    };
}

# which proxy for what
{
    TestAI::setup();
    is(utils::proxy_for('ai'), undef, "proxy: none by default");
    is(utils::proxy_for('web'), undef, "proxy: none for the web either");
    {
        local @::ORIG_ENV{qw(AI_PROXY AI_WEB_PROXY)} = ("http://llm-proxy:3128", "socks5h://web-proxy:1080");
        is(utils::proxy_for('ai'), "http://llm-proxy:3128", "proxy: AI_PROXY for the LLM API");
        is(utils::proxy_for('web'), "socks5h://web-proxy:1080", "proxy: AI_WEB_PROXY for the web tools, a separate one");
    }
    {
        local $::ORIG_ENV{AI_WEB_PROXY} = "http://web-proxy:8080";
        is(utils::proxy_for('ai'), undef, "proxy: the web proxy is not used for the LLM API");
        local $::ORIG_ENV{AI_PROXY} = "http://llm-proxy:3128";
        local $::ORIG_ENV{AI_WEB_PROXY};
        delete $::ORIG_ENV{AI_WEB_PROXY};
        is(utils::proxy_for('web'), undef, "proxy: the LLM proxy is not used for the web");
    }
    {
        local $::ORIG_ENV{HTTPS_PROXY} = "http://env-proxy:3128";
        is(utils::proxy_for('ai'), "http://env-proxy:3128", "proxy: HTTPS_PROXY is the fallback for the LLM API");
        is(utils::proxy_for('web'), "http://env-proxy:3128", "proxy: and for the web");
        foreach my $none ('none', 'off', 'direct', ''){
            local @::ORIG_ENV{qw(AI_PROXY AI_WEB_PROXY)} = ($none, $none);
            is(utils::proxy_for('ai'), undef, "proxy: AI_PROXY='$none' means no proxy, whatever the environment says");
            is(utils::proxy_for('web'), undef, "proxy: AI_WEB_PROXY='$none' too");
        }
        local $::ORIG_ENV{AI_PROXY} = "http://llm-proxy:3128";
        is(utils::proxy_for('ai'), "http://llm-proxy:3128", "proxy: AI_PROXY wins over HTTPS_PROXY");
        is(utils::proxy_for('web'), "http://env-proxy:3128", "proxy: the web keeps the one of the environment");
    }
    {
        local $::ORIG_ENV{http_proxy} = "http://lower:1";
        is(utils::proxy_for('web'), "http://lower:1", "proxy: lowercase http_proxy is understood");
    }
}

# a page as text
{
    my $html = join("\n",
        '<html><head><title> Perl &amp; friends </title><style>p {color: red}</style></head>',
        '<body><script>var x = "<p>not text</p>";</script><!-- a comment -->',
        '<h1>Welcome</h1><p>Some <b>bold</b> text &lt;here&gt;&nbsp;and&#33; &#x263a;</p>',
        '<ul><li>one</li><li><a href="/two.html">two <i>italic</i></a></li></ul>',
        '<a href="#top">top</a> <a href=\'https://example.org/x\'>out</a> <a href="javascript:void(0)">js</a>',
        '<table><tr><td>a</td><td>b</td></tr></table><div>last</div></body></html>');
    my $t = ai::html_to_text($html, "text/html; charset=utf-8");
    utf8::decode($t);
    like($t, qr/\ATitle: Perl & friends\n\n/, "html: title first, entities decoded");
    like($t, qr/^# Welcome$/m, "html: heading marked");
    like($t, qr/^Some bold text <here> and! \x{263a}$/m, "html: inline tags gone, entities and numeric entities decoded");
    like($t, qr/^- one\n- \[two italic\]\(\/two\.html\)$/m, "html: list items, links as [text](url)");
    like($t, qr/top \[out\]\(https:\/\/example\.org\/x\) js/, "html: anchors and javascript links are just text");
    like($t, qr/^a \| b \|$/m, "html: table cells separated");
    unlike($t, qr/not text|color: red|a comment|var x/, "html: scripts, styles and comments are gone");
    unlike($t, qr/<\/|<(?:p|b|i|a|li|ul|div|td|h1)\b|\n\n\n/, "html: no tags left, no piles of empty lines");
    is(ai::html_to_text("caf\xe9 <b>ol\xe9</b>", "text/html; charset=iso-8859-1"), "caf\xc3\xa9 ol\xc3\xa9\n", "html: other charsets become UTF-8");
    is(ai::html_to_text("plain &amp; simple"), "plain & simple\n", "html: no title, no problem");
}

# fetch
{
    TestAI::setup(AI_WEB_PROXY => "http://web-proxy:8080", AI_PROXY => "http://llm-proxy:3128");
    local $ai::api_key = "sk-secret";
    mock_web(
        "https://example.org/page"  => {body => "<title>Hi</title><p>Hello <a href='/next'>next</a></p>", final => "https://example.org/page/"},
        "https://example.org/data"  => {type => "application/json", body => '{"a":1}'},
        "https://example.org/img"   => {type => "image/png", body => "\x89PNG"},
        "https://example.org/big"   => {type => "text/plain", body => "x" x 5000},
        "https://example.org/gone"  => {code => 410, body => "<h1>Gone   for good</h1>"},
        "https://example.org/nohdr" => {type => "", body => "<!DOCTYPE html><p>sniffed</p>"},
    );
    my ($out, $err) = tool("fetch", " https://example.org/page \n");
    is($err, undef, "fetch: ok");
    is($out, "URL: https://example.org/page/\n\nTitle: Hi\n\nHello [next](/next)\n", "fetch: final URL and the page as text");
    my $r = $ASKED[0];
    is($r->{proxy}, "http://web-proxy:8080", "fetch: through the web proxy, not the one of the LLM");
    ok(!$r->{api_key}, "fetch: the API key is not sent");
    ok(!grep({m/Authorization|sk-secret/} @{$r->{headers}}), "fetch: no Authorization header");
    ok(scalar(grep {m/^User-Agent: /} @{$r->{headers}}), "fetch: has a User-Agent");
    is_deeply([@{$r}{qw(follow timeout connect_timeout max_size)}], [5, 30, 10, 2_000_000], "fetch: redirects, timeouts and a size limit");
    ok(!defined $r->{method} || lc($r->{method}) eq 'get', "fetch: a GET");

    is((tool("fetch", "https://example.org/data"))[0], "URL: https://example.org/data\n\n{\"a\":1}", "fetch: what is not HTML comes as it is");
    is((tool("fetch", "https://example.org/nohdr"))[0], "URL: https://example.org/nohdr\n\nsniffed\n", "fetch: HTML without a content type is recognized");
    like((tool("fetch", "https://example.org/img"))[1], qr/not a text: image\/png/, "fetch: no binary files");
    like((tool("fetch", "https://example.org/gone"))[1], qr/HTTP status 410: <h1>Gone for good<\/h1>/, "fetch: HTTP errors with the start of the body");
    like((tool("fetch", "https://example.org/nothing"))[1], qr/HTTP status 404/, "fetch: 404");
    {
        local $::ORIG_ENV{AI_WEB_MAX_SIZE} = 1000;
        local $::ORIG_ENV{AI_WEB_TIMEOUT} = 7;
        ($out, $err) = tool("fetch", "https://example.org/big");
        is($err, undef, "fetch: a page over the limit is not an error");
        like($out, qr/\AURL: \S+\n\nx{1000}\n\[\.\.\. cut here, there is more than 1000 bytes \.\.\.\]\n\z/, "fetch: it is cut, and says so");
        is($ASKED[-1]{timeout}, 7, "fetch: AI_WEB_TIMEOUT");
    }
    tool("fetch", "example.org/page");
    is($ASKED[-1]{url}, "https://example.org/page", "fetch: a bare host gets https://");
    my $n = @ASKED;
    like((tool("fetch", $_))[1], qr/need an http or https URL/, "fetch: refuses '$_'")
        for "file:///etc/passwd", "ftp://example.org/x", "/etc/passwd", "", "https://a b", "gopher://x";
    is(scalar(@ASKED), $n, "fetch: and asks nothing for those");
    {
        local $::ORIG_ENV{AI_WEB_PROXY} = "none";
        tool("fetch", "https://example.org/page");
        is($ASKED[-1]{proxy}, "", "fetch: AI_WEB_PROXY=none goes direct");
    }
}

# search
{
    TestAI::setup(AI_WEB_PROXY => "http://web-proxy:8080");
    ok(!tools::available("search"), "search: not available without AI_SEARXNG_URL");
    ok(tools::available("fetch") && tools::available("bash"), "search: the others are");
    like((tool("search", "perl"))[1], qr/no search engine is set up \(AI_SEARXNG_URL\)/, "search: says what is missing");

    local $::ORIG_ENV{AI_SEARXNG_URL} = "http://searx.lan:8888/";
    ok(tools::available("search"), "search: available with AI_SEARXNG_URL");
    my $results = JSON::XS::encode_json({results => [
        (map {{title => "Result  $_", url => "https://example.org/$_", content => "About\n number $_ ".("z" x ($_ == 2 ? 400 : 0))}} 1 .. 12),
        {title => "no url"},
    ]});
    my $q = "http://searx.lan:8888/search?q=perl%20select%28%29%20%26%20caf%C3%A9&format=json";
    mock_web(
        $q => {type => "application/json", body => $results},
        "http://searx.lan:8888/search?q=nothing&format=json" => {type => "application/json", body => '{"results":[]}'},
        "http://searx.lan:8888/search?q=denied&format=json"  => {code => 403, body => "Forbidden"},
        "http://searx.lan:8888/search?q=broken&format=json"  => {body => "<html>oops</html>"},
    );
    my ($out, $err) = tool("search", " perl   select() & caf\xc3\xa9 ");
    is($err, undef, "search: ok");
    is($ASKED[0]{url}, $q, "search: query escaped, JSON asked for");
    is($ASKED[0]{proxy}, "", "search: the SearXNG instance is asked directly, not through the web proxy");
    like($out, qr/\A1\. Result 1\n   https:\/\/example\.org\/1\n   About number 1\n\n2\. Result 2\n/, "search: numbered title, URL, text");
    like($out, qr/^   About number 2 z{285}\.\.\.$/m, "search: long texts are cut");
    is(scalar(() = $out =~ m/^\d+\. /mg), 8, "search: 8 results by default");
    {
        local $::ORIG_ENV{AI_SEARCH_RESULTS} = 3;
        ($out) = tool("search", "perl select() & caf\xc3\xa9");
        is(scalar(() = $out =~ m/^\d+\. /mg), 3, "search: AI_SEARCH_RESULTS");
        local $::ORIG_ENV{AI_SEARXNG_PROXY} = "http://search-proxy:9";
        tool("search", "nothing");
        is($ASKED[-1]{proxy}, "http://search-proxy:9", "search: AI_SEARXNG_PROXY when the instance is not near");
    }
    is((tool("search", "nothing"))[0], "no results for: nothing\n", "search: no results");
    like((tool("search", "denied"))[1], qr/refuses format=json, enable it in the SearXNG settings/, "search: 403 explains the setting");
    like((tool("search", "broken"))[1], qr/did not answer with JSON/, "search: not JSON");
    like((tool("search", "  "))[1], qr/no query/, "search: needs a query");
    {
        local $::ORIG_ENV{AI_SEARXNG_URL} = "http://searx.lan:8888/search";
        tool("search", "nothing");
        is($ASKED[-1]{url}, "http://searx.lan:8888/search?q=nothing&format=json", "search: the URL may end in /search");
    }
}

# async: web requests of sub-agents are in flight together, ctrl-C ends them
{
    TestAI::setup();
    mock_web(map {("https://example.org/slow$_" => {type => "text/plain", body => "page $_", delay => 0.3})} 1 .. 3);
    my %got;
    my $t0 = Time::HiRes::time();
    ai::execute_tool_async("fetch", "FETCH_6e1b", ["https://example.org/slow$_"], do {my $n = $_; sub {$got{$n} = [@_]}}) for 1 .. 3;
    is(scalar(keys %got), 0, "async: nothing is waited for");
    loop::run(sub {keys(%got) == 3});
    my $took = Time::HiRes::time() - $t0;
    is($MAX_INFLIGHT, 3, "async: three requests at the same time");
    ok($took < 0.8, "async: 3 x 0.3s in ".sprintf("%.2fs", $took));
    is_deeply($got{2}, ["URL: https://example.org/slow2\n\npage 2", undef], "async: results arrive in the callback");

    mock_web("https://example.org/hang" => {body => "never", delay => 60});
    local $SIG{ALRM} = sub {$::ABORT = 1};
    $t0 = Time::HiRes::time();
    alarm(1);
    my ($out, $err) = tool("fetch", "https://example.org/hang");
    alarm(0);
    $::ABORT = 0;
    like($err, qr/interrupted/, "abort: ctrl-C ends a fetch");
    ok(Time::HiRes::time() - $t0 < 4, "abort: at once");
    is(loop::pending(), 0, "abort: nothing left in the loop");
}

# the request to the LLM takes the proxy of the LLM
{
    TestAI::setup(AI_WEB_PROXY => "http://web-proxy:8080");
    mock_web();
    my $done;
    utils::http("get", "http://127.0.0.1:9/v1/models");
    ok(!exists $ASKED[0]{proxy}, "llm: no proxy is forced, the HTTP layer picks the one for the API");
}

# and for real, against the test server: the options work with this curl
SKIP: {
    no warnings 'redefine';
    *loop::http = $real_http;
    skip "needs Net::Curl or WWW::Curl", 6
        unless Net::Curl::Easy->can('new') or WWW::Curl::Easy->can('new');
    my $url = FakeLLM::start();
    TestAI::setup(AI_LOCAL_SERVER => $url);
    my ($out, $err) = tool("fetch", "$url/v1/models");
    is($err, undef, "real: fetched");
    like($out, qr/\AURL: \Q$url\E\/v1\/models\n\n\{"object":"list"/, "real: URL and body");
    {
        local $::ORIG_ENV{AI_WEB_MAX_SIZE} = 20;
        ($out, $err) = tool("fetch", "$url/v1/models");
        like($out, qr/\n\n\{"object":"list","da.*cut here, there is more than 20 bytes/s, "real: the size limit stops the transfer");
    }
    like((tool("fetch", "$url/nothing/here"))[1], qr/HTTP status 404: \{"error"/, "real: HTTP error with body");
    like((tool("fetch", "http://127.0.0.1:1/x"))[1], qr/\S+ \(http:\/\/127\.0\.0\.1:1\/x\)/, "real: connection error names the URL");
    my $out2 = TestAI::capture {ai::chat_completion("go")};
    like($out2, qr/The tool said: e2e-42/, "real: the LLM requests still work next to it");
    FakeLLM::stop();
}

# /retry and /rewind
{
    my $tmp = TestAI::setup();
    my $ok   = sub {[TestAI::content($_[0]), TestAI::done()]};
    my $bash = "///BASH_7c48+EO_dfd7\necho hi\nEO_dfd7\nBASH_7c48\n";
    my $cmd  = sub {my ($l) = @_; TestAI::capture {ai::handle_command($l)}};
    TestAI::mock_http();
    like($cmd->("/retry"), qr/Nothing to retry/, "retry: nothing yet");
    like($cmd->("/rewind"), qr/Nothing to rewind/, "rewind: nothing yet");

    TestAI::mock_http($ok->("answer one"), [TestAI::content($bash), TestAI::done()], $ok->("bad answer"));
    TestAI::capture {ai::chat_completion("first question"); ai::chat_completion("second question")};
    my $raw = ai::slurp($ai::STATUS_FILE);
    is(TestAI::roles(ai::load_messages()), "system,user,assistant,user,assistant,user,assistant", "two exchanges, the second with a tool");

    TestAI::mock_http($ok->("better answer"));
    my $out = $cmd->("/retry");
    like($out, qr/better answer/, "retry: asked again");
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user,assistant,user,assistant", "retry: the old answer and its tool run are gone");
    is($msgs[3]{content}, "second question", "retry: same question");
    is($msgs[4]{content}, "better answer", "retry: new answer");
    is(TestAI::roles(@{TestAI::sent_messages(0)}), "system,user,assistant,user", "retry: the model does not see the dropped answer");
    my $keep = length($raw) - length(($raw =~ m/(\{[^\n]*second question.*)\z/s)[0]);
    is(substr(ai::slurp($ai::STATUS_FILE), 0, $keep), substr($raw, 0, $keep), "retry: the start of the conversation is untouched (cache)");
    like(ai::slurp("$tmp/aicli/sessions/test/chat.archive"), qr/bad answer/, "retry: what was dropped is in the archive");

    $out = $cmd->("/rewind");
    like($out, qr/Removed 1 exchange \(2 messages\), back to before:\n  second question\n/, "rewind: says what went");
    is(TestAI::roles(ai::load_messages()), "system,user,assistant", "rewind: one exchange less");
    TestAI::mock_http($ok->("a"), $ok->("b"));
    TestAI::capture {ai::chat_completion("q2"); ai::chat_completion("q3")};
    like($cmd->("/rewind 2"), qr/Removed 2 exchanges \(4 messages\).*\n  q2\n/s, "rewind n: several at once");
    is(TestAI::roles(ai::load_messages()), "system,user,assistant", "rewind n: gone");
    like($cmd->("/rewind 9"), qr/Removed 1 exchange/, "rewind: more than there is takes what there is");
    is(TestAI::roles(ai::load_messages()), "system", "rewind: the system prompt always stays");
    like($cmd->("/rewind x"), qr{Usage: /rewind \[n\]}, "rewind: usage");

    # tool results and context notes are not what the user said
    ai::append_messages({role => 'user', content => "[The older messages of this conversation were removed to save context]"},
        {role => 'user', content => "real"}, {role => 'assistant', content => "x"},
        {role => 'user', content => "[BASH_7c48 RESULT_d170\nhi\nRESULT_d170]"}, {role => 'assistant', content => "y"});
    $cmd->("/rewind");
    is(scalar(ai::load_messages()), 2, "rewind: back to before the last real input, the note stays");
    like($cmd->("/rewind"), qr/Nothing to rewind/, "rewind: a note is not an exchange");
}

chdir("/");
done_testing();
