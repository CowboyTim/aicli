#!/usr/bin/perl
# a tool result that is not text (a binary file: NUL bytes, or not UTF-8) is shown as its size, not as its bytes;
# the model still gets all of it. A change to a binary file (write, edit) has no diff of its bytes.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
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

# the tests of the text
my $bin = "PK\x03\x04\x00\x00\x08\x00\xff\xfe\x80\x81data\x00";
ok(ai::is_binary($bin), "a zip file's bytes are binary (NUL bytes)");
ok(ai::is_binary("\xff\xfe latin-1 text\n"), "bytes that are not UTF-8 are binary");
ok(!ai::is_binary("plain text, \xc3\xbcnicode\n"), "UTF-8 text is text");
ok(!ai::is_binary(""), "an empty result is text");
ok(!ai::is_binary(undef), "no result is text");
is(ai::binary_note($bin), "not text, ".length($bin)." bytes: not shown here", "the note says the size");
is(ai::binary_note("hello\n"), undef, "a text has no note");

# a read of a binary file in a turn: the page's result is the note, the model gets the bytes
my $tmp = TestAI::setup(AI_TOOL_CALLS => 'native');
my $ws = "$tmp/work";
mkdir $ws or die "work: $!";
ai::set_workspace($ws);
open(my $fh, '>:raw', "$ws/blob.bin") or die "blob: $!";
print {$fh} $bin;
close($fh);
open($fh, '>:raw', "$ws/notes.txt") or die "notes: $!";
print {$fh} "line one\nline two\n";
close($fh);

{
    my @events;
    local $ai::EVENT_SINK = sub { push @events, [@_] };
    TestAI::mock_http(
        calls_reply(['read', 'call_bin', $::JSON->encode({path => "$ws/blob.bin"})]),
        text_reply("read it"),
    );
    TestAI::capture {ai::chat_completion("read the blob")};
    # the page's lines: a result is a text (full display) or a result line (brief display)
    my $shown = join('', map {$_->[1]{text} // ''} grep {$_->[0] eq 'text' or $_->[0] eq 'result'} @events);
    like($shown, qr/not text, \Q@{[length $bin]}\E bytes: not shown here/, "binary: the page shows its size");
    unlike($shown, qr/PK|RESULT_/, "binary: none of its bytes, nor the result's lines, are shown");
    my ($tool) = grep {($_->{role} // '') eq 'tool'} ai::load_messages();
    is($tool->{content}, $bin, "binary: the model still gets all of the bytes");
}

# a text read shows its lines, as before
{
    my @events;
    local $ai::EVENT_SINK = sub { push @events, [@_] };
    TestAI::mock_http(
        calls_reply(['read', 'call_txt', $::JSON->encode({path => "$ws/notes.txt"})]),
        text_reply("read it too"),
    );
    TestAI::capture {ai::chat_completion("read the notes")};
    my $shown = join('', map {$_->[1]{text} // ''} grep {$_->[0] eq 'text' or $_->[0] eq 'result'} @events);
    like($shown, qr/line one.*line two/s, "text: the page shows its lines");
    unlike($shown, qr/not text/, "text: no note for a text");
}

# the brief display (the default of the terminal and the page): the result line is the note too
{
    local $::ORIG_ENV{AI_TOOL_DISPLAY} = 'brief';
    my @events;
    local $ai::EVENT_SINK = sub { push @events, [@_] };
    TestAI::mock_http(
        calls_reply(['read', 'call_brief', $::JSON->encode({path => "$ws/blob.bin"})]),
        text_reply("read it briefly"),
    );
    TestAI::capture {ai::chat_completion("read the blob briefly")};
    my @results = map {$_->[1]{text}} grep {$_->[0] eq 'result'} @events;
    my @notes = grep {/not text/} @results;
    is(scalar(@notes), 1, "brief: one result line is the note (the other is the time it took)");
    like($notes[0] // '', qr/^\s*not text, \d+ bytes: not shown here/, "brief: the result line is the note");
    unlike(join('', @results), qr/PK/, "brief: no bytes in the result lines");
}

# a write over a binary file: no diff of its bytes, "a binary file" instead
{
    my $file = "$ws/blob.bin";
    tools::_changing($file, 'write', "now text\n");
    ok($tools::CHANGES[-1]{binary}, "a change to a binary file is marked binary");
    my $out = '';
    ai::show_changes(sub { $out .= $_[0] });
    like($out, qr/blob\.bin: a binary file/, "...and shown as a binary file");
    unlike($out, qr/PK/, "...with none of its bytes");
}

# a change to a text file keeps its diff
{
    tools::_changing("$ws/notes.txt", 'write', "line one\nline three\n");
    ok(!$tools::CHANGES[-1]{binary}, "a change to a text file is not binary");
    my $out = '';
    ai::show_changes(sub { $out .= $_[0] });
    like($out, qr/notes\.txt: \+1 -1/, "...and it has its diff");
}

done_testing();
