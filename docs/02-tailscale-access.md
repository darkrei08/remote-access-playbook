# 2. Reaching services over Tailscale: Serve and Services

Two different problems, two different tools.

- **Serve** answers "publish this port of this host on my tailnet, with TLS".
- **Services** answer "give this application a name that does not belong to a host".

Use Serve for one machine. Use Services when the name must outlive the machine, or
when several machines serve the same application.

## Tailscale Serve

Serve terminates TLS with the tailnet certificate, listens on the tailnet interface
only, and forwards to a target on the same host. Nothing is published to the internet.

Requirements: HTTPS certificates enabled for the tailnet (admin console, DNS page).
The `*.ts.net` certificate is provisioned automatically.

### One port per UI

```bash
tailscale serve --bg --https=443 http://127.0.0.1:6080
tailscale serve --bg --https=8787 http://127.0.0.1:8787
tailscale serve status
```

```text
https://host.tailnet.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:6080

https://host.tailnet.ts.net:8787 (tailnet only)
|-- / proxy http://127.0.0.1:8787
```

`--bg` makes the configuration persist across `tailscaled` restarts. The mapping lives
in `tailscaled`'s state, not in a file you edit.

### Why not one port with path prefixes

```bash
# do not do this for web consoles
tailscale serve --bg --https=443 --set-path=/vnc http://127.0.0.1:6080
```

A web console loads its assets and opens its WebSocket against absolute paths
(`/app/`, `/vnc.html`, `/websockify`). Behind a prefix both resolve outside it and the
page half-loads. Path prefixes are fine for plain HTTP APIs that already live under a
base path; they are not fine for noVNC, websockify, or anything that computes URLs from
`window.location`.

Give each console its own HTTPS port. There is no cost beyond a line in the config.

### The `off` trap

```bash
tailscale serve --https=443 off     # removes the handler
```

It removes, it does not pause. There is no `on`:

```text
error: failed apply web serve: non-localhost target "http://on" must include a scheme
```

Recreate the mapping by repeating the original command. `tailscale serve reset` removes
every mapping on the host.

### Plain TCP instead of HTTPS

When you do not want TLS termination, or the protocol is not HTTP:

```bash
tailscale serve --bg --tcp=6080 tcp://127.0.0.1:6080
```

The service is then reachable at `http://100.x.y.z:6080`, in clear text inside the
tailnet. Acceptable for a personal tailnet, not for anything shared.

### Verify

```bash
ss -tlnp 'sport = :443'          # tailscaled listening on the tailnet address
tailscale serve status           # mapping targets the port that is really open
curl -fsS --max-time 5 http://127.0.0.1:6080/ -o /dev/null -w '%{http_code}\n'
```

Then, from another device on the tailnet:

```bash
curl -fsS --max-time 10 https://host.tailnet.ts.net/ -o /dev/null -w '%{http_code}\n'
```

## Tailscale Services

A Service is a named resource with its own identity in the tailnet. Clients connect to
`https://<service>.<tailnet>.ts.net` and Tailscale routes to whichever hosts currently
advertise that Service. The name is decoupled from the machine, so replacing,
renaming, or load-balancing hosts does not change your bookmarks.

The result is that you stop bookmarking `IP:port`. You bookmark one name per
application.

### What it costs you

A Service is not a one-liner in a personal tailnet. Before it works you need:

1. **A tagged advertising host.** The node that advertises must carry a tag, because a
   Service has no user identity of its own. Either join with an auth key created with
   `--advertise-tags=tag:server`, or convert:

   ```bash
   tailscale up --advertise-tags=tag:server
   ```

   Tagged nodes are not "your device" for ACL purposes any more, and cannot be used
   with some user-only features. Decide that deliberately.

2. **The Service defined in the admin console**, with its endpoints.

3. **Approval of the advertisement.** Administrators approve or deny new Service hosts,
   exactly like subnet routes. Auto-approval is a policy keyed on services and tags:

   ```json
   {
     "autoApprovers": {
       "services": {
         "svc:web-server": ["tag:server"]
       }
     }
   }
   ```

4. **A grant so clients can reach it.** Being on the tailnet is not enough:

   ```json
   {
     "grants": [
       {
         "src": ["autogroup:member"],
         "dst": ["svc:web-server"],
         "ip": ["tcp:443"]
       }
     ]
   }
   ```

### Advertise

```bash
tailscale serve --service=svc:web-server --https=443 127.0.0.1:8080
tailscale serve status
```

Reachable at `https://web-server.<tailnet>.ts.net`.

Multiple endpoints and paths are allowed, same syntax as Serve:

```bash
tailscale serve --service=svc:web-server --https=443 8080
tailscale serve --service=svc:web-server --https=443 --set-path /api 8081
tailscale serve --service=svc:web-server --http=80 3000
```

### Replicas

Several hosts can advertise the same `svc:web-server`. Tailscale spreads connections
across the available hosts, which is the reason Services exist at all. A single host
gains only the stable name.

### Remove safely

Drain first, so open connections are not cut mid-flight, then remove the endpoint:

```bash
tailscale serve drain svc:web-server
tailscale serve --service=svc:web-server --https=443 off
tailscale serve clear svc:web-server
```

Removing an endpoint before draining abruptly ends every connection to it.

### Configuration file mode

For many endpoints, use `serveconfig.json` and advertise in two steps: write the
config, then `tailscale serve advertise svc:<service-name>`. This is the only mode that
lets you configure several endpoints in one atomic change.

### Automating it per container

Tools such as DockTail watch Docker labels and create or update Services as containers
come and go, so a `docker compose down/up` cycle keeps the DNS names correct. They are
a controller, not a per-container sidecar: one process, no image change. Worth it when
you run more than a handful of containers; unnecessary for three.

### Verify

```bash
tailscale status --json | jq '.Self.CapMap'      # capability advertisement
tailscale serve status                           # configured endpoints
```

In the admin console, the Service appears under **Advertised** with its endpoints. If
the advertisement is pending approval, it is not reachable yet.

## Choosing between them

| | Serve | Services |
|---|---|---|
| Name | `<host>.<tailnet>.ts.net` | `<service>.<tailnet>.ts.net` |
| Survives replacing the host | no | yes |
| Multiple backends | no | yes |
| Prerequisites | HTTPS certificates | tag, Service definition, approval, grant |
| Setup effort | one command | four steps, admin console involved |
| Right for | one homelab host | replicated or rotating hosts |

For a single host, Serve per port is the correct answer and Services are ceremony. Add
Services the day you have a second machine serving the same thing, or the day you get
tired of re-pointing bookmarks after a host rename.
