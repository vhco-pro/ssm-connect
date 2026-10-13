import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, chmod } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import dns from 'node:dns/promises';

const root = await mkdtemp(path.join(os.tmpdir(), 'ssm-browser-e2e-'));
await chmod(root, 0o700);
const requests = [];
const destinations = [];
const retainedSessions = new Set();
const sockets = new Set();
assert((await dns.lookup('outage.localtest.me', { all: true })).some(result => result.address === '127.0.0.1'));
const server = http.createServer((request, response) => {
  if (request.url === '/stop-socks') {
    for (const socket of sockets) socket.destroy();
    socks.close();
    response.end('stopped');
    return;
  }
  requests.push({ host: request.headers.host, url: request.url });
  const scope = request.url.match(/^\/(chrome-separate|zen-separate|zen-existing)-(?:internal|sign-in|callback|session-reopen)$/)?.[1];
  if (scope) {
    const internal = `http://private.fixture.invalid:${httpPort}/${scope}`;
    if (request.url === `/${scope}-sign-in`) {
      assert.equal(request.headers.host, `127.0.0.1:${httpPort}`);
      response.writeHead(302, { Location: `${internal}-callback` });
      response.end();
      return;
    }
    if (request.url === `/${scope}-callback`) {
      response.writeHead(302, { Location: `${internal}-internal`,
        'Set-Cookie': `ssm-fixture-session=${scope}; Max-Age=3600; HttpOnly; SameSite=Lax; Path=/` });
      response.end();
      return;
    }
    const authenticated = request.headers.cookie?.split(';').some(value => value.trim() === `ssm-fixture-session=${scope}`);
    if (request.url === `/${scope}-session-reopen`) {
      if (authenticated) retainedSessions.add(scope);
      response.writeHead(authenticated ? 200 : 401, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
      response.end(authenticated ? '<h1>Fixture session retained after browser restart</h1>' : '<h1>Fixture session missing</h1>');
      return;
    }
    if (!authenticated) {
      response.writeHead(302, { Location: `http://127.0.0.1:${httpPort}/${scope}-sign-in` });
      response.end();
      return;
    }
  }
  response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  response.end('<!doctype html><title>SSM Browser Routing Fixture</title><h1>Routing verified</h1>');
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const httpPort = server.address().port;
const socks = net.createServer(socket => {
  sockets.add(socket);
  socket.on('error', () => {});
  socket.on('close', () => sockets.delete(socket));
  let buffer = Buffer.alloc(0);
  let greeting = true;
  const receive = chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (greeting) {
      if (buffer.length < 2 || buffer.length < 2 + buffer[1]) return;
      assert.equal(buffer[0], 5);
      buffer = buffer.subarray(2 + buffer[1]);
      socket.write(Buffer.from([5, 0]));
      greeting = false;
    }
    if (buffer.length < 5) return;
    assert.equal(buffer[0], 5);
    assert.equal(buffer[1], 1);
    assert.equal(buffer[3], 3, 'The browser must send the hostname, not locally resolved IP bytes');
    const length = buffer[4];
    if (buffer.length < 7 + length) return;
    const hostname = buffer.subarray(5, 5 + length).toString('utf8');
    const port = buffer.readUInt16BE(5 + length);
    destinations.push({ hostname, port });
    socket.removeListener('data', receive);
    if ((!hostname.endsWith('.fixture.invalid') && !hostname.endsWith('.localtest.me')) || port !== httpPort) {
      socket.end(Buffer.from([5, 2, 0, 1, 127, 0, 0, 1, 0, 0]));
      return;
    }
    const upstream = net.connect(httpPort, '127.0.0.1', () => {
      socket.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]));
      const remaining = buffer.subarray(7 + length);
      if (remaining.length) upstream.write(remaining);
      socket.pipe(upstream).pipe(socket);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('close', () => upstream.destroy());
  };
  socket.on('data', receive);
});
socks.listen(0, '127.0.0.1');
await once(socks, 'listening');
try {
  const process = spawn('swift', ['test', '--package-path', 'SSMConnectKit', '--disable-automatic-resolution', '--filter', 'realBrowserRouting'], {
    stdio: 'inherit',
    env: { ...globalThis.process.env, BROWSER_E2E_PORT: String(socks.address().port),
      BROWSER_E2E_HTTP_PORT: String(httpPort), BROWSER_E2E_ROOT: root },
  });
  const [exitCode] = await once(process, 'exit');
  assert.equal(exitCode, 0);
  for (const scope of ['chrome-separate', 'zen-separate', 'zen-existing']) {
    assert(requests.some(request => request.url === `/${scope}-internal`), `${scope}: internal route missing`);
    assert(requests.some(request => request.url === `/${scope}-direct`), `${scope}: direct route missing`);
    assert.equal(requests.filter(request => request.url === `/${scope}-sign-in`).length, 1, `${scope}: fixture sign-in was not retained`);
    assert(retainedSessions.has(scope), `${scope}: authenticated fixture session did not survive browser restart`);
    assert(requests.some(request => request.url === `/${scope}-outage-direct`), `${scope}: public traffic failed during outage`);
    assert(!requests.some(request => request.url === `/${scope}-outage-internal`), `${scope}: internal traffic leaked to DIRECT`);
  }
  assert(destinations.length >= 3);
  assert(destinations.every(destination => destination.hostname === 'private.fixture.invalid'));
  console.log(JSON.stringify({ result: 'passed', scopes: 3, remoteDNS: true, selectiveRouting: true,
    fixtureSignInRedirect: true, sessionRetentionAfterRestart: true, failClosed: true, artifacts: root }));
} finally {
  for (const socket of sockets) socket.destroy();
  socks.close();
  server.closeAllConnections();
  server.close();
}