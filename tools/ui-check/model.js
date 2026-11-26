// The 3D view of a model on the page. A tool call that wrote an .stl (the fixture's chat gets one, and the
// file) shows a "view in 3D" button; the click loads the viewer (/viewer.js, the import map of three.js and
// the vendored files), and the model is drawn in a canvas. Headless Firefox has no WebGL here, so the view
// says why it cannot draw ("3D view: ..."): that is the expected result in this sandbox, and a browser with
// WebGL shows the canvas. Run it on a fresh state dir from start-server.sh:
//   AICLI_STATE=<state dir> NODE_PATH=$(npm root -g) node model.js
const fs = require('fs');
const path = require('path');
const { state, open } = require('./common');

// a binary STL of two triangles, standing on z = 0 (the format generate_3d writes for a printer)
function stl() {
  const tris = [[0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 20, 0], [0, 0, 1, 0, 0, 0, 0, 20, 0, 0, 0, 30]];
  const buf = Buffer.alloc(84 + 50 * tris.length);
  buf.writeUInt32LE(tris.length, 80);
  tris.forEach((t, i) => t.forEach((v, k) => buf.writeFloatLE(v, 84 + 50 * i + 4 * k)));
  return buf;
}

// the fixture's conversation gets a tool call that wrote the model, and the model is in the project
fs.writeFileSync(path.join(state, 'root', 'model.stl'), stl());
const line = o => JSON.stringify(o) + '\n';
fs.appendFileSync(path.join(state, 'ai/sessions/s1/chat'), [
  line({ role: 'user', content: 'make a model' }),
  line({ role: 'assistant', content: '', tool_calls: [{ id: 'm1', type: 'function', function: { name: 'generate_3d', arguments: JSON.stringify({ input: 'pic.png', output: 'model.stl', format: 'stl' }) } }] }),
  line({ role: 'tool', tool_call_id: 'm1', content: 'wrote model.stl: 2 triangles, 184 bytes\n' }),
].join(''));

(async () => {
  const { b, p, errors } = await open();
  let ok = true;
  const check = (c, m) => { console.log((c ? 'ok   ' : 'FAIL ') + m); if (!c) ok = false; };
  const pageErrors = () => errors.filter(e => e.startsWith('pageerror'));
  try {
    const button = p.getByRole('button', { name: 'view in 3D' });
    await button.waitFor({ timeout: 15000 });
    check(true, 'the model file has its button');
    check(await p.getByRole('link', { name: 'download model.stl' }).count() === 1, 'and its download');
    check(pageErrors().length === 0, 'no uncaught error on the page: ' + pageErrors().join('; '));

    // the viewer's module and the parser, in this browser: the import map and the file's bytes
    const r = await p.evaluate(async () => {
      const m = await import('/viewer.js');
      const resp = await fetch('/file?session=s1&path=model.stl', { credentials: 'same-origin' });
      const obj = await m.parseModel(await resp.arrayBuffer(), 'stl');
      let tris = 0;
      obj.traverse(o => { if (o.isMesh) { tris += o.geometry.attributes.position.count / 3; } });
      return { exports: Object.keys(m).sort().join(','), tris };
    });
    check(r.exports === 'MAX_BYTES,parseModel,show', 'viewer.js exports its three functions: ' + r.exports);
    check(r.tris === 2, 'the model parses in the browser: ' + r.tris + ' triangles');

    await button.click();
    await p.waitForFunction(() => {
      const h = document.querySelector('.model');
      return h && (h.querySelector('canvas') || /^3D view: /.test(h.textContent));
    }, null, { timeout: 30000 });
    const canvases = await p.locator('.model canvas').count();
    const text = await p.locator('.model').first().textContent();
    check(canvases === 1 || text.startsWith('3D view: '), 'the click draws the model or says why not');
    check(pageErrors().length === 0, 'no uncaught error after the click: ' + pageErrors().join('; '));
    console.log(canvases === 1 ? 'drawn: a canvas' : 'not drawn here: ' + text);
  } catch (e) {
    check(false, 'the check ran: ' + e.message.split('\n')[0]);
  } finally {
    await b.close();
  }
  process.exit(ok ? 0 : 1);
})();
