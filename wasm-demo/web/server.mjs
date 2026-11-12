#!/usr/bin/env node
// Static server for the container2wasm web artifacts with a same-origin proxy
// to the container's forwarded HTTP port.
//
//   /                 -> index.html (the auto-loader page)
//   /__status         -> {"ready": bool} (server-side probe of the guest port)
//   /__stats          -> traffic counters (bytes served, compressed sizes)
//   /vs, /vs/...      -> reverse proxy to the guest HTTP server (path rewritten)
//   /<static file>    -> static file from --root (out.js, .wasm, .data, ...)
//   /stable-<commit>/static/... -> VS Code client assets from --static-cache
//   anything else     -> reverse proxy to the guest (VS Code assets use absolute
//                        root paths, e.g. /stable-<commit>/...)
//
// WebSocket upgrades are proxied too, so the VS Code workbench inside an
// iframe can talk to its server on the same origin.
//
// Memory mode (--memory): all artifact files (including the multi-hundred-MB
// QEMU `.data`) are read into RAM at startup and served from there; nothing is
// read from disk per request. With --compress-data the data/wasm files are
// gzip-compressed in RAM once at startup and sent with `Content-Encoding:
// gzip`, so the browser downloads ~3x fewer bytes and decompresses in memory.
//
// The page is served COOP/COEP so the QEMU-Wasm runtime can use
// SharedArrayBuffer (cross-origin isolation).
import http from 'node:http';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import url from 'node:url';
import zlib from 'node:zlib';

const argv = process.argv.slice(2);
const hasFlag = (name) => argv.includes(`--${name}`);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback;
};

const root = path.resolve(opt('root', '.'));
const port = Number(opt('port', '8090'));
const host = opt('host', '127.0.0.1');
const guest = { host: opt('guest-host', '127.0.0.1'), port: Number(opt('guest-port', '18080')) };
const staticCache = opt('static-cache', '');
const memoryMode = hasFlag('memory');
const compressData = hasFlag('compress-data');
const STATIC_RE = /^\/stable-([0-9a-f]{40})\/static\/(.+)$/;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.map': 'application/json; charset=utf-8',
};

const CROSS_ORIGIN_ISOLATION = {
  'cross-origin-opener-policy': 'same-origin',
  'cross-origin-embedder-policy': 'require-corp',
};

const stats = {
  startedAt: new Date().toISOString(),
  wireBytes: 0,
  requests: 0,
  files: Object.create(null),
  served: Object.create(null),
};
function countBytes(name, n) {
  stats.wireBytes += n;
  stats.requests += 1;
  stats.served[name] = (stats.served[name] || 0) + 1;
  stats.files[name] = (stats.files[name] || 0) + n;
}

// ---------------------------------------------------------------------------
// In-memory artifact store
// ---------------------------------------------------------------------------
const memory = new Map(); // url path -> { buf, type, encoding?, originalLength }

function walkFiles(dir, prefix = '') {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...walkFiles(full, rel));
    else if (entry.isFile()) out.push(rel);
  }
  return out;
}

function preloadMemory() {
  const wanted = /\.(html|js|mjs|css|wasm|data|json|png|svg|ico)$/;
  let rawTotal = 0;
  let wireTotal = 0;
  for (const rel of walkFiles(root)) {
    if (!wanted.test(rel)) continue;
    const file = path.join(root, rel);
    const stat = fs.statSync(file);
    if (!stat.isFile()) continue;
    const buf = fs.readFileSync(file);
    rawTotal += buf.length;
    const type = MIME[path.extname(rel)] || 'application/octet-stream';
    const entry = { buf, type, originalLength: buf.length };
    // Compress the big payloads (the QEMU .data, the wasm binary, big JS) once.
    const compressible = /\.(data|wasm|js)$/.test(rel) && buf.length > 64 * 1024;
    if (compressData && compressible) {
      const gz = zlib.gzipSync(buf, { level: 4 });
      if (gz.length < buf.length) {
        entry.buf = gz;
        entry.encoding = 'gzip';
        entry.originalLength = buf.length;
        wireTotal += gz.length;
      } else {
        wireTotal += buf.length;
      }
    } else {
      wireTotal += buf.length;
    }
    memory.set('/' + rel.replace(/\\/g, '/'), entry);
  }
  console.log(
    `[server] memory mode: preloaded ${memory.size} files, ${(rawTotal / 1048576).toFixed(1)} MiB in RAM` +
      (compressData ? `, ${(wireTotal / 1048576).toFixed(1)} MiB on the wire (gzip)` : ''),
  );
}

