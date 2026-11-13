#!/usr/bin/perl
# the thinking of the model is shown as: spin (no text, a spinner in the status
# line, and a line of how long it took on a terminal), text (streamed in its
# color), or off. AI_THINKING_VIEW, AI_SHOW_THINKING and /thinking-view choose.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }

# the view: spin by default, what the variables say, and /thinking-view for the run
{
    TestAI::setup(AI_THINKING_VIEW => undef);
    is(ai::thinking_view(), 'spin', "view: spin by default");
    TestAI::setup(AI_THINKING_VIEW => 'text');
    is(ai::thinking_view(), 'text', "view: AI_THINKING_VIEW=text");
    TestAI::setup(AI_THINKING_VIEW => 'Off');
    is(ai::thinking_view(), 'off', "view: the case does not matter");
    TestAI::setup(AI_THINKING_VIEW => 'loud');
    is(ai::thinking_view(), 'spin', "view: an unknown value is spin");
    TestAI::setup(AI_SHOW_THINKING => 0, AI_THINKING_VIEW => 'text');
    is(ai::thinking_view(), 'off', "view: AI_SHOW_THINKING=0 is off, whatever the view says");
    TestAI::setup(AI_THINKING_VIEW => undef);
    {
        local $ai::THINKING_VIEW = 'text';
        is(ai::thinking_view(), 'text', "view: the choice of the run wins");
    }
    is(ai::thinking_view(), 'spin', "view: and it is gone after the run");
}

# the printer: a thinking part, then an answer
sub printed {
    my ($view, %o) = @_;
    TestAI::setup(AI_THINKING_VIEW => $view);
    my $out = '';
    my $p = ai::new_printer(sub {$out .= $_[0]}, %o);
    $p->{emit}->('think', "hmm, ");
    $p->{emit}->('think', "a plan");
    $p->{emit}->('text', "The answer.\n");
    $p->{finish}->();
    return $out;
}

{
    my $spin = printed('spin', tty => 1);
    unlike($spin, qr/hmm|a plan/, "spin: the thinking is not written out");
    like($spin, qr/thought for \d+\.\ds/, "spin, on a terminal: a line of how long it took");
    like($spin, qr/The answer\./, "spin: the answer is written");
    ok(index($spin, 'thought for') < index($spin, 'The answer.'), "spin: the line comes before the answer");

    my $pipe = printed('spin', tty => 0);
    unlike($pipe, qr/thought for|hmm/, "spin, not on a terminal: no line, no thinking");
    like($pipe, qr/The answer\./, "spin, not on a terminal: the answer is there");

    my $text = printed('text', tty => 1);
    like($text, qr/hmm, .*a plan/s, "text: the thinking is streamed");
    unlike($text, qr/thought for/, "text: no line of how long");

    my $off = printed('off', tty => 1);
    unlike($off, qr/hmm|a plan|thought for/, "off: no thinking and no line");
    like($off, qr/The answer\./, "off: the answer is there");
}

# a whole turn: the thinking of the model does not reach the chat in spin mode
{
    TestAI::setup(AI_THINKING_VIEW => 'spin', AI_TOOL_CALLS => 'text');
    TestAI::mock_http([
        TestAI::reasoning("Let me think. "), TestAI::reasoning("Four."),
        TestAI::content("The answer is 4."), TestAI::done(),
    ]);
    my $out = TestAI::capture {ai::chat_completion("sum")};
    unlike($out, qr/Let me think|Four\./, "turn: the thinking is not streamed");
    like($out, qr/The answer is 4\./, "turn: the answer is");
    is((ai::load_messages())[-1]{content}, "The answer is 4.", "turn: only the answer is kept");
}

# /thinking-view: shows the view, sets it for the run, refuses a wrong value
{
    TestAI::setup();
    my $out = TestAI::capture {ai::handle_command('/thinking-view')};
    like($out, qr/thinking view: text/, "command: without an argument it says the view");
    $out = TestAI::capture {ai::handle_command('/thinking-view off')};
    like($out, qr/thinking view: off/, "command: the view is set");
    is(ai::thinking_view(), 'off', "command: and it is the view of the run");
    $out = TestAI::capture {ai::handle_command('/thinking-view loud')};
    like($out, qr/Usage: \/thinking-view spin\|text\|off/, "command: a wrong value is refused");
    is(ai::thinking_view(), 'off', "command: and nothing changes");
    $ai::THINKING_VIEW = undef;
}

done_testing();
