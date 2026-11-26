#!/usr/bin/perl
# the 3D view of a model file on the page: the page's block for a .glb or .stl loads viewer.js (ai/ui/viewer.js)
# and the three.js files it needs (ai/ui/vendor/three, MIT), behind the login like the other routes; GET /file
# sends a .glb and an .stl as downloads. The vendored files are the ones ai/ui/vendor/three/NOTICE names (their
# checksums), and no other .js is there. The parsers of the viewer are checked by node when it is installed:
# a binary STL, a glTF with its own data, and a glTF whose data is a web address (no request leaves the page).
use strict; use warnings;

use Test::More;
use FindBin;
use Socket ();
use Digest::SHA ();
use File::Basename ();
use Cwd ();
use File::Find ();
use File::Path ();
use File::Copy ();
use File::Temp ();
use lib "$FindBin::Bin/..", "$FindBin::Bin/lib";
no warnings 'once';

$::DEBUG = 0;
$::UI = 1;
use ai;
use ui;
use TestAI;

my $ui_dir = Cwd::abs_path("$FindBin::Bin/../ai/ui"); # before the setup, which moves to its own directory
my $tmp = TestAI::setup();
$ai::ROOT = "$tmp/root"; # after the setup: the projects are under it
my $root = $ai::ROOT;
$ui::token = 'tok-view';
$ui::gate  = 'gate-view';
$ui::html_file = "$ui_dir/index.html";

my $A = 'ab' x 16; # the account of the login (32 hex digits)
my $STL = pack('a80 V', '', 2) # a binary STL: its header, two triangles (normal, three corners, attribute)
    .pack('f<12 v', 0,0,1, 0,0,0, 10,0,0, 0,20,0, 0)
    .pack('f<12 v', 0,0,1, 0,0,0, 0,20,0, 0,0,30, 0);
my $GLB = "glTF\x02\x00\x00\x00 glb-of-the-check";

sub put { my ($f, $d) = @_; open(my $h, '>:raw', $f) or die "$f: $!"; print {$h} $d; close $h; return }
for my $d ($root, "$root/$A", "$root/$A/proj") { mkdir $d or die "$d: $!" }
put("$root/$A/proj/model.stl", $STL);
put("$root/$A/proj/model.glb", $GLB);
mkdir "$ai::SESSIONS_DIR/mine" or die "mine: $!";
put("$ai::SESSIONS_DIR/mine/cwd", "$root/$A/proj\n");

