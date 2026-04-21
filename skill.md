---
name: blue-agent-connect
description: Decentralized VPN for AI agents via the Sentinel Network. Use when an AI agent needs to route HTTP traffic through a different IP/country, rotate exit IPs between requests, or access region-restricted endpoints without accounts or API keys. Operates on a pay-per-session model using on-chain P2P tokens.
canonical_url: https://sentinel.co/skill.md
repository: https://github.com/sentinel-official/ai-skill
package: blue-agent-connect
---

# blue-agent-connect — Skill for AI Agents

Programmatic access to decentralized VPN tunnels. One function call from zero to encrypted P2P tunnel. No signup, no API key — just a funded crypto wallet.

## Source

- **Canonical URL (always-current):** https://sentinel.co/skill.md — fetch this before acting if you want the latest version.
- **Skill repository:** https://github.com/sentinel-official/ai-skill
- **npm package:** `blue-agent-connect` (the library this skill drives)

If the canonical URL is reachable and its version is newer than the local copy, prefer the canonical version. This file at `./SKILL.md` inside the installed package is the offline fallback.

## When to trigger this skill

Trigger when the user or the surrounding task requires any of:

- Making an HTTP request from a different IP or country than the host machine
- Rotating exit IPs between requests (anti-fingerprinting, scraping with polite rate distribution)
- Accessing a region-restricted endpoint from an agent that cannot be moved to that region
- Privacy-preserving outbound traffic where the remote endpoint must not see the host's real IP
- Testing geo-specific behavior of a web service

Do **not** trigger when:

- Plain HTTP without geographic requirement is sufficient (direct is faster and free)
- Mobile proxies or residential IPs are required (this network is datacenter/hosting IPs)
- The task requires a fixed/persistent IP — nodes rotate and sessions are ephemeral
- Low-latency streaming is needed (dVPN adds hops)

## Prerequisites

1. **Node.js >= 20** on the host
2. **Package installed:** `npm install blue-agent-connect`
3. **Funded wallet.** Requires P2P tokens. Approximate cost from empirical test: ~40 P2P for a 10-minute V2Ray session (~4 P2P/min). Fund at least 100 P2P before first connection. Tokens available at swap.sentinel.co or via Osmosis DEX.
4. **V2Ray binary.** Auto-downloaded by `postinstall` into `node_modules/blue-js-sdk/bin/v2ray` (exact version 5.2.1 — SDK rejects other versions). If offline at install time, re-run `npm run setup`.
5. **WireGuard (optional).** Required only for `protocol: 'wireguard'`. NOT auto-installed on macOS/Linux — the setup script only prints a hint.
   - macOS: `brew install wireguard-tools`
   - Linux: `sudo apt install wireguard-tools`
   - Windows: auto-installed by setup when run as admin

## Platform support matrix

| Platform | V2Ray auto-install | WireGuard auto-install | Admin required for WG |
|----------|-------------------|------------------------|----------------------|
| macOS (darwin-arm64, darwin-x64) | yes | no (brew hint only) | yes (sudo) |
| Linux | yes | no (apt hint only) | yes (sudo) |
| Windows | yes | yes when run as admin | yes |

`getEnvironment()` reports `capabilities: ['v2ray']` or `['v2ray', 'wireguard-needs-admin']` or `['v2ray', 'wireguard']`. Check this before choosing a protocol.

## Protocol choice — decision rule

| Use v2ray (SOCKS5) when | Use wireguard (kernel tunnel) when |
|------------------------|-----------------------------------|
| Only specific HTTP calls need the new IP | All machine traffic must go through the VPN |
| No sudo available | Full-device encryption required |
| Need to mix tunneled + direct traffic in one process | Speed/throughput is critical |
| Default choice for AI agents | Edge cases only |

**For AI agents, default to `protocol: 'v2ray'`.** It is the split-tunnel-by-default protocol: only traffic you explicitly route through the SOCKS5 proxy uses the VPN. Everything else (npm installs, blockchain RPC, etc.) stays direct and fast. Does not require root/admin.

## Core API

