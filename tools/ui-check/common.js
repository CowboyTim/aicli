// Shared settings of the browser checks: the page's address and token, and the state dir of the
// server (start-server.sh prints it). Environment: AICLI_URL, AICLI_TOKEN, AICLI_STATE.
const fs = require('fs');
const { firefox } = require('playwright');

const url = process.env.AICLI_URL || 'http://127.0.0.1:8770';
const token = process.env.AICLI_TOKEN || 'abc123';
const state = process.env.AICLI_STATE;
if (!state) { console.error('set AICLI_STATE to the state dir that start-server.sh printed'); process.exit(2); }

const sessions = () => fs.readdirSync(state + '/ai/sessions').sort();
const projects = () => { try { return fs.readdirSync(state + '/root/acme').sort(); } catch (e) { return []; } };
const chatFile = name => fs.readFileSync(state + '/ai/sessions/' + name + '/chat', 'utf8');

// Firefox: the one Playwright has here (Chromium is not installed in this sandbox)
async function open() {
  const b = await firefox.launch();
  const p = await b.newPage({ viewport: { width: 900, height: 700 } });
  const errors = [];
  p.on('pageerror', e => errors.push('pageerror: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') errors.push('console.' + m.type() + ': ' + m.text()); });
  await p.goto(url + '/?token=' + token);
  await p.waitForFunction(() => document.getElementById('status').textContent.startsWith('session'), null, { timeout: 15000 });
  return { b, p, errors };
}

module.exports = { url, token, state, sessions, projects, chatFile, open };
