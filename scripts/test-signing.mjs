import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync, existsSync, chmodSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Real shell control flow, isolated bundle, and recording stand-ins for Apple services.
// These tests do not claim to verify Apple signatures or contact Apple's notary service.
if (process.platform === 'darwin') {
  const fixture = realpathSync(mkdtempSync(join(tmpdir(), 'fieldnotes-signing-')));
  try {
    for (const path of ['scripts', 'stubs', 'build/FIELDNOTES.app/Contents/MacOS', 'build/FIELDNOTES.app/Contents/Resources/editor-web', 'build/FIELDNOTES.app/Contents/Resources/bin']) mkdirSync(join(fixture, path), { recursive: true });
    for (const script of ['sign-and-package.sh', 'check-release-policy.sh']) copyFileSync(new URL(script, import.meta.url), join(fixture, 'scripts', script));
    const app = join(fixture, 'build/FIELDNOTES.app');
    for (const name of ['FIELDNOTESApp', 'fieldnotes']) writeFileSync(join(app, 'Contents/MacOS', name), 'binary');
    writeFileSync(join(app, 'Contents/Resources/editor-web/index.html'), 'web');
    writeFileSync(join(app, 'Contents/Resources/AppIcon.icns'), 'icnsfixture');
    writeFileSync(join(app, 'Contents/Resources/bin/fieldnotes'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    writeFileSync(join(fixture, 'keychain'), 'fixture');
    writeFileSync(join(fixture, 'notary.p8'), 'fixture');
    const stub = `#!${process.execPath}
const fs=require('fs'), path=require('path');
const name=path.basename(process.argv[1]), args=process.argv.slice(2), env=process.env;
fs.appendFileSync(env.EVENTS, JSON.stringify([name,...args])+'\\n');
if(name==='security' && env.SCENARIO!=='missing-identity') console.log('1) '+ 'A'.repeat(40)+' "'+env.DEVELOPER_ID+'"');
if(name==='lipo') console.log('x86_64 arm64');
if(name==='codesign' && args[0]==='-d' && env.SCENARIO==='adhoc') { console.log('Signature=adhoc'); process.exit(0); }
if(name==='codesign' && args[0]==='-d') {
 console.log('Authority='+env.DEVELOPER_ID+'\\nTeamIdentifier='+(env.SCENARIO==='wrong-team'?'WRONGTEAM1':env.APPLE_TEAM_ID)+'\\nTimestamp=Sep 16 2026\\nCodeDirectory v=20500 flags=0x10000(runtime)');
}
if(name==='ditto') { if(args[0]==='-c') fs.writeFileSync(args.at(-1),'zip'); else fs.cpSync(args[0],args[1],{recursive:true}); }
if(name==='hdiutil' && args[0]==='create') fs.writeFileSync(args.at(-1),'dmg');
if(name==='xcrun' && args[0]==='notarytool') {
 const id='12345678-1234-1234-1234-123456789abc';
 if(args[1]==='submit') console.log(JSON.stringify({id}));
 if(args[1]==='wait') {
   const countFile=path.join(env.FIXTURE,'wait-count');
   const n=fs.existsSync(countFile)?Number(fs.readFileSync(countFile))+1:1; fs.writeFileSync(countFile,String(n));
   if(env.SCENARIO==='malformed') console.log('broken json');
   else console.log(JSON.stringify({id,status:env.SCENARIO==='rejected'||(env.SCENARIO==='dmg-rejected'&&n===2)?'Invalid':env.SCENARIO==='timeout'?'In Progress':'Accepted'}));
   if(env.SCENARIO==='timeout') process.exit(69);
 }
 if(args[1]==='log') fs.writeFileSync(args.at(-1),JSON.stringify({id,issues:[]}));
}
if(name==='shasum') { const cp=require('child_process').spawnSync('/usr/bin/shasum',args,{encoding:'utf8'}); process.stdout.write(cp.stdout); process.exit(cp.status); }
if(name==='gh') console.log(env.POLICY||'false');
`;
    for (const command of ['security', 'plutil', 'lipo', 'nm', 'strings', 'codesign', 'ditto', 'hdiutil', 'xcrun', 'spctl', 'shasum', 'gh']) {
      writeFileSync(join(fixture, 'stubs', command), stub); chmodSync(join(fixture, 'stubs', command), 0o755);
    }
    const env = { ...process.env, PATH: `${join(fixture, 'stubs')}:${process.env.PATH}`, APP_VERSION: '1.2.3', APPLE_TEAM_ID: 'ABCDEF1234', DEVELOPER_ID: 'Developer ID Application: Example (ABCDEF1234)', SIGNING_KEYCHAIN: join(fixture, 'keychain'), NOTARY_KEY: join(fixture, 'notary.p8'), NOTARY_KEY_ID: 'EXAMPLEKEY1', NOTARY_ISSUER: '', EVENTS: join(fixture, 'events'), FIXTURE: fixture };
    const events = () => readFileSync(env.EVENTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
    const run = (scenario, overrides = {}, versions = ['1.2.3', '1.2.3']) => {
      for (const path of ['events', 'wait-count', 'build/notary-reports', 'build/FIELDNOTES-1.2.3.dmg', 'build/FIELDNOTES-1.2.3.sha256']) rmSync(join(fixture, path), { recursive: true, force: true });
      writeFileSync(env.EVENTS, '');
      writeFileSync(join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${versions[0]}</string><key>CFBundleVersion</key><string>${versions[1]}</string><key>CFBundleIconFile</key><string>AppIcon</string></dict></plist>`);
      return spawnSync('bash', ['scripts/sign-and-package.sh'], { cwd: fixture, env: { ...env, SCENARIO: scenario, ...overrides }, encoding: 'utf8' });
    };
    for (const version of ['01.2.3', '1.2', '1.2.3\n', '../1.2.3']) {
      assert.equal(run('accepted', { APP_VERSION: version }).status, 1);
      assert.deepEqual(events(), []);
    }
    for (const versions of [['1.2.2', '1.2.3'], ['1.2.3', '1.2.2']]) {
      assert.match(run('accepted', {}, versions).stderr, /rebuild with APP_VERSION/);
      assert.deepEqual(events(), []);
    }
    for (const identity of ['-', 'Apple Development: Example (ABCDEF1234)', 'Developer ID Application: Other (XYZABC1234)']) {
      assert.equal(run('accepted', { DEVELOPER_ID: identity }).status, 1);
      assert.deepEqual(events(), []);
    }
    for (const scenario of ['missing-identity', 'adhoc', 'wrong-team', 'rejected', 'dmg-rejected', 'timeout', 'malformed']) {
      const result = run(scenario);
      assert.notEqual(result.status, 0, `${scenario}: ${result.stderr}`);
      assert.ok(!events().some(e => e[0] === 'shasum'), scenario);
      assert.ok(!existsSync(join(fixture, 'build/FIELDNOTES-1.2.3.dmg')), scenario);
      if (!['missing-identity', 'adhoc', 'wrong-team'].includes(scenario)) assert.ok(existsSync(join(fixture, 'build/notary-reports/app-wait.json')));
      if (['rejected', 'timeout', 'malformed'].includes(scenario)) assert.ok(!events().some(e => e[0] === 'hdiutil'), scenario);
    }
    const result = run('accepted');
    assert.equal(result.status, 0, result.stderr);
    const sequence = events();
    const index = predicate => { const i = sequence.findIndex(predicate); assert.ok(i >= 0); return i; };
    const submitApp = index(e => e[0] === 'xcrun' && e[2] === 'submit' && e[3].endsWith('.zip'));
    const stapleApp = index(e => e[0] === 'xcrun' && e[1] === 'stapler' && e[2] === 'staple' && e[3] === app);
    const validateApp = index(e => e[0] === 'xcrun' && e[2] === 'validate' && e[3] === app);
    const createDMG = index(e => e[0] === 'hdiutil' && e[1] === 'create');
    const signDMG = index(e => e[0] === 'codesign' && e[1] === '--force' && e.at(-1).endsWith('.dmg'));
    const submitDMG = index(e => e[0] === 'xcrun' && e[2] === 'submit' && e[3].endsWith('.dmg'));
    const validateDMG = index(e => e[0] === 'xcrun' && e[2] === 'validate' && e[3].endsWith('.dmg'));
    const assessDMG = index(e => e[0] === 'spctl' && e.at(-1).endsWith('.dmg'));
    const checksum = index(e => e[0] === 'shasum');
    assert.deepEqual([submitApp, stapleApp, validateApp, createDMG, signDMG, submitDMG, validateDMG, assessDMG, checksum].toSorted((a,b)=>a-b), [submitApp, stapleApp, validateApp, createDMG, signDMG, submitDMG, validateDMG, assessDMG, checksum]);
    for (const e of sequence.filter(e => e[0] === 'codesign' && e[1] === '--force')) assert.ok(e.includes('--keychain') && e.includes('A'.repeat(40)) && e.includes('--timestamp'));
    for (const e of sequence.filter(e => e[0] === 'xcrun' && e[2] === 'wait')) assert.ok(e.includes('--timeout') && e.includes('15m'));
    assert.ok(sequence.filter(e => e[0] === 'xcrun' && e[1] === 'notarytool').every(e => !e.includes('--issuer')));
    assert.ok(existsSync(join(fixture, 'build/FIELDNOTES-1.2.3.sha256')));
    const teamResult = run('accepted', { NOTARY_ISSUER: '12345678-1234-1234-1234-123456789abc' });
    assert.equal(teamResult.status, 0, teamResult.stderr);
    assert.ok(events().filter(e => e[0] === 'xcrun' && e[1] === 'notarytool').every(e => e.includes('--issuer')));
    assert.equal(readFileSync(join(fixture, 'build/notary-reports/dmg-wait.json'), 'utf8').includes('Accepted'), true);
    for (const policy of ['false', 'null', '', 'true']) {
      const check = spawnSync('bash', ['scripts/check-release-policy.sh'], { cwd: fixture, env: { ...env, GITHUB_REPOSITORY: 'example/repo', POLICY: policy }, encoding: 'utf8' });
      assert.equal(check.status, policy === 'true' ? 0 : 1);
    }
    console.log('Signing command contracts: identity, versions, accepted/rejected/malformed/timeout, staging order, policy passed');
  } finally { rmSync(fixture, { recursive: true, force: true }); }
}
