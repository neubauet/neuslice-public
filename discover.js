/*
 * Copyright (c) 2024-2026 Tommy Neubauer. All rights reserved.
 *
 * NeuSlice Proprietary and Confidential. Patent Pending.
 *
 * See LICENSE and NOTICE in the repository root for full terms.
 * Contact: tommy@neuslice.com
 */

/**
 * discover.js — find the printer on the LAN, and pre-flight the endpoints the
 * installer is about to use.
 *
 * Why this exists: the printer's address is typed into the dashboard form at
 * registration (frontend ADAPTER_CONFIGS -> setup code -> adapter_env), long
 * before the installer sees it. Owners routinely do not know that address, and
 * a typo produces a node that registers, comes up, and never prints. This finds
 * the address for them, and — in `check` mode — proves every endpoint works
 * BEFORE the install rather than three failures deep into it.
 *
 * Two modes:
 *   node discover.js discover            find printers on this LAN
 *   node discover.js check               pre-flight installer endpoints
 *   node discover.js check --printer URL  ...plus fingerprint one address
 *
 * Add --json for the machine-readable shape (what the installer consumes).
 *
 * ── Zero dependencies, on purpose ────────────────────────────────────────────
 * This file must run from a bare Node with NO node_modules present — the whole
 * point is to run it BEFORE the install, from the portable runtime the
 * bootstrap script fetches. Only `node:` builtins and global fetch. Do not add
 * an import here that npm has to resolve.
 *
 * ── How discovery works ──────────────────────────────────────────────────────
 * Three passes, run concurrently:
 *
 *   1. Bambu SSDP    Bambu printers beacon to 239.255.255.250:2021 in LAN mode.
 *                    Yields IP + serial + model — exactly the three things
 *                    Bambuddy's add-printer form asks for and nobody can find.
 *   2. .local names  The stock images publish a predictable hostname over mDNS
 *                    (octopi.local, mainsailos.local, ...). Resolved through the
 *                    OS resolver, so no mDNS wire format is hand-rolled here.
 *   3. TCP sweep     The workhorse. Connect-scan the local /24 on four ports,
 *                    then HTTP-fingerprint only the hosts that answered.
 *
 * The sweep is a port scan of the operator's own LAN, initiated by them. It is
 * deliberately narrow (four ports, short timeouts) and refuses any interface
 * wider than a /22 so it can never wander into a 65k-host sweep.
 */

import os    from 'node:os'
import net   from 'node:net'
import dgram from 'node:dgram'
import dns   from 'node:dns/promises'
import { pathToFileURL } from 'node:url'

// ── Tunables ─────────────────────────────────────────────────────────────────

/** Ports worth knocking on. Keep this list short — every entry costs a full sweep. */
export const SWEEP_PORTS = [7125, 80, 5000, 8000]

/** Refuse to sweep an interface wider than this. /22 = 1022 hosts, already generous. */
export const MIN_PREFIX = 22

// A host that is not already in the ARP cache cannot answer until ARP resolves,
// which on Windows routinely takes ~1s. A shorter timeout than that intermittently
// misses a printer that is sitting right there — and "found it 3 runs out of 4"
// is useless for a tool whose whole job is finding the printer. The wider timeout
// is paid for with more concurrency, which makes the sweep faster overall.
const DEFAULT_CONCURRENCY     = 128
const DEFAULT_TCP_TIMEOUT_MS  = 1000
const DEFAULT_HTTP_TIMEOUT_MS = 2500
// Generous on purpose: SSDP listening runs concurrently with the TCP sweep,
// which takes longer than this anyway, so a wider window is free. It matters —
// beacons are lossy multicast on an interval, and a short window intermittently
// misses a printer that is sitting right there.
const DEFAULT_SSDP_TIMEOUT_MS = 9000
const SSDP_SEARCH_RETRIES     = 4
const SSDP_SEARCH_INTERVAL_MS = 1500
const MAX_BODY_BYTES          = 256 * 1024

const SSDP_ADDR       = '239.255.255.250'
const SSDP_PORT       = 2021
const SSDP_ALT_PORT   = 1990   // some firmware answers M-SEARCH here instead

/** Stock Klipper/OctoPrint images publish these over mDNS. Cheap to try, high hit rate. */
export const WELL_KNOWN_LOCAL = [
  'octopi.local', 'mainsailos.local', 'fluiddpi.local',
  'voron.local', 'klipper.local', 'ratos.local',
]

/** Bambu's SSDP beacon carries a model code, not a name. */
export const BAMBU_MODELS = {
  'C11':                 'Bambu Lab P1P',
  'C12':                 'Bambu Lab P1S',
  'C13':                 'Bambu Lab X1E',
  'N1':                  'Bambu Lab A1 mini',
  'N2S':                 'Bambu Lab A1',
  '3DPrinter-X1':        'Bambu Lab X1',
  '3DPrinter-X1-Carbon': 'Bambu Lab X1 Carbon',
}

