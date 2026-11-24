// A cancelled answer can be reverted, as the others: a question the answer never came for (cancelled before
// its first word, or while the model was still thinking) has its revert button, and so has an answer cut short
// (its partial text). Each revert takes
// the exchange out of the chat file and the page. Needs the fake services with the chat's slow answers, and a
// fresh start-server.sh fixture (see files.js and AGENTS.md):
//   python3 tools/ui-check/fake-services.py 8780 8781 8782 &
//   AICLI_CHECK_LLM=http://127.0.0.1:8780/v1 sh tools/ui-check/start-server.sh
const { open, chatFile } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  const answers = () => p.$$eval('#log .answer', as => as.length);
  const enabled = () => p.locator('#log .tag button.revert:not([disabled])').count();
  const idle = () => p.waitForFunction(() => !document.getElementById('send').disabled, null, { timeout: 30000 });
  const revertEnabled = async () => {
    const r = p.locator('#log .tag button.revert:not([disabled])').first();
    await r.click();
    await p.waitForTimeout(100);
    await r.click();
    await p.waitForTimeout(1500);
  };
  const lastChat = () => chatFile('s1').trim().split('\n').map(l => JSON.parse(l));
  const before = await answers();

  // 1. cancelled before its first word: the question has the revert, and the revert takes it out
  await p.fill('#text', 'a late slow story');
  await p.click('#send');
  await p.waitForTimeout(1500);
  await p.click('#abort');
  await idle();
  await p.waitForTimeout(500);
  check(await enabled() === 1, 'the cancelled question has its revert button');
  await revertEnabled();
  check(!lastChat().some(m => String(m.content).includes('late slow story')), 'the revert takes the cancelled question out of the chat file');
  check(await answers() === before, 'and out of the page (' + (await answers()) + ' answers, as before)');

  // 2. cancelled with some text: the answer has the revert, and the revert takes the answer and its question out
  await p.fill('#text', 'a slow story');
  await p.click('#send');
  await p.waitForFunction(() => document.body.innerText.includes('word2'), null, { timeout: 20000 });
  await p.click('#abort');
  await idle();
  await p.waitForTimeout(500);
  check(await enabled() === 1, 'the cut-short answer has its revert button');
  await revertEnabled();
  check(!lastChat().some(m => String(m.content).includes('slow story') || String(m.content).includes('word')),
    'the revert takes the cut-short answer and its question out of the chat file');
  check(await answers() === before, 'and out of the page (' + (await answers()) + ' answers, as before)');

  // 3. cancelled while the model is still thinking: the question has the revert, and no empty answer is left behind
  await p.fill('#text', 'slow think about it');
  await p.click('#send');
  await p.waitForTimeout(3000);
  await p.click('#abort');
  await idle();
  await p.waitForTimeout(500);
  check(await p.$$eval('#log .answer', as => as.every(a => a.textContent !== '')), 'no empty answer is left behind by the stop');
  check(await enabled() === 1, 'the question of the stopped thinking has its revert button');
  await revertEnabled();
  check(!lastChat().some(m => String(m.content).includes('think about it')), 'the revert takes that question out of the chat file');
  check(await answers() === before, 'and out of the page (' + (await answers()) + ' answers, as before)');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
