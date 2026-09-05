# sfdx-toolbox

A rebuildable toolbox containing VS Code, the official Salesforce Extension Pack,
the Apex Language Server, and Prettier formatting on save -- plus the Salesforce
DX MCP Server wired into Claude Code, Snowfakery for fake data, and a scratch-org
experiment helper for comparing architectural designs.

Lost the machine? See **[RECOVERY.md](RECOVERY.md)** -- clone, build, create,
one browser login.

## Use it

    ~/sfdx-toolbox/build.sh              # build the image (~5 min, network)
    ~/sfdx-toolbox/create.sh             # create the 'sfdx' toolbox + provision
    code-sfdx                            # launch VS Code in it

Rebuild from scratch any time:

    ~/sfdx-toolbox/build.sh && ~/sfdx-toolbox/create.sh --replace

Different container name: `BOX=other ./create.sh`

## Why your org auth survives a rebuild

`sf` writes org credentials to `~/.sfdx/<username>.json` and the key that
decrypts them to `~/.sfdx/key.json` (`Global.DIR` is still the legacy `.sfdx`
folder; `~/.sf` holds config and logs). Both are in `$HOME`, which toolbox
bind-mounts from the host, so replacing the container cannot touch them.

The image sets `SF_USE_GENERIC_UNIX_KEYCHAIN=true`. Without it `sf` tries a D-Bus
secret service that isn't reachable from the container, and auth would break on
rebuild. With it, the key is just that file.

Same reason your VS Code extensions and settings persist: `~/.vscode/extensions`
and `~/.config/Code` are in `$HOME` too. `provision-home.sh` is idempotent, so
re-running it is always safe.

Log in once after the first build:

    toolbox run -c sfdx sf org login web --alias devorg --set-default

## What's baked into the image

| Baked (rebuilt from the Containerfile) | Lives in $HOME (persists) |
|---|---|
| VS Code | org auth (`~/.sfdx/`) |
| Temurin 21 JDK | your source (`~/code/...`) |
| Node 24 + Salesforce CLI (pinned) | per-project `node_modules` |
| all 24 extensions (`/opt/code-extensions`) | your extension + settings edits |
| default settings (`/opt/code-defaults`) | per-project prettier config |
| `@salesforce/mcp` (pinned) | sf plugins (`~/.local/share/sf`) |
| Snowfakery (venv at `/opt/snowfakery`) | your experiments (`./experiments/`) |
| git, jq, fonts, libsecret | Claude Code MCP registration |
| `SF_USE_GENERIC_UNIX_KEYCHAIN` | |

VS Code only ever loads extensions and settings from `$HOME`, so those cannot be
read directly out of the image. Instead the image carries them as a read-only
seed and `provision-home.sh` copies them across:

- Extensions are copied from `/opt/code-extensions`, and the absolute paths in
  `extensions.json` are rewritten for `$HOME` (`seed-extensions.py`).
- Settings are merged from `/opt/code-defaults/settings.json`, filling in only
  keys you have not set yourself (`seed-settings.py`).

Both are additive -- anything you installed or changed by hand always wins. A
clean `$HOME` provisions in about 6 seconds with no network, because nothing is
downloaded from the marketplace at container-create time. If the seed is missing
(an older image), provisioning falls back to installing from the marketplace.

Note that a running container keeps the image it was created from. After
`build.sh` you must run `create.sh --replace` to actually pick up the new layers.

## Source lives on the host

Toolbox bind-mounts your whole home (`/var/home/tyler -> /var/home/tyler`), so
there is one copy of your source on the host disk and every container sees it.
Nothing is copied in. The image supplies the tools; `$HOME` supplies the code.

The CLI is pinned to `@salesforce/cli@2.150.6` to match the nvm-installed copy.
Because `~/.bashrc` sources nvm, nvm's `sf` still wins in an interactive shell --
the baked one is what VS Code and a fresh `$HOME` use. Bump the pin in the
Containerfile to upgrade.

## Driving orgs from Claude Code

The image bakes `@salesforce/mcp` (the Salesforce DX MCP Server) and
`provision-home.sh` registers it with Claude Code at **user scope**, so it works
in every project, not just this one. Then the org is something you talk to:

