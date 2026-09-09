// The receiver for the app's anonymous daily ping (Sources/Model/AnalyticsPing.swift).
//
// A Cloudflare Worker writing to Workers Analytics Engine, chosen because it can be made to
// keep nothing but the count: this code never reads the client address, sets no cookie, and
// writes one data point with the four enumerated fields the app sends. Cloudflare's own
// request logs are off for Workers unless Logpush is configured — leave it unconfigured.
//
// What the app sends, and all this accepts:
//   POST /v1/ping   {"v":1,"app":"0.13.0","os":"15","arch":"arm64","channel":"brew"}
// Anything else is dropped with a 204 too: a probe learns nothing from the status code.

const ALLOWED = {
  arch: new Set(["arm64", "x86_64", "other"]),
  channel: new Set(["brew", "plugin", "dmg"]),
};
const SHORT = /^[0-9A-Za-z.\-]{1,32}$/;

export default {
  async fetch(request, env) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/ping") {
      return new Response(null, { status: 204 });
    }
    let body;
    try {
      body = await request.json();
    } catch {
      return new Response(null, { status: 204 });
    }
    const app = SHORT.test(body?.app) ? body.app : null;
    const os = SHORT.test(body?.os) ? body.os : null;
    const arch = ALLOWED.arch.has(body?.arch) ? body.arch : null;
    const channel = ALLOWED.channel.has(body?.channel) ? body.channel : null;
    if (body?.v !== 1 || !app || !os || !arch || !channel) {
      return new Response(null, { status: 204 });
    }
    // No index: an index is the field Analytics Engine samples by, and there is no per-client
    // value here to sample on. Blobs are the four dimensions; the double is the count.
    env.PINGS.writeDataPoint({ blobs: [app, os, arch, channel], doubles: [1] });
    return new Response(null, { status: 204 });
  },
};
