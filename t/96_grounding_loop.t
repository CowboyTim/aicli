#!/usr/bin/perl
# devel: what a development language has installed, asked for by the model; the
# system prompt does not carry it. Loop control: a model that gets the same
# error turn after turn is stopped.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }
sub calls_reply {
    my (@calls) = @_;
    my @events;
    my $i = 0;
    for my $c (@calls){
        my ($name, $id, $args) = @$c;
        push @events, +{choices => [+{delta => +{tool_calls => [+{index => $i++, id => $id, function => +{name => $name, arguments => $args}}]}}]};
    }
    push @events, +{choices => [+{delta => +{}, finish_reason => 'tool_calls'}]};
    return [sse(@events)];
}
sub text_reply {
    my ($text) = @_;
    return [sse({choices => [{delta => {content => $text}}]}, {choices => [{delta => {}, finish_reason => 'stop'}]})];
}

# the tool: the profiles, a filter, the cache, a wrong name
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    ok(tools::available('devel'), "devel: available");
    my ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['cobol', '']);
    like($e // '', qr/no profile for 'cobol': the profiles are bash, c, lua, perl, python/, "devel: an unknown language names the profiles");
    ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['perl', '(']);
    like($e // '', qr/not a regular expression/, "devel: a bad filter is refused");

    ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['perl', '']);
    like($r // '', qr/give a filter/, "devel perl: without a filter, no list, a hint");
    unlike($r // '', qr/^Carp /m, "devel perl: and no module in it");

    ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['perl', '^Carp$']);
    ok(!$e, "devel perl: runs") or diag($e);
    like($r, qr/matching '\^Carp\$': 1 lines/, "devel perl: the filter is for the names, and it is said");
    like($r, qr/^Carp \S+$/m, "devel perl: a module with its version");
    unlike($r, qr/^Carp::Heavy/m, "devel perl: the filter leaves the others out");
    ok(exists $tools::DEVEL_CACHE{perl}, "devel perl: the list is kept for the rest of the process");
    unlike($r, qr/^Data::Dumper/m, "devel perl: the filter leaves the others out");

    ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['bash', 'git']);
    like($r // '', qr/^git \S+/m, "devel bash: the tools on the PATH");
}

# the lists made at build time: written to a directory, read by the tool instead
# of running the probe, and bash is never read from it
{
    my $dir = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_DEVEL_CACHE => $dir);
    tools::devel_build("$dir/built");
    ok(-s "$dir/built/perl", "build: the perl list is written");
    ok(!-e "$dir/built/bash", "build: bash is not written, it is live");
    TestAI::setup(AI_TOOL_CALLS => "native", AI_DEVEL_CACHE => "$dir/built");
    ai::spew("$dir/built/perl", "perl v9.9\nMARK 9.9\n");
    delete $tools::DEVEL_CACHE{perl};
    my ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['perl', 'MARK']);
    like($r // '', qr/MARK 9\.9/, "build: the tool reads the list the image has, without probing");
    like($r // '', qr/built with the image/, "build: and says where it comes from");
    ai::spew("$dir/built/perl", "not read again\n");
    delete $tools::DEVEL_CACHE{perl};
    ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['perl', 'not']);
    like($r // '', qr/not read again/, "build: the file is read each time the cache is empty");
}

# the python profile, when there is a python
SKIP: {
    skip "no python3 here", 2 unless grep {-x "$_/python3"} split m/:/, $ENV{PATH} // '';
    TestAI::setup(AI_TOOL_CALLS => 'native');
    my ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['python', '']);
    ok(!$e, "devel python: runs") or diag($e);
    like($r, qr/^python 3\./m, "devel python: the version");
}

# a profile whose program is not there says so, and is not an error of the loop
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    my ($r, $e) = ai::execute_tool('devel', 'DEVEL_9c3e', ['lua', '']);
    ok(!$e, "devel lua: not an error of the tool") ;
    like($r // '', qr/^devel lua/, "devel lua: answers either way");
}

# the system prompt is the same whatever is installed: the tool asks for it
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_MODULES => 'Carp');
    unlike(ai::system_prompt(), qr/Carp \d/, "prompt: no module list in the system prompt");
    like(ai::system_prompt(), qr/`devel` tool/, "prompt: the coder template names the devel tool");
    TestAI::mock_http(text_reply("ok"));
    TestAI::capture {ai::chat_completion("hi")};
    my @names = map {$_->{function}{name}} @{$::JSON->decode($TestAI::REQUESTS[0]{data})->{tools}};
    ok((grep {$_ eq 'devel'} @names), "devel: the request offers the tool");
}

# loop control: the same error turn after turn stops the input
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
        calls_reply(['bash', 'c1', '{"code":"exit 3"}']),
        calls_reply(['bash', 'c2', '{"code":"exit 3"}']),
        calls_reply(['bash', 'c3', '{"code":"exit 3"}']),
        calls_reply(['bash', 'c4', '{"code":"exit 3"}']),
        text_reply("never reached"),
    );
    my $out = TestAI::capture {ai::chat_completion("loop")};
    is(scalar(@TestAI::REQUESTS), 4, "loop: stopped after the 4th identical error (AI_LOOP_LIMIT default)");
    like($out, qr/stopped: the same error came back 4 turns in a row/, "loop: and it says so");
}
{
    TestAI::setup(AI_TOOL_CALLS => 'native', AI_LOOP_LIMIT => 0);
    TestAI::mock_http(
        map({calls_reply(['bash', "c$_", '{"code":"exit 3"}'])} 1 .. 5),
        text_reply("done"),
    );
    TestAI::capture {ai::chat_completion("no limit")};
    is(scalar(@TestAI::REQUESTS), 6, "loop: AI_LOOP_LIMIT=0 has no limit");
}
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
        calls_reply(['bash', 'd1', '{"code":"exit 3"}']),
        calls_reply(['bash', 'd2', '{"code":"exit 4"}']),
        calls_reply(['bash', 'd3', '{"code":"exit 5"}']),
        calls_reply(['bash', 'd4', '{"code":"exit 6"}']),
        text_reply("different errors, a model trying"),
    );
    TestAI::capture {ai::chat_completion("different")};
    is(scalar(@TestAI::REQUESTS), 5, "loop: different errors are not stuck");
}
{
    TestAI::setup(AI_TOOL_CALLS => 'native');
    TestAI::mock_http(
        calls_reply(['bash', 'e1', '{"code":"echo same"}']),
        calls_reply(['bash', 'e2', '{"code":"echo same"}']),
        calls_reply(['bash', 'e3', '{"code":"echo same"}']),
        calls_reply(['bash', 'e4', '{"code":"echo same"}']),
        text_reply("done"),
    );
    TestAI::capture {ai::chat_completion("same ok")};
    is(scalar(@TestAI::REQUESTS), 5, "loop: the same successful result is not stuck");
}

done_testing();