/** Endpoints the installer touches. Overridable so a staging run can point elsewhere. */
export const INSTALLER_ENDPOINTS = {
  dashboard: process.env.NEUSLICE_DASHBOARD_URL ?? 'https://neuslice.com/nodes/register',
  backend:   process.env.NEUSLICE_API_URL       ?? 'https://printshare-backend-234aeo2mva-uc.a.run.app',
  node_zip:  'https://nodejs.org/dist/v24.19.0/node-v24.19.0-win-x64.zip',
  agent_zip: 'https://raw.githubusercontent.com/neubauet/neuslice-public/main/neuslice-agent-native.zip',
}

/** The installer's setup-code callback listener. In use = a hard install failure. */
export const CALLBACK_PORT = 9876

// ── IPv4 helpers (pure) ──────────────────────────────────────────────────────

export function ip_to_int(ip) {
  const parts = String(ip).split('.')
  if (parts.length !== 4) return null
  let n = 0
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null
    const b = Number(p)
    if (b > 255) return null
    n = (n * 256) + b
  }
  return n
}

export function int_to_ip(n) {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.')
}

/** '255.255.255.0' -> 24. Returns null for a non-contiguous (invalid) mask. */
export function prefix_from_netmask(mask) {
  const n = ip_to_int(mask)
  if (n === null) return null
  const bits = n.toString(2).padStart(32, '0')
  const m = bits.match(/^(1*)(0*)$/)
  return m ? m[1].length : null
}

/**
 * Every IPv4 subnet worth sweeping, plus the ones deliberately skipped and why.
 * Skipping is reported rather than silent — "we found nothing" and "we never
 * looked" are different answers and the operator needs to tell them apart.
 */
export function local_subnets(interfaces = os.networkInterfaces()) {
  const subnets = []
  const skipped = []
  const seen    = new Set()

  for (const [iface, addrs] of Object.entries(interfaces ?? {})) {
    for (const a of addrs ?? []) {
      // Node <18 reported family as the number 4; >=18 uses the string 'IPv4'.
      const is_v4 = a.family === 'IPv4' || a.family === 4
      if (!is_v4 || a.internal) continue

      const prefix = prefix_from_netmask(a.netmask)
      const self   = ip_to_int(a.address)
      if (prefix === null || self === null) continue

      if (a.address.startsWith('169.254.')) {
        skipped.push({ iface, cidr: `${a.address}/${prefix}`, reason: 'link-local (no DHCP lease on this interface)' })
        continue
      }
      if (prefix < MIN_PREFIX) {
        skipped.push({ iface, cidr: `${a.address}/${prefix}`, reason: `wider than /${MIN_PREFIX} — too many hosts to sweep safely` })
        continue
      }
      if (prefix > 30) {
        skipped.push({ iface, cidr: `${a.address}/${prefix}`, reason: 'no usable host range' })
        continue
      }

      const mask    = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0
      const network = (self & mask) >>> 0
      const first   = network + 1
      const last    = (network | (~mask >>> 0)) >>> 0 // broadcast
      const key     = `${network}/${prefix}`
      if (seen.has(key)) continue                     // two ifaces on one LAN
      seen.add(key)

      subnets.push({
        iface,
        self:  a.address,
        cidr:  `${int_to_ip(network)}/${prefix}`,
        first,
        last:  last - 1,
        hosts: Math.max(0, last - first),
      })
    }
  }
  return { subnets, skipped }
}

/** Every host address in a subnet, as strings. */
export function subnet_hosts(subnet) {
  const out = []
  for (let n = subnet.first; n <= subnet.last; n++) out.push(int_to_ip(n))
  return out
}

// ── Fingerprint classifiers (pure — the whole reason these are separate) ─────

function header_of(headers, name) {
  if (!headers) return ''
  if (typeof headers.get === 'function') return headers.get(name) ?? ''
  return headers[name] ?? headers[name.toLowerCase()] ?? ''
}

function parse_json(text) {
  try { return JSON.parse(text) } catch { return null }
}

const MOONRAKER_LOCKED = {
  adapter:       'klipper',
  label:         'Klipper (via Moonraker)',
  detail:        'reachable — API key required (see trusted_clients in moonraker.conf)',
  ready:         true,
  needs_api_key: true,
  env_key:       'KLIPPER_HOST',
}

/**
 * Moonraker: GET /server/info. Also covers the Creality K2 and Snapmaker U1.
 *
 * A 401 means Moonraker is there and this machine is not in `trusted_clients` —
 * found, not missing. Claiming it needs corroboration though, since a 401 alone
 * could be anything: either Moonraker's own JSON error envelope, or the Tornado
 * server it is built on.
 */
export function classify_moonraker(status, headers, body_text) {
  if (status === 401) {
    const err = parse_json(body_text)?.error
    const is_moonraker_error = !!err && (err.code === 401 || typeof err.message === 'string')
    const is_tornado = /tornado/i.test(header_of(headers, 'server'))
    return (is_moonraker_error || is_tornado) ? { ...MOONRAKER_LOCKED } : null
  }
  if (status !== 200) return null
  const r = parse_json(body_text)?.result
  if (!r || typeof r !== 'object') return null
  const has_state   = typeof r.klippy_state === 'string'
  const has_version = typeof r.moonraker_version === 'string'
  if (!has_state && !has_version) return null
  return {
    adapter: 'klipper',
    label:   'Klipper (via Moonraker)',
    detail:  has_state ? `klippy: ${r.klippy_state}` : `moonraker ${r.moonraker_version}`,
    // klippy_state 'ready' means the firmware is up, not merely that Moonraker answers.
    ready:   has_state ? r.klippy_state === 'ready' : true,
    env_key: 'KLIPPER_HOST',
  }
}

