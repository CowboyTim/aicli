#!/usr/bin/perl
# slash commands: dispatch, the input readers, completion
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use ai;
use TestAI;

my $tmp = TestAI::setup();
TestAI::mock_http(); # any request would die: commands never talk to the LLM

sub cmd {
    my ($line) = @_;
    my $r;
    my $out = TestAI::capture {$r = ai::handle_command($line)};
    return ($r, $out);
}

# dispatch
{
    is(ai::handle_command("hello /exit"), undef, "not a command: undef");
    is(ai::handle_command(undef), undef, "no input: undef");
    is((cmd("/exit"))[0], 1, "/exit: leave");
    is((cmd("/quit"))[0], 1, "/quit: leave");
    my ($r, $out) = cmd("/nope 1 2");
    is($r, 0, "unknown: handled");
    like($out, qr{^Unknown command: /nope}, "unknown: said so");
    ($r, $out) = cmd("/help");
    is($r, 0, "/help: handled");
    like($out, qr{^\s+\Q$_\E\b}m, "/help: lists $_") for grep {!ref} @ai::COMMANDS;
    ok(ref($ai::COMMANDS{$_}{run}) eq 'CODE' && length($ai::COMMANDS{$_}{help}), "$_: has run + help")
        for sort keys %ai::COMMANDS;
    is(scalar(@TestAI::REQUESTS), 0, "no request to the LLM");
}

# /system, /clear, /tools, /debug
{
    my ($r, $out) = cmd("/system  be brief ");
    is($r, 0, "/system: handled");
    my @msgs = ai::load_messages();
    is_deeply($msgs[-1], {role => 'system', content => 'be brief'}, "/system: message added");
    ai::append_messages({role => 'user', content => 'x'}, {role => 'assistant', content => 'y'});
    ($r, $out) = cmd("/clear");
    @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system", "/clear: only the system prompt is left");
    like($msgs[0]{content}, qr/You are a master developer.*LIST OF TOOLS/s, "/clear: prompt and tools section are back");
    ($r, $out) = cmd("/tools");
    like($out, qr/^  \Q$_\E: /m, "/tools: lists $_") for qw(bash grep perl read write);
    cmd("/debug");
    is($::DEBUG, 1, "/debug: on");
    cmd("/nodebug");
    is($::DEBUG, 0, "/nodebug: off");
}

