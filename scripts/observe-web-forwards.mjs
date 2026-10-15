import { execFile } from 'node:child_process';
import { mkdir, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { parseArgs, promisify } from 'node:util';

const execute = promisify(execFile);
const { values } = parseArgs({
  options: {
    'socks-port': { type: 'string', default: '1080' },
    'local-port': { type: 'string', default: '4466' },
    'dcv-port': { type: 'string', default: '8443' },
    interval: { type: 'string', default: '60' },
    samples: { type: 'string', default: '0' },
    output: { type: 'string' },
  },
});

function integer(value, minimum, maximum) {
  const number = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new Error('Invalid numeric observation option.');
  }
  return number;
}

async function command(path, args) {
  try {
    const { stdout } = await execute(path, args, { encoding: 'utf8', timeout: 20000, maxBuffer: 1048576 });
    return stdout.trim();
  } catch {
    return '';
  }
}

async function http(url, proxyPort) {
  const args = ['--silent', '--show-error', '--connect-timeout', '3', '--max-time', '15',
    '--output', '/dev/null', '--write-out', '%{http_code} %{time_total}'];
  if (proxyPort) args.push('--socks5-hostname', `127.0.0.1:${proxyPort}`);
  args.push(url);
  const output = await command('/usr/bin/curl', args);
  const [status, seconds] = output.split(/\s+/);
  return { status: Number(status) || 0, seconds: Number(seconds) || 0 };
}

async function sample(socksPort, localPort, dcvPort, checkURL) {
  const appPIDs = (await command('/usr/bin/pgrep', ['-x', 'SSMConnect'])).split(/\s+/).filter(Boolean);
  const listener = await command('/usr/sbin/lsof', ['-nP', `-iTCP:${socksPort}`, '-sTCP:LISTEN', '-Fp']);
  const sshPID = listener.split('\n').find(line => /^p\d+$/.test(line))?.slice(1);
  const parentPID = sshPID ? await command('/bin/ps', ['-p', sshPID, '-o', 'ppid=']) : '';
  const viewerPIDs = (await command('/usr/bin/pgrep', ['-x', 'dcvviewer'])).split(/\s+/).filter(Boolean);
  const streams = viewerPIDs.length ? await command('/usr/sbin/lsof', [
    '-nP', '-a', '-p', viewerPIDs.join(','), `-iTCP:${dcvPort}`, '-sTCP:ESTABLISHED', '-Fn',
  ]) : '';
  const [proxy, local] = await Promise.all([
    http(checkURL, socksPort), http(`http://127.0.0.1:${localPort}/`),
  ]);
  const viewerStreams = streams.split('\n').filter(line => line.startsWith('n')).length;
  const appOwnedSSH = Boolean(sshPID && appPIDs.includes(parentPID));
  return {
    proxy, local, appOwnedSSH, viewerStreams,
    healthy: appOwnedSSH && viewerStreams > 0 && proxy.status === 200 && local.status === 200,
  };
}

async function main() {
  const socksPort = integer(values['socks-port'], 1, 65535);
  const localPort = integer(values['local-port'], 1, 65535);
  const dcvPort = integer(values['dcv-port'], 1, 65535);
  const interval = integer(values.interval, 1, 3600);
  const limit = integer(values.samples, 0, 1000000);
  let checkURL;
  try { checkURL = new URL(process.env.WF_CHECK_URL); }
  catch { throw new Error('Set WF_CHECK_URL to the private internal HTTPS health endpoint.'); }
  if (checkURL.protocol !== 'https:' || checkURL.username || checkURL.password || checkURL.search || checkURL.hash) {
    throw new Error('WF_CHECK_URL must be a credential-free HTTPS URL without query parameters.');
  }
  const started = Date.now();
  const output = values.output ?? join(homedir(), '.web-forwards', 'observations',
    `${new Date(started).toISOString().replaceAll(':', '-')}.jsonl`);
  await mkdir(dirname(output), { recursive: true, mode: 0o700 });
  const file = await open(output, 'wx', 0o600);
  let previous = started;
  let count = 0;
  let failures = 0;
  let gaps = 0;
  let busy = false;
  let stopping = false;
  let timer;

  async function finish() {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    if (busy) return;
    await close();
  }

  async function close() {
    const summary = { type: 'summary', time: new Date().toISOString(),
      elapsedSeconds: Math.round((Date.now() - started) / 1000), samples: count, failures, gaps };
    await file.write(`${JSON.stringify(summary)}\n`);
    await file.close();
    console.log(JSON.stringify(summary));
    if (failures || gaps) process.exitCode = 1;
  }

  async function tick() {
    if (busy || stopping) return;
    busy = true;
    try {
      const timestamp = Date.now();
      const gapSeconds = Math.round((timestamp - previous) / 1000);
      const missingCoverage = count > 0 && gapSeconds > interval * 2;
      const result = await sample(socksPort, localPort, dcvPort, checkURL.href);
      const row = { type: 'sample', time: new Date(timestamp).toISOString(),
        elapsedSeconds: Math.round((timestamp - started) / 1000), gapSeconds,
        missingCoverage, ...result };
      previous = timestamp;
      count += 1;
      if (!row.healthy) failures += 1;
      if (missingCoverage) gaps += 1;
      await file.write(`${JSON.stringify(row)}\n`);
      await file.sync();
      console.log(JSON.stringify(row));
    } finally {
      busy = false;
    }
    if (stopping || (limit > 0 && count >= limit)) {
      stopping = true;
      clearInterval(timer);
      await close();
    }
  }

  process.on('SIGINT', () => { finish().catch(() => { process.exitCode = 1; }); });
  process.on('SIGTERM', () => { finish().catch(() => { process.exitCode = 1; }); });
  console.log(JSON.stringify({ type: 'started', time: new Date(started).toISOString(), output, interval }));
  await tick();
  if (!stopping) timer = setInterval(() => {
    tick().catch(() => { console.error('Observation sample could not be recorded.'); process.exitCode = 1; });
  }, interval * 1000);
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });