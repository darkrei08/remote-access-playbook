# 1. The network model, or why nothing answers

Four independent layers decide whether a request reaches your service. Debug them in
this order and you never guess twice.

## Layer 1: is anything listening, and on which address

```bash
ss -tlnp
```

Read the **Local Address** column, not the process name.

| Local Address | Reachable from |
|---|---|
| `127.0.0.1:6080` | the host itself only |
| `0.0.0.0:6080` | every host interface, including `tailscale0` |
| `100.x.y.z%tailscale0:443` | the tailnet address only: this is `tailscaled` itself |
| `[::1]:5900` | the host, IPv6 loopback |

A service bound to `127.0.0.1` is not "protected by a firewall". It is simply not
reachable on any other address: the kernel refuses the connection before any firewall
rule is consulted.

## Layer 2: how Docker publishes a port

`-p 127.0.0.1:7080:6080` writes a DNAT rule whose destination match is the whole
trick:

```text
iptables -t nat -S DOCKER
ip daddr 127.0.0.1 iifname != "br-1312caa319b9" tcp dport 7080 dnat to 172.26.0.6:6080
```

A packet from a Tailscale peer has destination `100.x.y.z`. It never matches, reaches
the host stack untranslated, and finds no listening socket. The client gets
`ECONNREFUSED`, not a timeout.

Published on every interface instead:

```text
-p 8317:8317
iifname != "br-c4df796a4882" tcp dport 8317 dnat to 172.24.0.2:8317
```

No destination constraint, so tailnet traffic is translated exactly like LAN traffic.

### Reading the symptom

| Symptom | Meaning |
|---|---|
| `Connection refused`, curl exit 7 | nothing listens on that address and port |
| Timeout | packets dropped: route or firewall, not the application |
| `502` from `tailscale serve` | the proxy is up, its `127.0.0.1:PORT` target is dead |
| `404` or a blank page | right port, wrong path |

## Layer 3: namespaces make `ps` lie

The host sees every process, including the ones inside containers, with host PIDs.

```text
$ ps -o pid,ppid,args -p 1036955
1036955 1036755 /usr/bin/python3 /usr/bin/websockify --web /usr/share/novnc 6080 localhost:5900
```

That process is not on the host. It is inside a container:

```text
$ cat /proc/1036955/cgroup
0::/system.slice/docker-46acc4fb205a...scope
$ readlink /proc/1036955/ns/net
net:[4026537397]
$ readlink /proc/self/ns/net
net:[4026536560]
```

Different network namespace, therefore invisible to the host's `ss`, and its socket
inode is absent from the host's `/proc/net/tcp`. A health check built on `pgrep -f`
reports `ok` for a service that is down in your namespace.

Rule: **verify a listener with `ss`, never with a process name.** If you have to use
`ps`, compare `/proc/<pid>/ns/net` with your own first.

Real consequence, from a host with a containerized browser and a
host-side noVNC:

```text
$ webgui status
ok    websockify.*6080      # matches the container's websockify
$ ss -tln 'sport = :6080'
State Recv-Q Send-Q Local Address:Port
```

The desktop was up, x11vnc was up, the browser was up, and the web gateway was not.
`tailscale serve` answered `502` and every layer looked healthy.

## Layer 4: what the proxy is pointed at

`tailscale serve status` prints the mapping. Compare its port with the one that is
actually listening. A stale mapping is the quietest failure: everything looks
configured and nothing is connected.

```text
$ tailscale serve status
https://host.tailnet.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:6080     # nothing listens here
```

## Checklist

1. `ss -tlnp 'sport = :PORT'` has a row for the address you expect.
2. `curl -fsS --max-time 5 http://127.0.0.1:PORT/` answers on the host.
3. `tailscale serve status` targets that exact port.
4. From another device: `curl -fsS --max-time 10 https://host.tailnet.ts.net/`.
5. If 1 to 3 pass and 4 fails, the problem is the tailnet ACL, not the host.