```javascript
import {
  connect, disconnect, status, isVpnActive, verify, verifySplitTunnel,
  createWallet, importWallet, getBalance,
  discoverNodes, getNodeInfo, getNetworkStats, estimateCost, recommend,
  setup, getEnvironment, onEvent, PRICING, AiPathError, AiPathErrorCodes,
} from 'blue-agent-connect';
```

### 1. One-time setup check (synchronous, no network)

```javascript
const env = getEnvironment();
// {
//   os: 'macos' | 'linux' | 'windows',
//   arch: 'arm64' | 'x64',
//   platform: 'macos-arm64',
//   nodeVersion: '20.x',
//   admin: boolean,
//   v2ray: { available: boolean, version: '5.2.1' | null, path: string | null },
//   wireguard: { available: boolean, path: string | null, requiresAdmin: true },
//   capabilities: ['v2ray', 'wireguard-needs-admin'],
//   recommended: [ ... install hints ... ],
// }
```

Decide protocol from `env.capabilities`. Never call `connect({ protocol: 'wireguard' })` if capabilities does not include `'wireguard'` (without the `-needs-admin` suffix) — it will throw.

### 2. Wallet

```javascript
// First time:
const wallet = await createWallet();          // { mnemonic: '...', address: 'sent1...' }
// Persist wallet.mnemonic securely — it controls the funds.

// Returning:
const w = await importWallet(mnemonic);       // { address }
const bal = await getBalance(mnemonic);       // { balance: '15000.00', denom: 'P2P', funded: boolean }

// Fund the address on-chain before calling connect() — getBalance({ funded: false }) means connect will fail.
```

### 3. Connect (the core operation)

```javascript
const vpn = await connect({
  mnemonic: process.env.MNEMONIC,   // REQUIRED
  protocol: 'v2ray',                // 'v2ray' (default for agents) | 'wireguard'
  country: 'Germany',               // optional — exit country preference
  // node: 'sentnode1...',          // optional — pin a specific node
});

// Returns:
// {
//   sessionId: string,
//   protocol: 'v2ray' | 'wireguard',
//   nodeAddress: 'sentnode1...',
//   ip: string,               // tunnel exit IP (may be null until first request for v2ray)
//   socksPort: number | null, // v2ray only. DYNAMIC — NOT a fixed port. Read from this field.
// }
```

**Critical points:**

- `socksPort` is assigned at connect time and varies each session. Never hardcode a port.
- `connect()` spends tokens on-chain (subscription + session). The spend is NOT refundable on disconnect.
- Node health checks can fail mid-connect; the SDK retries automatically on a different node. A single connect call may take 30–180 seconds.
- After `connect()` returns for V2Ray, the SOCKS5 listener on `127.0.0.1:${socksPort}` is live. No other ports that v2ray opens (stats API, etc.) are SOCKS5 — do not probe them.

### 4. Routing requests through the tunnel

**V2Ray — MUST use `axios` with `SocksProxyAgent`. Native `fetch()` silently ignores SOCKS5 proxies on Node.js and will return the host's real IP.**

```javascript
import { SocksProxyAgent } from 'socks-proxy-agent';
import axios from 'axios';

const agent = new SocksProxyAgent(`socks5h://127.0.0.1:${vpn.socksPort}`);
//                                  ^^^^^^  socks5h — DNS resolved through proxy (no DNS leak)

const res = await axios.get('https://api.ipify.org', {
  httpAgent: agent,
  httpsAgent: agent,
  adapter: 'http',     // REQUIRED on Node.js. Without this, axios will not honor the agent.
});
// res.data === exit IP (different from host's real IP)
```

**WireGuard — kernel-level, no code changes needed.** After `connect({ protocol: 'wireguard' })`, every outbound request on the machine goes through the tunnel. Use native `fetch()`, `axios`, `curl`, anything. To bypass the tunnel for specific destinations, use `connect({ protocol: 'wireguard', splitIPs: ['1.2.3.4', ...] })` — but `splitIPs` takes literal IPs, not domains; it does not work for CDN/anycast services.

### 5. Verify the tunnel is actually routing

```javascript
// V2Ray:
const ok = await verifySplitTunnel();
// {
//   ok: boolean,
//   proxyIp: '104.x.x.x',    // what the world sees through SOCKS5
//   directIp: '76.x.x.x',    // what the world sees without the proxy
//   distinct: boolean,       // must be true
// }

