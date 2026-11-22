// The menu: session rename from the name box, delete with "sure?" and "cancel", then project
// create, rename and delete. Changes the state dir (it renames and deletes the sessions and projects).
const { open, sessions, projects, state } = require('./common');
(async () => {
  const { b, p, errors } = await open();
  const status = () => p.textContent('#status');
  const openMenu = async id => { if (!(await p.isVisible('#' + id))) { await p.click('#menu-btn'); } };
  await openMenu('newsession');
  await p.fill('#newsession', 'renamed-one');
  await p.click('#renamesession');
  await p.waitForTimeout(1500);
  console.log('rename:', await status(), '| on disk:', JSON.stringify(sessions()));
  await p.click('#delsession');
  console.log('delete 1:', await p.textContent('#delsession'), '| cancel visible:', await p.isVisible('#delsession-cancel'));
  await p.click('#delsession-cancel');
  console.log('cancel:', await p.textContent('#delsession'), '| still on disk:', JSON.stringify(sessions()));
  await p.click('#delsession');
  await p.click('#delsession');
  await p.waitForTimeout(2000);
  console.log('delete 2:', await status(), '| on disk:', JSON.stringify(sessions()));
  await openMenu('newproject');
  await p.fill('#newproject', 'acme/lab');
  await p.click('#projcreate');
  await p.waitForTimeout(1500);
  console.log('project created:', JSON.stringify(projects()));
  await p.selectOption('#project', 'acme/lab');
  await p.waitForTimeout(1000);
  await p.fill('#newproject', 'lab2');
  await p.click('#projrename');
  await p.waitForTimeout(1500);
  console.log('project renamed:', JSON.stringify(projects()));
  await p.click('#projdelete');
  await p.click('#projdelete');
  await p.waitForTimeout(1500);
  console.log('project deleted, on disk:', JSON.stringify(projects()));
  console.log('page errors:', JSON.stringify(errors));
  await b.close();
})().catch(e => { console.log('FAILED', e.message); process.exit(1); });
