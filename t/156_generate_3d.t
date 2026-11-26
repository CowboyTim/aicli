#!/usr/bin/perl
# generate_3d: a picture of the workspace to a 3D model through the 3D service (TRELLIS.2): a textured GLB, the mesh alone or an
# STL. The job is started (POST, the picture in base64 and the options), its state asked on a timer until it is done, the model
# downloaded and written to the workspace whole (the undo journal first; a failure leaves nothing), its name as the tool works it
# out; the arguments checked before anything is asked; the service's refusals, a failed job, a job that takes too long, an
# answer that is not a model; the same for a sub-agent (a job of the loop); the file offered after the call
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use JSON::XS ();
use MIME::Base64 ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
use ai;
use TestAI;

my $J = JSON::XS->new->canonical(1)->utf8;
my $PNG = "\x89PNG\r\n\x1a\n" . ("\0\x01" x 50);
my $GLB = "glTF\x02\0\0\0" . ("\x07" x 200);
my $STL = ("\0" x 80) . pack('V', 2) . ("\x01" x 100);   # a binary STL of two faces

sub slurp { my ($f) = @_; open(my $h, '<:raw', $f) or return undef; local $/; my $d = <$h>; close $h; return $d }
sub spew  { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }

# the 3D service: loop::http answers at once; %SVC says what each step gives. polls: the states before "completed"
my (@REQ, %SVC);
sub reset_service {
    %SVC = (start => sub { {code => 200, error => undef, body => $J->encode({id => '3d_00ff', status => 'in_progress'})} },
            polls => [{status => 'in_progress', progress => {stage => 'shape', step => 3, steps => 12}}],
            done  => {status => 'completed', bytes => length($GLB), seconds => 201.3, options => {resolution => 512}},
            content => sub { {code => 200, error => undef, body => $GLB} });
}
{
    no warnings 'redefine';
    *loop::http = sub {
        my (%r) = @_;
        push @REQ, \%r;
        my $reply;
        if (($r{method} // '') eq 'post') {
            $reply = $SVC{start}->(\%r);
        } elsif ($r{url} =~ m{/content\z}) {
            $reply = $SVC{content}->(\%r);
        } else {
            my $st = @{$SVC{polls}} ? shift @{$SVC{polls}} : $SVC{done};
            $reply = ref($st) eq 'CODE' ? $st->(\%r) : {code => 200, error => undef, body => $J->encode($st)};
        }
        $r{on_done}->({headers => {}, %$reply});
        return;
    };
}
reset_service();

TestAI::setup(AI_TOOL_CALLS => 'native', AI_3D => 1, AI_3D_URL => 'http://3d.test:8000/rocm/', AI_3D_POLL => 0);
my $ws = File::Temp::tempdir(CLEANUP => 1, TMPDIR => 1);
$ai::WORKSPACE = $ws;
chdir($ws);
spew("$ws/vase.png", $PNG);

ok(tools::available('generate_3d'), "available: the 3D service is set");
{
    local $::ORIG_ENV{AI_3D_URL} = '';
    ok(!tools::available('generate_3d'), "not available without AI_3D_URL");
}

# the model: the job started, its state asked until it is done, the model downloaded and written
{
    @REQ = ();
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a',
        ['vase.png', 'vase-model.glb', '512', '3', 'remove', '200000', '2048']);
    ok(!$err, "a model is made") or diag($err);
    like($res, qr/\Awrote vase-model\.glb: ${\ length $GLB} bytes of GLB \(resolution 512, seed 3, 201 seconds in the service\)/,
        "the result names the file, its size, the resolution, the seed and the service's time");
    is(slurp("$ws/vase-model.glb"), $GLB, "the file is the model the service sent");
    is(scalar(@REQ), 4, "four requests: the start, two states (in progress, then completed), the model");
    is($REQ[0]{url}, 'http://3d.test:8000/rocm/v1/3d/generations', "the start: the base (its slash taken off) and the path");
    is_deeply($J->decode($REQ[0]{data}),
        {model => 'trellis-2', image => MIME::Base64::encode_base64($PNG, ''), resolution => 512, seed => 3,
         remove_background => 'true', faces => 200000, texture_size => 2048},
        "the start's body: the model, the picture in base64, and the options as the service names them");
    is($REQ[1]{url}, 'http://3d.test:8000/rocm/v1/3d/generations/3d_00ff', "the state is asked by the job's id");
    is($REQ[3]{url}, 'http://3d.test:8000/rocm/v1/3d/generations/3d_00ff/content', "the model is the job's content");
    ok(!glob("$ws/.aicli-*"), "no temp file is left");
    my $last = $tools::CHANGES[-1];
    is($last->{tool}, 'generate_3d', "the change is listed under the tool");
    ok($last->{binary}, "as a binary file");
    like(slurp("$ai::AI_SESSION_DIR/undo/journal") // '', qr/"tool":"generate_3d"/, "the journal of the session has the entry");
    @tools::CHANGES = ();
}

# the defaults: the picture's name with .glb, the seed 0, the rest the service's; keep and auto name the background
{
    reset_service(); @REQ = ();
    $SVC{done} = {status => 'completed', seconds => 800, options => {resolution => 1024}};
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png']);
    ok(!$err, "a picture alone is enough") or diag($err);
    like($res, qr/\Awrote vase\.glb: .*\(resolution 1024, seed 0, 800 seconds in the service\)/, "no output: the picture's name with .glb");
    is_deeply($J->decode($REQ[0]{data}), {model => 'trellis-2', image => MIME::Base64::encode_base64($PNG, ''), seed => 0},
        "the start leaves out what is not given");
    reset_service(); @REQ = ();
    ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'kept.glb', '', '', 'keep']);
    is($J->decode($REQ[0]{data})->{remove_background}, 'false', "keep: the whole picture (remove_background false)");
    reset_service(); @REQ = ();
    ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'auto.glb', '', '', 'AUTO']);
    is($J->decode($REQ[0]{data})->{remove_background}, 'auto', "auto (any case): the service decides");
    is(tools::model3d_output('', 'uploads/cup.photo.jpg'), 'cup.photo.glb', "the default name: the picture's name, its last extension .glb");
    is(tools::model3d_output('', 'cup.png', 'stl'), 'cup.stl', "and .stl for an STL");
    @tools::CHANGES = ();
}

