#!/usr/bin/perl
# the footer of the terminal (tui.pm, bar mode) and the numbers shown in it
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = TestAI::setup();
my $fn = "$tmp/tty";
my ($S, $R) = ("\e7", "\e8"); # save and restore the cursor
sub screen {
    my $s = ai::slurp($fn) // '';
    utf8::decode($s);
    return $s;
}
sub fresh {
    my (%o) = @_;
    open(my $fh, '>', $fn) or die $!;
    return tui->new(fh => $fh, enabled => 1, rows => 24, width => 60, interval => 0, %o);
}

# the footer: opened, drawn, closed
{
    my $tui = fresh();
    ok(!$tui->bar(), "bar: not there before open");
    ok($tui->open(), "bar: open");
    ok($tui->bar(), "bar: there");
    like(screen(), qr/\A\n\n\e\[2A\Q$S\E\e\[1;22r\Q$R\E/, "open: room is made, then lines 1-22 are what scrolls, the cursor stays where it was");
    is($tui->open(), 1, "open: twice is once");
    is(scalar(() = screen() =~ m/\e\[1;22r/g), 1, "open: the region is set once");

    $tui->info(session => "work");
    $tui->info(model => sub {"big-model"});
    $tui->info(ctx => "ctx 12% of 32k");
    is($tui->info_line(), "work \x{2502} big-model \x{2502} ctx 12% of 32k", "info: pieces in the order they came, text or sub");
    $tui->set(tool => "bash");
    $tui->draw();
    like(screen(), qr/\Q$S\E\e\[23;1H\e\[2K\e\[0;36m\x{280B} bash\e\[0m\e\[24;1H\e\[2K\e\[0;2mwork \x{2502} big-model \x{2502} ctx 12% of 32k\e\[0m\Q$R\E\z/,
        "draw: activity on line 23, info on line 24, each at its place, cursor saved and put back");
    unlike(screen(), qr/\r/, "draw: nothing is written where the cursor is");

    $tui->info(ctx => "ctx 13% of 32k");
    $tui->info(model => undef);
    is($tui->info_line(), "work \x{2502} ctx 13% of 32k", "info: replaced in place, taken away with undef");
    my $size = -s $fn;
    $tui->clear();
    ok(-s $fn > $size, "clear: with a footer nothing is wiped, it is brought up to date");
    $size = -s $fn;
    $tui->clear();
    is(-s $fn, $size, "clear: and nothing is drawn when nothing changed");
    $tui->unset("tool");
    like(screen(), qr/\e\[23;1H\e\[2K\e\[0;36m\e\[0m\e\[24;1H[^\n]*\Q$R\E\z/, "unset: the activity line is empty at once");
    $size = -s $fn;
    $tui->tick();
    is(-s $fn, $size, "tick: nothing moves, nothing is drawn");
    $tui->set(model => "waiting for model");
    $tui->tick();
    like(screen(), qr/\x{2819} waiting for model/, "tick: the spinner moves while something is going on");

    $tui->info(long => "x" x 200);
    is(length($tui->info_line()), 59, "info: cut to the width of the terminal");
    like($tui->info_line(), qr/\x{2026}\z/, "info: with an ellipsis");

    $tui->at(3, 10, "HERE");
    like(screen(), qr/\Q$S\E\e\[3;10HHERE\Q$R\E\z/, "at: a text anywhere, the cursor stays");

    $tui->close();
    like(screen(), qr/\Q$S\E\e\[r\e\[24;1H\e\[2K\e\[23;1H\e\[2K\Q$R\E\z/, "close: the whole screen scrolls again, the footer lines are empty");
    ok(!$tui->bar(), "close: gone");
    $size = -s $fn;
    $tui->close();
    is(-s $fn, $size, "close: twice is once");
    $tui->draw();
    like(screen(), qr/\r\e\[2K\e\[0;36m\x{2819} waiting for model\e\[0m\z/, "after close the status is one line at the cursor again");
}

# when there is no footer
{
    my $tui = fresh(mode => 'line');
    ok(!$tui->open(), "line: asked for one line, no footer");
    is(screen(), "", "line: nothing done to the screen");
    $tui = fresh(rows => 5);
    ok(!$tui->open(), "small: a terminal of 5 lines gets no footer");
    $tui = fresh(enabled => 0);
    ok(!$tui->open(), "off: nothing");
    $tui->at(1, 1, "x");
    is(screen(), "", "off: at() draws nothing either");
    {
        local $::ORIG_ENV{AI_STATUS} = "line";
        is(fresh()->{mode}, "line", "AI_STATUS=line");
        local $::ORIG_ENV{AI_STATUS} = "bar";
        is(fresh()->{mode}, "bar", "AI_STATUS=bar");
        open(my $fh, '>', $fn) or die $!;
        local $::ORIG_ENV{AI_STATUS} = "0";
        ok(!tui->new(fh => $fh)->enabled(), "AI_STATUS=0 (and not a terminal anyway)");
    }
    open(my $fh, '>', $fn) or die $!;
    my @size = tui->new(fh => $fh, enabled => 1)->size();
    is_deeply(\@size, [], "size: not known for a file") unless $::ORIG_ENV{LINES};
    {
        local @::ORIG_ENV{qw(LINES COLUMNS)} = (40, 120);
        is_deeply([tui->new(fh => $fh, enabled => 1)->size()], [40, 120], "size: LINES and COLUMNS when the terminal cannot be asked");
    }
}

# another size of the terminal
{
    my $tui = fresh();
    $tui->open();
    $tui->info(a => "info");
    my $size = -s $fn;
    $tui->resize();
    is(-s $fn, $size, "resize: same size, nothing to do");
    @{$tui}{qw(rows width)} = (30, 80);
    $tui->resize();
    like(screen(), qr/\Q$S\E\e\[1;28r\Q$R\E\Q$S\E\e\[29;1H\e\[2K[^\n]*\e\[30;1H\e\[2K\e\[0;2minfo\e\[0m\Q$R\E\z/, "resize: the region and the footer move to the new bottom");
    is($tui->width(), 80, "resize: new width");
    @{$tui}{qw(rows width)} = (4, 80);
    $tui->resize();
    ok(!$tui->bar(), "resize: too small, the footer is taken away");
}

# the numbers
{
    is(ai::fmt_k($_->[0]), $_->[1], "fmt_k: ".($_->[0] // 'undef')." is $_->[1]") for [0, 0], [7, 7], [999, 999], [1000, "1.0k"], [1234, "1.2k"], [9999, "10.0k"], [12345, "12k"], [999_999, "999k"], [1_234_567, "1.2M"], [undef, 0];

    my $measured = {t_start => 100, t_first => 102, t_end => 106};
    is_deeply([ai::speeds(200, $measured)], [undef, 50], "speeds: generation is measured (200 tokens in 4s), the prompt speed is not known");
    is_deeply([ai::speeds(1, $measured)], [undef, undef], "speeds: not from one token");
    my $llama = {%$measured, timings => {prompt_n => 900, prompt_per_second => 812.5, predicted_n => 200, predicted_per_second => 52.25, cache_n => 4100}};
    is_deeply([ai::speeds(200, $llama)], [812.5, 52.25], "speeds: what a llama.cpp server reports wins");
    is(ai::cached_tokens($llama), 4100, "cached: llama.cpp timings.cache_n");
    is(ai::cached_tokens({usage => {prompt_tokens_details => {cached_tokens => 1536}}}), 1536, "cached: usage.prompt_tokens_details.cached_tokens");
    is(ai::cached_tokens({usage => {prompt_tokens => 5}}), undef, "cached: not said");

    # they come out of the stream
    my $st = ai::new_stream(sub {});
    $st->{feed}->(TestAI::content("hi").TestAI::sse({choices => [], usage => {prompt_tokens => 900, completion_tokens => 200}, timings => $llama->{timings}}).TestAI::done());
    is_deeply($st->{timings}, $llama->{timings}, "stream: timings are kept");

    ai::save_usage({total_tokens => 1100});
    like(ai::usage_line(900, 200, 0, $llama), qr/\A\[tokens: 900 in \+ 200 out, session 1100 \| 6\.0s, pp 812\.5 tok\/s, tg 52\.2 tok\/s \| 4100 cached\]\z/, "usage line: both speeds and the cache with a llama.cpp server");
    like(ai::usage_line(900, 200, 0, $measured), qr/\| 6\.0s, 50\.0 tok\/s\]\z/, "usage line: as before without");
}

# what the chat puts in the footer
{
    my $tmp2 = TestAI::setup(AI_CONTEXT_TOKENS => 32768, AI_MODEL => "big-model", AI_SHOW_USAGE => undef);
    open(my $fh, '>', $fn) or die $!;
    local $ai::TUI = tui->new(fh => $fh, enabled => 1, rows => 24, width => 120, interval => 0);
    $ai::TUI->open();
    ai::status_info();
    is($ai::TUI->info_line(), "test \x{2502} big-model \x{2502} ctx 0% of 32k", "start: session, model, context");

    my $timings = {prompt_per_second => 812.4, predicted_per_second => 52.3, cache_n => 4100};
    my (@activity, @live);
    TestAI::mock_http(sub {
        my ($cb) = @_;
        push @activity, $ai::TUI->line();
        $cb->(undef, TestAI::reasoning("hm " x 50));
        push @activity, $ai::TUI->line();
        $cb->(undef, TestAI::content("word " x 200));
        push @activity, $ai::TUI->line();
        push @live, $ai::TUI->info_line();
        $cb->(undef, TestAI::sse({choices => [], usage => {prompt_tokens => 5210, completion_tokens => 187}, timings => $timings}).TestAI::done());
        return "";
    });
    my $out = TestAI::capture {ai::chat_completion("hello")};
    like($activity[0], qr/waiting for model/, "request: waiting");
    like($activity[1], qr/thinking/, "request: thinking, the footer says so while the text streams above it");
    like($activity[2], qr/answering/, "request: answering");
    like($live[0], qr/\x{2193}~\d+/, "request: tokens so far, while it comes in");
    is($ai::TUI->info_line(), "test \x{2502} big-model \x{2502} ctx 16% of 32k \x{2502} \x{2191}5.2k \x{2193}187 \x{2502} \x{3a3} 5.4k \x{2502} pp 812/s tg 52/s \x{2502} cache 4.1k",
        "after: context, tokens of the request, of the session, both speeds, the cache");
    unlike($ai::TUI->info_line(), qr/~/, "after: the live estimate is gone");
    is(scalar(@{$ai::TUI->{order}}), 0, "after: no activity left");
    unlike($out, qr/\[tokens:/, "with a footer the usage line is not printed too");
    {
        local $::ORIG_ENV{AI_SHOW_USAGE} = 1;
        TestAI::mock_http([TestAI::content("x"), TestAI::usage(10, 2), TestAI::done()]);
        like(TestAI::capture {ai::chat_completion("again")}, qr/\[tokens: 10 in/, "unless AI_SHOW_USAGE=1 asks for it");
        unlike($ai::TUI->info_line(), qr/pp |cache/, "speed and cache are those of the last request: gone when it reported none");
    }

    # it follows the session, the model, the conversation
    TestAI::capture {ai::handle_command("/model other-model")};
    like($ai::TUI->info_line(), qr/\Atest \x{2502} other-model \x{2502}/, "/model: shown");
    TestAI::capture {ai::handle_command("/session create fresh")};
    is($ai::TUI->info_line(), "fresh \x{2502} big-model \x{2502} ctx 0% of 32k", "/session: the numbers of that session, not the speed of a request in another");
    {
        local $::ORIG_ENV{AI_TOKEN_BUDGET} = 100_000;
        local $::ORIG_ENV{AI_CONTEXT_TOKENS} = 0;
        ai::save_usage({total_tokens => 48_213, last_prompt_tokens => 5210, last_completion_tokens => 187, estimated => 1});
        ai::status_info();
        like($ai::TUI->info_line(), qr/ctx ~5\.4k \x{2502} \x{2191}~5\.2k \x{2193}187 \x{2502} \x{3a3} ~48k of 100k/, "estimates are marked, the budget is shown, no percentage without a known window");
    }
    $ai::TUI->close();
}

# widths: what a column is, and a footer that never gets wider than the terminal
{
    is(tui::_cols("abc"), 3, "columns: ascii is one each");
    is(tui::_cols("\x{3042}\x{3044}"), 4, "columns: hiragana are two each");
    is(tui::_cols("e\x{301}"), 1, "columns: a combining mark takes none");
    is(tui::_cols("\x{1F600}"), 2, "columns: an emoji is two");
    is(tui::_text("a\x{1F600}b\x{200D}c"), "a?bc", "text: emoji shown as ?, joiners dropped");

    my $tui = fresh(width => 20);
    $tui->set(work => "\x{3042}" x 30);
    $tui->info(model => "\x{3044}" x 30);
    my $line = $tui->line();
    cmp_ok(tui::_cols($line), "<=", 19, "footer: activity line cut by columns, not characters");
    like($line, qr/\x{2026}\z/, "footer: cut lines end with the ellipsis");
    cmp_ok(tui::_cols($tui->info_line()), "<=", 19, "footer: info line cut by columns");

    {
        local $::ORIG_ENV{AI_GLYPHS} = "ascii";
        is(tui::glyph("sep"), " | ", "ascii: separator");
        my $t2 = fresh(width => 60);
        $t2->info(tokens => tui::glyph("up")."200 ".tui::glyph("down")."7");
        $t2->info(total => tui::glyph("sum")." 207");
        $t2->set(work => "waiting");
        my $all = $t2->line()." / ".$t2->info_line();
        ok($all !~ m/[^\x00-\x7f]/, "ascii: nothing outside ASCII on the footer");
        like($t2->info_line(), qr/in:200 out:7 \| sum: 207/, "ascii: arrows and sum as words");
    }
    {
        local $::ORIG_ENV{AI_GLYPHS};
        local $::ORIG_ENV{LC_ALL};
        local $::ORIG_ENV{LC_CTYPE};
        local $::ORIG_ENV{LANG} = "C";
        ok(!tui::unicode_ok(), "glyphs: a C locale gets the ASCII set");
        $::ORIG_ENV{LANG} = "en_US.UTF-8";
        ok(tui::unicode_ok(), "glyphs: a UTF-8 locale gets the Unicode set");
        $::ORIG_ENV{LC_ALL} = "C";
        ok(!tui::unicode_ok(), "glyphs: LC_ALL wins over LANG");
    }
}

done_testing();