/**
 * Moonraker: GET /access/info — deliberately unauthenticated, so a web UI can
 * discover which login methods exist before it has a token. That makes it the
 * reliable way to identify a Moonraker whose /server/info is locked down.
 */
export function classify_moonraker_access(status, body_text) {
  if (status !== 200) return null
  const r = parse_json(body_text)?.result
  if (!r || typeof r !== 'object') return null
  if (!Array.isArray(r.available_sources) && typeof r.default_source !== 'string') return null
  return { ...MOONRAKER_LOCKED }
}

/**
 * OctoPrint: GET /api/version.
 *
 * A 401/403 here is a POSITIVE identification — OctoPrint guards this route
 * behind an API key. The installer's probe (install-native.ps1) treats any
 * non-200 as unreachable, so an OctoPrint with a missing key reports "could not
 * reach OctoPrint" when the truth is "your key is wrong". Keep those separate.
 */
export function classify_octoprint(status, headers, body_text) {
  const clacks = header_of(headers, 'x-clacks-overhead')
  if (status === 200) {
    const j = parse_json(body_text)
    if (typeof j?.text === 'string' && /octoprint/i.test(j.text)) {
      return { adapter: 'octoprint', label: 'OctoPrint', detail: j.text, ready: true, needs_api_key: false, env_key: 'OCTOPRINT_HOST' }
    }
    return null
  }
  if (status === 401 || status === 403) {
    if (clacks || /api\s*key/i.test(body_text ?? '')) {
      return { adapter: 'octoprint', label: 'OctoPrint', detail: 'reachable — API key required', ready: true, needs_api_key: true, env_key: 'OCTOPRINT_HOST' }
    }
  }
  return null
}

/** Bambuddy: GET /api/v1/printers/. Finding one already running saves a whole install step. */
export function classify_bambuddy(status, body_text) {
  if (status === 401 || status === 403) {
    return { adapter: 'bambu', label: 'Bambuddy', detail: 'reachable — API key required', ready: true, needs_api_key: true, env_key: 'BAMBU_HOST' }
  }
  if (status !== 200) return null
  const j = parse_json(body_text)
  if (!Array.isArray(j)) return null
  return {
    adapter:  'bambu',
    label:    'Bambuddy',
    detail:   j.length === 1 ? '1 printer configured' : `${j.length} printers configured`,
    ready:    true,
    env_key:  'BAMBU_HOST',
    printers: j.map(p => ({ id: p?.id, name: p?.name, model: p?.model })),
  }
}

const P_MOONRAKER = { path: '/server/info',      classify: (s, h, b) => classify_moonraker(s, h, b) }
const P_ACCESS    = { path: '/access/info',      classify: (s, h, b) => classify_moonraker_access(s, b) }
const P_OCTOPRINT = { path: '/api/version',      classify: (s, h, b) => classify_octoprint(s, h, b) }
const P_BAMBUDDY  = { path: '/api/v1/printers/', classify: (s, h, b) => classify_bambuddy(s, b) }

/** Which probes are worth running against an open port, in order. */
const PROBES = {
  7125: [P_MOONRAKER, P_ACCESS],
  80:   [P_MOONRAKER, P_ACCESS, P_OCTOPRINT],
  5000: [P_OCTOPRINT],
  8000: [P_BAMBUDDY, P_MOONRAKER],
}

/** Bambu SSDP beacon -> a printer record. Returns null for anything else on the wire. */
export function parse_ssdp(text) {
  const lines = String(text ?? '').split(/\r?\n/)
  if (lines.length < 2) return null
  const h = {}
  for (const line of lines.slice(1)) {
    const i = line.indexOf(':')
    if (i > 0) h[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim()
  }

  const nt = `${h['nt'] ?? ''} ${h['st'] ?? ''}`
  if (!/bambulab/i.test(nt) && !h['devmodel.bambu.com']) return null

  // Location is a bare IP on current firmware, but has been seen as a URL.
  const ip = (h['location'] ?? '').match(/\d{1,3}(?:\.\d{1,3}){3}/)?.[0]
  if (!ip || ip_to_int(ip) === null) return null

  const code = h['devmodel.bambu.com'] ?? ''
  return {
    ip,
    serial:     h['usn'] ?? '',
    model_code: code,
    model:      BAMBU_MODELS[code] ?? (code ? `Bambu Lab (${code})` : 'Bambu Lab printer'),
    name:       h['devname.bambu.com'] ?? '',
    // 'free' = no other client holds the LAN slot; 'occupy' = Studio/Orca has it.
    bind:       h['devbind.bambu.com'] ?? '',
    signal:     h['devsignal.bambu.com'] ?? '',
  }
}

// ── Network I/O ──────────────────────────────────────────────────────────────

/** Bounded-concurrency map. Order of results matches order of items. */
async function pool(items, limit, worker) {
  const results = new Array(items.length)
  let next = 0
  const runners = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (;;) {
      const i = next++
      if (i >= items.length) return
      try { results[i] = await worker(items[i], i) } catch { results[i] = null }
    }
  })
  await Promise.all(runners)
  return results
}

