// A picture a bash call made (here: cp, from the fake model's "copy" message) is offered on the page like
// the ones the file tools make: inline, with its download, live and after a reload. Needs the fake services
// with the image service, and a server started with them (see files.js and AGENTS.md).
//   python3 tools/ui-check/fake-services.py 8780 8781 8782 &
//   AICLI_CHECK_LLM=http://127.0.0.1:8780/v1 AICLI_CHECK_IMAGE=http://127.0.0.1:8781/rocm sh tools/ui-check/start-server.sh
const fs = require('fs');
const { open, state } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  const loaded = n => p.waitForFunction(n => {
    const imgs = Array.from(document.querySelectorAll('#log .msg.file img'));
    return imgs.length >= n && imgs.every(i => i.complete && i.naturalWidth > 0);
  }, n, { timeout: 30000 });

  await p.fill('#text', 'draw a cube');
  await p.click('#send');
  await loaded(1);
  await p.waitForFunction(() => document.getElementById('send').disabled === false, null, { timeout: 30000 });

  await p.fill('#text', 'copy the picture');
  await p.click('#send');
  await loaded(2);
  let names = await p.$$eval('#log .msg.file img', imgs => imgs.map(i => i.getAttribute('src').replace(/^.*path=/, '').replace(/&.*$/, '')));
  check(names.join() === 'live.png,copy.png', 'the copy the bash call made is shown, after the picture it copies (' + names.join(' ') + ')');
  check(fs.existsSync(state + '/root/copy.png') && fs.readFileSync(state + '/root/copy.png').equals(fs.readFileSync(state + '/root/live.png')),
    'the copy is in the project, and its bytes are the picture\'s');
  const link = p.locator('#log .msg.file a[download]').nth(1);
  check((await link.textContent()) === 'download copy.png', 'and it has a download link named copy.png');
  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 15000 }), link.click()]);
  check(dl.suggestedFilename() === 'copy.png', 'the download is named copy.png');
  const src = await p.locator('#log .msg.file img').nth(1).getAttribute('src');
  check(/[?&]v=/.test(src), 'its address has a version, so a changed file is not kept by the browser');

  // the result of the bash call on the page does not show the list of files the call made
  const results = await p.$$eval('#log .result', els => els.map(e => e.textContent));
  check(!results.some(t => t.includes('[aicli file]')), 'the result on the page has no list of files');

  await p.reload();
  await p.waitForFunction(() => document.getElementById('status').textContent.startsWith('session'), null, { timeout: 15000 });
  await loaded(2);
  names = await p.$$eval('#log .msg.file img', imgs => imgs.map(i => i.getAttribute('src').replace(/^.*path=/, '').replace(/&.*$/, '')));
  check(names.join() === 'live.png,copy.png', 'after a reload the copy is there, from the history');
  check(await p.locator('#log .msg.file a[download]').count() === 2, 'and both downloads');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
