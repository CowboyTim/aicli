#!/usr/bin/perl
# grounding: the Perl and modules of a session, made once and kept in it; loop
# control: a model that gets the same error turn after turn is stopped
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

# grounding: what it says, and that a session keeps what it was given
{
    TestAI::setup(AI_MODULES => '');
    is(ai::make_grounding(), '', "grounding: nothing without AI_MODULES");

    TestAI::setup(AI_MODULES => 'Carp No::Such::Mod ../bad');
    my $g = ai::make_grounding();
    like($g, qr/^- perl v5/m, "grounding: the perl version");
    like($g, qr/^- Carp \S+/m, "grounding: a module with its version");
    like($g, qr/^- No::Such::Mod: not installed/m, "grounding: a missing module is said so");
    unlike($g, qr/bad/, "grounding: a name that is not a module is left out");
}
{
    TestAI::setup(AI_MODULES => 'Carp');
    my $dir = $ai::AI_SESSION_DIR;
    ok(-f "$dir/grounding", "session: the grounding is made when the session starts");
    like(ai::system_prompt(), qr/^- Carp /m, "session: the system prompt has it");

    # the same session, as a resumed one would read it: what it made stays
    $::ORIG_ENV{AI_MODULES} = 'JSON::XS';
    my $prompt = ai::system_prompt($dir);
    like($prompt, qr/^- Carp /m, "session: a changed AI_MODULES does not change the session");
    unlike($prompt, qr/JSON::XS/, "session: and the new modules are not in it");

    unlink "$dir/grounding";
    unlike(ai::system_prompt(), qr/The Perl of this session/, "session: an older session without one has no change");
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