/** Is this TCP port open? Never rejects — a closed port is an answer, not an error. */
export function tcp_probe(ip, port, timeout_ms = DEFAULT_TCP_TIMEOUT_MS) {
  return new Promise(resolve => {
    let settled = false
    const done = (open) => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(open)
    }
    const socket = net.createConnection({ host: ip, port })
    socket.setTimeout(timeout_ms)
    socket.once('connect', () => done(true))
    socket.once('timeout', () => done(false))
    socket.once('error',   () => done(false))
  })
}

/** GET with a hard timeout and a body cap. Returns a result object; never throws. */
export async function http_get(url, { timeout_ms = DEFAULT_HTTP_TIMEOUT_MS, headers = {}, method = 'GET' } = {}) {
  try {
    const res = await fetch(url, { method, headers, redirect: 'follow', signal: AbortSignal.timeout(timeout_ms) })
    const len = Number(res.headers.get('content-length') ?? 0)
    const body = (method === 'HEAD' || len > MAX_BODY_BYTES) ? '' : await res.text()
    return { ok: true, status: res.status, headers: res.headers, body }
  } catch (err) {
    return { ok: false, status: 0, headers: null, body: '', error: describe_net_error(err) }
  }
}

/** Turn a fetch/socket error into something an owner can act on. */
export function describe_net_error(err) {
  const code = err?.cause?.code ?? err?.code ?? ''
  const name = err?.name ?? ''
  if (name === 'TimeoutError' || code === 'UND_ERR_CONNECT_TIMEOUT' || code === 'ETIMEDOUT') {
    return 'timed out — wrong address, or a firewall is dropping the connection'
  }
  if (code === 'ECONNREFUSED')  return 'connection refused — nothing is listening on that port'
  if (code === 'ENOTFOUND')     return 'hostname did not resolve'
  if (code === 'EHOSTUNREACH')  return 'host unreachable — is it on this network?'
  if (code === 'ECONNRESET')    return 'connection reset'
  if (code === 'CERT_HAS_EXPIRED' || code === 'DEPTH_ZERO_SELF_SIGNED_CERT') return 'TLS certificate rejected'
  return err?.message ?? String(err)
}

/**
 * Identify what is running at ip:port. Returns a service record, or an
 * 'unknown' marker when something answered but did not look like a printer.
 */
export async function fingerprint(ip, port, timeout_ms = DEFAULT_HTTP_TIMEOUT_MS) {
  const base = `http://${ip}${port === 80 ? '' : `:${port}`}`
  for (const probe of PROBES[port] ?? []) {
    const res = await http_get(`${base}${probe.path}`, { timeout_ms })
    if (!res.ok) continue
    const hit = probe.classify(res.status, res.headers, res.body)
    if (hit) return { ...hit, ip, port, url: base, source: 'sweep' }
  }
  return { adapter: null, ip, port, url: base, source: 'sweep' }
}

/**
 * Listen for Bambu LAN beacons.
 *
 * Binding 2021 fails with EADDRINUSE when Bambu Studio or OrcaSlicer is open —
 * common, and worth saying out loud rather than reporting "no Bambu printers".
 */
export function discover_bambu_ssdp({ timeout_ms = DEFAULT_SSDP_TIMEOUT_MS } = {}) {
  return new Promise(resolve => {
    const found  = new Map()
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    let settled  = false

    let search_timer = null
    const finish = (error = null) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (search_timer) clearInterval(search_timer)
      try { socket.close() } catch { /* already closed */ }
      resolve({ ok: !error, error, printers: [...found.values()] })
    }
    const timer = setTimeout(() => finish(null), timeout_ms)

    socket.on('error', err => {
      finish(err?.code === 'EADDRINUSE'
        ? `UDP port ${SSDP_PORT} is in use — close Bambu Studio / OrcaSlicer and re-run to detect Bambu printers`
        : describe_net_error(err))
    })

    socket.on('message', msg => {
      const p = parse_ssdp(msg.toString('utf8'))
      if (p) found.set(p.serial || p.ip, p)
    })

    socket.bind(SSDP_PORT, () => {
      // Multicast membership per interface — a multi-homed box (Wi-Fi + Ethernet)
      // otherwise joins on only one of them, whichever the OS picks.
      try { socket.addMembership(SSDP_ADDR) } catch { /* no default route for multicast */ }
      for (const s of local_subnets().subnets) {
        try { socket.addMembership(SSDP_ADDR, s.self) } catch { /* already joined */ }
      }
      try { socket.setBroadcast(true) } catch { /* not fatal */ }

      // Printers beacon on their own every few seconds; the M-SEARCH just makes
      // the common case faster than the beacon interval. Repeated because this
      // is unacknowledged multicast — a single lost datagram would otherwise
      // read as "no Bambu printer on this network".
      const search = Buffer.from([
        'M-SEARCH * HTTP/1.1',
        `HOST: ${SSDP_ADDR}:${SSDP_PORT}`,
        'MAN: "ssdp:discover"',
        'MX: 1',
        'ST: urn:bambulab-com:device:3dprinter:1',
        '', '',
      ].join('\r\n'))
      const send_search = () => {
        for (const port of [SSDP_PORT, SSDP_ALT_PORT]) {
          socket.send(search, 0, search.length, port, SSDP_ADDR, () => { /* best effort */ })
        }
      }
      send_search()
      let sent = 1
      search_timer = setInterval(() => {
        if (sent++ >= SSDP_SEARCH_RETRIES) { clearInterval(search_timer); search_timer = null; return }
        send_search()
      }, SSDP_SEARCH_INTERVAL_MS)
    })
  })
}