function serveMemory(req, res, entry) {
  const headers = {
    'content-type': entry.type,
    'content-length': entry.buf.length,
    'cache-control': 'no-store',
    ...CROSS_ORIGIN_ISOLATION,
  };
  if (entry.encoding) {
    headers['content-encoding'] = entry.encoding;
    headers['x-original-length'] = String(entry.originalLength);
  }
  res.writeHead(200, headers);
  res.end(entry.buf);
  if (req.method !== 'HEAD') countBytes(req.url, entry.buf.length);
}

// ---------------------------------------------------------------------------
// Regular disk serving (fallback when not in memory mode)
// ---------------------------------------------------------------------------
function sendFile(req, res, file, stat) {
  const type = MIME[path.extname(file)] || 'application/octet-stream';
  const headers = {
    'content-type': type,
    'content-length': stat.size,
    'cache-control': 'no-store',
    ...CROSS_ORIGIN_ISOLATION,
  };
  res.writeHead(200, headers);
  fs.createReadStream(file).pipe(res);
  if (req.method !== 'HEAD') countBytes(req.url, stat.size);
}

// ---------------------------------------------------------------------------
// Guest proxying
// ---------------------------------------------------------------------------
let cachedShell = null; // { body, headers } for the VS Code index HTML

function proxyToGuest(req, res, targetPath, { cacheShell = false } = {}) {
  const headers = { ...req.headers, host: `${guest.host}:${guest.port}` };
  const preq = http.request(
    { host: guest.host, port: guest.port, path: targetPath, method: req.method, headers },
    (pres) => {
      // The guest sets `frame-ancestors 'self'` / `X-Frame-Options: SAMEORIGIN`;
      // both are satisfied because the proxied response is same-origin.
      // COOP/COEP is required on the iframe document itself: the top page is
      // cross-origin isolated (needed by the wasm runtime), and Chrome refuses
      // to embed frames that are not also COEP-protected.
      const outHeaders = { ...pres.headers, ...CROSS_ORIGIN_ISOLATION };
      res.writeHead(pres.statusCode || 502, outHeaders);
      if (cacheShell && pres.statusCode === 200 && /text\/html/i.test(pres.headers['content-type'] || '')) {
        const chunks = [];
        let size = 0;
        pres.on('data', (c) => {
          chunks.push(c);
          size += c.length;
          if (size <= 8 * 1024 * 1024) res.write(c);
        });
        pres.on('end', () => {
          if (size <= 8 * 1024 * 1024) {
            cachedShell = {
              body: Buffer.concat(chunks),
              headers: { ...pres.headers, ...CROSS_ORIGIN_ISOLATION, 'cache-control': 'no-store' },
            };
            console.log(`[server] cached VS Code shell HTML (${size} bytes)`);
          }
          res.end();
          countBytes(req.url, size);
        });
        pres.on('error', () => res.destroy());
        return;
      }
      let received = 0;
      pres.on('data', (c) => {
        received += c.length;
      });
      pres.on('end', () => countBytes(req.url, received));
      pres.pipe(res);
    },
  );
  preq.setTimeout(180000, () => preq.destroy(new Error('guest request timeout')));
  preq.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8', ...CROSS_ORIGIN_ISOLATION });
    }
    res.end('bad gateway: ' + err.message);
  });
  req.pipe(preq);
}