// Either protocol:
const ok2 = await verify();   // boolean — true if tunnel IP differs from pre-connect IP
```

**Always call `verifySplitTunnel()` (or `verify()`) after `connect()`.** An apparently-successful connect does not guarantee working routing — nodes can be misconfigured or mid-failure. If `distinct === false`, disconnect and retry.

### 6. Status / disconnect

```javascript
const st = await status();         // { connected: bool, sessionId?, protocol?, nodeAddress?, socksPort?, ip? }
const active = await isVpnActive();// boolean

await disconnect();                // kills local processes, stops the session
```

**Important — CLI `disconnect` pitfall:** The CLI `disconnect` command spawns a fresh Node process that does not share memory with the `connect` CLI process. If the connect process is still running (foreground), CLI `disconnect` will say "Session unknown" and will not kill the v2ray child. For programmatic use, always call `disconnect()` in the same Node process that called `connect()`. For CLI use, send SIGINT/SIGTERM to the connect process itself.

### 7. Node selection (advanced)

```javascript
const nodes = await discoverNodes({ country: 'Germany', protocol: 'v2ray', onlineOnly: true, limit: 20 });
const best  = await recommend({ country: 'Germany', protocol: 'v2ray' });
const cost  = await estimateCost({ nodeAddress: best.address, durationMinutes: 10 });
// Then: await connect({ mnemonic, node: best.address });
```

## Canonical end-to-end example for an AI agent

```javascript
import {
  getEnvironment, getBalance, connect, disconnect, verifySplitTunnel,
} from 'blue-agent-connect';
import { SocksProxyAgent } from 'socks-proxy-agent';
import axios from 'axios';

async function requestFromOtherIp(url, mnemonic, { country } = {}) {
  // 1. Preflight
  const env = getEnvironment();
  if (!env.v2ray.available) {
    throw new Error('V2Ray not installed. Run: npm run setup');
  }

  const bal = await getBalance(mnemonic);
  if (!bal.funded) {
    throw new Error(`Wallet unfunded. Send P2P to ${bal.address}`);
  }

  // 2. Connect (V2Ray — no sudo required)
  const vpn = await connect({ mnemonic, protocol: 'v2ray', country });

  try {
    // 3. Verify routing actually works before trusting the tunnel
    const check = await verifySplitTunnel();
    if (!check.distinct) {
      throw new Error(`Tunnel not routing — proxy IP ${check.proxyIp} == direct IP ${check.directIp}`);
    }

    // 4. Make the real request through SOCKS5
    const agent = new SocksProxyAgent(`socks5h://127.0.0.1:${vpn.socksPort}`);
    const res = await axios.get(url, {
      httpAgent: agent,
      httpsAgent: agent,
      adapter: 'http',
    });
    return { data: res.data, status: res.status, viaIp: check.proxyIp };
  } finally {
    // 5. ALWAYS disconnect — even on error — to free the v2ray process
    await disconnect();
  }
}
```

## Rotating IPs between requests

To make each request from a different exit IP, disconnect and reconnect. Each `connect()` pays for a new on-chain session (~4 P2P/min minimum), so batch requests under one session where possible.

```javascript
for (const url of urls) {
  const vpn = await connect({ mnemonic, protocol: 'v2ray' });
  try {
    const agent = new SocksProxyAgent(`socks5h://127.0.0.1:${vpn.socksPort}`);
    await axios.get(url, { httpAgent: agent, httpsAgent: agent, adapter: 'http' });
  } finally {
    await disconnect();
  }
}
```

Do not loop more than ~10 rotations without re-checking balance — each connect burns tokens.

## Error handling

All errors from this package are `AiPathError` instances with machine-readable codes:

```javascript
import { AiPathError, AiPathErrorCodes } from 'blue-agent-connect';