/** Resolve the stock image hostnames through the OS resolver (Bonjour / nss-mdns). */
export async function resolve_well_known(names = WELL_KNOWN_LOCAL) {
  const hits = await pool(names, 8, async name => {
    try {
      const { address } = await dns.lookup(name, { family: 4 })
      return { hostname: name, ip: address }
    } catch { return null }
  })
  return hits.filter(Boolean)
}

/** Best-effort reverse lookup so the table can show a name instead of digits. */
async function reverse_name(ip) {
  try {
    const names = await dns.reverse(ip)
    return names?.[0] ?? ''
  } catch { return '' }
}

// ── Discovery orchestration ──────────────────────────────────────────────────

/**
 * Sweep the LAN, fingerprint what answers, and merge in the Bambu beacons.
 *
 * @returns {Promise<{printers:Array, unidentified:Array, scanned:Array, skipped:Array, ssdp:object, duration_ms:number}>}
 */
export async function discover({
  ports        = SWEEP_PORTS,
  concurrency  = DEFAULT_CONCURRENCY,
  tcp_timeout  = DEFAULT_TCP_TIMEOUT_MS,
  http_timeout = DEFAULT_HTTP_TIMEOUT_MS,
  ssdp_timeout = DEFAULT_SSDP_TIMEOUT_MS,
  ssdp         = true,
  interfaces,
  on_progress  = () => {},
} = {}) {
  const started = Date.now()
  const { subnets, skipped } = local_subnets(interfaces)

  // SSDP and the .local lookups run alongside the sweep — all three are mostly
  // waiting, so serialising them would just add their timeouts together.
  const ssdp_task  = ssdp ? discover_bambu_ssdp({ timeout_ms: ssdp_timeout }) : Promise.resolve({ ok: true, error: null, printers: [] })
  const local_task = resolve_well_known()

  const targets = new Set()
  for (const s of subnets) for (const ip of subnet_hosts(s)) targets.add(ip)
  // Path A puts Bambuddy on this very machine, which the LAN sweep can miss if
  // it binds loopback only.
  targets.add('127.0.0.1')
  for (const hit of await local_task) targets.add(hit.ip)

  const tasks = []
  for (const ip of targets) for (const port of ports) tasks.push({ ip, port })

  on_progress({ phase: 'sweep', subnets, skipped, hosts: targets.size, ports, tasks: tasks.length })

  let done = 0
  const open = await pool(tasks, concurrency, async t => {
    const is_open = await tcp_probe(t.ip, t.port, tcp_timeout)
    on_progress({ phase: 'sweep_progress', done: ++done, total: tasks.length })
    return is_open ? t : null
  })

  const answered = open.filter(Boolean)
  on_progress({ phase: 'fingerprint', count: answered.length })

  const services = (await pool(answered, 16, t => fingerprint(t.ip, t.port, http_timeout))).filter(Boolean)

  const ssdp_result = await ssdp_task

  // ── Merge ──
  // One device can answer on several ports (Moonraker on 7125 AND nginx on 80),
  // and this machine answers on both 127.0.0.1 and its own LAN address. Collapse
  // to one entry per device and keep the richest hit, preferring the direct
  // service port over a reverse proxy.
  const self_ips = new Set(['127.0.0.1', ...subnets.map(s => s.self)])
  const key_of   = ip => (self_ips.has(ip) ? '@self' : ip)

  const by_ip = new Map()
  for (const s of services) {
    if (!s.adapter) continue
    const key  = key_of(s.ip)
    const prev = by_ip.get(key)
    if (!prev || rank_service(s) > rank_service(prev)) by_ip.set(key, s)
  }

  for (const b of ssdp_result.printers) {
    const key  = key_of(b.ip)
    const prev = by_ip.get(key)
    const beacon = { serial: b.serial, model: b.model, model_code: b.model_code, name: b.name, bind: b.bind, signal: b.signal }

    // A Bambu beacon and an HTTP hit at the same IP are one device. The beacon
    // carries the serial and model, which no HTTP probe can tell us — but an
    // identified service already knows what it is, so attach the beacon to it
    // rather than relabelling a Bambuddy as the printer that happens to share
    // its address.
    if (prev?.adapter) {
      by_ip.set(key, { ...prev, bambu: beacon })
      continue
    }
    by_ip.set(key, {
      ...(prev ?? {}),
      adapter: 'bambu',
      label:   b.model,
      detail:  b.bind === 'occupy' ? 'LAN slot held by another app (Studio/Orca)' : 'LAN mode, available',
      ip:      b.ip,
      // Deliberately NOT `http://<printer ip>`: a Bambu printer is reached
      // through Bambuddy, so its own address is not a host any adapter can use.
      url:     '',
      ready:   true,
      source:  'ssdp',
      bambu:   beacon,
    })
  }

  const printers = [...by_ip.values()]
  const resolved = await local_task
  for (const p of printers) {
    p.local = self_ips.has(p.ip)
    const hint = resolved.find(h => h.ip === p.ip)
    p.hostname = p.local
      ? 'this computer'
      : hint?.hostname ?? p.bambu?.name ?? await reverse_name(p.ip)
  }
  printers.sort((a, b) => (ip_to_int(a.ip) ?? 0) - (ip_to_int(b.ip) ?? 0))

  // A home LAN has plenty of port-80 boxes (the router, a NAS, a TV). Only the
  // printer-ish ports are worth reporting as "something is here, unidentified",
  // and each device only once.
  const unidentified = []
  const seen_unknown = new Set()
  for (const s of services) {
    if (s.adapter || s.port === 80) continue
    const key = `${key_of(s.ip)}:${s.port}`
    if (by_ip.has(key_of(s.ip)) || seen_unknown.has(key)) continue
    seen_unknown.add(key)
    unidentified.push({ ip: s.ip, port: s.port, url: s.url, local: self_ips.has(s.ip) })
  }

  return {
    printers,
    unidentified,
    scanned: subnets.map(s => ({ cidr: s.cidr, iface: s.iface, hosts: s.hosts })),
    skipped,
    ssdp: { ok: ssdp_result.ok, error: ssdp_result.error, count: ssdp_result.printers.length },
    duration_ms: Date.now() - started,
  }
}