> Create a scratch org, alias it `exp-sharing-role-hierarchy`, make it default.
> Retrieve all agents from my org.
> Run all local Apex and agent tests.

Claude Code runs in a different container than this one, so the registration
points at `~/.local/bin/sf-mcp-server-box`, a launcher that hops into the `sfdx`
toolbox from wherever it is invoked -- the host, `dev`, or here.

Toolsets are limited to `orgs,metadata,data,testing,code-analysis`. The server
ships over 60 tools and enabling them all floods the model's context, so widen
this deliberately by editing the `ARGS` line in the launcher, not by default.

Check it with `claude mcp list`. To re-register by hand:

    claude mcp add --scope user salesforce-dx -- ~/.local/bin/sf-mcp-server-box

## Running experiments

`sfdx-exp` exists because a year of "spin up an org, try a design, throw it
away" is mostly boring steps around one interesting question. Run it from a
project root; everything lands in `./experiments/<name>/`.

    sfdx-exp new  sharing-role-hierarchy    # scratch org exp-<name>, deploy source
    sfdx-exp seed sharing-role-hierarchy    # Snowfakery data from its recipe.yml
    sfdx-exp snap sharing-role-hierarchy    # retrieve org metadata into the experiment
    sfdx-exp diff sharing-role-hierarchy sharing-criteria-sets
    sfdx-exp list                           # what exists, what is still alive
    sfdx-exp rm   sharing-role-hierarchy    # delete the org, keep the snapshot

`new` scaffolds a `NOTES.md` (design / expected / actual) and a starter
`recipe.yml`. Snapshots are plain source-format files, so `diff` is just `diff`,
and both the design and the reasoning are still readable in git months later --
which matters, because scratch orgs expire in 30 days and your memory of why you
chose something expires faster.

`rm` deletes only the org. The snapshot and notes are the durable artifact.

## Fake data

Snowfakery is baked in (`/opt/snowfakery`, on `PATH` as `snowfakery`). Sharing
models, large-data-volume behaviour and skinny-table questions all behave
differently at 200 records than at 200,000, and an empty org proves nothing.

`sfdx-exp seed` runs the recipe and prints the `sf data import bulk` command for
each generated CSV, parents first. Lookups across files need External IDs to
resolve -- add them to the recipe, or use `sf data import tree` for small
related sets.

## Extra CLI plugins

`provision-home.sh` installs three plugins on first run. They live in
`~/.local/share/sf` (i.e. `$HOME`), so they survive container rebuilds and
cannot be baked into the image:

| Plugin | For |
|---|---|
| `code-analyzer` | Apex/LWC static analysis (uses the Temurin JDK already here) |
| `lightning-dev` | `sf lightning dev app\|component\|site` -- local preview, no deploy |
| `sfdx-git-delta` | metadata delta between two git commits |

Installing them up front rather than letting them just-in-time download means
the first `code-analyzer` run mid-experiment isn't a surprise stall.

## Browsers, and why `sf org login web` failed

There is no browser in the container, so `sf org login web` fails with:

    CannotOpenBrowserError: Unable to open the browser you specified (undefined)

The `(undefined)` is a red herring. From `plugin-auth/.../login/web.js`:

    const browserApp = browser && browser in apps ? browser : undefined;
    ...
    reject(messages.createError('error.cannotOpenBrowser', [browserApp], ...))

`browserApp` is `undefined` whenever you did not pass `--browser`, which is
normal; it only reaches the message on the failure path. The real failure is a
non-zero exit from the opener.

Three things make this harder to fix than it looks:

1. **The opener is not the system `xdg-open`.** The npm `open` package that `sf`
   uses ships its own copy at `node_modules/open/xdg-open` and prefers it, so a
   shim earlier on `PATH` is never consulted.
2. **You cannot fake it with `$BROWSER`.** The bundled script only reads
   `$BROWSER` on its generic code path, and it never gets there.
