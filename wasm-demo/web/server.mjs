#!/usr/bin/env node
// Static server for the container2wasm web artifacts with a same-origin proxy
// to the container's forwarded HTTP port.
//
//   /                 -> index.html (the auto-loader page)
//   /__status         -> {"ready": bool} (server-side probe of the guest port)
//   /vs, /vs/...      -> reverse proxy to the guest HTTP server (path rewritten)
//   /<static file>    -> static file from --root (out.js, .wasm, .data, ...)
//   anything else     -> reverse proxy to the guest (VS Code assets use absolute
//                        root paths, e.g. /stable-<commit>/...)
//
// WebSocket upgrades are proxied too, so the VS Code workbench inside an
// iframe can talk to its server on the same origin.
//
// The page is served COOP/COEP so the QEMU-Wasm runtime can use
// SharedArrayBuffer (cross-origin isolation).
import http from 'node:http';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import url from 'node:url';

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};
const root = path.resolve(opt('root', '.'));
const port = Number(opt('port', '8090'));
const host = opt('host', '127.0.0.1');
const guest = { host: opt('guest-host', '127.0.0.1'), port: Number(opt('guest-port', '18080')) };
// Optional local copy of the VS Code web server files (the pre-warmed
// serve-web cache baked into the container image). Serving the big static
// client assets from the host makes the workbench load fast; only dynamic
// requests are proxied to the emulated guest.
const staticCache = opt('static-cache', '');
const STATIC_RE = /^\/stable-([0-9a-f]{40})\/static\/(.+)$/;
let cachedShell = null; // { body, headers } for the VS Code index HTML

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

function sendJson(res, code, value) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(value));
}

function sendFile(req, res, file, stat) {
  const type = MIME[path.extname(file)] || 'application/octet-stream';
  const headers = {
    'content-type': type,
    'content-length': stat.size,
    'cache-control': 'no-store',
    ...CROSS_ORIGIN_ISOLATION,
  };
  // Minimal byte-range support (browsers may request ranges for large files).
  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m) {
      let start = m[1] === '' ? stat.size - Number(m[2]) : Number(m[1]);
      let end = m[2] === '' || m[1] === '' ? stat.size - 1 : Number(m[2]);
      if (start >= 0 && start <= end && end < stat.size) {
        res.writeHead(206, {
          ...headers,
          'content-length': end - start + 1,
          'content-range': `bytes ${start}-${end}/${stat.size}`,
          'accept-ranges': 'bytes',
        });
        fs.createReadStream(file, { start, end }).pipe(res);
        return;
      }
    }
  }
  res.writeHead(200, { ...headers, 'accept-ranges': 'bytes' });
  fs.createReadStream(file).pipe(res);
}

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
            console.log('[server] cached VS Code shell HTML (' + size + ' bytes)');
          }
          res.end();
        });
        pres.on('error', () => res.destroy());
        return;
      }
      pres.pipe(res);
    },
  );
  preq.setTimeout(120000, () => preq.destroy(new Error('guest request timeout')));
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
    g.on('timeout', () => { g.destroy(); resolve({ ready: false, status: 'timeout' }); });
    g.on('error', () => resolve({ ready: false }));
  });

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url);
  let pathname = decodeURIComponent(parsed.pathname || '/');

  if (staticCache) {
    const m = STATIC_RE.exec(pathname);
    if (m) {
      const rel = decodeURIComponent(m[2]).replace(/\0/g, '');
      const file = path.join(staticCache, path.normalize(rel));
      if (file.startsWith(staticCache + path.sep)) {
        fs.stat(file, (err, st) => {
          if (!err && st.isFile()) {
            sendFile(req, res, file, st);
            return;
          }
          proxyToGuest(req, res, req.url);
        });
        return;
      }
    }
  }

  if (pathname === '/__status') {
    probeGuest().then((st) => sendJson(res, 200, st));
    return;
  }
  if (pathname === '/vs') {
    res.writeHead(302, { location: '/vs/' }).end();
    return;
  }
  if (pathname === '/vs/') {
    if (cachedShell) {
      res.writeHead(200, cachedShell.headers);
      res.end(cachedShell.body);
      return;
    }
    proxyToGuest(req, res, '/', { cacheShell: true });
    return;
  }
  if (pathname.startsWith('/vs/')) {
    // Rewrite the iframe prefix away: /vs/<x> -> /<x>
    const rest = req.url.slice(3) || '/';
    proxyToGuest(req, res, rest);
    return;
  }

  if (pathname.endsWith('/')) pathname += 'index.html';
  const file = path.join(root, path.normalize(pathname));
  const insideRoot = file.startsWith(root + path.sep);
  if (insideRoot) {
    fs.stat(file, (err, st) => {
      if (!err && st.isFile()) {
        sendFile(req, res, file, st);
        return;
      }
      // Not a local static file: fall through to the guest (VS Code assets).
      proxyToGuest(req, res, req.url);
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

server.listen(port, host, () => {
  console.log(`[server] page:  http://${host}:${port}/`);
  console.log(`[server] guest: http://${guest.host}:${guest.port}/ (proxied at /vs/)`);
  console.log(`[server] root:  ${root}`);
  if (staticCache) console.log(`[server] static cache: ${staticCache}`);
});
