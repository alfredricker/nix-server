/**
 * cinemafred.com — self-discovering geographic CDN router
 *
 * Nodes register themselves in Workers KV every 90s with a 120s TTL.
 * This Worker reads the live registry and routes each request to the
 * nearest online node, falling back down the list by distance.
 *
 * No hardcoded node list — adding or removing a node requires no changes here.
 *
 * Deploy: cd worker && wrangler deploy
 */

/** Haversine distance in km between two lat/lon points. */
function distanceKm(lat1, lon1, lat2, lon2) {
  const R    = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a    =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) *
    Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export default {
  async fetch(request, env) {
    const { latitude, longitude } = request.cf ?? {};
    const path = new URL(request.url).pathname + new URL(request.url).search;

    // Discover all currently-online nodes from KV.
    // Stale entries (offline nodes) have already expired via TTL.
    const { keys } = await env.NODES_KV.list({ prefix: "node-" });

    if (keys.length === 0) {
      return new Response("No nodes available", { status: 503 });
    }

    const nodes = (
      await Promise.all(
        keys.map(async ({ name }) => {
          const val = await env.NODES_KV.get(name, { type: "json" });
          return val ? { name, ...val } : null;
        })
      )
    ).filter(n => n?.url && n?.lat != null && n?.lon != null);

    // Sort nearest-first. If Cloudflare can't determine visitor coordinates
    // (extremely rare), fall back to arbitrary order.
    const sorted = [...nodes].sort((a, b) => {
      if (latitude == null) return 0;
      return (
        distanceKm(latitude, longitude, a.lat, a.lon) -
        distanceKm(latitude, longitude, b.lat, b.lon)
      );
    });

    for (const node of sorted) {
      let response;
      try {
        response = await fetch(`${node.url}${path}`, {
          method:  request.method,
          headers: request.headers,
          body:    request.method !== "GET" && request.method !== "HEAD"
                     ? request.body
                     : undefined,
          signal: AbortSignal.timeout(4000),
        });
      } catch {
        continue; // timed out or refused — try next node
      }

      if (response.ok || response.status === 304 || response.status === 206) {
        const out = new Response(response.body, response);
        out.headers.set("X-Edge-Node", node.name);
        return out;
      }
    }

    // All edge nodes failed — fall back to the origin on main-node.
    try {
      const origin = await fetch(`https://cinemafred-origin.rickermedia.com${path}`, {
        method:  request.method,
        headers: request.headers,
        body:    request.method !== "GET" && request.method !== "HEAD"
                   ? request.body
                   : undefined,
        signal: AbortSignal.timeout(8000),
      });
      if (origin.ok || origin.status === 304 || origin.status === 206) {
        const out = new Response(origin.body, origin);
        out.headers.set("X-Edge-Node", "main-node (origin fallback)");
        return out;
      }
    } catch {}

    return new Response("All nodes unavailable", { status: 503 });
  },
};
