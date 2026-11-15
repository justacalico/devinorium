# Plugins

Plugins are installable bundles that extend what agents can see and do.
The layout is compatible with Claude Code plugins, so an existing plugin
directory works as is:

```text
my-plugin/
├── .claude-plugin/plugin.json   (or plugin.json at the root)
├── skills/<name>/SKILL.md
├── commands/<name>.md
├── hooks/hooks.json
└── .mcp.json
```

Every part is optional. A directory with just `commands/` is a valid
plugin.

## Scopes

Two scopes exist, with different trust levels:

- **User plugins** live under `~/.config/devinorium/plugins` and
  contribute everything: skills, slash commands, MCP servers, and hooks.
  The owner manages them from Settings -> Plugins or the REST API.
- **Project plugins** live under `<working dir>/.devinorium/plugins` and
  contribute only skills and commands. A cloned repository may add prompt
  text (the same trust level as its `.devin/skills`) but it can never
  gain shell command execution or tool servers just by being opened.

## Manifest

`plugin.json` (under `.claude-plugin/` or the plugin root):

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What it does",
  "author": "someone"
}
```

`author` may also be the Claude Code object form `{"name": "..."}`.
Without a manifest the directory name is used and the plugin still
works; the manifest only controls the displayed metadata.

## Skills and commands

`skills/<name>/SKILL.md` files join skill discovery exactly like
`.devin/skills`, shown in the composer `/` picker with a `plugin:<name>`
source. `commands/<name>.md` files register `/name` slash commands with
`$ARGUMENTS` substitution.

Precedence follows the existing skill rules: project skills shadow
plugin and user skills of the same name. Devin CLI resolves its own
slash commands natively, so for Devin only plugin-provided commands are
expanded inline; other providers get every skill expanded inline as
before.

## MCP servers

A plugin `.mcp.json` uses the standard `mcpServers` map:

```json
{
  "mcpServers": {
    "tools": { "command": "npx", "args": ["-y", "tools-mcp"] }
  }
}
```

Enabled user-scope plugins merge their servers into owner runs. A
server name already in the owner's MCP list always wins. Because a
stdio entry is arbitrary code execution as the server user, plugin MCP
servers are owner-only, same as the MCP settings list.

## Hooks

`hooks/hooks.json` registers shell commands for run lifecycle events,
in the Claude Code format:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "./check.sh", "timeout": 10 } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo context-here" } ] }
    ]
  }
}
```

Supported events: `UserPromptSubmit` (before the prompt reaches the
provider), `SessionStart` (first turn of a thread), and `Stop` (after
the provider finishes; cannot block).

Each hook runs through `sh -c` (or `cmd /C` on Windows) in the thread's
working directory with the event JSON on stdin and these environment
variables: `DEVINORIUM_PLUGIN_ROOT` and `CLAUDE_PLUGIN_ROOT` (the
plugin's directory), `DEVINORIUM_PROJECT_DIR` and `CLAUDE_PROJECT_DIR`
(the working directory), `DEVINORIUM_PLUGIN_NAME`, and
`DEVINORIUM_HOOK_EVENT`. Timeout defaults to 30 seconds and is capped
at 120; a timed-out hook's whole process group is killed.

A hook decides by exit code and stdout:

- Exit `2` blocks the event; stderr is the reason shown to the user.
- Exit `0` with JSON `{"decision": "block", "reason": "..."}` also
  blocks.
- Exit `0` with JSON `{"hookSpecificOutput": {"additionalContext": "..."}}`
  (or a bare `additionalContext`) appends that text to the prompt.
- Exit `0` with plain stdout appends it to the prompt as context.
- Any other failure is logged and skipped; hooks are best-effort.

Only user-scope plugins run hooks, and only for owner-initiated runs ,
a hook is arbitrary code execution as the server user, the same trust
class as plugin MCP servers. Hooks run on the machine that runs the
agent: on a paired satellite, the satellite's own plugins fire instead
of the hub's.

## Installing

Settings -> Plugins accepts two source forms:

- **Git URL**: cloned into `~/.config/devinorium/plugins/<name>` and
  updatable later with the refresh button (`git pull`).
- **Local directory**: a path on the server. A single plugin directory is
  linked into the plugins root; a marketplace directory (one with
  `.claude-plugin/marketplace.json` listing plugin entries) links every
  listed plugin individually.

Uninstall removes the entry from the plugins root; for linked installs
only the link is removed, the source directory stays. Enable/disable
state lives in `~/.config/devinorium/plugins.json` under a `disabled`
name list, so toggling never writes inside a plugin directory.

## REST API

All endpoints are owner-only:

- `GET /api/plugins?cwd=<dir>`: list plugins. With `cwd`, project-scope
  plugins under `<dir>/.devinorium/plugins` are included with
  `source: "project"`.
- `POST /api/plugins/install` `{ "source": "<git-url-or-path>" }`:
  install, returns `{ "installed": [names] }`.
- `PUT /api/plugins/:name/enabled` `{ "enabled": true|false }`: toggle a
  user-scope plugin.
- `POST /api/plugins/:name/update`: `git pull` a git-installed plugin.
- `DELETE /api/plugins/:name`: uninstall a user-scope plugin.

## Security

A plugin can register shell hooks and stdio MCP servers, both of which
execute as the server user. Management is owner-only, hooks and plugin
MCP servers apply only to owner-initiated runs, and project-scope
plugins can contribute prompt text only, but only install plugins from
sources you trust with shell access to the server.
