// Several tool calls in one answer: each is listed on the page (its tool line, which opens to its whole
// call), each is run and shows its picture, and each result says how long it took, live and after a
// reload. Needs the fake services and a server started with them (see files.js and AGENTS.md): the
// message "draw two cubes" makes the fake model ask for two pictures in one answer.
const { open } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  await p.fill('#text', 'draw two cubes');
  await p.click('#send');
  await p.waitForFunction(() => {
    const imgs = Array.from(document.querySelectorAll('#log .msg.file img'));
    return imgs.length >= 2 && imgs.every(i => i.complete && i.naturalWidth > 0);
  }, null, { timeout: 30000 });

  const counts = async () => ({
    lines: await p.locator('#log .tool-head').filter({ hasText: 'generate_image' }).count(),
    pictures: await p.locator('#log .msg.file img').count(),
    took: await p.locator('#log .result').filter({ hasText: /took \d/ }).count(),
    names: await p.$$eval('#log .msg.file img', imgs => imgs.map(i => i.getAttribute('src').replace(/^.*path=/, ''))),
  });

  let c = await counts();
  check(c.lines === 2, 'two tool lines, one for each call (' + c.lines + ')');
  check(c.pictures === 2 && c.names.join() === 'pair-1.png,pair-2.png', 'two pictures, each from its own call (' + c.names.join(' ') + ')');
  check(c.took === 2, 'each result says how long it took (' + c.took + ')');

  // each tool line opens to the call it is: its own output name
  const heads = p.locator('#log .tool-head').filter({ hasText: 'generate_image' });
  for (const [i, out] of [[0, 'pair-1.png'], [1, 'pair-2.png']]) {
    await heads.nth(i).click();
    const text = await p.locator('#log .tool-full').nth(i).textContent();
    check(text.includes('output: ' + out), 'tool line ' + (i + 1) + ' opens to its call (output: ' + out + ')');
  }

  await p.reload();
  await p.waitForFunction(() => document.getElementById('status').textContent.startsWith('session'), null, { timeout: 15000 });
  await p.waitForFunction(() => document.querySelectorAll('#log .msg.file img').length >= 2, null, { timeout: 15000 });
  await p.waitForFunction(() => Array.from(document.querySelectorAll('#log .msg.file img')).every(i => i.complete && i.naturalWidth > 0), null, { timeout: 15000 });
  const again = await counts();
  check(again.lines === 2 && again.pictures === 2 && again.names.join() === c.names.join(),
    'after a reload the same: two tool lines, two pictures');
  // the times are not kept with the chat, but the header has the session's totals
  const header = await p.textContent('#status');
  check(/\b2 tool calls, \d+\.\d s$/.test(header), 'the header has the totals of the session (' + header + ')');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
