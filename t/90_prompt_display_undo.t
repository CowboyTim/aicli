#!/usr/bin/perl
# project instructions and date in the system prompt (and that the start of
# the conversation never changes), the brief tool display, diffs, /undo
use strict; use warnings;

use Test::More;
use FindBin;
use POSIX ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my ($Y, $G, $R, $RED, $C) = ($colors::yellow_color1, $colors::green_color, $colors::reset_color, $colors::red_color, $colors::cyan_color);
my $bash = sub {"///BASH_7c48+EO_dfd7\n$_[0]\nEO_dfd7\nBASH_7c48\n"};
my $ok   = sub {[TestAI::content($_[0] // "fine"), TestAI::done()]};
my $dot  = "\xe2\x97\x8f";
sub cmd {
    my ($line) = @_;
    return TestAI::capture {ai::handle_command($line)};
}
sub sys_prompt {
    return (ai::load_messages())[0]{content};
}

# the date: coarse by default, configurable
{
    my $tmp = TestAI::setup(AI_PROMPT_DATE => undef);
    my $month = POSIX::strftime("%B %Y", localtime());
    like(sys_prompt(), qr/\n\nCurrent date: \Q$month\E\n\z/, "date: month and year by default ($month)");
    unlike(sys_prompt(), qr/\d\d:\d\d/, "date: no time of day");
    foreach my $case ([year => '%Y'], [day => '%Y-%m-%d'], [month => '%B %Y'], ['%d/%m/%Y' => '%d/%m/%Y']){
        local $::ORIG_ENV{AI_PROMPT_DATE} = $case->[0];
        is(ai::prompt_date(), POSIX::strftime($case->[1], localtime()), "date: AI_PROMPT_DATE=$case->[0]");
    }
    foreach my $off ('none', 'off', '0', ''){
        local $::ORIG_ENV{AI_PROMPT_DATE} = $off;
        is(ai::prompt_date(), '', "date: AI_PROMPT_DATE='$off' leaves it out");
        unlike(ai::system_prompt(), qr/Current date/, "date: '$off' no line in the prompt");
    }
}

# project instructions
{
    my $tmp = TestAI::setup(AI_PROJECT_FILE => undef, AI_PROMPT_DATE => 'year');
    unlike(sys_prompt(), qr/PROJECT INSTRUCTIONS/, "project: nothing without a file");
    mkdir "$tmp/proj" or die $!;
    chdir("$tmp/proj") or die $!;
    ai::spew("AGENTS.md", "# Rules\n- never use threads\n");
    cmd("/clear");
    my $p = sys_prompt();
    like($p, qr/\n\n\*\*PROJECT INSTRUCTIONS\*\* \(from AGENTS\.md in the working directory\)\n\n# Rules\n- never use threads\n/, "project: AGENTS.md of the working directory is in the prompt");
    like($p, qr/\AYou are a master developer.*LIST OF TOOLS.*PROJECT INSTRUCTIONS.*Current date: \d{4}\n\z/s, "project: template, tools, project, date - the stable parts first");
    like(ai::subagent_prompt(), qr/You are a sub-agent.*PROJECT INSTRUCTIONS.*never use threads.*Current date/s, "project: sub-agents get it too");

    {
        local $::ORIG_ENV{AI_PROJECT_FILE} = "CLAUDE.md, missing.md AGENTS.md";
        ai::spew("CLAUDE.md", "other rules");
        like(ai::project_instructions(), qr/from CLAUDE\.md.*other rules\n.*from AGENTS\.md.*never use threads/s, "project: AI_PROJECT_FILE lists the files");
        local $::ORIG_ENV{AI_PROJECT_FILE} = "";
        is(ai::project_instructions(), "", "project: empty AI_PROJECT_FILE switches it off");
    }
    {
        local $::ORIG_ENV{AI_PROJECT_FILE_MAX} = 20;
        like(ai::project_instructions(), qr/# Rules\n- never use \n\[\.\.\. AGENTS\.md is cut here, it is longer \.\.\.\]\n\z/, "project: a huge file is cut");
    }
    ai::spew("empty.md", "  \n");
    {
        local $::ORIG_ENV{AI_PROJECT_FILE} = "empty.md";
        is(ai::project_instructions(), "", "project: an empty file adds nothing");
    }
}

# the start of the conversation never changes: what a prefix cache needs
{
    my $tmp = TestAI::setup(AI_PROJECT_FILE => undef, AI_PROMPT_DATE => '%Y-%m-%d %H:%M:%S');
    mkdir "$tmp/proj" or die $!;
    chdir("$tmp/proj") or die $!;
    ai::spew("AGENTS.md", "version one\n");
    cmd("/clear");
    my $first = sys_prompt();
    like($first, qr/version one/, "stable: prompt made");
    my $raw_chat = ai::slurp($ai::STATUS_FILE);

    TestAI::mock_http([TestAI::content($bash->('echo one')), TestAI::done()], $ok->("done"), $ok->("more"), $ok->("again"));
    TestAI::capture {ai::chat_completion("first")};
    # the project file and the clock change, the session does not notice
    ai::spew("AGENTS.md", "version two\n");
    sleep 1;
    TestAI::capture {ai::chat_completion("second")};
    TestAI::capture {cmd("/system extra"); ai::chat_completion("third")};
    is(sys_prompt(), $first, "stable: the system prompt of a session is made once");
    is(substr(ai::slurp($ai::STATUS_FILE), 0, length($raw_chat)), $raw_chat, "stable: the chat file only grows");

    my @raw = map {$_->{data}} @TestAI::REQUESTS;
    is(scalar(@raw), 4, "stable: 4 requests");
    my @m = map {
        my $at = index($_, '"messages":[');
        ok($at > 0, "stable: request has messages");
        [substr($_, 0, $at), substr($_, $at) =~ s/\][^\]]*\z//r];
    } @raw;
    foreach my $i (1 .. 3){
        is($m[$i][0], $m[0][0], "stable: request ".($i + 1)." starts with the same bytes before the messages");
        is(substr($m[$i][1], 0, length($m[$i - 1][1])), $m[$i - 1][1], "stable: request ".($i + 1)." = request $i + new messages, byte for byte");
        ok(length($m[$i][1]) > length($m[$i - 1][1]), "stable: and it grew");
    }
    # the same session in a new process sends the same bytes
    my $again = JSON::XS->new->utf8->canonical->encode([ai::load_messages()]);
    like($raw[3], qr/\Q${\ substr($again, 0, 200)}\E/, "stable: encoding does not depend on the process");

    cmd("/clear");
    like(sys_prompt(), qr/version two/, "stable: /clear starts over with the current file");
}

# the printer hides tool calls, whatever the chunks look like
{
    TestAI::setup();
    my $answer = "Let me look.\n\n".$bash->("ls -la\necho done")."// not a tool\n///NOPE_1 neither\n  /// nor this\na /// b\n"
        ."///WRITE_edf5+EO_d068+EO_ecde\nf.txt\nEO_d068[5]\ncontent\nwith ///BASH_7c48 inside\nEO_ecde\nWRITE_edf5\nThe end /";
    my $want = "Let me look.\n\n// not a tool\n///NOPE_1 neither\n  /// nor this\na /// b\nThe end /\n";
    foreach my $size (1, 2, 3, 5, 7, 16, 1000){
        my $got = '';
        my $p = ai::new_printer(sub {$got .= $_[0]}, hide_tools => 1);
        $p->{emit}->('text', $_) for unpack("(a$size)*", $answer);
        $p->{finish}->();
        $got =~ s/\e\[[0-9;]*m//g;
        is($got, $want, "hide: tool calls gone, the rest stays (chunks of $size)");
    }
    my $got = '';
    my $p = ai::new_printer(sub {$got .= $_[0]});
    $p->{emit}->('text', $answer);
    $p->{finish}->();
    like($got, qr{///BASH_7c48\+EO_dfd7\nls -la}, "hide: off by default, everything is shown");

    # a call that is never closed hides the rest, a half header is shown in the end
    $got = '';
    $p = ai::new_printer(sub {$got .= $_[0]}, hide_tools => 1);
    $p->{emit}->('text', "ok\n///BASH_7c48+EO_dfd7\nsleep 1\n");
    $p->{finish}->();
    is($got =~ s/\e\[[0-9;]*m//gr, "ok\n", "hide: an unclosed call stays hidden");
    $got = '';
    $p = ai::new_printer(sub {$got .= $_[0]}, hide_tools => 1);
    $p->{emit}->('text', "see ///BASH\n///BASH_7c");
    $p->{finish}->();
    is($got =~ s/\e\[[0-9;]*m//gr, "see ///BASH\n///BASH_7c\n", "hide: what never became a call is shown at the end");
}

# the brief display of a whole turn
{
    my $tmp = TestAI::setup(AI_TOOL_DISPLAY => 'brief', COLUMNS => 60);
    chdir($tmp) or die $!;
    TestAI::mock_http(
        [(map {TestAI::content($_)} unpack("(a9)*", "I check.\n".$bash->("seq 1 20\necho the end")."and write:\n"
            ."///WRITE_edf5+EO_d068+EO_ecde\nnew.txt\nEO_d068\none\ntwo\nEO_ecde\nWRITE_edf5\n")), TestAI::done()],
        [TestAI::content($bash->('echo oops >&2; exit 3')."///READ_c5a3+EO_d0f1\nnew.txt\nEO_d0f1\nREAD_c5a3\n"), TestAI::done()],
        $ok->("All done."),
    );
    my $out = TestAI::capture {ai::chat_completion("go")};
    unlike($out, qr{///|EO_dfd7|BASH_7c48|RESULT_d170|ERROR_9a78}, "brief: no tool syntax on the screen");
    like($out, qr/\A\Q${G}\EI check\./, "brief: the text of the model is there");
    like($out, qr/\Q${Y}$dot bash${R} seq 1 20 (+1 lines)\E\n/, "brief: one line per call, with what it is about");
    like($out, qr/\Q${G}\E  1\n  2\n  3\n  4\n  5\n  6\n  7\n  8\n  \.\.\. \+13 more lines\n\Q${R}\E/, "brief: the first lines of the result");
    like($out, qr/write:.*\Q${Y}$dot write${R} new.txt\E\n  \Q${C}\Enew\.txt \(new\): \+2 -0\Q${R}\E\n.*\Q${G}\E\+ one\Q${R}\E\n  \Q${G}\E\+ two\Q${R}\E\n/s, "brief: a written file shows as a diff");
    unlike($out, qr/\[OK\] written/, "brief: the diff stands in for the result line");
    like($out, qr/\Q${Y}$dot bash${R} echo oops >&2; exit 3\E\n\Q${RED}\E  exit code: 3, output: oops\n\Q${R}\E/, "brief: errors in red, without the wrapping");
    like($out, qr/\Q${Y}$dot read${R} new.txt\E\n\Q${G}\E  one\n  two\n\Q${R}\E/, "brief: short results in full");
    like($out, qr/All done\./, "brief: final answer");
    # the model still gets everything
    my @msgs = ai::load_messages();
    like($msgs[2]{content}, qr{\AI check\.\n///BASH_7c48\+EO_dfd7\nseq 1 20}, "brief: the stored answer has the tool calls");
    like($msgs[3]{content}, qr/\A\[BASH_7c48 RESULT_d170\n1\n2\n.*\n20\nthe end\n/s, "brief: the model gets the whole result");

    # how many lines
    local $::ORIG_ENV{AI_TOOL_LINES} = 2;
    TestAI::mock_http([TestAI::content($bash->('seq 1 5')), TestAI::done()], $ok->());
    $out = TestAI::capture {ai::chat_completion("again")};
    like($out, qr/  1\n  2\n  \.\.\. \+3 more lines\n/, "brief: AI_TOOL_LINES");
    local $::ORIG_ENV{AI_TOOL_DISPLAY} = 'full';
    TestAI::mock_http([TestAI::content($bash->('echo full')), TestAI::done()], $ok->());
    $out = TestAI::capture {ai::chat_completion("full")};
    like($out, qr{///BASH_7c48\+EO_dfd7.*\Q[TOOL BASH_7c48(...))]\E.*\[BASH_7c48 RESULT_d170\nfull\n}s, "full: AI_TOOL_DISPLAY=full shows it all");
}

# diffs
{
    TestAI::setup(COLUMNS => 80);
    my $d = sub {join('', map {"$_->[0]$_->[1]\n"} ai::diff_lines(@_))};
    is($d->("a\nb\nc\n", "a\nB\nc\n"), " a\n-b\n+B\n c\n", "diff: one line changed");
    is($d->("a\nb\n", "a\nb\nc\n"), " a\n b\n+c\n", "diff: line added at the end");
    is($d->("a\nb\nc\n", "b\nc\n"), "-a\n b\n c\n", "diff: line removed at the start");
    is($d->("", "x\ny\n"), "+x\n+y\n", "diff: new file");
    is($d->("x\n", ""), "-x\n", "diff: emptied");
    is($d->("a\nb\nc\nd\ne\n", "a\nX\nc\nY\ne\n"), " a\n-b\n+X\n c\n-d\n+Y\n e\n", "diff: two separate changes");
    is($d->("a\nb\nc\n", "a\nc\nb\n"), " a\n-b\n c\n+b\n", "diff: a moved line");
    is($d->("same\n", "same\n"), " same\n", "diff: no change");
    is($d->("a\nb", "a\nb\n"), " a\n b\n", "diff: only the final newline differs: no line changed");

    my $old = join('', map {"line $_\n"} 1 .. 30);
    (my $new = $old) =~ s/line 15\n/line fifteen\nand more\n/;
    $new =~ s/line 28\n//;
    my ($text, $added, $removed) = ai::format_diff($old, $new);
    is_deeply([$added, $removed], [2, 2], "format: counts");
    (my $plain = $text) =~ s/\e\[[0-9;]*m//g;
    is($plain, "  @@ line 13 @@\n    line 13\n    line 14\n  - line 15\n  + line fifteen\n  + and more\n    line 16\n    line 17\n"
              ."  @@ line 26 @@\n    line 26\n    line 27\n  - line 28\n    line 29\n    line 30\n", "format: hunks with context and the line number");
    like($text, qr/\Q${RED}\E- line 15\Q${R}\E\n  \Q${G}\E\+ line fifteen\Q${R}\E/, "format: red and green");
    ($text) = ai::format_diff($old, "", max => 5);
    is(scalar(() = $text =~ m/^  \S*- line/mg), 5, "format: at most max lines");
    like($text, qr/\.\.\. the diff goes on/, "format: says that there is more");
    is_deeply([ai::format_diff("a\n", "a\n")], ['', 0, 0], "format: nothing for no change");
    ($text) = ai::format_diff("", ("x" x 300)."\n");
    ok(length(($text =~ m/\+ (x+)/)[0]) < 80, "format: long lines are cut to the terminal");

    # shown after an edit, with or without the brief display
    my $tmp = $TestAI::TMP;
    chdir($tmp) or die $!;
    ai::spew("d.txt", "one\ntwo\nthree\n");
    my $edit = "///EDIT_b3e1+EO_0c7a+EO_d95f\nd.txt\nEO_0c7a\n2c\nTWO\n.\nEO_d95f\nEDIT_b3e1\n";
    my $out = TestAI::capture {ai::handle_llm_response(\$edit)};
    like($out, qr/\[EDIT_b3e1 RESULT_d170\n\[OK\] edited d\.txt.*d\.txt: \+1 -1.*- two.*\+ TWO/s, "shown: after the full result too");
    {
        local $::ORIG_ENV{AI_SHOW_DIFF} = 0;
        local $::ORIG_ENV{AI_TOOL_DISPLAY} = 'brief';
        my $repl = "///REPLACE_91c4+EO_5a0e+EO_c2b7+EO_f61d\nd.txt\nEO_5a0e\nTWO\nEO_c2b7\n2\nEO_f61d\nREPLACE_91c4\n";
        $out = TestAI::capture {ai::handle_llm_response(\$repl)};
        unlike($out, qr/-.*TWO/, "shown: AI_SHOW_DIFF=0 hides the diff");
        like($out, qr/\[OK\] replaced in d\.txt/, "shown: the result line instead");
    }
    my @printed;
    ai::handle_llm_response(\$edit =~ s/2c\nTWO/1c\nONE/r, sub {push @printed, $_[0]});
    is(scalar(@printed), 2, "shown: a printer of the caller gets call and result, no diff");
    is(scalar(@tools::CHANGES), 0, "shown: changes are not kept around");
}

# /undo
{
    my $tmp = TestAI::setup();
    chdir($tmp) or die $!;
    my $tool = sub {my ($name, @args) = @_; my @r = ai::execute_tool($name, uc($name), \@args); @tools::CHANGES = (); @r};
    like(cmd("/undo"), qr/Cannot undo: nothing to undo/, "undo: nothing yet");
    like(cmd("/undo list"), qr/Nothing to undo/, "undo list: nothing yet");

    ai::spew("keep.txt", "original\n");
    chmod(0640, "keep.txt");
    $tool->("write", "keep.txt", "overwritten\n");
    $tool->("write", "created.txt", "brand new\n");
    $tool->("replace", "keep.txt", "overwritten", "replaced");
    $tool->("edit", "keep.txt", "1a\nappended\n.");
    $tool->("mkdir", "a/b/c");
    $tool->("move", "created.txt", "a/b/moved.txt");
    $tool->("delete", "a/b/moved.txt");
    $tool->("delete", "a/b/c");
    is(ai::slurp("keep.txt"), "replaced\nappended\n", "undo: all changes are there");
    ok(!-e "a/b/moved.txt" && !-d "a/b/c", "undo: deleted");

    my $list = cmd("/undo list");
    is(scalar(() = $list =~ m/^\s*\d+  /mg), 8, "undo list: 8 changes");
    like($list, qr/\A  8  delete \S+\/a\/b\/c\n  7  delete \S+\/a\/b\/moved\.txt\n  6  move \S+\/created\.txt -> \S+\/a\/b\/moved\.txt\n/, "undo list: newest first");
    like($list, qr/  2  write \S+\/created\.txt \(new file\)\n  1  write \S+\/keep\.txt\n\z/, "undo list: oldest last");

    like(cmd("/undo"), qr/Undone: delete \S+\/a\/b\/c/, "undo: says what");
    ok(-d "a/b/c", "undo: deleted directory is back");
    cmd("/undo");
    is(ai::slurp("a/b/moved.txt"), "brand new\n", "undo: deleted file is back, with its content");
    cmd("/undo");
    ok(-e "created.txt" && !-e "a/b/moved.txt", "undo: moved back");
    cmd("/undo");
    ok(!-d "a", "undo: created directories removed");
    cmd("/undo");
    is(ai::slurp("keep.txt"), "replaced\n", "undo: edit taken back");
    cmd("/undo");
    is(ai::slurp("keep.txt"), "overwritten\n", "undo: replace taken back");
    cmd("/undo");
    ok(!-e "created.txt", "undo: a new file is removed");
    cmd("/undo");
    is(ai::slurp("keep.txt"), "original\n", "undo: the overwritten file has its old content");
    is((stat("keep.txt"))[2] & 07777, 0640, "undo: and its mode");
    like(cmd("/undo"), qr/nothing to undo/, "undo: journal is empty");
    is(scalar(() = glob("$tmp/aicli/sessions/test/undo/[0-9]*")), 0, "undo: copies are cleaned up");

    # what cannot be undone says so and stays in the journal
    $tool->("move", "keep.txt", "elsewhere.txt");
    ai::spew("keep.txt", "in the way\n");
    like(cmd("/undo"), qr/Cannot undo: \S+keep\.txt exists again/, "undo: refuses to overwrite");
    is(scalar(ai::undo_journal()), 1, "undo: the change is still in the journal");
    unlink("keep.txt");
    cmd("/undo");
    is(ai::slurp("keep.txt"), "original\n", "undo: works once the way is free");

    # failed tools leave nothing behind, sub-agents are covered, per session
    $tool->("edit", "keep.txt", "99d");
    $tool->("replace", "keep.txt", "not there", "x");
    is(scalar(ai::undo_journal()), 0, "undo: a failed edit is not a change");
    ai::execute_tool_async("write", "WRITE_edf5", ["agent.txt", "by an agent\n"], sub {});
    is(scalar(ai::undo_journal()), 1, "undo: changes of sub-agents are in the journal");
    cmd("/session create other");
    is(scalar(ai::undo_journal()), 0, "undo: the journal is per session");
    cmd("/session test");
    cmd("/undo");
    ok(!-e "agent.txt", "undo: back in the session, undone");
    {
        local $::ORIG_ENV{AI_UNDO_MAX_SIZE} = 10;
        ai::spew("big.txt", "x" x 100);
        $tool->("write", "big.txt", "small");
        like(cmd("/undo"), qr/Cannot undo: no copy of the old content was kept/, "undo: files over AI_UNDO_MAX_SIZE are not copied");
    }
}

chdir("/");
done_testing();
