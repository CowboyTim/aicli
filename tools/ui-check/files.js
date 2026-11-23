// The files of a session on the page: a picture a tool wrote is shown inline and has a download,
// at once (the turn's file event) and after a reload (the history). Needs the fixture with the fake
// services (see "Testing the page in a browser" in AGENTS.md):
//   python3 tools/ui-check/fake-services.py 8780 8781 &
//   AICLI_CHECK_LLM=http://127.0.0.1:8780/v1 AICLI_CHECK_IMAGE=http://127.0.0.1:8781/rocm sh tools/ui-check/start-server.sh
// The model asks for generate_image("a cube", live.png) once; the picture is 256 x 256.
const fs = require('fs');
const { open, state, url } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  await p.fill('#text', 'draw a cube');
  await p.click('#send');

  // the live picture: shown inline once it has loaded
  await p.waitForSelector('#log .msg.file img', { timeout: 30000 });
  const live = p.locator('#log .msg.file img').first();
  await p.waitForFunction(() => {
    const i = document.querySelector('#log .msg.file img');
    return i && i.complete && i.naturalWidth > 0;
  }, null, { timeout: 15000 });
  check(await live.evaluate(i => i.naturalWidth) === 256, 'the live picture is shown inline, 256 pixels wide');
  check(fs.existsSync(state + '/root/live.png'), 'the file is in the session\'s project');

  // the download: the browser saves the file under its own name, with the bytes the tool wrote
  const link = p.locator('#log .msg.file a[download]').first();
  check((await link.textContent()) === 'download live.png', 'a download link names the file');
  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 15000 }), link.click()]);
  const saved = state + '/downloaded-live.png';
  await dl.saveAs(saved);
  check(dl.suggestedFilename() === 'live.png', 'the download is named live.png (' + dl.suggestedFilename() + ')');
  check(fs.readFileSync(saved).equals(fs.readFileSync(state + '/root/live.png')), 'and its bytes are the file\'s');

  // the picture's own address: inline, as a picture, sandboxed; the download asks for an attachment
  const src = await live.getAttribute('src');
  const view = await p.context().request.get(url + src);
  check(view.status() === 200, 'the picture answers 200 (' + view.status() + ')');
  check((view.headers()['content-type'] || '') === 'image/png', 'as image/png');
  check((view.headers()['content-disposition'] || '').startsWith('inline'), 'inline');
  const file = await p.context().request.get(url + src + '&download=1');
  check((file.headers()['content-disposition'] || '').startsWith('attachment'), 'and with download=1 an attachment');

  // after a reload the history shows the picture and its download again
  await p.reload();
  await p.waitForFunction(() => document.getElementById('status').textContent.startsWith('session'), null, { timeout: 15000 });
  await p.waitForSelector('#log .msg.file img', { timeout: 15000 });
  await p.waitForFunction(() => {
    const i = document.querySelector('#log .msg.file img');
    return i && i.complete && i.naturalWidth > 0;
  }, null, { timeout: 15000 });
  check(await p.locator('#log .msg.file img').first().evaluate(i => i.naturalWidth) === 256,
    'after a reload the picture is shown again, from the history');
  check(await p.locator('#log .msg.file a[download]').count() >= 1, 'and its download link is there');

  // the tool line: shown closed, a click opens the whole call with its arguments in full (also from the history)
  const line = () => p.locator('#log .tool-head').filter({ hasText: 'generate_image' }).first();
  check((await line().getAttribute('aria-expanded')) === 'false', 'the tool line is shown closed');
  await line().click();
  check((await line().getAttribute('aria-expanded')) === 'true', 'a click opens the tool line');
  const full = p.locator('#log .tool-full').first();
  const text = await full.textContent();
  check(/prompt: a cube/.test(text) && /output: live\.png/.test(text), 'the whole call: its arguments in full (' + JSON.stringify(text.slice(0, 60)) + ')');
  check(await full.isVisible(), 'and it is visible');
  await line().click();
  check(!(await full.isVisible()), 'a second click closes it again');
  await line().click();
  check(await p.locator('#log .tool-full').first().isVisible(), 'and the history\'s tool line opens too');
  await p.screenshot({ path: state + '/files.png' });

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  console.log('screenshot: ' + state + '/files.png');
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
