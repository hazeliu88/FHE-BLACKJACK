#!/usr/bin/env node
import http from 'http';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import handler from 'serve-handler';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const root = resolve(__dirname, '..');

const HOST = process.env.HOST || '127.0.0.1';
const PORT = Number(process.env.PORT || 3000);

const headers = [
  { key: 'Cross-Origin-Opener-Policy', value: 'same-origin' },
  { key: 'Cross-Origin-Embedder-Policy', value: 'require-corp' },
  { key: 'Cross-Origin-Resource-Policy', value: 'cross-origin' },
  { key: 'Access-Control-Allow-Origin', value: '*' }
];

const server = http.createServer((request, response) => {
  headers.forEach(({ key, value }) => response.setHeader(key, value));
  if (request.method === 'OPTIONS') {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.url === '/' || request.url === '') {
    request.url = '/index.html';
  }

  if (request.url === '/favicon.ico') {
    response.writeHead(204);
    response.end();
    return;
  }

  handler(request, response, {
    public: root,
    cleanUrls: false,
    directoryListing: false,
    headers: [
      {
        source: '**/*',
        headers
      }
    ]
  });
});

server.listen(PORT, HOST, () => {
  const url = `http://${HOST}:${PORT}`;
  console.log(`[dev-server] serving ${root}`);
  console.log(`[dev-server] COOP/COEP headers enabled`);
  console.log(`[dev-server] listening on ${url}`);
});

const shutdown = () => {
  console.log('\n[dev-server] shutting down');
  server.close(() => process.exit(0));
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
