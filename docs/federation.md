# Federation: one public hub, many machines

Federation lets a single publicly reachable Devinorium instance (the *hub*)
front any number of private machines (*satellites*). Satellites register
with the hub over outbound HTTP; the owner picks a node in the sidebar and
the app proxies every API call to that machine through the hub. Only the
hub needs a public address; satellites can sit on a LAN, behind NAT, or on
a laptop that roams.

Each satellite is a full Devinorium server with its own database, projects,
threads, and agents. The hub keeps no copy of satellite state; it is a
registry plus a reverse proxy.

## Concepts

- **Hub**: a normal Devinorium server with `DEVINORIUM_FEDERATION_TOKEN`
  set. It accepts satellite registrations and proxies authenticated owner
  requests to the chosen node.
- **Satellite**: a normal Devinorium server with the same
  `DEVINORIUM_FEDERATION_TOKEN` plus `DEVINORIUM_HUB_URL` pointing at the
  hub. On startup it registers itself and re-registers every 30 seconds;
  that re-registration doubles as the online heartbeat.
- **Node**: a registered satellite as the hub sees it: id, name, base URL,
  version, and an online flag derived from the last heartbeat (a node
  counts as online for 90 s after its last beat).

## Setup

Generate one shared secret and use it on every machine:

```sh
openssl rand -base64 48
```

### Hub

On the public machine:

```sh
DEVINORIUM_FEDERATION_TOKEN=<shared-secret>
```

plus the usual public-facing settings (`DEVINORIUM_SECURE_COOKIE=true`,
a reverse proxy terminating TLS, and so on).

### Satellite

On each private machine:

```sh
DEVINORIUM_FEDERATION_TOKEN=<shared-secret>
DEVINORIUM_HUB_URL=https://hub.example
DEVINORIUM_NODE_NAME=workstation          # optional; defaults to hostname
DEVINORIUM_NODE_URL=http://192.168.1.10:7878  # optional; see below
```

`DEVINORIUM_NODE_URL` is the address the **hub** dials to reach the
satellite. If unset, the satellite reports its bound address (fine when the
hub is on the same LAN). Set it when the hub cannot reach the satellite's
bind address directly, for example a Tailscale address, a tunnel endpoint,
or a port-forward. The satellite keeps working standalone; the hub just
cannot proxy to it until the URL is reachable.

Satellites never need inbound connectivity from the public internet. They
do need to reach the hub (to register) and the hub needs to reach them (to
proxy). If the hub cannot reach the satellite at all, use a tunnel both
ways, for example put the satellite on the same Tailnet as the hub and
advertise `DEVINORIUM_NODE_URL=https://<machine>.tailnet.ts.net` (see
`docs/deployment.md` for Tailscale serve).

## Using it

The owner sees a node picker in the sidebar once at least one satellite is
registered. Selecting a node switches the whole app (threads, projects,
files, git, terminal, composer) to that machine, the same way switching
servers does. Choosing the hub entry switches back.

A satellite that misses heartbeats shows as offline; requests to it return
`502` until it re-registers. Nodes can be deregistered under Settings →
Servers → Nodes.

Non-owner accounts never see federation data: listing nodes and every
proxied call are owner-only.

## How it works

- `POST /api/federation/register`: satellites announce themselves with
  `Authorization: Bearer <federation-token>`. No session needed; the shared
  token is the credential.
- `GET /api/federation/nodes`: owner-only node list.
- `DELETE /api/federation/nodes/:id`: owner-only deregistration.
- `ANY /api/federation/nodes/:id/proxy/*`: the hub forwards the request to
  the satellite's `base_url`, replacing the caller's credentials with the
  federation token (which the satellite maps onto its local owner account).
  Plain requests stream both ways, so SSE message streams work; WebSocket
  upgrades are tunneled frame-for-frame so remote terminals work.
- A hop-count header caps forwarding so a misconfigured ring of hubs fails
  fast instead of looping.

## Security notes

- Treat `DEVINORIUM_FEDERATION_TOKEN` like a root password for the whole
  fleet: anyone holding it can register a node and authenticate as owner on
  any machine configured with it, hub included. Keep it out of version
  control and out of logs.
- The token is a bearer credential, so proxy hops must run over TLS or a
  trusted private path (Tailnet). Never proxy over plain public HTTP.
- A satellite trusts any request carrying the token: firewall it so only
  the hub (or your tailnet) can reach it.
- Session cookies never cross the proxy: the hub strips `Cookie`,
  `Authorization`, `Origin`, and forwarding headers before contacting the
  satellite and injects the federation token instead.
