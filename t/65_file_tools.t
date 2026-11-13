#!/usr/bin/perl
# the file tools in plain perl: lines, replace, edit (ed script), delete, move, mkdir, list
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = TestAI::setup();
chdir($tmp) or die $!;

sub tool {
    my ($name, @args) = @_;
    return ai::execute_tool($name, uc($name), \@args);
}
sub ed_ok {
    my ($text, $script, $want, $name) = @_;
    my $got = eval {tools::ed_apply($text, $script)};
    is($got, $want, $name) or diag($@);
}
sub ed_fails {
    my ($text, $script, $rx, $name) = @_;
    my $got = eval {tools::ed_apply($text, $script)};
    like($@, $rx, $name);
}

# no process is started for these: fork would show
{
    no warnings 'redefine';
    local *utils::fork_run = sub {die "a file tool forked\n"};
    ai::spew("nofork.txt", "a\nb\n");
    is((tool("lines", "nofork.txt", ""))[1], undef, "lines: in-process");
    is((tool("replace", "nofork.txt", "a", "A"))[1], undef, "replace: in-process");
    is((tool("edit", "nofork.txt", "1d"))[1], undef, "edit: in-process");
    is((tool("mkdir", "nofork.d"))[1], undef, "mkdir: in-process");
    is((tool("move", "nofork.txt", "nofork.d"))[1], undef, "move: in-process");
    is((tool("list", "nofork.d"))[1], undef, "list: in-process");
    is((tool("delete", "nofork.d/nofork.txt"))[1], undef, "delete: in-process");
    is((tool("delete", "nofork.d"))[1], undef, "delete dir: in-process");
}

my $five = join('', map {"line $_\n"} 1 .. 5);

# lines
{
    ai::spew("five.txt", $five);
    my ($out, $err) = tool("lines", "five.txt", "");
    is($out, "1\tline 1\n2\tline 2\n3\tline 3\n4\tline 4\n5\tline 5\n", "lines: whole file numbered");
    is((tool("lines", "five.txt", "2-3"))[0], "2\tline 2\n3\tline 3\n", "lines: range");
    is((tool("lines", "five.txt", " 4 "))[0], "4\tline 4\n", "lines: one line");
    is((tool("lines", "five.txt", "4-"))[0], "4\tline 4\n5\tline 5\n", "lines: open end");
    is((tool("lines", "five.txt", "4-99"))[0], "4\tline 4\n5\tline 5\n", "lines: end is clamped");
    like((tool("lines", "five.txt", "9-12"))[1], qr/no such lines, five.txt has 5 lines/, "lines: beyond the end");
    like((tool("lines", "five.txt", "abc"))[1], qr/bad range 'abc'/, "lines: bad range");
    like((tool("lines", "missing.txt", ""))[1], qr/cannot read missing.txt/, "lines: missing file");
    ai::spew("noeol.txt", "a\nb");
    is((tool("lines", "noeol.txt", ""))[0], "1\ta\n2\tb\n", "lines: file without final newline");
}

# replace
{
    ai::spew("r.pl", "sub a {\n    return 1;\n}\n\nsub b {\n    return 1;\n}\n");
    my ($out, $err) = tool("replace", "r.pl", "sub b {\n    return 1;", "sub b {\n    return 2;");
    is_deeply([$out, $err], ["[OK] replaced in r.pl at line 5", undef], "replace: done, says where");
    is(ai::slurp("r.pl"), "sub a {\n    return 1;\n}\n\nsub b {\n    return 2;\n}\n", "replace: only that place");
    ($out, $err) = tool("replace", "r.pl", "    return ", "    return 0+");
    like($err, qr/the old text is 2 times in r.pl/, "replace: must be unique");
    ($out, $err) = tool("replace", "r.pl", "return 3;", "x");
    like($err, qr/the old text is not in r.pl/, "replace: must be there");
    ($out, $err) = tool("replace", "r.pl", "", "x");
    like($err, qr/the old text is empty/, "replace: needs old text");
    is(ai::slurp("r.pl"), "sub a {\n    return 1;\n}\n\nsub b {\n    return 2;\n}\n", "replace: failures change nothing");
    tool("replace", "r.pl", "\nsub b {\n    return 2;\n}\n", "");
    is(ai::slurp("r.pl"), "sub a {\n    return 1;\n}\n", "replace: empty new text removes");
    tool("replace", "r.pl", "return 1;", 'return $x{a.b}[0] =~ /^\d+$/;');
    is(ai::slurp("r.pl"), "sub a {\n    return \$x{a.b}[0] =~ /^\\d+\$/;\n}\n", "replace: no regex or variable magic in the texts");
    chmod(0755, "r.pl");
    tool("replace", "r.pl", "sub a", "sub c");
    is((stat("r.pl"))[2] & 07777, 0755, "replace: file mode kept");
    is(scalar(() = glob("r.pl.aicli.*")), 0, "replace: no temp file left");
}