3. **You cannot get to that path by clearing `XDG_CURRENT_DESKTOP` either.** Its
   `detectDE` falls back to asking `org.gnome.SessionManager` over the host's
   D-Bus socket, which the container can reach, so it always concludes GNOME and
   calls `gio open` -- which fails with *Failed to find default application for
   content type 'text/html'*.

So the fix is to give the container a real handler. The image installs
`/usr/local/bin/host-browser` (which forwards to the host with `flatpak-spawn`),
a `host-browser.desktop` entry, and an `/etc/xdg/mimeapps.list` making it the
default for `http`, `https` and `text/html`.

All three live in the **image**, not `$HOME`, and that is deliberate:
`/etc/xdg` and `/usr/share/applications` are container-only, so the host's own
default browser is untouched. Putting a `mimeapps.list` or a desktop entry in
`$HOME` would change the host's default browser too -- and the wrapper would
then recurse into itself.

The OAuth round trip completes because toolbox containers use **host
networking**: the callback server listens on `localhost:1717` inside the
container, and the host browser's redirect to `localhost:1717` reaches it.

This fixes every URL-opening path at once -- `sf org login web`, `sf org open`,
`sfdx-exp open`, `gio open`, the system `xdg-open`, and links clicked in VS Code.

## Formatting

Format-on-save is on, with Prettier as the default formatter for `apex`,
`apex-anon`, `visualforce`, `html`, `javascript`, `json`, `xml`, `css`, `yaml`
and `markdown` (language ids come from the installed Salesforce extensions;
Aura and LWC markup register as `html`).

Prettier resolves its Apex plugin from the **project's** `node_modules`, which is
why the toolbox alone isn't enough:

- New projects: `sf project generate` already scaffolds `.prettierrc`,
  `.prettierignore` and the `prettier` / `prettier-plugin-apex` /
  `@prettier/plugin-xml` devDependencies. Just run `npm install`.
- Existing projects missing that: run `sfdx-prettier-init` in the project root.
  It writes the same config Salesforce scaffolds and installs the three
  devDependencies.

`prettier-plugin-apex` v2 ships a native parser binary -- it does **not** need
Java. The JDK in this image is for the Apex Language Server, which is separate.

## Apex Language Server

`salesforcedx-vscode-apex.java.home` is set to the Temurin 21 JDK by
`provision-home.sh`. Verified: the server (`dist/apex-jorje-lsp.jar`) starts on
JDK 21 and reports `definitionProvider`, `hoverProvider`, `referencesProvider`
and `documentSymbolProvider`. It needs a real project root -- open the folder
containing `sfdx-project.json`, not a parent directory, or it won't index.

## Notes

- Fedora 44 ships only JDK 25+, outside the Apex Language Server's supported
  11/17/21 range, so the JDK comes from Adoptium.
- `provision-home.sh` guards the `alias sf=` and `alias claude=` lines in
  `~/.bashrc` so they only fire on the host -- unguarded they route the command
  into the `dev` container from anywhere.
- Those two host aliases also **swallow their arguments**: the alias closes its
  quote before `$*`, so `sf org list` hands `org list` to `bash -lc` rather than
  to `sf`, and you get the help screen. Inside this toolbox the aliases are
  guarded off and the real binaries are used, so the workflow above is
  unaffected. To fix them on the host, make each a shell function using `"$@"`
  instead of an alias.
- The MS build of VS Code is used (not VSCodium) because the Salesforce
  extensions are only on the Microsoft marketplace.
- Snowfakery's venv pins `setuptools<81`. Snowfakery 4.2.1 still imports
  `pkg_resources`, which setuptools dropped in 81, and Python 3.14 venvs no
  longer seed setuptools at all -- so unpinned it installs cleanly and then
  dies with `ModuleNotFoundError` the first time you run it. The Containerfile
  imports `pkg_resources` during the build so a regression fails there rather
  than mid-experiment.
- `sfdx-git-delta` is a community plugin, so `sf plugins install` stops to ask
  whether you trust it -- unanswerable during unattended provisioning. Section 7
  pre-approves it with `sf plugins trust allowlist add`, which is Salesforce's
  supported mechanism, rather than piping `yes` at the prompt.