# a request to the local interface, with the headers nginx would send (the gate's secret, the account)
sub get {
    my ($path, %h) = @_;
    socketpair(my $a, my $b, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or die $!;
    $a->blocking(0); $b->blocking(0);
    my $cn = {fh => $a, out => '', req => ''};
    ui::_dispatch($cn, 'GET', $path, {%h}, '');
    my $raw = '';
    for (1 .. 200) {
        my $n = sysread($b, my $buf, 65536);
        if (defined $n and $n > 0) { $raw .= $buf; next }
        last if defined $n and $n == 0;
        last if $cn->{closed};
        select(undef, undef, undef, 0.01);
    }
    close($a);
    close($b);
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    my ($status) = ($head // '') =~ m{\AHTTP/1\.1 (\d{3})};
    my %hdr = map {my ($k, $v) = m/\A([^:]+):\s*(.*)\z/; (lc($k), $v)} grep {/:/} split /\r\n/, $head // '';
    return ($status // 0, \%hdr, $body // '');
}
my %mine = ('x-aicli-gate' => 'gate-view', 'x-aicli-account' => $A);

sub slurp { my ($f) = @_; open(my $h, '<:raw', $f) or die "$f: $!"; local $/; my $d = <$h>; close $h; return $d }

# the vendored files: the NOTICE's list, with the checksum of each
my $notice = slurp("$ui_dir/vendor/three/NOTICE");
my @vendored; # [path, checksum]
while ($notice =~ m/^([0-9a-f]{64})  (\S+)$/mg) { push @vendored, [$2, $1] }

# ---------------------------------------------------------------------------
# the routes: behind the login, the .js files only

{
    my ($s) = get("/viewer.js");
    is($s, 401, "viewer.js: no login, no module");
    ($s) = get("/vendor/three/build/three.module.js");
    is($s, 401, "the three.js files: no login, nothing");

    my ($st, $h, $body) = get("/viewer.js", %mine);
    is($st, 200, "viewer.js is served to a login");
    is($h->{'content-type'}, 'text/javascript; charset=utf-8', "as a JavaScript module");
    like($body, qr/export async function show\(/, "it is the viewer");
    is($h->{'content-length'}, length(slurp("$ui_dir/viewer.js")), "the length of the file");

    for my $f (@vendored) {
        my ($path, $sum) = @$f;
        my $file = "$ui_dir/vendor/three/$path";
        my ($s2, $h2, $b2) = get("/vendor/three/$path", %mine);
        is($s2, 200, "$path is served");
        is($h2->{'content-length'}, -s $file, "$path: its length");
        is(substr($b2, 0, 200), substr(slurp($file), 0, 200), "$path: its first bytes are the file's");
    }

    for my $bad ("/vendor/three/missing.js", "/vendor/three/LICENSE", "/vendor/three/NOTICE",
                 "/vendor/three/../../ui.pm", "/vendor/three/build/../../../ai.pm", "/viewer.txt") {
        my ($s2) = get($bad, %mine);
        is($s2, 404, "$bad: not served");
    }
}

# ---------------------------------------------------------------------------
# GET /file: a model is a download, never shown inline

{
    my ($s, $h, $body) = get("/file?session=mine&path=model.stl", %mine);
    is($s, 200, "an .stl of the session's project is served");
    is($h->{'content-type'}, 'model/stl', "as an STL");
    is($h->{'content-disposition'}, 'attachment; filename="model.stl"', "as a download");
    is($body, $STL, "the bytes of the file");

    ($s, $h, $body) = get("/file?session=mine&path=model.glb", %mine);
    is($s, 200, "a .glb of the session's project is served");
    is($h->{'content-type'}, 'model/gltf-binary', "as a glTF binary");
    is($h->{'content-disposition'}, 'attachment; filename="model.glb"', "as a download");
    is($body, $GLB, "the bytes of the file");
}

# ---------------------------------------------------------------------------
# the page: the import map of three.js, the viewer loaded on the first click, no other script from outside

{
    my $html = slurp("$ui_dir/index.html");
    like($html, qr{<script type="importmap">\{"imports": \{"three": "/vendor/three/build/three\.module\.js"\}\}</script>},
        "the page maps 'three' to the vendored build");
    like($html, qr{import\("/viewer\.js"\)}, "the viewer is loaded when it is asked for");
    like($html, qr/view in 3D/, "a model file has its view button");
    unlike($html, qr{<script[^>]+\bsrc=}i, "the page loads no script from a file of its own");
    unlike($html, qr{<link[^>]+\bhref="https?:}i, "nor a stylesheet or icon from outside");
}

# ---------------------------------------------------------------------------
# the vendored files: the checksums of NOTICE, and no other .js in the directory

{
    my $vendor = "$ui_dir/vendor/three";
    ok(scalar(@vendored) >= 7, "NOTICE names the files (" . scalar(@vendored) . ")");
    for my $f (@vendored) {
        my ($path, $sum) = @$f;
        is(Digest::SHA::sha256_hex(slurp("$vendor/$path")), $sum, "$path: the checksum of NOTICE");
    }
    my @js;
    File::Find::find({wanted => sub { push @js, substr($File::Find::name, length("$vendor/")) if /\.js\z/ }, no_chdir => 1}, $vendor);
    is_deeply([sort @js], [sort map { $_->[0] } @vendored], "no other .js file in the vendored directory");
    like(slurp("$vendor/LICENSE"), qr/^The MIT License$/m, "the license is the MIT License");
    like(slurp("$vendor/LICENSE"), qr/^Copyright .*three\.js authors$/mi, "with the copyright of three.js");
    like(slurp("$vendor/build/three.module.js"), qr{\@license\s+\*\s*Copyright 2010-\d+ Three\.js Authors}, "the build keeps its license header");
}

# ---------------------------------------------------------------------------
# the viewer's parsers in node (when it is installed): a copy of the files in a directory of its own, with
# 'three' resolved to the vendored build (node_modules), and the checks in check.mjs

my ($node) = grep { -x } map { "$_/node" } split /:/, $ENV{PATH} // '';
SKIP: {
    skip "node is not installed: the viewer's parsers are not checked", 1 unless $node;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    for my $f ('viewer.js', map { "vendor/three/$_->[0]" } @vendored) {
        File::Path::make_path((File::Basename::dirname("$dir/ai/ui/$f")));
        File::Copy::copy("$ui_dir/$f", "$dir/ai/ui/$f") or die "copy $f: $!";
    }
    put("$dir/package.json", qq({"type": "module"}\n));
    File::Path::make_path("$dir/node_modules/three");
    put("$dir/node_modules/three/package.json", qq({"name": "three", "type": "module", "main": "index.js"}\n));
    put("$dir/node_modules/three/index.js", qq{export * from "../../ai/ui/vendor/three/build/three.module.js";\n});
    put("$dir/check.mjs", <<'JS');
import { parseModel, MAX_BYTES } from "./ai/ui/viewer.js";
const fetched = [];
globalThis.fetch = async (u) => { fetched.push(typeof u === "string" ? u : (u.url ?? String(u))); throw new Error("no network in the check"); };
let failures = 0;
const check = (c, m) => { if (!c) { failures++; console.error("FAILED: " + m); } };

// a binary STL: two triangles, standing on z = 0
function stl(tris) {
  const buf = new ArrayBuffer(84 + 50 * tris.length);
  const dv = new DataView(buf);
  dv.setUint32(80, tris.length, true);
  tris.forEach((t, i) => { const o = 84 + 50 * i; for (let k = 0; k < 12; k++) dv.setFloat32(o + 4 * k, t[k] ?? 0, true); });
  return buf;
}
const obj = await parseModel(stl([[0,0,1, 0,0,0, 10,0,0, 0,20,0], [0,0,1, 0,0,0, 0,20,0, 0,0,30]]), "stl");
const meshes = []; obj.traverse(o => { if (o.isMesh) meshes.push(o); });
check(meshes.length === 1, "stl: one mesh");
check(meshes[0].geometry.attributes.position.count === 6, "stl: two triangles, six vertices");
check(Math.abs(obj.rotation.x + Math.PI / 2) < 1e-9, "stl: z up turned to y up");
let refused = false; try { await parseModel(new ArrayBuffer(10), "stl"); } catch (e) { refused = true; }
check(refused, "stl: a truncated file is refused");

// a binary glTF: one triangle, from the file's own data (its BIN chunk), or from a web address
function glb(json, bin) {
  const pad = (b, p) => Buffer.concat([b, Buffer.alloc((4 - b.length % 4) % 4, p)]);
  const jp = pad(Buffer.from(JSON.stringify(json)), 0x20);
  const jh = Buffer.alloc(8); jh.writeUInt32LE(jp.length, 0); jh.write("JSON", 4);
  let body = Buffer.concat([jh, jp]);
  if (bin) { const bp = pad(bin, 0); const bh = Buffer.alloc(8); bh.writeUInt32LE(bp.length, 0); bh.write("BIN\0", 4); body = Buffer.concat([body, bh, bp]); }
  const head = Buffer.alloc(12); head.write("glTF", 0); head.writeUInt32LE(2, 4); head.writeUInt32LE(12 + body.length, 8);
  const all = Buffer.concat([head, body]);
  return all.buffer.slice(all.byteOffset, all.byteOffset + all.byteLength);
}
const pos = Buffer.alloc(42);
[0,0,0, 1,0,0, 0,1,0].forEach((v, i) => pos.writeFloatLE(v, 4 * i));
[0,1,2].forEach((v, i) => pos.writeUInt16LE(v, 36 + 2 * i));
const base = { asset: { version: "2.0" }, scene: 0, scenes: [{ nodes: [0] }], nodes: [{ mesh: 0 }],
  meshes: [{ primitives: [{ attributes: { POSITION: 0 }, indices: 1 }] }],
  bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: 36 }, { buffer: 0, byteOffset: 36, byteLength: 6 }],
  accessors: [{ bufferView: 0, componentType: 5126, count: 3, type: "VEC3", min: [0,0,0], max: [1,1,0] },
              { bufferView: 1, componentType: 5123, count: 3, type: "SCALAR" }] };
const own = await parseModel(glb({ ...base, buffers: [{ byteLength: 42 }] }, pos), "glb");
const tris = []; own.traverse(o => { if (o.isMesh) tris.push(o); });
check(tris.length === 1 && tris[0].geometry.index.count === 3, "glb: one triangle from its own data");
check(fetched.length === 0, "glb: its own data needs no request");
let failed = false;
try { await parseModel(glb({ ...base, buffers: [{ byteLength: 42, uri: "https://example.invalid/part.bin" }] }, null), "glb"); } catch (e) { failed = true; }
check(fetched.every(u => !/^https?:/.test(u)), "glb: a web address in the file is not requested: " + fetched.join(", "));
check(failed, "glb: a web address for its data does not load (the check's fetch refuses it)");
check(MAX_BYTES === 50 * 1024 * 1024, "the size cap is 50 MB");
process.exitCode = failures ? 1 : 0;
JS
    my $errfile = "$dir/errors.txt";
    open(my $olderr, '>&', \*STDERR) or die $!;
    open(STDERR, '>', $errfile) or die $!;
    my $rc = system($node, "$dir/check.mjs");
    open(STDERR, '>&', $olderr) or die $!;
    ok($rc == 0, "the viewer's parsers (node)") or diag(slurp($errfile));
}

done_testing();
