#!/usr/bin/perl
# The meta file of a session: the thinking and the usage of an answer, kept apart from the
# messages (never sent to the model). A line matches its message by index and by a hash of the
# answer: a line whose message is gone (a rewind, a compaction) is not used. The history of the
# web page carries them.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();

use lib "$FindBin::Bin/../";
require "$FindBin::Bin/lib/TestAI.pm";
use ai;
use ui;

my $root = File::Temp::tempdir("aicli_meta_XXXXXX", TMPDIR => 1, CLEANUP => 1);
mkdir "$root/sessions"; mkdir "$root/sessions/s1";
local $ai::SESSIONS_DIR = "$root/sessions";
local $ai::AI_SESSION_DIR = "$root/sessions/s1";
local $ai::STATUS_FILE = "$root/sessions/s1/chat";

ai::append_messages({role => 'user', content => 'hello'});
ai::append_messages({role => 'assistant', content => 'hi there'});
ai::record_meta('hi there', '<think>a short plan</think>hi there', {reasoning => ' and more'}, 'in 10 out 2');

ok(-f "$root/sessions/s1/meta", "the meta file is written");
my @msgs = ai::load_messages();
ok(!grep({ exists $_->{thinking} or exists $_->{usage} } @msgs), "the messages have no thinking or usage (the model does not get them)");
my %meta = ai::meta_of("$root/sessions/s1", \@msgs);
is_deeply($meta{1}, {thinking => 'a short plan and more', usage => 'in 10 out 2'}, "the meta of the answer, by its index");

my $h = ui::_history_data('s1');
is(scalar(@{ $h->{messages} }), 2, "the history has the exchange");
is($h->{messages}[1]{thinking}, 'a short plan and more', "with the thinking of the answer");
is($h->{messages}[1]{usage}, 'in 10 out 2', "and its usage");
ok(!exists $h->{messages}[0]{thinking}, "the user message has none");

# a rewind: the answer is gone, its meta line is not used any more
ai::rewind_chat(1);
ai::append_messages({role => 'user', content => 'again'});
ai::append_messages({role => 'assistant', content => 'a different answer'});
@msgs = ai::load_messages();
%meta = ai::meta_of("$root/sessions/s1", \@msgs);
ok(!exists $meta{1}, "after a rewind the old line does not match the new answer");
$h = ui::_history_data('s1');
ok(!exists $h->{messages}[1]{thinking}, "and the history has no thinking for it");

# an answer without thinking or usage writes no line
my $lines_before = do { open(my $fh, '<', "$root/sessions/s1/meta") or die; my @l = <$fh>; scalar @l };
ai::record_meta('a different answer', 'a different answer', {}, '');
my $lines_after = do { open(my $fh, '<', "$root/sessions/s1/meta") or die; my @l = <$fh>; scalar @l };
is($lines_after, $lines_before, "nothing to keep: no line");

done_testing();
