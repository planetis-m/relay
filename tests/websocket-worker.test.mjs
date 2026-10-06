// Independent wire peer for bounded worker correctness, including controlled TLS.
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {createServer as createTlsServer} from 'node:https';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {frame, decoder} from './ws_fixture.mjs';

const probe = resolve(process.env.WEBSOCKET_WORKER_PROBE ?? 'build/websocket-worker-probe');
async function fixture(tls) {
  const sockets = new Set();
  const timers = [];
  const evidence = {pongs: 0, closes: 0, binary: 0};
  const response = (_req, res) => {
    timers.push(setTimeout(() => res.end('relay http'), 40));
  };
  const server = tls ? createTlsServer(tls, response) : createServer(response);
  server.on('connection', socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.once('close', () => sockets.delete(socket));
  });
  server.on('upgrade', (req, socket) => {
    if (req.url.endsWith('stall')) return;
    const accept = req.url.endsWith('bad') ? 'wrong' : createHash('sha1')
      .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
      .digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
      `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    if (req.url.endsWith('disconnect-send')) {
      socket.once('data', () => socket.destroy());
      return;
    }
    if (req.url.endsWith('disconnect')) {
      timers.push(setTimeout(() => socket.destroy(), 50));
      return;
    }
    if (req.url.endsWith('pause')) { socket.pause(); return; }
    if (req.url.endsWith('close-deadline')) {
      socket.once('data', () => {
        socket.pause();
        socket.write(frame('close barrier'));
        timers.push(setTimeout(() => socket.write(frame('', 8)), 250));
      });
      return;
    }
    if (req.url.endsWith('partial')) {
      socket.pause();
      timers.push(setTimeout(() => socket.resume(), 70));
    }
    if (req.url.endsWith('duplex')) {
      socket.write(Buffer.concat([frame('i'.repeat(100_000), 1, false),
        frame('idle ping', 9), frame('i'.repeat(100_000), 0)]));
    }
    let closeReplied = false;
    decoder(socket, item => {
      if (item.opcode === 1 || item.opcode === 2) {
        if (item.opcode === 2) ++evidence.binary;
        assert.ok(item.final);
        socket.write(frame(item.payload, item.opcode));
      } else if (item.opcode === 10) {
        ++evidence.pongs;
        assert.deepEqual(item.payload, Buffer.from('idle ping'));
        if (!req.url.endsWith('duplex')) socket.write(frame('pong observed'));
      } else if (item.opcode === 8) {
        ++evidence.closes;
        if (req.url.endsWith('close-handshake')) {
          // Keep reading until the client disconnects to catch duplicate CLOSEs.
          if (!closeReplied) socket.write(frame(item.payload, 8));
          closeReplied = true;
        } else if (!req.url.endsWith('no-close')) socket.end(frame(item.payload, 8));
      }
    });
    if (req.url.endsWith('ping')) socket.write(frame('idle ping', 9));
    if (req.url === '/close') socket.write(frame(Buffer.from([3, 232]), 8));
    if (req.url.endsWith('flood')) {
      socket.write(Buffer.concat(Array.from({length: 10}, (_, i) => frame(`flood${i}`))));
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    url: `${tls ? 'wss' : 'ws'}://${tls ? 'localhost' : '127.0.0.1'}:${server.address().port}/`,
    evidence,
    async close() {
      timers.forEach(clearTimeout);
      sockets.forEach(socket => socket.destroy());
      await new Promise(resolve => server.close(resolve));
    }
  };
}
function execute(url, mode, ca = '') {
  return new Promise((resolve, reject) => {
    const child = spawn(probe, [url, mode, ca]);
    let stdout = '', stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`Worker probe hung (${mode}): ${stderr}`));
    }, 5000);
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', (status, signal) => {
      clearTimeout(timer);
      try {
        assert.equal(signal, null, stderr);
        assert.equal(status, 0, stderr);
        assert.equal(stdout.trim(), 'ok');
        resolve();
      } catch (error) { reject(error); }
    });
  });
}
for (const mode of ['http-first', 'socket-first', 'blocking-client', 'blocking-failure',
  'blocking-timeouts', 'blocking-disposal', 'blocking-close-pending',
  'close-handshake', 'close-deadline', 'cancel-close',
  'idle', 'pressure', 'cancel-connect',
  'cancel-send', 'queued-deadline', 'cancel-receive', 'failure', 'shutdown-full',
  'bytes', 'duplex', 'partial', 'idle-close', 'abort-full', 'shutdown-scope', 'slow-peer',
  'disconnect', 'disconnect-send']) {
  test(`separate WebSocket worker: ${mode}`, async () => {
    const server = await fixture();
    try {
      await execute(server.url, mode);
      if (mode === 'idle') {
        assert.equal(server.evidence.pongs, 1, 'Idle ping serviced before consumer receive');
        assert.ok(server.evidence.closes >= 1, 'Idle peer close acknowledged');
      }
      if (mode === 'http-first' || mode === 'socket-first') {
        assert.equal(server.evidence.binary, 1);
      }
      if (mode === 'close-handshake') {
        assert.equal(server.evidence.closes, 2, 'One CLOSE per local/peer handshake');
      }
    } finally { await server.close(); }
  });
}
test('WSS verifies trust and hostname, with explicit trusted CA', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'relay-wss-'));
  const key = join(directory, 'key.pem');
  const ca = join(directory, 'cert.pem');
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', key, '-out', ca, '-days', '1', '-subj', '/CN=localhost',
      '-addext', 'subjectAltName=DNS:localhost'], {stdio: 'ignore'});
    const server = await fixture({key: readFileSync(key), cert: readFileSync(ca)});
    try {
      await execute(server.url, 'tls-accept', ca);
      await execute(server.url, 'tls-reject');
      await execute(server.url.replace('localhost', '127.0.0.1'), 'tls-host', ca);
    } finally { await server.close(); }
  } finally { rmSync(directory, {recursive: true, force: true}); }
});
