// Connects the official TypeScript MCP client (@modelcontextprotocol/client 2.3.1) to a server
// and lists its tools (mcp-update-plan §3.0 "Real SDK clients", §3.1 step 4).
//
//   (cd script/mcp_compat/tsclient && npm ci)
//   node tsclient.mjs stdio auto -- bundle exec ruby bin/mcp_stdio_runner.rb
//   node tsclient.mjs http legacy http://127.0.0.1:3999/mcp
//
// Env: MCP_TOKEN (HTTP bearer), MCP_CLIENT (X-MCP-Client header, default mcp-compat-ts).
// Prints one result line; exit 1 when connect or tools/list fails.
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { readFileSync } from 'node:fs';

const [kind, mode, ...rest] = process.argv.slice(2);
const target = rest[0] === '--' ? rest.slice(1) : rest;
if (!['stdio', 'http'].includes(kind) || !['auto', 'legacy'].includes(mode) || target.length === 0) {
  console.error('usage: tsclient.mjs <stdio|http> <auto|legacy> <url | -- command...>');
  process.exit(2);
}

const pkgUrl = new URL('./node_modules/@modelcontextprotocol/client/package.json', import.meta.url);
const { version } = JSON.parse(readFileSync(pkgUrl, 'utf8'));
const label = `ts-sdk ${version} ${kind} ${mode}`.padEnd(32);
const started = performance.now();
const elapsed = () => `${((performance.now() - started) / 1000).toFixed(1)}s`;

let transport;
if (kind === 'stdio') {
  // Pass the whole environment: the default only inherits a few safe variables (no RAILS_ENV).
  transport = new StdioClientTransport({ command: target[0], args: target.slice(1), env: { ...process.env }, stderr: 'ignore' });
} else {
  const headers = { 'X-MCP-Client': process.env.MCP_CLIENT ?? 'mcp-compat-ts' };
  if (process.env.MCP_TOKEN) headers.Authorization = `Bearer ${process.env.MCP_TOKEN}`;
  transport = new StreamableHTTPClientTransport(new URL(target[0]), { requestInit: { headers } });
}

const client = new Client({ name: 'mcp-compat-ts', version: '0' }, { versionNegotiation: { mode } });
let failed = false;
try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  console.log(`OK   ${label} protocol=${client.getNegotiatedProtocolVersion() ?? '?'} era=${client.getProtocolEra() ?? '?'} tools=${tools.length} ${elapsed()}`);
} catch (error) {
  failed = true;
  console.log(`FAIL ${label} ${error?.name ?? 'Error'}: ${String(error?.message ?? error).slice(0, 200)} ${elapsed()}`);
} finally {
  await client.close().catch(() => {});
}
process.exit(failed ? 1 : 0);