/** Prefer the direct service port over a reverse proxy, and identified over not. */
function rank_service(s) {
  let score = s.adapter ? 10 : 0
  if (s.port === 7125 || s.port === 5000 || s.port === 8000) score += 3
  if (s.ready) score += 1
  if (!s.needs_api_key) score += 1
  return score
}

// ── Pre-flight check ─────────────────────────────────────────────────────────

/** Can the installer's callback listener bind? Never throws. */
export function port_free(port, host = '127.0.0.1') {
  return new Promise(resolve => {
    const server = net.createServer()
    server.once('error', err => resolve({ free: false, code: err?.code ?? 'EUNKNOWN' }))
    server.once('listening', () => server.close(() => resolve({ free: true, code: null })))
    server.listen(port, host)
  })
}

/**
 * Prove every endpoint the installer needs, before it needs them. Optionally
 * fingerprint one printer URL the owner already has.
 */
export async function check({ printer = null, endpoints = INSTALLER_ENDPOINTS, timeout_ms = 8000 } = {}) {
  const checks = []
  const add = (name, ok, detail, fatal = true) => checks.push({ name, ok, detail, fatal })

  const major = Number(process.versions.node.split('.')[0])
  add('Node runtime', major >= 18, `v${process.versions.node}${major >= 18 ? '' : ' — the agent needs v18 or newer'}`)

  const cb = await port_free(CALLBACK_PORT)
  add(`Setup callback port ${CALLBACK_PORT}`, cb.free,
    cb.free ? 'free' : `in use (${cb.code}) — the installer cannot receive the setup code. Find it with: netstat -ano | findstr :${CALLBACK_PORT}`)

  const remote = [
    { name: 'Dashboard',        url: endpoints.dashboard,           method: 'GET',  expect: s => s > 0 && s < 500 },
    { name: 'NeuSlice backend', url: `${endpoints.backend}/health`, method: 'GET',  expect: s => s === 200 },
    { name: 'Node.js runtime download', url: endpoints.node_zip,    method: 'HEAD', expect: s => s === 200 },
    { name: 'Agent package download',   url: endpoints.agent_zip,   method: 'HEAD', expect: s => s === 200 },
  ]
  const results = await pool(remote, 4, async r => ({ r, res: await http_get(r.url, { timeout_ms, method: r.method }) }))
  for (const { r, res } of results.filter(Boolean)) {
    if (!res.ok)                add(r.name, false, res.error)
    else if (!r.expect(res.status)) add(r.name, false, `HTTP ${res.status}`)
    else                        add(r.name, true, `HTTP ${res.status}`)
  }

  if (printer) {
    const probed = await probe_printer_url(printer, timeout_ms)
    add(`Printer at ${probed.url}`, probed.ok, probed.detail)
    checks.at(-1).printer = probed
  }

  return { ok: checks.every(c => c.ok || !c.fatal), checks }
}

/**
 * Fingerprint one address the owner supplied. This is the "check my endpoint"
 * path: it must distinguish "nothing there" from "there, but needs a key",
 * because those have completely different fixes.
 */
export async function probe_printer_url(input, timeout_ms = DEFAULT_HTTP_TIMEOUT_MS) {
  const url = normalize_url(input)
  if (!url) return { ok: false, url: String(input), detail: 'could not parse that as a URL' }

  const attempts = [P_MOONRAKER, P_ACCESS, P_OCTOPRINT, P_BAMBUDDY]
  let last_error = null
  for (const a of attempts) {
    const res = await http_get(`${url}${a.path}`, { timeout_ms })
    if (!res.ok) { last_error = res.error; continue }
    const hit = a.classify(res.status, res.headers, res.body)
    if (hit) return { ok: true, url, adapter: hit.adapter, detail: `${hit.label} — ${hit.detail}`, needs_api_key: !!hit.needs_api_key }
    last_error = `HTTP ${res.status} from ${a.path} — answered, but not a printer API we recognise`
  }
  return { ok: false, url, detail: last_error ?? 'no response' }
}

