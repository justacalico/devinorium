# Federation: one hub, many execution machines

Federation lets a normal Devinorium server (the *hub*) run agents on any
number of remote machines (*satellites*). A satellite is the same binary
started in satellite mode: stateless, no database, no accounts, no UI. It
exists only to execute agents and machine-local services (files, git,
terminals, clones) for the hubs that paired with it.

## Concepts

- **Hub**: your normal Devinorium instance with its database, accounts,
  projects, and UI. It pairs with satellites and routes work to them.
- **Satellite**: a Devinorium binary started with `DEVINORIUM_SATELLITE=1`.
  It keeps a node identity and issued tokens in a single state file under
  its data directory; losing the file only means re-pairing. Everything
  else is in-memory.
- **Node**: a paired satellite as the hub sees it: id, name, base URL,
  version, and an online flag from a live probe.
- **Pairing**: a one-time exchange. The satellite prints a pairing code on
  startup; the hub owner enters the satellite's URL and code; the hub
  receives a per-node bearer token it stores and uses for every later
  call.

## Setup

### Satellite

On each machine that should run agents:

```sh
DEVINORIUM_SATELLITE=1
DEVINORIUM_NODE_NAME=workstation   # optional; defaults to hostname
DEVINORIUM_HOST=0.0.0.0            # default in satellite mode
DEVINORIUM_PORT=7878               # default port
```

On startup the satellite prints:

```
Devinorium satellite (workstation) listening on 0.0.0.0:7878

  Pairing code: ABCD-EFGH-IJKL-MNOP

  In your main instance go to Settings -> Nodes, enter
  this server's URL and the code above, then pair.
```

The code pairs exactly one hub and rotates on every boot; re-pairing
after a hub change needs a satellite restart for a fresh code. The hub
must be able to reach the
satellite's address; nothing dials outbound from the satellite, so it can
sit anywhere the hub can connect to (LAN, Tailnet, a tunnel).

### Hub

On the hub, go to Settings -> Servers -> Nodes, press "Pair a machine",
and enter the satellite's URL (for example `http://192.168.1.10:7878`) and
the code it printed. The hub verifies the address is a satellite, exchanges
the code for a node token, and stores the pairing.

## Using it

When creating a project (existing path, new folder, or git clone) the
dialog offers a machine picker: this server or any paired node. All work
for that project runs on the chosen machine: agents, files, git
operations, worktrees, terminals, and model listings.

A node that stops answering shows as offline in the node list; requests to
it fail until it comes back. Removing a node drops the stored token; the
satellite forgets the pairing on its next restart, or immediately if you
delete its state file.

Non-owner accounts never see federation data: pairing, listing, and any
project bound to a node are owner-only.

## How it works

- `GET /api/node/info`: unauthenticated identity probe (`satellite: true`,
  node id, name, version).
- `POST /api/node/pair`: exchanges the printed code for a node token.
  Wrong codes are rate-limited per client address and lock out briefly
  after repeated failures.
- Everything else under `/api/node/*` requires
  `Authorization: Bearer <node-token>`: runs (with server-sent events for
  session updates), provider operations, files, git, terminals, and
  clones.
- Hub-side: `GET /api/federation/nodes` (owner-only list, with a live
  online probe), `POST /api/federation/nodes/pair`, and
  `DELETE /api/federation/nodes/:id`.
- `projects.node_id` binds a project to a node. The hub resolves that
  binding at request time and forwards the call to the satellite with the
  stored token; the caller's username rides along in
  `x-devinorium-proxy-user` for the satellite's logs.

## Security notes

- The pairing code is printed in the satellite's stderr once per boot, is
  consumed by the first successful pair, and is never persisted. Keep the satellite's port firewalled to machines
  that may pair: anyone who can reach it while it is unpaired can claim it
  with a guessed code (the code is ~64 bits and guesses are rate-limited,
  but pairing is an admin operation).
- The node token is a bearer credential granting full control of the
  satellite's machine-local services. It lives in the hub's database and
  in the satellite's state file (hashed there). Proxy traffic should run
  over TLS or a trusted private path such as a Tailnet.
- A paired node has no concept of hub accounts: the hub enforces
  owner-only access before forwarding, then the satellite trusts the
  token. Revoke by deleting the node on the hub, or wipe the satellite's
  state file to drop all pairings.
