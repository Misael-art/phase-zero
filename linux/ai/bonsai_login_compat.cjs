'use strict';

// Login-only compatibility for the pinned Bonsai 0.4.19 bundle. The CLI calls
// semver.gt(undefined, installedVersion) when npm removes /latest. PhaseZero
// reports the registry failure separately and never claims this is an update.
const fs = require('node:fs');
const path = require('node:path');

if (process.argv[2] !== 'login') {
  throw new Error('Bonsai compatibility loader is restricted to explicit login');
}

const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(process.argv[1]), '..', 'package.json'), 'utf8'));
if (manifest.name !== '@bonsai-ai/cli' || manifest.version !== '0.4.19') {
  throw new Error('Unsupported Bonsai CLI for compatibility login');
}

const latest = 'https://registry.npmjs.org/@bonsai-ai/cli/latest';
const originalFetch = globalThis.fetch;
globalThis.fetch = async function bonsaiLoginFetch(input, init) {
  const response = await originalFetch(input, init);
  const url = typeof input === 'string' ? input : input && input.url;
  if (url !== latest || response.status !== 404) return response;
  process.stderr.write('PhaseZero: npm Bonsai /latest = HTTP 404; pulando somente verificação de versão nesta tentativa de login. Autenticação não comprovada.\n');
  return new Response(JSON.stringify({ version: manifest.version }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
};
