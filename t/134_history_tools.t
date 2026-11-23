#!/usr/bin/perl
# the history of a session on the page: the tool calls of the chat come back with their results,
# as the live page showed them (a tool line, then its result), in their place between what was
# said; a call without a result yet has no result line
use strict; use warnings;

use Test::More;
use FindBin;
use JSON::XS ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;
TestAI::setup();

my $J = JSON::XS->new->canonical(1)->utf8;
my $name = 'history-tools-test';
mkdir "$ai::SESSIONS_DIR/$name" or die "mkdir: $!";
open(my $fh, '>', "$ai::SESSIONS_DIR/$name/chat") or die $!;
print {$fh} map {$J->encode($_)."\n"} (
    {role => 'user', content => 'show the greeting'},
    {role => 'assistant', content => '', tool_calls => [{id => 'call_1', type => 'function',
        function => {name => 'bash', arguments => $J->encode({code => "echo hi"})}}]},
    {role => 'tool', tool_call_id => 'call_1', content => "hi\n"},
    {role => 'assistant', content => 'It says hi.'},
    {role => 'assistant', content => '', tool_calls => [{id => 'call_2', type => 'function',
        function => {name => 'bash', arguments => $J->encode({code => "sleep 1"})}}]},
);
close $fh;

my $h = ui::_history_data($name);
my @m = @{$h->{messages}};
is_deeply([map {$_->{role}} @m], ['user', 'tool', 'assistant', 'tool'],
    "what was said, the call with its result, the answer, and a call still without its result, in order");
is($m[0]{text}, 'show the greeting', "what the user said");
like($m[1]{text}, qr/bash echo hi/, "the call's line: its name and its first argument line, as the live line");
is($m[1]{result}, "  hi\n", "and its result, indented and clipped as the live one is");
is($m[2]{text}, 'It says hi.', "the answer after it");
like($m[3]{text}, qr/bash sleep 1/, "a call that has not answered yet");
ok(!exists $m[3]{result}, "and it has no result line");
ok(!${$h->{more}}, "not cut");

# the whole call, for the page's tool line when it is opened: the name, then each argument in full,
# a value's further lines indented under it
is($m[1]{full}, "BASH\n  code: echo hi", "the whole call of a bash call: its name and its argument");
{
    my $name2 = 'history-full-test';
    mkdir "$ai::SESSIONS_DIR/$name2" or die "mkdir: $!";
    open(my $fh2, '>', "$ai::SESSIONS_DIR/$name2/chat") or die $!;
    print {$fh2} map {$J->encode($_)."\n"} (
        {role => 'assistant', content => '', tool_calls => [{id => 'call_w', type => 'function',
            function => {name => 'write', arguments => $J->encode({path => 'notes.txt', content => "one\ntwo"})}}]},
        {role => 'tool', tool_call_id => 'call_w', content => "[OK] wrote notes.txt\n"},
    );
    close $fh2;
    my ($w) = grep {$_->{role} eq 'tool'} @{ui::_history_data($name2)->{messages}};
    is($w->{full}, "WRITE\n  path: notes.txt\n  content: one\n    two",
        "a value over several lines: its further lines are indented under it");
}

done_testing();