# the ed script engine
{
    ed_ok($five, "2d", "line 1\nline 3\nline 4\nline 5\n", "ed: d");
    ed_ok($five, "2,4d", "line 1\nline 5\n", "ed: d range");
    ed_ok($five, "\$d", "line 1\nline 2\nline 3\nline 4\n", "ed: \$ is the last line");
    ed_ok($five, "2a\nnew a\nnew b\n.", "line 1\nline 2\nnew a\nnew b\nline 3\nline 4\nline 5\n", "ed: a");
    ed_ok($five, "0a\ntop\n.", "top\n$five", "ed: 0a prepends");
    ed_ok($five, "\$a\nend\n.", "${five}end\n", "ed: \$a appends");
    ed_ok($five, "3i\nbefore 3\n.", "line 1\nline 2\nbefore 3\nline 3\nline 4\nline 5\n", "ed: i");
    ed_ok($five, "2,4c\nmiddle\n.", "line 1\nmiddle\nline 5\n", "ed: c range");
    ed_ok($five, "3c\n.", "line 1\nline 2\nline 4\nline 5\n", "ed: c with no text deletes");
    ed_ok($five, "2a\n\n  indented\n\n.", "line 1\nline 2\n\n  indented\n\nline 3\nline 4\nline 5\n", "ed: empty lines and indent in the text");
    ed_ok($five, "3s/line/LINE/", "line 1\nline 2\nLINE 3\nline 4\nline 5\n", "ed: s");
    ed_ok($five, "1,\$s/l(i)ne (\\d)/\\2:\\1:&/", join('', map {"$_:i:line $_\n"} 1 .. 5), "ed: s with groups and &");
    ed_ok("a a a\n", "1s/a/b/", "b a a\n", "ed: s replaces the first");
    ed_ok("a a a\n", "1s/a/b/g", "b b b\n", "ed: s///g replaces all");
    ed_ok("Aa\n", "1s/a/x/gi", "xx\n", "ed: s///i");
    ed_ok("a/b\n", "1s|/|::|", "a::b\n", "ed: s with another delimiter");
    ed_ok("a/b\n", "1s/\\//::/", "a::b\n", "ed: s with escaped delimiter");
    ed_ok("cost\n", "1s/cost/& \\& \\\\ \$0/", "cost & \\ cost\n", "ed: &, literal \\& and \\\\, \$0 in the replacement");

    # addresses by regex
    my $code = "use strict;\nsub foo {\n    1;\n}\nsub bar {\n    2;\n}\n";
    ed_ok($code, "/sub bar/,/^}/d", "use strict;\nsub foo {\n    1;\n}\n", "ed: /regex/,/regex/ range, 2nd searched after the 1st");
    ed_ok($code, "/sub foo/a\n    my \$x;\n.", "use strict;\nsub foo {\n    my \$x;\n    1;\n}\nsub bar {\n    2;\n}\n", "ed: /regex/ address");
    ed_ok($code, "/sub foo/,\$s/^    //", "use strict;\nsub foo {\n1;\n}\nsub bar {\n2;\n}\n", "ed: regex to \$ range");
    ed_fails($code, "/sub baz/d", qr/command 1 \(\/sub baz\/d\): no line matches \/sub baz\//, "ed: regex without a match");

    # several commands: numbers are those after the previous command
    ed_ok($five, "4,5d\n2c\ntwo\n.\n1i\nzero\n.", "zero\nline 1\ntwo\nline 3\n", "ed: bottom to top");
    ed_ok($five, "1d\n1d", "line 3\nline 4\nline 5\n", "ed: numbers shift like in ed");
    ed_ok($five, "\n2d\nw\nq\n", "line 1\nline 3\nline 4\nline 5\n", "ed: empty lines, w and q are ignored");

    # files without final newline, empty files
    ed_ok("a\nb", "1d", "b", "ed: no final newline stays that way");
    ed_ok("", "0a\nfirst\n.", "first\n", "ed: empty file");
    ed_ok("only\n", "1d", "", "ed: deleting everything");

    # errors name the command
    ed_fails($five, "9d", qr/command 1 \(9d\): no line 9, the file has 5 lines/, "ed: line out of range");
    ed_fails($five, "4,2d", qr/line 4 is after line 2/, "ed: reversed range");
    ed_fails($five, "0d", qr/no line 0/, "ed: line 0 only for a");
    ed_fails($five, "d", qr/needs a line address/, "ed: no address");
    ed_fails($five, "2a\ntext without end", qr/not closed by a line with only a dot/, "ed: missing dot");
    ed_fails($five, "2a text", qr/text follows on the next lines/, "ed: text on the command line");
    ed_fails($five, "2x", qr/command 1: cannot parse '2x'/, "ed: unknown command");
    ed_fails($five, "2s/nope/x/", qr/no match for \/nope\/ in line 2/, "ed: s without a match");
    ed_fails($five, "2s/(/x/", qr/bad regex/, "ed: bad regex");
    ed_fails($five, "1d\n7d", qr/command 2 \(7d\)/, "ed: the failing command is named");
    ed_fails($five, "\n", qr/no commands/, "ed: empty script");
}

# edit: the tool
{
    ai::spew("e.pl", "#!/usr/bin/perl\nprint \"Hello, World!\\n\";\nexit 0;\n");
    chmod(0750, "e.pl");
    my ($out, $err) = tool("edit", "e.pl", "2c\nmy \$name = shift // \"World\";\nprint \"Hello, \$name!\\n\";\n.\n1a\nuse strict;\n.");
    is_deeply([$out, $err], ["[OK] edited e.pl: 3 -> 5 lines", undef], "edit: done");
    is(ai::slurp("e.pl"), "#!/usr/bin/perl\nuse strict;\nmy \$name = shift // \"World\";\nprint \"Hello, \$name!\\n\";\nexit 0;\n", "edit: file changed");
    is((stat("e.pl"))[2] & 07777, 0750, "edit: file mode kept");
    my $before = ai::slurp("e.pl");
    ($out, $err) = tool("edit", "e.pl", "1d\n99d");
    like($err, qr/problem running tool 'EDIT': command 2 \(99d\): no line 99/, "edit: error names the command");
    is(ai::slurp("e.pl"), $before, "edit: nothing written when a command fails");
    ($out, $err) = tool("edit", "e.pl", "2s/strict/strict/");
    is($out, "[OK] no change in e.pl", "edit: no change is said");
    like((tool("edit", "missing.pl", "1d"))[1], qr/cannot read missing.pl/, "edit: missing file");
    is(scalar(() = glob("e.pl.aicli.*")), 0, "edit: no temp file left");

    # as the model would call it, with a dot line inside the tool call
    my $call = "///EDIT_b3e1+EO_0c7a+EO_d95f\ne.pl\nEO_0c7a\n\$a\n# the end\n.\nEO_d95f\nEDIT_b3e1\n";
    my ($n, undef, $r) = ai::handle_llm_response(\$call, sub {});
    is($r->[0]{content}, "[EDIT_b3e1 RESULT_d170\n[OK] edited e.pl: 5 -> 6 lines\nRESULT_d170]", "edit: through the parser");
    like(ai::slurp("e.pl"), qr/exit 0;\n# the end\n\z/, "edit: appended");
}

# delete, move, mkdir, list
{
    my ($out, $err) = tool("mkdir", "d1/d2/d3");
    is_deeply([$out, $err], ["[OK] created d1/d2/d3", undef], "mkdir: with parents");
    ok(-d "d1/d2/d3", "mkdir: there");
    is((tool("mkdir", "d1/d2"))[0], "[OK] d1/d2 exists already", "mkdir: existing is fine");
    ai::spew("d1/file.txt", "12345");
    like((tool("mkdir", "d1/file.txt/x"))[1], qr/cannot create d1\/file.txt\/x/, "mkdir: failure");

    ($out, $err) = tool("move", "d1/file.txt", "d1/d2/renamed.txt");
    is_deeply([$out, $err], ["[OK] moved d1/file.txt to d1/d2/renamed.txt", undef], "move: rename");
    ok(!-e "d1/file.txt" && -s "d1/d2/renamed.txt" == 5, "move: on disk");
    ($out, $err) = tool("move", "d1/d2/renamed.txt", "d1");
    is($out, "[OK] moved d1/d2/renamed.txt to d1/renamed.txt", "move: into a directory");
    ai::spew("d1/other.txt", "x");
    like((tool("move", "d1/other.txt", "d1/renamed.txt"))[1], qr/d1\/renamed.txt exists already/, "move: never overwrites");
    is(ai::slurp("d1/renamed.txt"), "12345", "move: target untouched");
    like((tool("move", "d1/nope", "d1/x"))[1], qr/no such file: d1\/nope/, "move: missing source");
    ($out, $err) = tool("move", "d1/d2", "d1/dir2");
    ok(-d "d1/dir2/d3", "move: directories too");

    symlink("renamed.txt", "d1/link");
    ($out, $err) = tool("list", "d1");
    is($out, "d          - dir2/\nl         11 link\nf          1 other.txt\nf          5 renamed.txt\n", "list: type, size, name, sorted");
    is((tool("list", ""))[1], undef, "list: empty path is the current directory");
    like((tool("list", "d1/nope"))[1], qr/cannot list d1\/nope/, "list: missing directory");

    ($out, $err) = tool("delete", "d1/other.txt");
    is_deeply([$out, $err], ["[OK] deleted d1/other.txt", undef], "delete: file");
    ok(!-e "d1/other.txt", "delete: gone");
    ($out, $err) = tool("delete", "d1/link");
    ok(!-l "d1/link" && -e "d1/renamed.txt", "delete: a symlink, not its target");
    like((tool("delete", "d1/dir2"))[1], qr/cannot remove directory d1\/dir2: /, "delete: not a directory with content");
    ok(-d "d1/dir2/d3", "delete: content is still there");
    is((tool("delete", "d1/dir2/d3"))[0], "[OK] removed directory d1/dir2/d3", "delete: empty directory");
    like((tool("delete", "d1/nope"))[1], qr/no such file: d1\/nope/, "delete: missing");
    like((tool("delete", ""))[1], qr/no path/, "delete: needs a path");
}

# find: the walk with its filter, prune, depth and max subs, and the tool
{
    mkdir "f1" or die $!;
    mkdir "f1/a" or die $!;
    mkdir "f1/a/sub" or die $!;
    mkdir "f1/.git" or die $!;
    ai::spew("f1/top.pm", "x");
    ai::spew("f1/a/b.pm", "x");
    ai::spew("f1/a/c.txt", "x");
    ai::spew("f1/a/sub/d.pm", "x");
    ai::spew("f1/.git/g.pm", "x");
    symlink("/", "f1/a/rootlink") or die $!; # never followed

    my ($all) = tools::walk_tree("f1", "f1", filter => sub {$_[1] =~ /\.pm$/});
    is_deeply($all, ["f1/.git/g.pm", "f1/a/b.pm", "f1/a/sub/d.pm", "f1/top.pm"], "walk: the matches, sorted within each directory");
    my ($pruned) = tools::walk_tree("f1", "f1", filter => sub {$_[1] =~ /\.pm$/}, prune => sub {$_[1] eq '.git'});
    is_deeply($pruned, ["f1/a/b.pm", "f1/a/sub/d.pm", "f1/top.pm"], "walk: prune: the directory is not gone into");
    my ($top) = tools::walk_tree("f1", "f1", depth => 1);
    is_deeply($top, ["f1/.git", "f1/a", "f1/top.pm"], "walk: depth 1 is only the start's own entries");
    my ($two, $more) = tools::walk_tree("f1", "f1", max => 2);
    is(scalar(@$two), 2, "walk: max results");
    ok($more, "walk: and says that more matched");
    my ($links) = tools::walk_tree("f1", "f1", filter => sub {$_[3]});
    is_deeply($links, ["f1/a/rootlink"], "walk: a symbolic link is an entry, the filter sees it as one");
    my (undef, undef, $unreadable) = tools::walk_tree("f1/nope", "f1/nope");
    is($unreadable, 1, "walk: a directory that cannot be read is counted");

    my ($out, $err) = tool("find", "f1", "\\.pm\$");
    is_deeply([$out, $err], ["f1/.git/g.pm\nf1/a/b.pm\nf1/a/sub/d.pm\nf1/top.pm\n", undef], "find: the tool, by name");
    is((tool("find", "f1", "^zzz"))[0], "no matches\n", "find: nothing matches");
    my ($everything) = tool("find", "f1", "");
    like($everything, qr{^f1/a/rootlink\n}m, "find: an empty name is every entry, links too");
    unlike($everything, qr{f1/a/rootlink/}, "find: no entry below a link");
    like((tool("find", "f1/top.pm", ""))[1], qr/not a directory/, "find: a file is not a directory");
    like((tool("find", "f1", "(bad"))[1], qr/bad name pattern '\(bad'/, "find: a pattern that does not compile");
    {
        local $ai::WORKSPACE = $tmp;
        like((tool("find", "/", ""))[1], qr/outside of the workspace/, "find: nothing outside of the workspace");
    }
}

chdir("/");
done_testing();
