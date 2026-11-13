#!/usr/bin/perl
# the perl template: a file in ai/, listed by /prompt, and what it asks of the
# agent for Perl: the work done with the tools, perl -c after each change,
# replace rather than a rewrite, no CPAN module without asking. It names no
# module of a project: those belong in the project's AGENTS.md.
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $text = ai::slurp("$FindBin::Bin/../ai/perl") // '';
ok(length($text), "template: ai/perl is there");
like($text, qr/perl -c/, "template: checks with perl -c");
like($text, qr/`replace`/, "template: changes files with replace");
like($text, qr/`write` only for a new file/, "template: no rewrite of an existing file with write");
like($text, qr/CPAN modules without asking/, "template: no CPAN module without asking");
like($text, qr/big picture/i, "template: the big picture when it is needed");
unlike($text, qr/PDL|Audio::Wav|lame|aicli/, "template: no module or project of one project");

# a session started with it has it as the system prompt, and /prompt lists it
TestAI::setup(AI_PROMPT_TEMPLATE => 'perl', AI_PROMPT_TEMPLATE_FILE => "$TestAI::ROOT/ai/perl");
like(ai::slurp($ai::PROMPT_FILE) // '', qr/perl -c/, "session: the prompt of the session is the perl one");
ok((grep {$_ eq 'perl'} @{ai::prompt_templates()}), "template: listed by /prompt");

done_testing();
