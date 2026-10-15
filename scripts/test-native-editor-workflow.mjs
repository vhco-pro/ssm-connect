import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  'profile-id': { type: 'string' }, 'socket-mode': { type: 'boolean', default: false },
  verify: { type: 'boolean', default: false },
  'second-window': { type: 'boolean', default: false },
} });
const stateFile = values['socket-mode'] ? '/tmp/ssm-socket-editor-workflow-state.json' : '/tmp/ssm-native-editor-workflow-state.json';
const code = '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code';
const editorEnvironment = { ...process.env };
delete editorEnvironment.ELECTRON_RUN_AS_NODE;
delete editorEnvironment.ELECTRON_NO_ASAR;
if (values.verify || values['second-window']) {
  assert(values['socket-mode'], 'Socket verification requires --socket-mode');
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  assert(state.socketMode && path.basename(state.userDataDirectory).startsWith('ssm-socket-editor-'));
  if (values['second-window']) {
    assert(!values.verify, 'Select either verification or second-window setup');
    assert(/^ssm-connect-editor-fixture-[a-f0-9-]+$/.test(state.fixtureName));
    assert(state.folder.endsWith(`/${state.fixtureName}`));
    const secondFolder = path.join(state.folder, 'second-window');
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    execFileSync('/usr/bin/ssh', ['-F', path.join(os.homedir(), '.ssh/config'), '-T', state.alias,
      `umask 077; mkdir ${quote(secondFolder)} && cp ${quote(path.join(state.folder, 'fixture.mjs'))} ${quote(path.join(state.folder, 'fixture.test.mjs'))} ${quote(secondFolder)}`],
    { timeout: 100_000, stdio: ['ignore', 'pipe', 'pipe'] });
    const uri = new URL(`vscode-remote://ssh-remote+${state.alias}`);
    uri.pathname = secondFolder;
    execFileSync(code, ['--new-window', '--folder-uri', uri.href, '--user-data-dir', state.userDataDirectory,
      '--extensions-dir', path.join(os.homedir(), '.vscode/extensions')],
    { timeout: 20_000, stdio: 'ignore', env: editorEnvironment });
    fs.writeFileSync(stateFile, JSON.stringify({ ...state, secondFolder }), { mode: 0o600 });
    console.log(JSON.stringify({ result: 'second-window-requested', privateState: stateFile, workspaceUIVerified: false }));
    process.exit(0);
  }
  const logs = [];
  const collectLogs = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) collectLogs(file);
      else if (entry.name.includes('Remote - SSH') && entry.name.endsWith('.log')) {
        const contents = fs.readFileSync(file, 'utf8');
        if (contents.includes(state.alias)) logs.push({ file, contents });
      }
    }
  };
  collectLogs(path.join(state.userDataDirectory, 'logs'));
  const latest = logs.sort((first, second) => first.file.localeCompare(second.file)).at(-1)?.contents ?? '';
  assert(latest.includes('remote.SSH.remoteServerListenOnSocket = true'), 'Native socket mode must be enabled');
  assert(/(?:^|>\s*)listeningOn==\/[^=\r\n]+==/m.test(latest), 'Native server must report an actual Unix socket');
  assert(latest.includes(`Resolved "ssh-remote+${state.alias}"`), 'Native remote authority must resolve');
  console.log(JSON.stringify({ result: 'native-socket-transport-verified', nativeSocketListener: true,
    nativeAuthorityResolved: true, workspaceUIVerified: false }));
  process.exit(0);
}
const root = path.join(os.homedir(), 'Library/Application Support/pro.vhco.ssm-connect.about-preview/RemoteAccess');
const profiles = fs.readdirSync(root).filter(name => /^[A-F0-9-]{36}$/.test(name));
const profile = values['profile-id']?.toUpperCase() ?? (profiles.length === 1 ? profiles[0] : undefined);
assert(profile, 'The approved native preview lease is required');
assert(profiles.includes(profile), 'Select an existing approved lease with --profile-id');
const lease = JSON.parse(fs.readFileSync(path.join(root, profile, 'lease.json'), 'utf8'));
const alias = `ssm-connect-${lease.profile.id.toLowerCase()}`;
const commit = execFileSync(code, ['--version'], { encoding: 'utf8', env: editorEnvironment }).trim().split('\n')[1];
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
const editorArguments = ['--new-window', '--folder-uri', folderURI.href];
let userDataDirectory;
if (values['socket-mode']) {
  userDataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ssm-socket-editor-'));
  fs.chmodSync(userDataDirectory, 0o700);
  const user = path.join(userDataDirectory, 'User');
  fs.mkdirSync(user, { mode: 0o700 });
  fs.writeFileSync(path.join(user, 'settings.json'), JSON.stringify({
    'remote.SSH.remoteServerListenOnSocket': true,
    'remote.SSH.useLocalServer': true,
    'remote.SSH.remotePlatform': { [alias]: 'linux' },
    'remote.SSH.serverInstallPath': { [alias]: path.join(remote, '.vscode-server-socket') },
    'extensions.autoUpdate': false,
    'extensions.autoCheckUpdates': false,
    'accessibility.signalOptions.volume': 0,
  }), { mode: 0o600 });
  editorArguments.push('--user-data-dir', userDataDirectory, '--extensions-dir', path.join(os.homedir(), '.vscode/extensions'));
}
execFileSync(code, editorArguments, { timeout: 20_000, stdio: 'ignore', env: editorEnvironment });
const report = { result: 'fixture-created', fixtureName: name, folder: remote, alias, runtime,
  baselineProjectTest: true, nativeFolderLaunch: true, socketMode: values['socket-mode'], userDataDirectory };
fs.writeFileSync(stateFile, JSON.stringify(report), { mode: 0o600 });
console.log(JSON.stringify({ result: report.result, baselineProjectTest: true, nativeFolderLaunch: true,
  fixtureName: name, socketMode: report.socketMode, privateState: stateFile }));