# the mesh alone (format mesh: texture false), and an STL for a 3D printer (format stl: its size, its own checks)
{
    reset_service(); @REQ = ();
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'plain.glb', '512', '', '', '', '', 'mesh']);
    ok(!$err, "the mesh alone is made") or diag($err);
    like($res, qr/\Awrote plain\.glb: \d+ bytes of GLB, the mesh alone \(/, "the result says it is the mesh alone");
    is($J->decode($REQ[0]{data})->{texture}, JSON::XS::false, "the start asks for no texture");
    ok(!exists $J->decode($REQ[0]{data})->{format}, "and leaves the format (glb) to the service");

    reset_service(); @REQ = ();
    $SVC{content} = sub { {code => 200, error => undef, body => $STL} };
    ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', '', '512', '', '', '', '', 'STL', '80']);
    ok(!$err, "an STL is made") or diag($err);
    like($res, qr/\Awrote vase\.stl: 184 bytes of STL, 2 faces, 80 mm \(resolution 512/, "the default name is .stl; the faces and the size");
    is(slurp("$ws/vase.stl"), $STL, "the file is the STL the service sent");
    my $b = $J->decode($REQ[0]{data});
    is($b->{format}, 'stl', "the start asks for an STL");
    is($b->{size_mm}, 80, "of the size given");
    ok(grep({ $_ eq 'Accept: model/stl' } @{$REQ[3]{headers}}), "the download accepts model/stl");
    reset_service();
    $SVC{content} = sub { {code => 200, error => undef, body => $GLB} };
    ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'wrong.stl', '', '', '', '', '', 'stl']);
    like($err // '', qr/the 3D service sent no binary STL/, "an STL that is not one (a GLB) is an error");
    ok(!-e "$ws/wrong.stl", "  and leaves no file");

    # hollow: the walls (and the service's default drain, or none)
    reset_service(); @REQ = ();
    $SVC{content} = sub { {code => 200, error => undef, body => $STL} };
    ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'hollow.stl', '512', '', '', '', '', 'stl', '80', '2']);
    ok(!$err, "a hollow STL is made") or diag($err);
    like($res, qr/\Awrote hollow\.stl: 184 bytes of STL, 2 faces, 80 mm, hollow: 2 mm walls, 3 mm drain holes \(/,
        "the result says hollow, its walls and the default drain");
    $b = $J->decode($REQ[0]{data});
    is($b->{hollow_mm}, 2, "the start asks for the walls");
    ok(!exists $b->{drain_mm}, "and leaves the drain to the service's default");
    reset_service(); @REQ = ();
    $SVC{content} = sub { {code => 200, error => undef, body => $STL} };
    ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'sealed.stl', '', '', '', '', '', 'stl', '', '1.5', '0']);
    like($res // '', qr/hollow: 1\.5 mm walls, no drain holes/, "no drain holes asked: said so");
    is_deeply([@{$J->decode($REQ[0]{data})}{qw(hollow_mm drain_mm)}], [1.5, 0], "the walls and drain 0 sent");
    reset_service(); @REQ = ();
    $SVC{content} = sub { {code => 200, error => undef, body => $STL} };
    ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'solid.stl', '', '', '', '', '', 'stl', '', '0']);
    unlike($res // '', qr/hollow/, "hollow_mm 0 is a solid model");
    ok(!exists $J->decode($REQ[0]{data})->{hollow_mm}, "  and asks for no hollow");
    @tools::CHANGES = ();
}