# sessions
{
    my ($r, $out) = cmd("/session");
    like($out, qr/\* test/, "/session: current one marked");
    ($r, $out) = cmd("/session create work-1");
    like($out, qr/Created session 'work-1'.*Switched to session: work-1/s, "create: created + switched");
    is($ai::AI_SESSION, "work-1", "create: current session");
    is($ai::STATUS_FILE, "$tmp/aicli/sessions/work-1/chat", "create: chat file follows");
    is(TestAI::roles(ai::load_messages()), "system", "create: new conversation");
    cmd("/model m-1");
    is($ai::SESSION_MODEL, "m-1", "model set in work-1");
    ($r, $out) = cmd("/session test");
    like($out, qr/Switched to session: test/, "switch: shortcut form");
    isnt($ai::SESSION_MODEL // '', "m-1", "switch: model of the other session is not kept");
    cmd("/session switch work-1");
    is($ai::SESSION_MODEL, "m-1", "switch: model of the session is back");
    ($r, $out) = cmd("/session rename work-1 work-2");
    like($out, qr/Renamed session 'work-1' to 'work-2'/, "rename: done");
    is($ai::AI_SESSION, "work-2", "rename: current session follows");
    ok(-d "$tmp/aicli/sessions/work-2" && !-d "$tmp/aicli/sessions/work-1", "rename: on disk");
    ($r, $out) = cmd("/session delete work-2");
    like($out, qr/Cannot delete the current session/, "delete: not the current one");
    cmd("/session test");
    ($r, $out) = cmd("/session delete work-2");
    like($out, qr/Deleted session 'work-2'/, "delete: done");
    ok(!-d "$tmp/aicli/sessions/work-2", "delete: on disk");
    ($r, $out) = cmd("/session create");
    like($out, qr{^Usage: /session create <name>}, "create: needs a name");

    # names can't leave the sessions directory
    foreach my $bad ('..', '../x', 'a/b', '.hidden', 'a b'){
        ($r, $out) = cmd("/session create $bad");
        like($out, qr/Invalid session name/, "create '$bad': refused");
        ($r, $out) = cmd("/session delete $bad");
        like($out, qr/does not exist/, "delete '$bad': refused");
    }
    ok(-d "$tmp/aicli/sessions/test", "sessions are still there");
    ok(-d "$tmp/aicli", "base dir is still there");
    is_deeply(ai::get_sessions(), ["test"], "only the test session exists");
}

# /model
{
    my ($r, $out) = cmd("/model 'big-model' ");
    like($out, qr/Switched model to 'big-model'/, "/model: switched");
    is($ai::SESSION_MODEL, "big-model", "/model: in use");
    is(ai::slurp("$tmp/aicli/sessions/test/model"), "big-model", "/model: saved");
    is(provider::req({role => 'user', content => 'x'})->{model}, "big-model", "/model: used for requests");

    TestAI::mock_http(sub {
        my ($cb, $req) = @_;
        is($req->{url}, "http://127.0.0.1:9/v1/models", "/model: list url");
        return '{"data":[{"id":"small-model"},{"id":"big-model"}]}';
    });
    ($r, $out) = cmd("/model");
    like($out, qr/^  small-model$/m, "/model: lists models");
    like($out, qr/\* big-model/, "/model: marks the current one");
    TestAI::mock_http(undef);
    ($r, $out) = cmd("/model");
    is($r, 0, "/model: survives a failing API");
    like($out, qr/Failed to fetch models.*Current model: big-model/s, "/model: says what it knows");
    TestAI::mock_http();
}

# /prompt
{
    ai::append_messages({role => 'user', content => 'keep me'});
    my ($r, $out) = cmd("/prompt");
    like($out, qr/\* coder/, "/prompt: current one marked");
    like($out, qr/^  default$/m, "/prompt: lists the others");
    ($r, $out) = cmd("/prompt default");
    like($out, qr/Switched system prompt/, "/prompt: switched");
    my @msgs = ai::load_messages();
    is(TestAI::roles(@msgs), "system,user", "/prompt: conversation kept");
    is($msgs[0]{content}, "You are a helpful agent\n", "/prompt: default has no tools section");
    cmd("/prompt coder");
    like((ai::load_messages())[0]{content}, qr/LIST OF TOOLS/, "/prompt: coder has the tools again");
    ($r, $out) = cmd("/prompt ../ai.pl");
    like($out, qr/Failed to read prompt template/, "/prompt: only templates");
}

# /files, /chdir, /pwd, /ls
{
    my $dir = "$tmp/work";
    mkdir $dir or die $!;
    ai::spew("$dir/a.pl", "print 1;\n");
    ai::spew("$dir/b.txt", "bee\n");
    ai::spew("$dir/secret.txt", "s3cret\n");
    ai::spew("$dir/.dot", "hidden\n");
    my ($r, $out) = cmd("/chdir $dir");
    is($out, "", "/chdir: quiet");
    like((cmd("/pwd"))[1], qr{/work$}, "/pwd");
    is((cmd("/ls"))[1], "a.pl\nb.txt\nsecret.txt\n", "/ls: sorted, no dot files");
    cmd("/clear");

    # worked only with an .aiignore before
    ($r, $out) = cmd("/files \\.pl\$");
    like($out, qr/added a\.pl to chat/, "/files: regex match, no .aiignore");
    unlike($out, qr/b\.txt/, "/files: others not added");
    my @msgs = ai::load_messages();
    is($msgs[-1]{content}, "a.pl:\n```\nprint 1;\n\n```\n", "/files: content added as user message");

    ai::spew("$dir/.aiignore", "secret*\n");
    cmd("/clear");
    ($r, $out) = cmd("/files");
    like($out, qr/added b\.txt/, "/files: all files");
    unlike($out, qr/secret/, "/files: .aiignore respected");
    is(scalar(ai::load_messages()), 3, "/files: system + 2 files");
    ($r, $out) = cmd("/files (");
    like($out, qr/Bad pattern/, "/files: bad regex is not fatal");
    ($r, $out) = cmd("/cd /nonexistent-dir");
    like($out, qr/Failed to change directory/, "/cd: alias, failure reported");
    chdir("/");
}

# the terminal reader: commands are executed, never returned as chat text
{
    package FakeTerm;
    sub new { my ($c, @lines) = @_; return bless {lines => [@lines], history => []}, $c }
    sub readline { my ($s) = @_; return shift @{$s->{lines}} }
    sub addhistory { my ($s, $l) = @_; push @{$s->{history}}, $l }
    sub AUTOLOAD { return }
}
{
    my $term = FakeTerm->new("/pwd", "/nope", "hello world", "/system quiet", "second", "/exit", "never");
    my $input = ai::input_terminal($term);
    my @got;
    my $out = TestAI::capture {
        while(defined(my $l = $input->())){
            push @got, $l;
        }
    };
    is_deeply(\@got, ["hello world", "second"], "terminal: only chat text comes out, /exit ends it");
    like($out, qr{^/\n}m, "terminal: /pwd ran");
    like($out, qr{Unknown command: /nope}, "terminal: unknown command reported");
    is((ai::load_messages())[-1]{content}, "quiet", "terminal: /system ran");
    is_deeply($term->{history}, ["/pwd", "/nope", "hello world\n", "/system quiet", "second\n", "/exit"], "terminal: all in the history");
    is(scalar(@TestAI::REQUESTS), 0, "terminal: nothing sent to the LLM by the reader");
    $::T = undef;
}

# stdin reader
{
    my $fn = "$tmp/stdin";
    ai::spew($fn, "/pwd\nline one\n/exit\nline two\n");
    open(my $old, '<&', \*STDIN) or die $!;
    open(STDIN, '<', $fn) or die $!;
    my $input = ai::input_stdin();
    my @got;
    my $out = TestAI::capture {
        while(defined(my $l = $input->())){
            push @got, $l;
        }
    };
    open(STDIN, '<&', $old) or die $!;
    is_deeply(\@got, ["", "line one\n"], "stdin: command gives no chat text, /exit ends it");
}

# completion
{
    ai::setup_commands();
    is_deeply([sort keys %$ai::cmds], [sort keys %ai::COMMANDS], "completion: every command is known");
    is_deeply([ai::chat_word_completions_cli("/se", "/se", 0, 3)], ["/session"], "completion: /se -> /session");
    my @c = ai::chat_word_completions_cli("/", "/", 0, 1);
    is($c[0], "", "completion: / is ambiguous, nothing to insert");
    ok(scalar(grep {$_ eq '/model'} @c), "completion: / offers the commands");
    @c = ai::chat_word_completions_cli("", "/session ", 9, 9);
    ok(scalar(grep {$_ eq 'create'} @c) && scalar(grep {$_ eq 'test'} @c), "completion: /session offers subcommands and sessions");
    cmd("/session create zz-new");
    @c = ai::chat_word_completions_cli("", "/session delete ", 16, 16);
    ok(scalar(grep {$_ eq 'zz-new'} @c), "completion: new session is offered right away");
    @c = ai::chat_word_completions_cli("", "/prompt ", 8, 8);
    is_deeply([@c[1 .. $#c]], ["coder", "default"], "completion: /prompt offers the templates");
}

done_testing();