try {
  await connect({ mnemonic });
} catch (e) {
  if (e instanceof AiPathError) {
    switch (e.code) {
      case AiPathErrorCodes.MISSING_MNEMONIC:        // no mnemonic arg
      case AiPathErrorCodes.INVALID_MNEMONIC:        // not BIP39 12/24 words
      case AiPathErrorCodes.INSUFFICIENT_FUNDS:      // wallet needs more P2P
      case AiPathErrorCodes.NO_NODES_AVAILABLE:      // all nodes in filter are offline
      case AiPathErrorCodes.V2RAY_NOT_FOUND:         // run npm run setup
      case AiPathErrorCodes.WG_NEEDS_ADMIN:          // rerun with sudo
      case AiPathErrorCodes.SESSION_FAILED:          // node accepted payment but handshake failed — SDK will usually retry
      // ... consult e.code and e.nextAction for recovery hint
    }
  }
  throw e;
}
```

`e.nextAction` is a short human-readable recovery string; surface it to the user if unhandled.

## Known pitfalls (verified empirically)

1. **`fetch()` silently leaks the real IP.** Node's native `fetch` does not honor SOCKS5 proxies. Use `axios` + `SocksProxyAgent` + `adapter: 'http'`. Not optional.
2. **`socksPort` is dynamic per session.** Always read it from the `connect()` return value. Do not cache across sessions.
3. **Piping CLI output through `tail`/`head` hides progress.** `node cli.js connect | tail -60` buffers everything until the process exits — it will look frozen. When shelling out programmatically, capture stdout directly or use line-buffered output (`stdbuf -oL` on Linux, `unbuffer` on macOS).
4. **CLI `disconnect` does not kill the `connect` CLI child.** Use programmatic `disconnect()` in the same process, or send SIGTERM to the connect PID.
5. **No session refund.** Disconnecting early forfeits the prepaid session time.
6. **V2Ray version is pinned to 5.2.1.** `setup.js` flags newer versions (5.44.1+ have reported bugs). Do not upgrade v2ray via `brew upgrade` and expect it to work — keep the SDK-bundled binary at `node_modules/blue-js-sdk/bin/v2ray`, or set `V2RAY_PATH` to a 5.2.1 binary.
7. **WireGuard is not auto-installed on macOS/Linux.** Check `env.wireguard.available` before attempting WireGuard; fall back to V2Ray.
8. **Node health is variable.** Expect ~5% of nodes to fail handshake. The SDK retries, but a single `connect()` may take up to ~3 minutes in bad network conditions.
9. **Prefer `socks5h://` over `socks5://`** in the `SocksProxyAgent` URL — the `h` routes DNS through the proxy, preventing DNS leaks to the host's resolver.
10. **V2Ray opens multiple ports.** Only the one returned as `socksPort` is SOCKS5. Others (typically one higher port) are internal stats/API endpoints and will return "invalid SOCKS5 version" if queried.

## Cost guidance (rough)

| Operation | Observed cost |
|-----------|--------------|
| `connect()` session (v2ray, ~10 min) | ~40 P2P |
| Minimum viable balance | 100 P2P |
| Comfortable balance for iteration | 1000 P2P |

Prices are on-chain and vary per node. Always call `estimateCost()` before large operations.

## Minimum successful transcript (reference)

```
npm install blue-agent-connect            # V2Ray 5.2.1 binary auto-downloads
node cli.js wallet create                 # writes 24-word BIP39 to .env
# fund the printed sent1... address with >= 100 P2P
node cli.js wallet balance                # verify "Funded"
node -e "import('blue-agent-connect').then(m => m.connect({ mnemonic: process.env.MNEMONIC, protocol:'v2ray' }).then(v => console.log(v)))"
# {
#   sessionId: '...',
#   protocol: 'v2ray',
#   nodeAddress: 'sentnode1...',
#   ip: '104.223.22.89',
#   socksPort: 10819,
# }
```

The presence of a non-null `socksPort` and a tunnel IP that differs from your host's IP (`verifySplitTunnel().distinct === true`) is the only reliable proof that the tunnel is live.