# a file of that name already there stays as it was: the model goes to the first free name, and the result names it
{
    reset_service();
    spew("$ws/vase.glb", "old model");
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png']);
    ok(!$err, "a name already taken is made again") or diag($err);
    like($res, qr/\Awrote vase-2\.glb: /, "the model goes to vase-2.glb");
    is(slurp("$ws/vase.glb"), "old model", "the file that was there stays as it was");
    is(slurp("$ws/vase-2.glb"), $GLB, "the new model is the new file");
    @tools::CHANGES = ();
}

# refusals: nothing is asked of the service
{
    spew("$ws/notes.txt", "not a picture");
    my $asked = scalar @REQ;
    my @refuse = (
        [[''],                                          qr/no input/,                          "no picture"],
        [['nothere.png'],                               qr/no such file: nothere\.png/,        "a picture that is not there"],
        [['notes.txt'],                                 qr/not a picture/,                     "a file that is not a picture"],
        [['../vase.png'],                               qr/outside of the workspace/,          "a picture outside the workspace"],
        [['vase.png', '../x.glb'],                      qr/outside of the workspace/,          "an output outside the workspace"],
        [['vase.png', 'x.obj'],                         qr/the output must be a \.glb file/,   "an output that is not a .glb"],
        [['vase.png', '', '768'],                       qr/resolution: 512 or 1024/,           "a resolution the service does not have"],
        [['vase.png', '', '', 'x'],                     qr/seed: a whole number/,              "a seed that is not a number"],
        [['vase.png', '', '', '', 'maybe'],             qr/background: auto, remove or keep/,  "a background that is not one of the three"],
        [['vase.png', '', '', '', '', '10'],            qr/faces: a whole number from 1000/,   "too few faces"],
        [['vase.png', '', '', '', '', '', '300'],       qr/texture_size: 512, 1024, 2048 or 4096/, "a texture size the service does not take"],
        [['vase.png', '', '', '', '', '', '', 'obj'],   qr/format: glb, mesh or stl/,          "a format that is not one of the three"],
        [['vase.png', '', '', '', '', '', '', 'stl', '0'], qr/size_mm: a number of millimetres/, "an STL of 0 mm"],
        [['vase.png', '', '', '', '', '', '', 'stl', 'big'], qr/size_mm: a number of millimetres/, "a size that is not a number"],
        [['vase.png', '', '', '', '', '', '', 'glb', '80'], qr/size_mm is for the format stl/,  "a size for a GLB"],
        [['vase.png', '', '', '', '', '', '', 'mesh', '', '2'], qr/hollow_mm is for the format stl/, "a hollow mesh GLB"],
        [['vase.png', '', '', '', '', '', '', 'stl', '', 'thick'], qr/hollow_mm: a number of millimetres/, "walls that are not a number"],
        [['vase.png', '', '', '', '', '', '', 'stl', '', '2', '2000'], qr/drain_mm: a number of millimetres/, "a drain of 2 m"],
        [['vase.png', '', '', '', '', '', '', 'stl', '', '', '3'], qr/drain_mm is for a hollow model/, "a drain without a hollow"],
        [['vase.png', 'x.glb', '', '', '', '', '', 'stl'], qr/the output must be a \.stl file/, "an STL named .glb"],
        [['vase.png', 'x.stl', '', '', '', '', '', 'mesh'], qr/the output must be a \.glb file/, "a mesh GLB named .stl"],
    );
    for my $case (@refuse) {
        my ($args, $re, $what) = @$case;
        my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', $args);
        ok($err, "refused: $what") or diag($res);
        like($err // '', $re, "  and the reason says so");
    }
    {
        local $::ORIG_ENV{AI_3D_MAX} = 10;
        my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png']);
        like($err // '', qr/bigger than 10 bytes \(AI_3D_MAX\)/, "refused: a picture over AI_3D_MAX");
    }
    is(scalar(@REQ), $asked, "no request went to the service for any of them");
    eval { local $::ORIG_ENV{AI_3D_URL} = ''; tools::generate_3d_4c9a(['vase.png']) };
    like($@, qr/no 3D service is set up \(AI_3D_URL\)/, "the handler says what is missing without AI_3D_URL");
}

# the service's refusals and failures: an error each, and no file
{
    my @cases = (
        [sub { $SVC{start} = sub { {code => 429, error => 'HTTP status 429', body => '{"error":{"message":"a 3D generation is running: try again when it completes"}}'} } },
         qr/the 3D service is busy with another model/, "busy (429)"],
        [sub { $SVC{start} = sub { {code => 400, error => 'HTTP status 400', body => '{"error":{"message":"the mask is empty: no object in the image"}}'} } },
         qr/the 3D service refused the picture: the mask is empty/, "a refusal with the service's reason"],
        [sub { $SVC{start} = sub { {code => 413, error => 'HTTP status 413', body => "<html>\n<head><title>413 Request Entity Too Large</title></head>\n</html>"} } },
         qr/: the 3D service refused the picture as too large \(HTTP 413\): vase\.png is 0\.0 MB, 0\.0 MB in the request \(base64 makes it a third bigger\), more than the service or the web server in front of it takes \(nginx: client_max_body_size\)\. Make the picture smaller with convert first: width and height 2048 is plenty/,
         "too large for the web server (413): the sizes and what to do, not nginx's page"],
        [sub { $SVC{start} = sub { {code => 200, error => undef, body => '{"status":"in_progress"}'} } },
         qr/no job id/, "an answer with no job id"],
        [sub { $SVC{polls} = []; $SVC{done} = {status => 'failed', error => 'out of pinned memory'} },
         qr/the 3D job failed: out of pinned memory/, "a job that failed"],
        [sub { $SVC{polls} = [sub { {code => 404, error => 'HTTP status 404', body => '{"error":{"message":"no 3D generation"}}'} }] },
         qr/the state of the 3D job: no 3D generation/, "a job the service no longer has"],
        [sub { $SVC{content} = sub { {code => 200, error => undef, body => '{"error":"x"}'} } },
         qr/the 3D service sent no binary glTF/, "a download that is not a model"],
        [sub { $SVC{content} = sub { {code => 409, error => 'HTTP status 409', body => 'the 3D generation is failed'} } },
         qr/HTTP status 409/, "a download that is refused"],
    );
    for my $case (@cases) {
        my ($setup, $re, $what) = @$case;
        reset_service();
        $setup->();
        my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'bad.glb']);
        like($err // '', $re, "an error: $what") or diag($res);
        ok(!-e "$ws/bad.glb" && !glob("$ws/.aicli-*"), "  and no file is left");
    }
    # a job that is not done in AI_3D_TIMEOUT: the tool stops asking, the job goes on in the service
    reset_service();
    $SVC{done} = {status => 'in_progress'};
    local $::ORIG_ENV{AI_3D_TIMEOUT} = 0.05;
    local $::ORIG_ENV{AI_3D_POLL} = 0.02;
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'slow.glb']);
    like($err // '', qr/the 3D job 3d_00ff is not done after 0\.05 seconds \(AI_3D_TIMEOUT\); it goes on in the service/,
        "a job over AI_3D_TIMEOUT: the tool says so");
    ok(!-e "$ws/slow.glb", "  and writes nothing");
}

