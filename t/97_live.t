#!/usr/bin/perl
# A real model, when there is one: set AI_LIVE_SERVER (an OpenAI compatible
# server, e.g. llama.cpp) and AI_LIVE_MODEL, optionally AI_LIVE_SEARXNG for the
# search tool. Without AI_LIVE_SERVER the whole file is skipped. Not part of
# what must always pass: the answers of a model vary, so the checks are loose.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

plan skip_all => 'set AI_LIVE_SERVER (and AI_LIVE_MODEL) to run against a real model'
    unless length($ENV{AI_LIVE_SERVER} // '');

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my %live = (
    AI_LOCAL_SERVER => $ENV{AI_LIVE_SERVER},
    AI_MODEL        => $ENV{AI_LIVE_MODEL},
    AI_TOOL_CALLS   => 'native',
    AI_RETRIES      => 2,
    AI_SHOW_USAGE   => 0,
    AI_PROVIDER     => 'local',
);

# one plain answer
{
    my $tmp = TestAI::setup(%live);
    my $out = TestAI::capture {ai::chat_completion("Reply with the single word: pong")};
    like($out, qr/pong/i, "plain: the model answers");
    my @msgs = ai::load_messages();
    is((grep {($_->{role} // '') eq 'assistant'} @msgs), 1, "plain: one answer kept");
}

# a native tool call: the list tool runs on a directory of the workspace
{
    my $tmp = TestAI::setup(%live);
    my $ws = "$tmp/ws";
    mkdir $ws or die $!;
    for my $f (qw(one.txt two.txt)){ open(my $fh, '>', "$ws/$f") or die $!; close $fh }
    ai::set_workspace($ws);
    my $out = TestAI::capture {ai::chat_completion("Use the list tool to list the directory $ws. Then reply with only the number of files in it.")};
    my @msgs = ai::load_messages();
    my ($call) = grep {($_->{role} // '') eq 'assistant' and $_->{tool_calls}} @msgs;
    ok($call, "tool: the model made a call of its own");
    is($call && $call->{tool_calls}[0]{function}{name}, 'list', "tool: it is the list tool") if $call;
    my ($result) = grep {($_->{role} // '') eq 'tool'} @msgs;
    like($result->{content} // '', qr/one\.txt/, "tool: the result lists the files") if $result;
    (my $plain = $out) =~ s/\e\[[0-9;]*m//g;
    like($plain, qr/\b2\b/, "tool: the answer has the count");
}

# the reasoning setting goes to the server: off gives no reasoning text
{
    my $tmp = TestAI::setup(%live, AI_THINKING => 'off');
    my $out = TestAI::capture {ai::chat_completion("What is 2+2? Answer with the number only.")};
    like($out, qr/4/, "thinking off: the answer");
    unlike($out, qr/thinking process|Let me think|The user/i, "thinking off: no reasoning shown");
}

# the search tool, when a SearXNG instance is given
if (length($ENV{AI_LIVE_SEARXNG} // '')) {
    my $tmp = TestAI::setup(%live, AI_SEARXNG_URL => $ENV{AI_LIVE_SEARXNG});
    my $r = eval {tools::search_d4a7(["perl"])};
    ok(!$@ && defined $r && length($r), "search: the instance answers") or diag($@);
}

done_testing();
