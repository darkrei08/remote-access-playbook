# Remote Access Playbook

How to reach a headless Linux host over Tailscale: a VNC desktop, a real browser that
you and an AI agent can share, and the login flows that CLI tools need.

Everything here comes from a working Debian 13 host that runs Docker services, a
headless Firefox on Xvfb behind noVNC, and a containerized browser driven by an agent.
The failure modes documented here are the ones that actually happened, including two
that look like firewall problems and are not.

## The rules, in order

1. **A service is unreachable until something listens on a reachable address.** Run
   `ss -tlnp` before you touch a firewall.
2. **`-p 127.0.0.1:PORT:PORT` means loopback only.** Only a proxy that runs on the same
   loopback can help, and that is exactly what Tailscale Serve is.
3. **Never audit a process by name.** The host sees processes from every container, so
   `pgrep` reports services that are not listening in your network namespace.
4. **Path prefixes break web consoles.** Give every UI its own port.
5. **Serve is tailnet-only; Funnel is the internet.** They are different commands and
   different risks.

## Choose the method

| Need | Method | Doc |
|---|---|---|
| Several web UIs on one host | `tailscale serve` per port | [docs/02](docs/02-tailscale-access.md) |
| A name that survives replacing the host | Tailscale Services | [docs/02](docs/02-tailscale-access.md#tailscale-services) |
| Full desktop, or a browser shared with an agent | noVNC on loopback, then Serve | [docs/03](docs/03-browser-access.md) |
| CLI OAuth login with a loopback callback | browser inside the box, or `ssh -L` | [docs/04](docs/04-cli-login.md) |
| Something does not answer | failure taxonomy | [docs/05](docs/05-troubleshooting.md) |
| Before exposing anything | exposure rules | [docs/06](docs/06-security.md) |

## Quick start

Install and join the tailnet:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh
```

Expose one loopback web UI, one HTTPS port per UI:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:6080
tailscale serve status
```

Verify from another tailnet device:

```bash
curl -fsS --max-time 10 "https://<host>.<tailnet>.ts.net/vnc.html" -o /dev/null -w '%{http_code}\n'
```

`200` means the whole chain works. `502` means the proxy is fine and its target is
dead. `Could not connect` means nothing listens on any address.

## Scripts

- `scripts/webgui` — one idempotent command for a headless Firefox desktop
  (Xvfb + Openbox + DBus + Firefox ESR + x11vnc + noVNC).
  Subcommands: `start stop restart status url open fit zoom res reset logs`.
- `scripts/exposure-audit.sh` — what listens outside loopback, what Docker publishes,
  what Serve and Funnel currently expose.

## Reading order

New to this: [docs/01](docs/01-network-model.md) explains why ports fail, then
[docs/02](docs/02-tailscale-access.md) and [docs/03](docs/03-browser-access.md) give
the two working patterns. In a hurry and something is down: go straight to
[docs/05](docs/05-troubleshooting.md).

## License

MIT. See [LICENSE](LICENSE).