# a sub-agent: the tool is a job of the event loop, the same requests and the same file
{
    reset_service(); @REQ = ();
    my ($got, $gerr, $called);
    ai::execute_tool_async('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'agent.glb', '512'],
        sub { ($got, $gerr) = @_; $called = 1 });
    ok(!$called, "a sub-agent's call does not wait: the callback comes from the loop");
    loop::run(sub { $called });
    ok(!$gerr, "the sub-agent's model is made") or diag($gerr);
    like($got // '', qr/\Awrote agent\.glb: /, "its result names the file");
    is(slurp("$ws/agent.glb"), $GLB, "the file is there");
    is(scalar(@REQ), 4, "the same four requests");
    @tools::CHANGES = ();
}

# a stop (ctrl-C) while the job runs: the wait ends with "interrupted", nothing is written
{
    reset_service();
    $SVC{polls} = [sub { $::ABORT = 1; {code => 200, error => undef, body => '{"status":"in_progress"}'} }];
    my ($res, $err) = ai::execute_tool('generate_3d', 'GENERATE_3D_4c9a', ['vase.png', 'stopped.glb']);
    $::ABORT = 0;
    like($err // '', qr/interrupted/, "a stop ends the wait");
    ok(!-e "$ws/stopped.glb", "  and nothing is written");
}

# the file a call made is offered: the name the result gives
is(tools::offered_file('generate_3d', ['vase.png', '', '', '', '', '', ''], $ws, "wrote vase-2.glb: 208 bytes of GLB (resolution 1024, seed 0, 800 seconds in the service)\n"),
    'vase-2.glb', "the file the result names is offered");
ok(!defined tools::offered_file('generate_3d', ['vase.png'], $ws, "wrote nothere.glb: 1 bytes of GLB\n"),
    "a file that is not there is not offered");

done_testing();
