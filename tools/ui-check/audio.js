// A clip a tool made in the chat: it plays (the audio element) and downloads, live and after a reload.
// Needs the fake services with the audio service, and a server started with them (see files.js and
// AGENTS.md): the message "make a sound" makes the fake model ask for generate_audio, and the fake
// audio service answers with a one second WAV.
//   python3 tools/ui-check/fake-services.py 8780 8781 8782 &
//   AICLI_CHECK_LLM=http://127.0.0.1:8780/v1 AICLI_CHECK_IMAGE=http://127.0.0.1:8781/rocm \
//     AICLI_CHECK_AUDIO=http://127.0.0.1:8782/rocm sh tools/ui-check/start-server.sh
const fs = require('fs');
const { open, state, url } = require('./common');

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };

(async () => {
  const { b, p, errors } = await open();
  await p.fill('#text', 'make a sound');
  await p.click('#send');

  // live: the clip is an audio element, and it loads (its length is known)
  await p.waitForSelector('#log .msg.file audio', { timeout: 30000 });
  const audio = p.locator('#log .msg.file audio').first();
  const src = await audio.getAttribute('src');
  check(src !== null && src.includes('path=clip.wav'), 'the clip is in the chat as an audio element (' + src + ')');
  await p.waitForFunction(() => {
    const a = document.querySelector('#log .msg.file audio');
    return a && a.readyState >= 1;
  }, null, { timeout: 15000 });
  const seconds = await audio.evaluate(a => a.duration);
  check(seconds > 0.5 && seconds < 1.5, 'it loads, and is about a second long (' + seconds.toFixed(2) + ' s)');
  check(fs.existsSync(state + '/root/clip.wav'), 'the file is in the session\'s project');

  // its address: the clip as audio/wav, inline so that it plays
  const view = await p.context().request.get(url + src);
  check(view.status() === 200 && (view.headers()['content-type'] || '') === 'audio/wav', 'the clip answers 200 as audio/wav');
  check((view.headers()['content-disposition'] || '').startsWith('inline'), 'and inline, to play');

  // the download: the file under its own name, with the bytes the tool wrote
  const link = p.locator('#log .msg.file a[download]').first();
  check((await link.textContent()) === 'download clip.wav', 'a download link names the clip');
  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 15000 }), link.click()]);
  const saved = state + '/downloaded-clip.wav';
  await dl.saveAs(saved);
  check(dl.suggestedFilename() === 'clip.wav', 'the download is named clip.wav (' + dl.suggestedFilename() + ')');
  const bytes = fs.readFileSync(saved);
  check(bytes.equals(fs.readFileSync(state + '/root/clip.wav')) && bytes.slice(0, 4).toString() === 'RIFF',
    'and its bytes are the file\'s, a WAV');

  // after a reload the history has the clip again, playable and downloadable
  await p.reload();
  await p.waitForFunction(() => document.getElementById('status').textContent.startsWith('session'), null, { timeout: 15000 });
  await p.waitForSelector('#log .msg.file audio', { timeout: 15000 });
  await p.waitForFunction(() => {
    const a = document.querySelector('#log .msg.file audio');
    return a && a.readyState >= 1;
  }, null, { timeout: 15000 });
  check(await p.locator('#log .msg.file audio').count() === 1, 'after a reload the clip is there, from the history');
  check(await p.locator('#log .msg.file a[download]').count() === 1, 'and its download link');

  check(errors.length === 0, 'no page errors: ' + JSON.stringify(errors));
  await b.close();
  if (failed) { console.log(failed + ' check(s) failed'); process.exit(1); }
  console.log('all checks passed');
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
