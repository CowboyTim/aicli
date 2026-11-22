// The revert button on the chat: only the last answer's is enabled; the first click says "sure?",
// the second reverts it. Needs start-server.sh (the session s1 has two exchanges).
const { open, chatFile, state } = require('./common');
(async () => {
  const { b, p, errors } = await open();
  await p.waitForFunction(() => document.querySelectorAll('#log .answer').length >= 2, null, { timeout: 15000 });
  const info = () => p.$$eval('#log .tag button.revert', bs => bs.map(x => ({ text: x.textContent, disabled: x.disabled })));
  console.log('buttons:', JSON.stringify(await info()));
  const last = p.locator('#log .tag button.revert').last();
  await last.click();
  console.log('after 1 click:', JSON.stringify(await info()));
  await last.click();
  await p.waitForTimeout(1500);
  console.log('after 2 clicks:', JSON.stringify(await info()), 'answers:', await p.$$eval('#log .answer', a => a.length));
  console.log('chat file now has', chatFile('s1').trim().split('\n').length, 'lines (was 5)');
  console.log('page errors:', JSON.stringify(errors));
  await p.screenshot({ path: state + '/after-revert.png' });
  await b.close();
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
