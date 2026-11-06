# 4. CLI logins without a local browser

`gh`, `gcloud`, `wrangler`, `aws sso login`, most "sign in with" CLIs assume a browser
on the same machine. On a headless box that fails in two different ways, and the fixes
are different.

## The two failure modes

1. **Device flow.** The CLI prints a URL and a code, waits, and polls. Any browser
   anywhere can complete it. Failure looks like "your browser will not open
   automatically, visit this URL".
2. **Loopback callback.** The CLI starts a listener on `127.0.0.1:<port>`, opens that
   URL, and waits for the identity provider to redirect back with a code. A browser on
   another machine cannot deliver that redirect, because `127.0.0.1` means the browser's
   own machine. Failure looks like a page that cannot connect after you approve, and
   the login never completes.

Diagnose which one you have by watching what the CLI does: if it prints a code to type,
it is device flow; if it opens a localhost URL with a `redirect_uri` pointing at
`127.0.0.1`, it is a loopback callback.

## Option 1: a browser inside the box

The most general fix, and the only one that works from a phone. Put a real browser on
the same loopback as the CLI, then reach it over noVNC. See
[docs/03](03-browser-access.md).

Then make CLIs use it:

```bash
printf '#!/bin/sh\nexec /usr/local/bin/webgui open "$1"\n' > /usr/local/bin/open-url
chmod +x /usr/local/bin/open-url
ln -sf /usr/local/bin/open-url /usr/local/bin/xdg-open
echo 'export BROWSER=/usr/local/bin/open-url' >> /root/.bashrc
export BROWSER=/usr/local/bin/open-url
```

`$BROWSER` covers the polite tools; the `xdg-open` symlink covers the ones that call it
directly. `webgui open` uses Firefox remoting over DBus, so it adds a tab to the
existing instance instead of starting a second process against the same profile.

Test:

```bash
webgui open https://example.com
```

Typical flows:

```bash
gh auth login --hostname github.com --git-protocol ssh --web
gcloud auth login
```

The tab opens in the remote Firefox, you complete the login from your laptop or phone,
the loopback callback lands on the box because the browser is also on the box, and the
CLI finishes. No port forwarding, no copy of codes.

## Option 2: forward the callback port

When you want to use your own laptop browser but the CLI insists on `127.0.0.1`, forward
only that port:

```bash
ssh -L 8085:127.0.0.1:8085 root@<host>
```

The redirect to `127.0.0.1:8085` on your laptop is then delivered through the tunnel to
the CLI's listener. Read the port from the CLI output; the common ones are 8085, 1455,
54545, 51121, 11451 for OAuth providers and 3000 for assorted dev tools. Keep those
ports on loopback permanently in compose: they are only needed during account linking,
and they are never needed remotely.

## Option 3: skip the browser with a token

For automation and CI, a token is simpler than a browser. Create it in the provider's
settings page from your own machine.

```bash
install -m 600 /dev/null /root/.config/gh-token.env
printf 'GITHUB_TOKEN=ghp_xxxxxxxxxxxx\n' > /root/.config/gh-token.env
printf 'set -a; [ -f /root/.config/gh-token.env ] && . /root/.config/gh-token.env; set +a\nexport GH_TOKEN="${GITHUB_TOKEN:-}"\n' >> /root/.bashrc
source /root/.bashrc && gh api user --jq .login
```

A token also solves the anonymous GitHub API limit, which bites during plugin and tool
installation: 60 requests per hour per IP anonymously, 5000 with a token.

```bash
curl -fsS --max-time 10 https://api.github.com/rate_limit | jq '.rate'
```

For a machine that hosts an autonomous agent, prefer a **deploy key per repository** or
a **GitHub App** over your personal token. Revoking a deploy key does not touch your
account, and the blast radius is one repository.

```bash
ssh-keygen -t ed25519 -C "host" -f /root/.ssh/id_ed25519 -N ""
gh ssh-key add /root/.ssh/id_ed25519.pub --title "host"
ssh -T git@github.com
```

## Which option

| Situation | Option |
|---|---|
| Phone, or no SSH client available | 1, browser in the box |
| You have SSH and only the callback fails | 2, `ssh -L` |
| Unattended agent, no human at the keyboard | 3, token or deploy key |
| Provider forces a passkey | 2, with your own device's authenticator |

Passkeys and WebAuthn cannot complete inside a remote desktop: the authenticator is on
your hardware. Use TOTP, an app password, or a token for those providers.
