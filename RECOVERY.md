# Recovery

Rebuilding this environment on a machine that has never seen it.

Everything here is reproducible from this repo plus a browser login. Nothing in
the working environment is precious: the image is rebuilt from `Containerfile`,
`$HOME` is re-provisioned by `provision-home.sh`, and org auth is one web login.

## Prerequisites

- Fedora Silverblue, or any host with `podman` and `toolbox` (both ship with
  Silverblue -- nothing to install on the host, which is the point).
- Network access.
- `git` to clone this repo.

You do **not** need Node, nvm, a JDK, or the Salesforce CLI on the host. The
image carries all of them. Do not install them on the host.

## The whole restore

    git clone <your-remote> ~/sfdx-toolbox
    ~/sfdx-toolbox/build.sh                 # builds the image; several minutes, downloads a lot
    ~/sfdx-toolbox/create.sh                # creates the 'sfdx' toolbox and provisions $HOME

Then authorize the Dev Hub -- this is the only step that needs a human and a
browser:

    toolbox run -c sfdx sf org login web --set-default-dev-hub --alias personal
    toolbox run -c sfdx sf config set target-dev-hub=personal --global

That is the entire recovery. Budget ~15 minutes, nearly all of it the image
build.

## What comes back automatically

| Restored by | What |
|---|---|
| `build.sh` (the image) | VS Code, Temurin 21 JDK, Node 24, pinned Salesforce CLI, `@salesforce/mcp`, Snowfakery, `jq`, the host-browser handoff |
| `create.sh` → `provision-home.sh` | VS Code extensions + settings, `sf` plugins (`code-analyzer`, `lightning-dev`, `sfdx-git-delta`), the `sfdx-exp` / `code-sfdx` / `sf-mcp-server-box` / `sfdx-prettier-init` helpers, the Claude Code MCP registration |

Both are idempotent. Re-running them on a machine that already has the
environment changes nothing.

## What is NOT in this repo

| Thing | How to get it back |
|---|---|
| Dev Hub / org auth (`~/.sfdx`) | the web login above, ~2 minutes |
| Scratch orgs | gone, and that is fine -- they expire in 30 days anyway. Recreate with `sfdx-exp new`. The Dev Hub itself lives in Salesforce's cloud and survives the machine. |
| Your Salesforce project source | a **separate repo** (e.g. `salesforce-lab`). This repo is deliberately project-agnostic and references no project. |
| Experiment snapshots and notes | in the project repo, under `experiments/` |

## Verifying the restore

    toolbox run -c sfdx sf --version                    # pinned CLI
    toolbox run -c sfdx java -version                   # Temurin 21
    toolbox run -c sfdx snowfakery --version            # "Properly installed"
    toolbox run -c sfdx sf plugins                      # three plugins listed
    toolbox run -c sfdx sf org list                     # Dev Hub, with a tree marker
    claude mcp get salesforce-dx                        # Status: Connected

If the browser handoff is working, this exits 0 rather than 4:

    toolbox run -c sfdx bash -lc 'xdg-open https://example.com; echo $?'

## Gotchas that will cost you time

- **A running container keeps the image it was created from.** After `build.sh`
  you must run `create.sh --replace` to pick up new layers. Rebuilding alone
  changes nothing you can see.
- **`create.sh` refuses to clobber an existing container** without `--replace`.
  That is deliberate. `BOX=other ./create.sh` makes a second one instead.
- **`~/.local/bin` must be on `PATH`** for the helpers. It is by default on
  Fedora; if the helpers appear missing, check that first.
- **Nothing in `$HOME` is touched by a container rebuild.** If auth or settings
  seem lost after a rebuild, the cause is elsewhere -- see the keychain section
  in `README.md`.

## Restoring the whole machine, not just this

This repo covers the Salesforce environment only. On a fresh machine you will
also want, in rough order:

1. This repo (tools).
2. Your project repos (the work).
3. Anything else you keep only on this laptop.

A repo that exists only on the lost machine restores nothing. Each of the above
needs a remote, or a copy somewhere that is not this computer.
