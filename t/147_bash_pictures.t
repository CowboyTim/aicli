#!/usr/bin/perl
# a bash call on the web page: the pictures and sounds it made or changed are offered to the page (a file
# event with a version, so that a changed file is not shown from the browser's cache, and the history of
# the chat); the result the model gets lists them, and the page shows the result without the list. A
# change of anything else, and a call that failed, offers nothing.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use JSON::XS ();
use MIME::Base64 ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $PNG = MIME::Base64::decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==");

sub sse { join('', map {"data: ".$::JSON->encode($_)."\n\n"} @_) . "data: [DONE]\n\n" }
sub calls_reply {
    my ($name, $id, $args) = @_;
    return [sse({choices => [{delta => {tool_calls => [{index => 0, id => $id, function => {name => $name, arguments => $args}}]}}]},
        {choices => [{delta => {}, finish_reason => 'tool_calls'}]})];
}
sub text_reply {
    my ($text) = @_;
    return [sse({choices => [{delta => {content => $text}}]}, {choices => [{delta => {}, finish_reason => 'stop'}]})];
}
sub spew { my ($f, $d, $mode) = @_; open(my $h, $mode // '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

TestAI::setup(AI_TOOL_CALLS => 'native', AI_TOOL_DISPLAY => 'brief');
my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
$ai::WORKSPACE = $ws;
$ai::ROOT = $ws;   # the session's project is the workspace
chdir($ws);
spew("$ws/shot.png", $PNG);
spew("$ws/notes.txt", "hi\n");

# one turn with one bash call; returns the file events and the result events the page got
sub bash_turn {
    my ($code, $id) = @_;
    TestAI::mock_http(calls_reply('bash', $id, $J->encode({code => $code})), text_reply('done'));
    my @EV;
    local $ai::EVENT_SINK = sub { push @EV, [@_] };
    TestAI::capture {ai::chat_completion("run it")};
    return \@EV;
}
sub file_events { my ($EV) = @_; return map {$_->[1]} grep {$_->[0] eq 'file'} @$EV }

# 1. a picture the call made
{
    my $EV = bash_turn('cp shot.png made.png', 'call_1');
    my @files = file_events($EV);
    is(scalar(@files), 1, "a new picture: one file event");
    is($files[0]{path}, 'made.png', "for the picture it made");
    ok(length($files[0]{v} // '') > 0, "with its version");
    like($TestAI::REQUESTS[1]{data} // '', qr/\[aicli file\] made\.png/, "the model's result lists the file");
    my @shown = grep {$_->[0] eq 'result'} @$EV;
    ok(@shown && $shown[0][1]{text} !~ /\[aicli file\]/, "the page shows the result without the list");
}

# 2. a picture the call changed in place: offered again, with a new version
{
    my $none = bash_turn('true', 'call_0');
    is(scalar(file_events($none)), 0, "a call that changes nothing offers nothing");
    my $EV = bash_turn('printf x >> shot.png', 'call_2');
    my @files = file_events($EV);
    is(scalar(@files), 1, "a changed picture: one file event");
    is($files[0]{path}, 'shot.png', "for the picture it changed");
    ok(length($files[0]{v} // '') > 0, "with a version, so the page does not keep the old one");
}

# 3. a file that is not a picture or a sound: nothing is offered
{
    my $EV = bash_turn('echo more >> notes.txt', 'call_3');
    is(scalar(file_events($EV)), 0, "a change to a text file is not offered");
}

# 4. a call that fails offers nothing, though it made a picture before it failed
{
    my $EV = bash_turn('cp shot.png partial.png && false', 'call_4');
    is(scalar(file_events($EV)), 0, "a failed call offers no file");
    ok(-e "$ws/partial.png", "(the picture is there, the call failed)");
}

# 5. the history of the chat has the picture the call made, with its version, and the result without the list
{
    my @tools = grep {$_->{role} eq 'tool'} @{ui::_history_data('test')->{messages}};
    my @with = grep {$_->{files}} @tools;
    is(scalar(@with), 2, "the history: the two calls that made or changed a picture");
    is_deeply([map {$_->{path}} @{$with[0]{files}}], ['made.png'], "the first: the picture it made");
    is_deeply([map {$_->{path}} @{$with[1]{files}}], ['shot.png'], "the second: the picture it changed");
    ok(length($with[0]{files}[0]{v} // '') > 0, "with its version");
    ok(!grep({($_->{result} // '') =~ /\[aicli file\]/} @tools), "the results on the page have no list");
}

done_testing();
