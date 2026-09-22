# Security

## Reporting a vulnerability

Do not open a public issue for security reports. Email the maintainers
privately or use the repository's private vulnerability reporting if it is
enabled on the hosting platform.

Include:

- A description of the issue and its impact.
- Steps to reproduce or a proof of concept.
- Affected versions, if known.

## Deployment notes

Devinorium runs AI agents that can read and write files on the host. Treat
the server as privileged:

- Put it behind TLS and a strong password in production.
- Set `DEVINORIUM_SESSION_KEY` to a random value of at least 32 characters.
- Treat `DEVINORIUM_FEDERATION_TOKEN` like a root password for every
  federated node.
- Do not expose the plain `--dev` mode on a network interface; it disables
  authentication.

See `docs/deployment.md` and `docs/federation.md` for the full hardening
guidance.
