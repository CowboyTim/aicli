// The "+" by the message box: the files picked with it go to the project's uploads/ folder (any kind), each
// shows as a chip with a link to the file, and the next message names them. The check picks a text file and a
// binary one, looks at the chips, the folder and the link, then sends a message and looks at the chat file.
// Needs a fresh start-server.sh fixture (the session s1 runs in the root, as the local operator):
//   AICLI_URL=http://127.0.0.1:8770 AICLI_STATE=<state dir> NODE_PATH=$(npm root -g) node upload.js
const fs = require('fs');
const path = require('path');
const { open, state, chatFile } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  const folder = path.join(state, 'root', 'uploads');

  check(await p.locator('#attach').count() === 1, 'the + button is by the message box');
  check(await p.getAttribute('#file', 'accept') === null, 'the picker takes any kind of file (no accept filter)');

  await p.setInputFiles('#file', [
    { name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('line one\nline two\n') },
    { name: 'data bin.dat', mimeType: 'application/octet-stream', buffer: Buffer.from([0, 1, 254, 255]) },
  ]);
  await p.waitForFunction(() => document.querySelectorAll('#chips .chip a').length === 2, null, { timeout: 15000 });
  const links = await p.$$eval('#chips .chip a', as => as.map(a => a.textContent));
  check(JSON.stringify(links) === JSON.stringify(['uploads/notes.txt', 'uploads/data bin.dat']),
    'two chips, each with its uploads/ name: ' + JSON.stringify(links));
  check(fs.readFileSync(path.join(folder, 'notes.txt'), 'utf8') === 'line one\nline two\n', 'the text file is in uploads/');
  const bin = fs.readFileSync(path.join(folder, 'data bin.dat'));
  check(bin.length === 4 && bin[2] === 254 && bin[3] === 255, 'the binary file is in uploads/, the bytes as they were');

  // the chip's link opens the file: the file route serves it from the project
  const href = await p.getAttribute('#chips .chip a', 'href');
  const r = await p.request.get(new URL(href, p.url()).toString());
  check(r.status() === 200 && (await r.text()) === 'line one\nline two\n', 'the chip link serves the file (' + r.status() + ')');

  // the next message names the files, and the chips go
  await p.fill('#text', 'what is in them?');
  await p.click('#send');
  await p.waitForFunction(() => document.querySelectorAll('#chips .chip').length === 0, null, { timeout: 15000 });
  const named = 'Uploaded: uploads/notes.txt, uploads/data bin.dat\n\nwhat is in them?';
  let inChat = false;
  for (let i = 0; i < 50 && !inChat; i++) {
    inChat = chatFile('s1').includes(JSON.stringify(named).slice(1, -1));
    if (!inChat) await p.waitForTimeout(200);
  }
  check(inChat, 'the chat file has the message with the file names');
  check(await p.locator('#log .user', { hasText: 'Uploaded: uploads/notes.txt' }).count() >= 1, 'the page shows it as the user message');

  // an empty file is a file too: it is kept, and it gets a chip of its own
  await p.setInputFiles('#file', [{ name: 'empty.txt', mimeType: 'text/plain', buffer: Buffer.alloc(0) }]);
  await p.waitForFunction(() => document.querySelectorAll('#chips .chip a').length === 1, null, { timeout: 15000 });
  check(fs.existsSync(path.join(folder, 'empty.txt')), 'an empty file is kept too');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
