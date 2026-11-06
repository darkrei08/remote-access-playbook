# 3. Graphical access: VNC, a real browser, and the agent

Two working patterns. Pick by who needs the pixels.

- **Pattern A, browser in a container.** A full desktop with a browser inside a
  container, noVNC published on loopback. You can watch and drive it, and an agent
  drives the same window over CDP or MCP. Login state persists in a volume.
- **Pattern B, browser on the host.** Xvfb plus Firefox plus x11vnc plus noVNC, driven
  by `scripts/webgui`. Roughly a third of the memory, no Docker, but the agent has no
  clean programmatic handle on it.

Both end the same way: something listens on `127.0.0.1`, and Tailscale Serve publishes
it. See [docs/01](01-network-model.md) if that sentence does not yet make sense.

## Pattern A: a browser shared with the agent

The point of this pattern is a single session with two drivers. You log in by hand
once, the cookies live in a volume, and afterwards the agent operates a browser that is
already authenticated while you watch in noVNC and can take over at any moment.

An example compose service. Any image that exposes noVNC plus CDP or MCP fits; the
BrowserOS neo image is used here because it does both.

```yaml
services:
  browser:
    image: ghcr.io/browseros-ai/neo:latest
    restart: unless-stopped
    shm_size: 1g
    environment:
      NEO_SCREEN: 1600x1000
      NEO_SANDBOX: "false"
    ports:
      # noVNC for humans. Loopback only: Serve publishes it to the tailnet.
      - "127.0.0.1:7080:6080"
      # Agent endpoint. Never publish this anywhere else. See docs/06.
      - "127.0.0.1:9010:9010"
    volumes:
      - ./data/browser:/data
```

Publish the human view and nothing else:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7080
tailscale serve status
```

Open `https://<host>.<tailnet>.ts.net/`. This image redirects `/` to
`vnc.html?autoconnect=1&resize=remote`; a bare `websockify --web` serves `/vnc.html`
directly, so use that path when the root is a directory listing.

The agent connects to `http://127.0.0.1:9010/mcp` on the same host. A `406` on a plain
`GET` is the normal answer from a Streamable HTTP MCP endpoint: it wants the MCP
headers, and it proves the service is up.

### Why the session is shared, and what it costs

- Login once in noVNC, in the container browser. The profile directory is the volume.
- The agent then sees an authenticated browser without handling your credentials.
- Memory: a desktop plus Chromium is 1.5 to 2 GB. Budget it.
- The profile directory is a credential. Back it up encrypted, never commit it.

## Pattern B: a headless Firefox desktop on the host

Stack: Xvfb (virtual display) + Openbox (window manager) + a session DBus + Firefox ESR
+ x11vnc (VNC server on loopback) + websockify/noVNC (browser client).

About 350 MB while running, zero when stopped, no Docker.

### Install

```bash
apt install -y xvfb x11vnc novnc websockify openbox firefox-esr dbus-x11 jq curl
apt install -y fonts-liberation fonts-dejavu fonts-noto-core fonts-noto-color-emoji x11-xserver-utils
apt install -y xdotool wmctrl autocutsel
```

Each package earns its place: without the window manager OAuth popups cannot be moved
or focused, without `dbus-x11` Firefox remoting fails, without the font packages pages
render as boxes, without `autocutsel` copy and paste works in one direction only.

VNC password:

```bash
mkdir -p /root/.vnc && x11vnc -storepasswd /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
```

### The script

`scripts/webgui` starts, stops and inspects the whole stack and is idempotent: it
detects what is already running and starts only what is missing.

```bash
install -m 755 scripts/webgui /usr/local/bin/webgui
bash -n /usr/local/bin/webgui && echo INTEGRO
webgui restart
webgui status
```

```text
ok    Xvfb :99
ok    openbox
ok    firefox.*-P remote
ok    x11vnc
ok    websockify.*6080
port  127.0.0.1:5900
port  [::1]:5900
geom  1920x1080  zoom 1.25
dbus  presente
prof  remote registrato
serve attivo su 6080
```

`status` reports `ok` only for a process that lives in this host's network namespace, and
it prints a separate `gate` line for the gateway socket, because a live process is not
proof of a listener:

```text
ok    websockify 6080
gate  in ascolto su 6080
```

