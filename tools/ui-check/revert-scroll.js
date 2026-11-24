// Reverting the last answer of a long chat keeps the page at its end: it does not jump to the top, on a
// desktop and on a phone-sized view. Needs a FRESH start-server.sh fixture: the script adds long exchanges
// to the chat of s1 before the page opens (the page loads the chat when it connects).
const fs = require('fs');
const { open, state } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const lines = [];
  for (let i = 1; i <= 12; i++) {
    lines.push(JSON.stringify({ role: 'user', content: 'question ' + i }));
    lines.push(JSON.stringify({ role: 'assistant', content: Array.from({ length: 14 },
      (_, k) => 'answer ' + i + ' line ' + (k + 1) + ' with some text to fill the line').join('\n') }));
  }
  fs.appendFileSync(state + '/ai/sessions/s1/chat', lines.join('\n') + '\n');

  const { b, p, errors } = await open();
  await p.waitForFunction(() => document.querySelectorAll('#log .answer').length >= 12, null, { timeout: 15000 });

  // how far the view is from the end of the page, and from the top
  const place = () => p.evaluate(() => ({
    fromEnd: Math.round(document.documentElement.scrollHeight - window.innerHeight - window.scrollY),
    y: Math.round(window.scrollY),
  }));
  const revertLast = async (what) => {
    await p.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await p.waitForTimeout(300);
    const before = await place();
    const last = p.locator('#log .tag button.revert').last();
    await last.scrollIntoViewIfNeeded();
    await last.click();
    await p.waitForTimeout(100);
    await last.click();
    const seen = [];
    for (let i = 0; i < 6; i++) {
      await p.waitForTimeout(250);
      seen.push(await place());
    }
    check(before.fromEnd <= 2, what + ': the page is at its end before the revert');
    check(seen.every(s => s.fromEnd <= 2 && s.y > 0),
      what + ': at the end all the time after the revert, never at the top (' + JSON.stringify(seen.map(s => s.y)) + ')');
  };

  await revertLast('desktop');
  await p.setViewportSize({ width: 390, height: 844 });
  await p.waitForTimeout(300);
  await revertLast('phone');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
