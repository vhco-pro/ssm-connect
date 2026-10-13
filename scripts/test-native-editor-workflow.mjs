import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const code = '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code';
const root = path.join(os.homedir(), 'Library/Application Support/pro.vhco.ssm-connect.about-preview/RemoteAccess');
const profile = fs.readdirSync(root).find(name => /^[A-F0-9-]{36}$/.test(name));
assert(profile, 'The approved native preview lease is required');
const lease = JSON.parse(fs.readFileSync(path.join(root, profile, 'lease.json'), 'utf8'));
const alias = `ssm-connect-${lease.profile.id.toLowerCase()}`;
const commit = execFileSync(code, ['--version'], { encoding: 'utf8' }).trim().split('\n')[1];
assert(/^[a-f0-9]{40}$/.test(commit));
const name = `ssm-connect-editor-fixture-${crypto.randomUUID()}`;
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const ssh = command => execFileSync('/usr/bin/ssh', ['-F', path.join(os.homedir(), '.ssh/config'), '-T', alias, command], {
  encoding: 'utf8', timeout: 100_000, stdio: ['ignore', 'pipe', 'pipe'],
});
const remote = ssh(`umask 077; mkdir "$HOME/${name}" && printf '%s' "$HOME/${name}"`).trim();
assert(remote.startsWith('/') && remote.endsWith(`/${name}`));
const runtime = ssh(`if test -x "$HOME/.vscode-server/cli/servers/Stable-${commit}/server/node"; then printf '%s' "$HOME/.vscode-server/cli/servers/Stable-${commit}/server/node"; elif test -x "$HOME/.vscode-server/bin/${commit}/node"; then printf '%s' "$HOME/.vscode-server/bin/${commit}/node"; else exit 1; fi`).trim();
const files = {
  'fixture.mjs': 'export function multiply(value) { return value * 2; }\nconsole.log("SSM_EDITOR_BUILD_OK=" + multiply(21));\n',
  'fixture.test.mjs': 'import assert from "node:assert/strict";\nimport { multiply } from "./fixture.mjs";\nassert.equal(multiply(21), 42);\nconsole.log("SSM_EDITOR_TEST_OK");\n',
  'language.ts': 'export function twice(value: number): number { return value * 2; }\nconst answer = twice(21);\nconsole.log(answer);\n',
  '.vscode/launch.json': JSON.stringify({ version: '0.2.0', configurations: [{
    type: 'node', request: 'launch', name: 'SSM fixture debug',
    program: '${workspaceFolder}/fixture.mjs', runtimeExecutable: runtime,
    stopOnEntry: true, console: 'internalConsole',
  }] }),
};
ssh(`umask 077; mkdir ${quote(`${remote}/.vscode`)}`);
for (const [file, contents] of Object.entries(files)) {
  const encoded = Buffer.from(contents).toString('base64');
  ssh(`printf '%s' ${quote(encoded)} | base64 --decode > ${quote(`${remote}/${file}`)}`);
}
assert(ssh(`${quote(runtime)} ${quote(`${remote}/fixture.test.mjs`)}`).includes('SSM_EDITOR_TEST_OK'));
const folderURI = new URL(`vscode-remote://ssh-remote+${alias}`);
folderURI.pathname = remote;
execFileSync(code, ['--new-window', '--folder-uri', folderURI.href], { timeout: 20_000, stdio: 'ignore' });
const report = { result: 'fixture-created', fixtureName: name, folder: remote, alias, runtime,
  baselineProjectTest: true, nativeFolderLaunch: true };
fs.writeFileSync('/tmp/ssm-native-editor-workflow-state.json', JSON.stringify(report), { mode: 0o600 });
console.log(JSON.stringify({ result: report.result, baselineProjectTest: true, nativeFolderLaunch: true,
  fixtureName: name, privateState: '/tmp/ssm-native-editor-workflow-state.json' }));