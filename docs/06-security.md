# 6. Security

The tailnet is the authentication layer. Treat every decision here as "what happens if
this port answers someone I did not intend".

## The three exposures, from safe to worst

| Exposure | Reachable by | Use when |
|---|---|---|
| `127.0.0.1:PORT` | the host itself | default for everything |
| `tailscale serve` | your tailnet, over TLS, subject to ACL | web UIs you need remotely |
| `tailscale funnel` | the internet | almost never |

Publishing a port on `0.0.0.0` is not a fourth, middle option. It is the same as
"everyone who can route to this host": LAN, and internet too if any router forwards to
it. That happens by accident more often than by decision, because a compose file that
publishes `"3389:3389"` and a router with UPnP is all it takes.

## Rules

1. **Loopback by default.** Every service binds `127.0.0.1` unless you can name the
   authenticated proxy in front of it.
2. **Serve, not `0.0.0.0`, to fix remote access.** It does not expose the port, it
   terminates TLS with the tailnet certificate, and the ACL still applies.
3. **One UI per port.** Path prefixes on a single port put unrelated apps behind the
   same origin, and their cookies and service workers then share a scope.
4. **Funnel is a publishing decision.** It needs an ACL `nodeAttrs` permission and it
   makes the service public. Never enable it to "see if it works".
5. **Tagged nodes are not you.** A device joined with `--advertise-tags` loses
   user-derived identity in ACLs. Decide the tag before you join, not after.

## What each kind of service actually grants

| Service | What access means |
|---|---|
| VNC / noVNC | full control of a desktop, with every session in it |
| Browser profile volume | every cookie, token and login stored in that browser |
| CDP on 9222 | arbitrary code execution as that user, in that profile |
| MCP endpoint | tool calls the agent can make, including file and network access |
| Scraper APIs | outbound requests from your IP, sometimes with your credentials |
| Admin consoles | the system itself: containers, databases, accounts |

A browser profile is a credential. It holds live session cookies, so a copy of it is as
sensitive as an unencrypted password database. Encrypt backups, never commit the
directory, never import a production profile into a throwaway stack.

CDP deserves its own line: an open debugging port is a remote shell that can read every
page the browser can read. Loopback only, never behind Serve, and if another host needs
it use `ssh -L`.

## Isolate the agent's browser

An autonomous agent navigates untrusted pages. Do not give it the profile that is logged
into your mail, GitHub, and bank. Give it a container with its own volume, and log into
it only for the accounts the task needs. Two separate volumes cost nothing and contain
the damage of one compromised page.

The same logic applies to tokens: a deploy key per repository or a GitHub App for the
host, not a personal token with `repo` scope over everything.

## X11 and VNC specifics

- Always `x11vnc -localhost`. It is the flag that keeps the VNC server off every
  interface; nothing else does.
- Set a real VNC password (`x11vnc -storepasswd`, file mode `600`). noVNC itself has no
  authentication: whoever reaches the gateway reaches the password prompt.
- The session DBus address file lets a local user inject commands into the running
  Firefox. Keep it at `0600`.
- The Firefox profile stores cookies in the clear on disk. Full-disk encryption or an
  encrypted backup, not both optional.

## Audit what is exposed

Run this before and after any change, and after every `docker compose up` that someone
else wrote:

```bash
ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]'
tailscale serve status
tailscale funnel status
docker ps --format '{{.Names}}\t{{.Ports}}'
```

`scripts/exposure-audit.sh` runs all four and flags the differences.

A clean host shows: services on `127.0.0.1`, `tailscaled` on the tailnet address, Docker
publishing on loopback, and Funnel empty.

## Revoking access

```bash
tailscale serve --https=8787 off     # one UI
tailscale serve reset                # everything on this host
```

Then remove the device or the grant in the admin console. Removing a Service host is
different: drain it first, or you cut live connections.

```bash
tailscale serve drain svc:web-server
tailscale serve clear svc:web-server
```

## What never enters a public repository

- `.env` and any file with a key, token, or password.
- Browser profile directories and their backups.
- Screenshots of authenticated pages.
- Your tailnet name and tailnet IPs inside example commands. Use `<tailnet>`,
  `<host>`, `100.x.y.z`. Not because they are secrets, but because a public repository
  is not the place to publish the map of your network.
- Private hostnames and the real LAN range, for the same reason.

```bash
grep -rInE 'ts\.net|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' docs README.md
```

Any hit should be a placeholder, a loopback address, or a documented example range.

## Rationale in one line

Remote access fails because of addresses, not firewalls, and it becomes dangerous
because of convenience, not attackers. Keep the default loopback, put Serve in front of
what you need, and write down why each exception exists.
