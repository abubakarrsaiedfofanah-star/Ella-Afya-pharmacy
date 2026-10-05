import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fs.realpathSync(path.dirname(fileURLToPath(import.meta.url)));
const port = Number(process.env.PORT || 3000);
const aliases = [
  ['/admin', '/frontend/admin'],
  ['/seller', '/frontend/seller'],
  ['/auth', '/frontend/auth'],
  ['/verify', '/frontend/verify'],
  ['/shared', '/frontend/shared']
];
const types = { '.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.json':'application/json; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp','.ico':'image/x-icon' };

function resolveUrl(urlPath) {
  let p;
  try {
    p = decodeURIComponent(String(urlPath).split('?')[0]);
  } catch {
    return null;
  }
  if (!p.startsWith('/') || p.includes('\0')) return null;
  p = p.replace(/\\/g, '/');
  if (p === '/') p = '/frontend/auth/';
  for (const [from, to] of aliases) if (p === from || p.startsWith(from + '/')) { p = to + p.slice(from.length); break; }
  let file = path.resolve(root, p.replace(/^\/+/, ''));
  const isInsideRoot = candidate => {
    const relative = path.relative(root, candidate);
    return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
  };
  if (!isInsideRoot(file)) return null;
  if (!path.extname(file)) file = path.join(file, 'index.html');
  if (!isInsideRoot(file) || !fs.existsSync(file)) return null;
  try {
    const actualFile = fs.realpathSync(file);
    if (!isInsideRoot(actualFile) || !fs.statSync(actualFile).isFile()) return null;
    return actualFile;
  } catch {
    return null;
  }
}

http.createServer((req, res) => {
  try {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { 'Content-Type':'text/plain; charset=utf-8', 'Allow':'GET, HEAD' });
      return res.end('Method not allowed');
    }
    const file = resolveUrl(req.url || '/');
    if (!file) { res.writeHead(404, {'Content-Type':'text/plain; charset=utf-8'}); return res.end('Not found'); }
    const ext = path.extname(file).toLowerCase();
    res.writeHead(200, {
      'Content-Type': types[ext] || 'application/octet-stream',
      'Cache-Control':'no-store',
      'X-Content-Type-Options':'nosniff',
      'X-Frame-Options':'DENY',
      'Referrer-Policy':'strict-origin-when-cross-origin',
      'Permissions-Policy':'camera=(), microphone=(), geolocation=()',
      'Content-Security-Policy':"default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self' https://esm.sh; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' https://*.supabase.co wss://*.supabase.co;"
    });
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(file).pipe(res);
  } catch (err) {
    res.writeHead(500, {'Content-Type':'text/plain; charset=utf-8'}); res.end('Server error');
  }
}).listen(port, () => console.log(`Pharmacy Management System: http://localhost:${port}`));