const probeGuest = () =>
  new Promise((resolve) => {
    const g = http.get({ host: guest.host, port: guest.port, path: '/', timeout: 2500 }, (r) => {
      resolve({ ready: r.statusCode === 200, status: r.statusCode });
      r.resume();
    });
    g.on('timeout', () => {
      g.destroy();
      resolve({ ready: false, status: 'timeout' });
    });
    g.on('error', () => resolve({ ready: false }));
  });

function sendJson(res, code, value) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(value));
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url);
  let pathname = decodeURIComponent(parsed.pathname || '/');

  if (pathname === '/__status') {
    probeGuest().then((st) => sendJson(res, 200, st));
    return;
  }
  if (pathname === '/__stats') {
    sendJson(res, 200, stats);
    return;
  }

  // VS Code client static assets from the local cache (fast path + fewer bytes
  // through the emulated guest).
  if (staticCache) {
    const m = STATIC_RE.exec(pathname);
    if (m) {
      const file = path.join(staticCache, path.normalize(decodeURIComponent(m[2])));
      if (file.startsWith(staticCache + path.sep)) {
        fs.stat(file, (err, st) => {
          if (!err && st.isFile()) sendFile(req, res, file, st);
          else proxyToGuest(req, res, req.url);
        });
        return;
      }
    }
  }

  if (pathname === '/vs') {
    res.writeHead(302, { location: '/vs/' }).end();
    return;
  }
  if (pathname === '/vs/') {
    if (cachedShell) {
      res.writeHead(200, cachedShell.headers);
      res.end(cachedShell.body);
      countBytes('/vs/', cachedShell.body.length);
      return;
    }
    proxyToGuest(req, res, '/', { cacheShell: true });
    return;
  }
  if (pathname.startsWith('/vs/')) {
    proxyToGuest(req, res, req.url.slice(3) || '/');
    return;
  }

  // Memory mode: serve artifact/page files from RAM.
  if (memoryMode) {
    const key = pathname.endsWith('/') ? pathname + 'index.html' : pathname;
    const entry = memory.get(key);
    if (entry) {
      serveMemory(req, res, entry);
      return;
    }
    // Unknown path: VS Code absolute asset URLs -> guest.
    proxyToGuest(req, res, req.url);
    return;
  }

  // Disk mode.
  if (pathname.endsWith('/')) pathname += 'index.html';
  const file = path.join(root, path.normalize(pathname));
  if (file.startsWith(root + path.sep)) {
    fs.stat(file, (err, st) => {
      if (!err && st.isFile()) sendFile(req, res, file, st);
      else proxyToGuest(req, res, req.url);
    });
    return;
  }
  proxyToGuest(req, res, req.url);
});

// Proxy WebSocket upgrades (VS Code workbench management/extension host sockets).
server.on('upgrade', (req, socket, head) => {
  const targetPath = req.url.startsWith('/vs/') ? req.url.slice(3) || '/' : req.url;
  const upstream = net.connect(guest.port, guest.host, () => {
    const headers = { ...req.headers };
    delete headers.host;
    let handshake = `GET ${targetPath} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(headers)) handshake += `${k}: ${v}\r\n`;
    handshake += `host: ${guest.host}:${guest.port}\r\n\r\n`;
    upstream.write(handshake);
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

if (memoryMode) preloadMemory();

server.listen(port, host, () => {
  console.log(`[server] page:  http://${host}:${port}/`);
  console.log(`[server] guest: http://${guest.host}:${guest.port}/ (proxied at /vs/)`);
  console.log(`[server] root:  ${root}`);
  console.log(`[server] mode:  ${memoryMode ? 'in-memory' : 'disk'}${compressData ? ' + gzip wire compression' : ''}`);
  if (staticCache) console.log(`[server] static cache: ${staticCache}`);
});
