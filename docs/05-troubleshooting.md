# 5. Troubleshooting

Start from the symptom. Every entry here was observed on a real host, not guessed.

## Triage in four commands

```bash
ss -tlnp                                  # what listens, on which address
curl -fsS --max-time 5 http://127.0.0.1:PORT/ -o /dev/null -w '%{http_code}\n'
tailscale serve status                    # what the proxy targets
tailscale status | head -3                # is the node even up
```

`Connection refused` is nothing listening. `Timeout` is a drop. `502` from Serve is a
dead target behind a live proxy. A wrong path is `404`.

## Status says ok and the page does not load

The most expensive failure of the whole setup. A health check on a process name matches
a process from another container:

```text
$ webgui status
ok    websockify.*6080
$ ss -tln 'sport = :6080'
State Recv-Q Send-Q Local Address:Port
```

Nothing is listening, and `pgrep` found the websockify that belongs to a containerized
browser on a different network namespace. The host's own gateway was simply never
started.

Confirm the namespace before trusting any process check:

```bash
readlink /proc/<pid>/ns/net
readlink /proc/self/ns/net
```

Different inode, different namespace, not your listener. Fix the check, then the
service:

```bash
# replace a pgrep check with a socket check
ss -tln 'sport = :6080' | grep -q ':6080' && echo ok || echo GIU
```

```bash
webgui restart
ss -tlnp 'sport = :6080'
```

## 502 Bad Gateway from Tailscale

Serve is up and its target refused the connection.

```bash
ss -tln 'sport = :6080'        # is the target listening at all
websockify --web=/usr/share/novnc 6080 localhost:5900
```

Run it in the foreground once: the real error appears there and nowhere else, which is
also why a gateway started with output to `/dev/null` is undiagnosable. Then start it
properly and confirm the socket exists.

## The site is gone after `tailscale serve off`

`tailscale serve --https=443 off` deletes the handler. It does not pause it. There is no
`on`, and the stack underneath is untouched, so every other check still passes.

```bash
tailscale serve --bg --https=443 http://127.0.0.1:6080
tailscale serve status
```

## Firefox: "profile missing" or "already running"

Almost always a second process launched with `--no-remote` against the same profile, or
locks left by a `SIGKILL`.

```bash
pgrep -af firefox
pkill -f firefox-esr && sleep 2
rm -f /root/.mozilla/firefox/remote/.parentlock /root/.mozilla/firefox/remote/lock
webgui start
```

The `--no-remote` flag disables exactly the remoting that would have prevented the
conflict. Start the main instance without it, and open URLs with
`firefox -P remote --new-tab <url>`, which talks to the running instance. On Linux that
channel is DBus, which is why the stack keeps a session bus and why
`MOZ_LEGACY_PROFILES=1` and `HOME=/root` are set explicitly for non-interactive
starts.

If the profile is not registered:

```bash
cat /root/.mozilla/firefox/profiles.ini
HOME=/root DISPLAY=:99 firefox-esr --no-remote -CreateProfile "remote /root/.mozilla/firefox/remote"
webgui restart
```

## Black screen in noVNC

```bash
DISPLAY=:99 xdpyinfo | head -5     # does the display exist
pgrep -af firefox-esr              # is anything drawing on it
webgui logs
```

A live display with no browser is a browser crash. A missing display is Xvfb, and
Xvfb usually dies because of a leftover lock:

```bash
webgui stop
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
webgui start
```

## noVNC: "Failed to connect to server"

The web gateway is up and the VNC server it forwards to is not.

```bash
ss -tlnp 'sport = :5900'
x11vnc -display :99 -rfbport 5900 -localhost -rfbauth /root/.vnc/passwd -forever -shared -bg -quiet
```

## Text renders as boxes

No fonts.

```bash
apt install -y fonts-liberation fonts-dejavu fonts-noto-core fonts-noto-color-emoji
fc-cache -fv
webgui restart
```

## `command not found` right after installing

Not a failed install, an incomplete `PATH`. Some templates set `PATH` without appending
the existing one, and `/usr/local/bin` disappears.

```bash
echo "$PATH"
command -v webgui websockify x11vnc Xvfb
```

```bash
echo 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"' >> /root/.bashrc
```

## OAuth popup invisible or not clickable

No window manager, so the popup exists, focused by nothing, positioned nowhere.

```bash
DISPLAY=:99 openbox >/dev/null 2>&1 &
```

## Clipboard works in one direction

```bash
apt install -y autocutsel
webgui restart
```

Both directions need the two `autocutsel` instances the script starts: the default
selection and `PRIMARY`. For long tokens, use the noVNC side panel Clipboard anyway.

## Window is small with black borders, or text is tiny

```bash
webgui fit
webgui zoom 1.5
webgui res 1920x1080
```

Zoom is a global UI scale and persists in `/etc/webgui.conf` and the profile's
`user.js`. Page zoom in the browser is per site and is not what you want.

## Pasted commands arrive corrupted

The Proxmox web console and `pct enter` mangle long pastes, overwriting the middle of
lines. Symptom: a script truncated mid-line, or
`syntax error near unexpected token '('` because output text came along with the
commands.

Validate before believing:

```bash
bash -n /usr/local/bin/webgui && echo INTEGRO
sha256sum /usr/local/bin/webgui
```

Work around it with SSH instead of the console, with `nano`, or by shipping the file in
base64 chunks and checking the hash after decoding.

## CDP does not listen on 9222

Since Chrome 136, `--remote-debugging-port` is ignored unless `--user-data-dir` is also
given.

```bash
chromium --headless --no-sandbox --disable-dev-shm-usage \
  --user-data-dir=/root/.cache/cdp-profile --remote-debugging-port=9222 &
ss -tlnp 'sport = :9222'
```

## Serve works, another device still cannot connect

The host is fine and the ACL is not. Check, in the admin console:

- the device is authorised and the key has not expired;
- a grant or ACL rule allows your source to that destination and port;
- for a Service, the advertisement is approved, not pending;
- you are not connecting to the wrong tailnet address (a stale `100.x` after a re-auth).

```bash
tailscale status
tailscale ping <peer>
```

## Order of operations that wastes the least time

1. `ss` for the listener.
2. `curl` on loopback for the app.
3. `tailscale serve status` for the mapping.
4. `curl` from a peer for the ACL.