`GATE NESSUN LISTENER` means the web gateway is down even when every other line says
`ok`. The three ways that check used to lie are documented in
[docs/05](05-troubleshooting.md#a-process-check-says-ok-and-the-page-does-not-load).

### Commands

| Command | Effect |
|---|---|
| `webgui start` | start missing components, leave running ones alone |
| `webgui stop` | stop everything, free the memory, clear the locks |
| `webgui restart` | `stop` then `start` |
| `webgui status` | processes, ports, DBus, profile, Serve state |
| `webgui url` | the noVNC URL, Tailscale name or LAN IP |
| `webgui open <url>` | new tab in the existing instance over DBus remoting |
| `webgui fit` | maximise the browser window on the virtual display |
| `webgui zoom <f>` | UI scale factor, `1.25`, `1.5`, `1.75` |
| `webgui res <WxH>` | virtual display resolution, then restart |
| `webgui reset` | destructive: delete the profile and the bus |
| `webgui logs` | last lines of `/var/log/webgui.log` |

### Publish

```bash
tailscale serve --bg --https=443 http://127.0.0.1:6080
webgui url
```

### Display tuning

Three problems show up on the first connection and none of them is a bug.

- **Black borders.** Openbox does not maximise new windows, so Firefox opens smaller
  than the display. `webgui fit`.
- **Text too small.** The display is 96 DPI, fixed. Do not use page zoom, which is per
  site. `webgui zoom 1.5` changes the whole UI scale and survives restarts, since it is
  written to `/etc/webgui.conf` and into the profile's `user.js`.
- **Bandwidth.** `webgui res 1280x800` for a phone, `1920x1080` for a desktop. Lower
  resolution beats higher compression.

| Device | Resolution | Zoom |
|---|---|---|
| Desktop 1080p | `1600x900` | `1.25` |
| Desktop 1440p or 4K | `1920x1080` | `1.5` |
| Tablet | `1440x900` | `1.5` |
| Phone | `1280x800` | `1.75` |

### Clipboard and mobile

- Copy and paste both ways needs `autocutsel`, which the script starts when present.
- For long tokens and OTP codes the noVNC side panel **Clipboard** is the reliable
  route, not the native clipboard.
- On a phone, open `/vnc.html`, add to home screen, and use the panel keyboard icon.
- **Passkeys and WebAuthn do not work over VNC.** The authenticator lives on your
  device, not in the container. Use TOTP, an app password, or an API token.
- To show someone without giving control, either enable **View Only** in noVNC or start
  a second read-only server:

```bash
x11vnc -display :99 -rfbport 5901 -localhost -viewonly -rfbauth /root/.vnc/passwd -forever -shared -bg -quiet
```

### Files downloaded inside the desktop

They stay in the box:

```bash
ls -lt /root/Downloads 2>/dev/null
scp root@<host>:/root/Downloads/file ./
```

## Giving the agent a programmatic browser

VNC is for you. An agent should use CDP or a scraping API, on loopback, on the same
host.

```bash
chromium --headless --no-sandbox --disable-dev-shm-usage \
  --user-data-dir=/root/.cache/cdp-profile \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 &
curl -fsS --max-time 5 http://127.0.0.1:9222/json/version | jq -r .Browser
```

Since Chrome 136 the `--remote-debugging-port` flag is ignored without an explicit
`--user-data-dir`. If CDP silently does not listen, that is why.

A CDP endpoint is arbitrary code execution plus every authenticated session in that
profile. Loopback only, never through Serve, never through Funnel. If another host
needs it, tunnel it:

```bash
ssh -L 9222:127.0.0.1:9222 root@<host>
```

## Which pattern

| | Pattern A, container | Pattern B, host |
|---|---|---|
| Memory | 1.5 to 2 GB | ~350 MB |
| Agent has CDP or MCP | yes, by design | only if you add a headless browser |
| Shared authenticated session | yes | no |
| Isolation from your real profile | yes | no, it is the box |
| Setup | compose plus one serve command | packages plus one script |
| Right for | agent work with real logins | OAuth logins, quick checks, low resources |

They compose: run Pattern A for the agent, Pattern B for the occasional login that
needs a real window, and only one of them gets port 443.
