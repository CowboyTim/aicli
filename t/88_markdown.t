#!/usr/bin/perl
# markdown in the answer: drawn line by line as it streams, tables aligned,
# code blocks left as they are, and the printer only draws it for a terminal
use strict; use warnings; use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use md;
use TestAI;

TestAI::setup(AI_GLYPHS => 'unicode');

sub plain { my $s = shift; $s =~ s/\e\[[0-9;]*m//g; $s }
sub draw { my $m = md->new(base => "\e[0;32m"); my $o = $m->feed(shift); $o .= $m->flush; $o }

# headings, emphasis, code, links
{
    my $o = draw("# Title\nSome **bold**, *it* and `code`.\n[site](http://x.example)\n");
    is(plain($o), "Title\nSome bold, it and code.\nsite (http://x.example)\n", "md: the markup is gone, the text stays");
    like($o, qr/\e\[38;5;33;1mTitle/, "md: a heading in its colour");
    like($o, qr/\e\[1mbold\e\[22m/, "md: bold");
    like($o, qr/\e\[3mit\e\[23m/, "md: italic");
    like($o, qr/\e\[38;5;180mcode\e\[0m/, "md: code span");
    like($o, qr/\e\[4msite\e\[24m/, "md: link text underlined");
}

# lists, quotes, rules
{
    my $o = draw("- one\n* two\n3. three\n> quoted\n---\n");
    my ($bullet) = map {/^(\S) one/ ? $1 : ()} split /\n/, plain($o);
    is($bullet, tui::glyph('bullet'), "md: a dash list item gets the bullet");
    like(plain($o), qr/^3\. three$/m, "md: numbers stay");
    like(plain($o), qr/^\│ quoted$/m, "md: a quote gets the bar");
    like(plain($o), qr/^─{40}$/m, "md: a rule");
}

# streaming: a line is drawn when it is complete, pieces join up
{
    my $m = md->new(base => "");
    is($m->feed("**bo"), "", "stream: an open line waits");
    is(plain($m->feed("ld**\nnext")), "bold\n", "stream: the complete line is drawn, the next waits");
    is(plain($m->flush), "next\n", "stream: the rest is drawn at the end");
}

# code blocks: their content is not marked up
{
    my $o = draw("```perl\nmy **x** = 1;\n```\nafter **it**\n");
    like(plain($o), qr/^my \*\*x\*\* = 1;$/m, "code: the block as written");
    like($o, qr/\e\[0;36mmy \*\*x\*\* = 1;/, "code: in the code colour");
    like(plain($o), qr/^after it$/m, "code: back to markdown after the fence");
}

# tables: aligned, the header bold, the separator dropped
{
    my $o = draw("| name | n |\n|---|--:|\n| apple | 1 |\n| kiwi | 22 |\n\nafter\n");
    my @lines = grep {length} split /\n/, plain($o);
    is($lines[0], "name  │ n ", "table: header, columns padded");
    like($o, qr/\e\[1mname/, "table: header in bold");
    is($lines[2], "apple │ 1 ", "table: first row");
    is($lines[3], "kiwi  │ 22", "table: the wider number sets the width");
    is(scalar(grep {/---/} @lines), 0, "table: no separator row in the text");
    like(plain($o), qr/^after$/m, "table: ends at a line that is not a row");
}

# the printer: drawn for a terminal (AI_MARKDOWN=1 here), plain otherwise
{
    local $::ORIG_ENV{AI_MARKDOWN} = 1;
    my $out = TestAI::capture {
        my $p = ai::new_printer();
        $p->{emit}->('think', "hmm");
        $p->{emit}->('text', "# Head\n**yes**");
        $p->{finish}->();
    };
    unlike($out, qr/# Head/, "printer: the heading is not shown as markup");
    like($out, qr/\e\[1myes\e\[22m/, "printer: bold drawn");
    like($out, qr/hmm\e\[0m\n\n/, "printer: a blank line between thinking and the answer");
    like($out, qr/yes\e\[22m\e\[0m\n/, "printer: the line the answer ends on is drawn at the end");
}
{
    local $::ORIG_ENV{AI_MARKDOWN} = 0;
    my $out = TestAI::capture {
        my $p = ai::new_printer();
        $p->{emit}->('text', "# Head\n");
        $p->{finish}->();
    };
    like($out, qr/# Head/, "printer: AI_MARKDOWN=0 keeps the text as it is");
}
{
    my $out = TestAI::capture {
        my $p = ai::new_printer();
        $p->{emit}->('text', "# Head\n");
        $p->{finish}->();
    };
    like($out, qr/# Head/, "printer: not a terminal, the text as it is");
}

done_testing();
