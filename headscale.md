# Headscale Setup

Headscale runs on main-node and is the control plane for the WireGuard mesh. Every
node and personal device authenticates with it once to get keys; after that, traffic
flows peer-to-peer and headscale carries nothing.

Because Cloudflare's proxy strips the HTTP Upgrade header that Tailscale's TS2021
protocol requires, headscale cannot sit behind a Cloudflare Tunnel. It is exposed
directly on port 443 with its own Let's Encrypt certificate.

---

## Static IP for main-node

main-node needs a stable LAN address so the router's port forward doesn't break if
DHCP reassigns the address.

### NixOS config (`main-node.nix`)

```nix
networking.interfaces.eno1.ipv4.addresses = [{
  address      = "10.0.0.64";
  prefixLength = 24;
}];
networking.defaultGateway = "10.0.0.1";
networking.nameservers    = [ "1.1.1.1" "1.0.0.1" ];
```

### Router DHCP reservation (Netgear Genie)

Belt-and-suspenders alongside the NixOS static config. Prevents the router from
handing `10.0.0.64` to a different device.

1. **Advanced → Setup → LAN Setup → Address Reservation → Add**
2. Select main-node from the attached devices list (or enter its MAC manually)
3. Assign IP: `10.0.0.64`
4. Save

Find main-node's MAC: `ip link show eno1` — the `link/ether` value.

---

## Port forwarding (Netgear Genie)

Headscale needs two inbound ports forwarded from the router to main-node:

| Port | Protocol | Purpose |
|------|----------|---------|
| 443  | TCP      | Headscale TLS — Tailscale TS2021 handshake |
| 80   | TCP      | ACME HTTP-01 — Let's Encrypt certificate renewal |

**Advanced → Setup → Port Forwarding/Port Triggering → Add Custom Service**

Create two rules, both targeting `10.0.0.64`:

| Field            | Rule 1        | Rule 2       |
|------------------|---------------|--------------|
| Service Name     | headscale-tls | headscale-acme |
| Protocol         | TCP           | TCP          |
| External Port    | 443           | 80           |
| Internal Port    | 443           | 80           |
| Internal IP      | 10.0.0.64     | 10.0.0.64    |

---

## Cloudflare DNS

`headscale.rickermedia.com` must be **DNS-only (grey cloud)** — not proxied. If
Cloudflare proxies the record it terminates TLS and strips the Upgrade header,
breaking the handshake.

The DDNS service on main-node (`services.cloudflare-dyndns` in `headscale.nix`)
keeps the A record pointed at the current home IP automatically. The token needs
`Zone:DNS:Edit` scope for `rickermedia.com`. Provision it with:

```bash
agenix -e secrets/cloudflare-ddns-token.age
```

---

## Security

**What is exposed:** port 443 on your home IP runs headscale directly. There is no
Cloudflare WAF or DDoS protection in front of it. Port 80 is open only for ACME
certificate renewal challenges.

**What protects it:**

- *TLS* — all connections are encrypted with a valid Let's Encrypt certificate.
  Plain-text connections are rejected.
- *Tailscale's noise protocol* — the TS2021 handshake uses Noise_IK, a
  cryptographic handshake that authenticates both sides before any data flows. An
  attacker hitting port 443 cannot do anything useful without a valid pre-auth key.
- *Pre-auth keys are short-lived* — keys are generated on demand
  (`headscale preauthkeys create --expiration 1h`) and expire. A leaked key stops
  working quickly.
- *No other services share port 443* — headscale binds `0.0.0.0:443` exclusively.
  Nothing else on main-node is reachable through this port forward.

**What is not protected:** headscale itself becomes a target if a vulnerability is
discovered in it. Keep the system updated (`nixos-rebuild switch` pulls the latest
nixpkgs). The attack surface is small — headscale has no web UI exposed on this port
and the only valid operations require a pre-auth key or an existing node credential.

Port 80 is the only plaintext port open, and it only serves ACME challenge responses
(a single token string). It does not accept connections for any other purpose.