/** '192.168.1.5' -> 'http://192.168.1.5'; strips a trailing slash. */
export function normalize_url(input) {
  let s = String(input ?? '').trim()
  if (!s) return null
  if (!/^https?:\/\//i.test(s)) s = `http://${s}`
  try {
    const u = new URL(s)
    if (!u.hostname) return null
    return `${u.protocol}//${u.host}`
  } catch { return null }
}

// ── Handoff to the dashboard (?found=) ───────────────────────────────────────

/**
 * Reduce a discovery result to the compact records the registration form reads.
 *
 * MUST stay byte-compatible with decodeFound in frontend/src/lib/foundPrinters.js
 * — discover.test.js asserts that by decoding this with the frontend's own
 * parser, so the two halves cannot drift apart silently.
 */
export function to_found_payload(result) {
  return (result?.printers ?? [])
    .map(p => ({
      adapter: p.adapter,
      // A URL is only offered when an HTTP service actually answered on a port.
      // An SSDP-only Bambu has no usable host — its printer address is not
      // something any adapter can be pointed at.
      url:         p.port ? p.url : '',
      name:        p.bambu?.name || (p.hostname === 'this computer' ? '' : p.hostname) || '',
      detail:      p.detail ?? '',
      needsApiKey: !!p.needs_api_key,
      serial:      p.bambu?.serial ?? '',
      model:       p.bambu?.model ?? '',
    }))
    .filter(c => c.adapter && (c.url || c.serial))
}

/**
 * base64url of the compact JSON. base64url specifically because this string
 * travels through PowerShell's Start-Process and a shell before a browser sees
 * it, and plain JSON does not survive that intact.
 */
export function encode_found(list) {
  const compact = (list ?? []).slice(0, 8).map(p => ({
    a: p.adapter,
    u: p.url,
    ...(p.name        ? { n: p.name }   : {}),
    ...(p.detail      ? { d: p.detail } : {}),
    ...(p.needsApiKey ? { k: 1 }        : {}),
    ...(p.serial      ? { s: p.serial } : {}),
    ...(p.model       ? { m: p.model }  : {}),
  }))
  return Buffer.from(JSON.stringify(compact), 'utf8').toString('base64url')
}

// ── Rendering ────────────────────────────────────────────────────────────────

const DASH = '  ------------------------------------------'

/** The dashboard field an owner should paste a given result into. */
export function paste_hint(p) {
  if (p.adapter === 'klipper')   return { field: 'Moonraker Host URL', value: p.url }
  if (p.adapter === 'octoprint') return { field: 'OctoPrint Host URL', value: p.url }
  if (p.bambu)                   return { field: "Bambuddy's add-printer form", value: `${p.ip}  (serial ${p.bambu.serial || 'unknown'})` }
  if (p.adapter === 'bambu')     return { field: 'Bambuddy Host URL', value: p.url }
  return null
}

export function render_discover(result) {
  const out = []
  out.push('')
  out.push('  NeuSlice Printer Discovery')
  out.push(DASH)
  out.push('')

  for (const s of result.scanned) out.push(`  Scanned ${s.cidr} (${s.hosts} hosts) on ${s.iface}`)
  for (const s of result.skipped) out.push(`  [!]  Skipped ${s.iface} ${s.cidr}: ${s.reason}`)
  if (result.ssdp && !result.ssdp.ok) out.push(`  [!]  ${result.ssdp.error}`)
  out.push(`  Finished in ${(result.duration_ms / 1000).toFixed(1)}s`)
  out.push('')

  if (result.printers.length === 0) {
    out.push('  No printers found.')
    out.push('')
    out.push('  Things worth checking:')
    out.push('    - Is the printer powered on and on the SAME network as this computer?')
    out.push('      (a 5GHz laptop and a 2.4GHz printer are often on separate guest networks)')
    out.push('    - Bambu Lab: the printer must be in LAN mode, and Bambu Studio / OrcaSlicer closed.')
    out.push('    - Klipper: Moonraker listens on 7125. If yours is elsewhere, pass --ports=7125,4409')
    out.push('')
  } else {
    out.push(`  Found ${result.printers.length} printer${result.printers.length === 1 ? '' : 's'}:`)
    out.push('')
    result.printers.forEach((p, i) => {
      const where = p.url || p.ip
      out.push(`   ${i + 1}) ${(p.label ?? 'Printer').padEnd(24)} ${where}`)
      const meta = [p.hostname, p.detail].filter(Boolean).join('  |  ')
      if (meta) out.push(`      ${' '.repeat(24)} ${meta}`)
      if (p.bambu?.serial) out.push(`      ${' '.repeat(24)} serial ${p.bambu.serial}`)
    })
    out.push('')
    out.push('  Paste into the NeuSlice dashboard:')
    for (const p of result.printers) {
      const hint = paste_hint(p)
      if (hint) out.push(`    ${hint.field.padEnd(30)} ${hint.value}`)
    }
    out.push('')
  }

  if (result.unidentified.length) {
    out.push('  Something is listening here, but did not identify itself as a printer:')
    for (const u of result.unidentified) out.push(`    ${u.url}`)
    out.push('')
  }
  return out.join('\n')
}

export function render_check(result) {
  const out = []
  out.push('')
  out.push('  NeuSlice Pre-Install Check')
  out.push(DASH)
  out.push('')
  for (const c of result.checks) {
    out.push(`  ${c.ok ? '[OK]' : '[X] '} ${c.name.padEnd(34)} ${c.detail}`)
  }
  out.push('')
  out.push(result.ok
    ? '  All clear — the installer has everything it needs.'
    : '  Fix the [X] lines above before running the installer.')
  out.push('')
  return out.join('\n')
}

// ── CLI ──────────────────────────────────────────────────────────────────────

export function parse_args(argv) {
  const opts = { mode: 'discover', json: false, ssdp: true }
  for (const arg of argv) {
    if (arg === 'discover' || arg === 'check' || arg === 'found') { opts.mode = arg; continue }
    if (arg === '--json')     { opts.json = true; continue }
    if (arg === '--no-ssdp')  { opts.ssdp = false; continue }
    if (arg === '--help' || arg === '-h') { opts.help = true; continue }
    const m = arg.match(/^--([a-z-]+)=(.*)$/)
    if (!m) continue
    const [, key, value] = m
    if (key === 'ports')       opts.ports = value.split(',').map(p => parseInt(p.trim(), 10)).filter(Boolean)
    if (key === 'timeout')     opts.tcp_timeout = parseInt(value, 10)
    if (key === 'concurrency') opts.concurrency = parseInt(value, 10)
    if (key === 'ssdp-timeout') opts.ssdp_timeout = parseInt(value, 10)
    if (key === 'printer')     opts.printer = value
    // Write the ?found= payload to a file while stdout keeps the human table.
    // Lets a wrapper script show results AND open the pre-filled dashboard from
    // a single sweep, instead of paying for the scan twice.
    if (key === 'found-out')   opts.found_out = value
  }
  return opts
}

const USAGE = `
  NeuSlice printer discovery + pre-install check

    node discover.js discover              find printers on this network
    node discover.js check                 pre-flight the installer's endpoints
    node discover.js check --printer=URL   ...and test one printer address

  Options
    --json                 machine-readable output
    --ports=7125,80        ports to sweep      (default ${SWEEP_PORTS.join(',')})
    --timeout=400          per-port TCP timeout in ms
    --concurrency=64       parallel connections
    --ssdp-timeout=5000    how long to listen for Bambu beacons
    --no-ssdp              skip Bambu beacon listening

  Exit codes
    0  success (discover: at least one printer found)
    1  error, or a failed check
    3  discover: nothing found
`

async function main() {
  const opts = parse_args(process.argv.slice(2))
  if (opts.help) { console.log(USAGE); return 0 }

  if (opts.mode === 'check') {
    const result = await check({ printer: opts.printer })
    console.log(opts.json ? JSON.stringify(result, null, 2) : render_check(result))
    return result.ok ? 0 : 1
  }

  // `found` is the installer's mode: sweep and print ONLY the URL parameter, so
  // the caller can append it to the dashboard link. Deliberately silent on BOTH
  // streams — the installer prints its own progress, and under PowerShell's
  // ErrorActionPreference='Stop' anything on stderr from a native command can
  // abort the whole install.
  if (opts.mode === 'found') {
    const result = await discover({ ...opts, on_progress: () => {} })
    const payload = to_found_payload(result)
    if (payload.length) console.log(encode_found(payload))
    return payload.length ? 0 : 3
  }

  // Progress only makes sense for a human; --json output must stay parseable.
  const on_progress = opts.json ? () => {} : progress_reporter()
  const result = await discover({ ...opts, on_progress })
  if (!opts.json) process.stderr.write('\r' + ' '.repeat(60) + '\r')
  console.log(opts.json ? JSON.stringify(result, null, 2) : render_discover(result))

  if (opts.found_out) {
    const payload = to_found_payload(result)
    // Only write on a real result. An empty file is a clearer "nothing found"
    // signal to the caller than a file holding the encoding of an empty array.
    if (payload.length) {
      const { writeFile } = await import('node:fs/promises')
      await writeFile(opts.found_out, encode_found(payload), 'utf8')
    }
  }
  return result.printers.length > 0 ? 0 : 3
}

function progress_reporter() {
  let last = 0
  return (ev) => {
    if (ev.phase === 'sweep') {
      process.stderr.write(`\n  Scanning ${ev.hosts} addresses on ports ${ev.ports.join(', ')}...\n`)
    } else if (ev.phase === 'sweep_progress') {
      const pct = Math.floor((ev.done / ev.total) * 100)
      if (pct >= last + 5) { last = pct; process.stderr.write(`\r  ${pct}%`) }
    } else if (ev.phase === 'fingerprint' && ev.count) {
      process.stderr.write(`\r  Identifying ${ev.count} responding service(s)...`)
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main()
    .then(code => { process.exitCode = code })
    .catch(err => {
      console.error(`\n  [X]  ${err?.message ?? err}\n`)
      process.exitCode = 1
    })
}
