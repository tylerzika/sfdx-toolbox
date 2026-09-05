#!/usr/bin/env bash
# Runs INSIDE the toolbox. Idempotent -- everything it writes lives in $HOME,
# so it survives container rebuilds and only needs re-running after changes.
set -euo pipefail

if [ ! -f /run/.containerenv ]; then
  echo "run this inside the toolbox, not on the host" >&2; exit 1
fi

BOX="${BOX:-sfdx}"

# --- 1. Extensions ----------------------------------------------------------
# The image bakes extensions into /opt/code-extensions at build time. VS Code
# only loads extensions from $HOME, so seed them across -- no network, no
# marketplace download, identical set on every rebuild. Falls back to the
# marketplace if the seed is missing (older image, or running this standalone).
SEED="/opt/code-extensions"
USER_EXT="$HOME/.vscode/extensions"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -d "$SEED" ]; then
  echo ">> seeding extensions from image"
  mkdir -p "$USER_EXT"
  for d in "$SEED"/*/; do
    name="$(basename "$d")"
    [ -d "$USER_EXT/$name" ] || cp -a "$d" "$USER_EXT/"
  done
  python3 "$DIR/seed-extensions.py" \
    "$SEED/extensions.json" "$USER_EXT/extensions.json" "$SEED" "$USER_EXT"
else
  for ext in salesforce.salesforcedx-vscode esbenp.prettier-vscode; do
    echo ">> installing $ext from marketplace (no baked seed found)"
    code --install-extension "$ext" --force
  done
fi

# --- 2. VS Code settings ----------------------------------------------------
# Defaults are baked at /opt/code-defaults/settings.json. Merge them in without
# clobbering anything the user has set themselves.
DEFAULTS="/opt/code-defaults/settings.json"
SETTINGS="$HOME/.config/Code/User/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

if [ -f "$DEFAULTS" ]; then
  python3 "$DIR/seed-settings.py" "$DEFAULTS" "$SETTINGS"
else
  echo ">> no baked defaults found, skipping settings" >&2
fi

# --- 3. Keep sf auth in a file, not an unreachable keyring ------------------
MARK="# sfdx-toolbox: sf auth key in ~/.sfdx/key.json"
if [ ! -f "$HOME/.bashrc" ] || ! grep -qF "$MARK" "$HOME/.bashrc"; then
  printf '\n%s\nexport SF_USE_GENERIC_UNIX_KEYCHAIN=true\n' "$MARK" >> "$HOME/.bashrc"
  echo ">> added SF_USE_GENERIC_UNIX_KEYCHAIN to ~/.bashrc"
fi

# --- 4. Stop host aliases from firing inside containers ---------------------
# ~/.bashrc has: alias sf='toolbox run -c dev ...' and the same shape for
# claude -- inside a toolbox those bounce the command into the wrong container.
# Only define them on the host. Both are guarded because the MCP launcher in
# section 8 calls claude, and an unguarded alias would send it round in a loop.
for a in sf claude; do
  if [ -f "$HOME/.bashrc" ] && grep -qE "^alias $a='toolbox run" "$HOME/.bashrc"; then
    [ -f "$HOME/.bashrc.bak.$(date +%Y%m%d)" ] || cp "$HOME/.bashrc" "$HOME/.bashrc.bak.$(date +%Y%m%d)"
    sed -i "s#^alias $a='toolbox run#[ -f /run/.containerenv ] || alias $a='toolbox run#" "$HOME/.bashrc"
    echo ">> guarded the host '$a' alias (backup: ~/.bashrc.bak.$(date +%Y%m%d))"
  fi
done

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"

# --- 5. Prettier bootstrap for existing projects ----------------------------
# 'sf project generate' already writes .prettierrc, .prettierignore and the
# devDependencies. This adds the same official config to a project that
# predates it, or one cloned without node_modules installed.
cat > "$HOME/.local/bin/sfdx-prettier-init" <<'INITEOF'
#!/usr/bin/env bash
# Add Salesforce's official Prettier setup to the project in the current dir.
set -euo pipefail
[ -f sfdx-project.json ] || { echo "no sfdx-project.json here -- run this in a Salesforce project root" >&2; exit 1; }

export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true

# Config matches what 'sf project generate' scaffolds.
if [ ! -f .prettierrc ]; then
  cat > .prettierrc <<'RC'
{
  "trailingComma": "none",
  "plugins": [
    "prettier-plugin-apex",
    "@prettier/plugin-xml"
  ],
  "overrides": [
    {
      "files": "**/lwc/**/*.html",
      "options": { "parser": "lwc" }
    },
    {
      "files": "*.{cmp,page,component}",
      "options": { "parser": "html" }
    }
  ]
}
RC
  echo ">> wrote .prettierrc"
fi

if [ ! -f .prettierignore ]; then
  cat > .prettierignore <<'IG'
# List files or directories below to ignore them when running prettier
# More information: https://prettier.io/docs/en/ignore.html
#

**/staticresources/**
.localdevserver
.sfdx
.sf
.vscode

coverage/
IG
  echo ">> wrote .prettierignore"
fi

[ -f package.json ] || npm init -y >/dev/null

# The prettier / prettier:verify scripts 'sf project generate' writes.
python3 - <<'PKG'
import json
GLOB = "**/*.{cls,cmp,component,css,html,js,json,md,page,trigger,xml,yaml,yml}"
pkg = json.load(open("package.json"))
scripts = pkg.setdefault("scripts", {})
scripts.setdefault("prettier", 'prettier --write "%s"' % GLOB)
scripts.setdefault("prettier:verify", 'prettier --check "%s"' % GLOB)
pkg["private"] = True
json.dump(pkg, open("package.json", "w"), indent=2)
print(">> added prettier / prettier:verify scripts")
PKG

echo ">> installing prettier + Salesforce plugins as devDependencies"
npm install --save-dev --no-audit --no-fund \
  prettier@^3 prettier-plugin-apex@^2 @prettier/plugin-xml@^3

echo ">> done. Apex, LWC, Visualforce and XML now format on save."
INITEOF
chmod +x "$HOME/.local/bin/sfdx-prettier-init"
echo ">> helper: sfdx-prettier-init"

# --- 6. Host launcher -------------------------------------------------------
cat > "$HOME/.local/bin/code-sfdx" <<EOF
#!/usr/bin/env bash
# Launch VS Code inside the '$BOX' toolbox.
if [ -f /run/.containerenv ]; then
  exec code "\$@"
fi
exec toolbox run -c $BOX env SF_USE_GENERIC_UNIX_KEYCHAIN=true code "\$@"
EOF
chmod +x "$HOME/.local/bin/code-sfdx"

cat > "$HOME/.local/share/applications/code-sfdx.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=VS Code (Salesforce)
Comment=VS Code with Salesforce DX, inside the $BOX toolbox
Exec=$HOME/.local/bin/code-sfdx %F
Icon=vscode
Terminal=false
Categories=Development;IDE;
StartupWMClass=Code
EOF
echo ">> launcher: code-sfdx  (and 'VS Code (Salesforce)' in your app menu)"
# --- 7. Salesforce CLI plugins ---------------------------------------------
# sf installs plugins under ~/.local/share/sf, i.e. in $HOME -- so they cannot
# be baked into the image, but they do survive container rebuilds. Installed
# here once rather than left to just-in-time download, so the first use of
# 'code-analyzer' mid-experiment isn't a surprise 60-second stall.
export SF_USE_GENERIC_UNIX_KEYCHAIN=true

# sfdx-git-delta is a community plugin, so 'plugins install' stops to ask
# whether you trust it -- which nothing can answer during unattended
# provisioning. Salesforce's own allowlist is the supported way to pre-approve
# it; it writes to ~/.config/sf/unsignedPluginAllowList.json.
for plugin in sfdx-git-delta; do
  sf plugins trust allowlist add -n "$plugin" >/dev/null 2>&1 || true
done

for plugin in code-analyzer lightning-dev sfdx-git-delta; do
  if sf plugins inspect "$plugin" >/dev/null 2>&1; then
    echo ">> plugin $plugin already installed"
  else
    echo ">> installing plugin $plugin"
    sf plugins install "$plugin" >/dev/null 2>&1 \
      && echo "   ok" \
      || echo "   FAILED (network?) -- rerun: sf plugins install $plugin" >&2
  fi
done

# --- 8. DX MCP server for Claude Code ---------------------------------------
# The server is baked into this image, but Claude Code runs in a different
# container. The launcher hops into '$BOX' from wherever it is invoked, so one
# registration works from the host, from 'dev', or from here.
cat > "$HOME/.local/bin/sf-mcp-server-box" <<EOF
#!/usr/bin/env bash
# stdio MCP server for Claude Code, served out of the '$BOX' toolbox so the
# pinned @salesforce/mcp is used rather than whatever npx resolves today.
set -euo pipefail

# Toolsets are deliberately narrow: the server ships 60+ tools and enabling
# them all floods the model's context. These four cover the scratch-org loop.
ARGS=(--orgs DEFAULT_TARGET_ORG --toolsets orgs,metadata,data,testing,code-analysis)

if command -v sf-mcp-server >/dev/null 2>&1; then
  exec sf-mcp-server "\${ARGS[@]}"          # already inside the sfdx toolbox
elif [ -f /run/.containerenv ]; then
  exec flatpak-spawn --host toolbox run -c $BOX sf-mcp-server "\${ARGS[@]}"
else
  exec toolbox run -c $BOX sf-mcp-server "\${ARGS[@]}"
fi
EOF
chmod +x "$HOME/.local/bin/sf-mcp-server-box"
echo ">> launcher: sf-mcp-server-box"

# Register at user scope so it is available in every project, not just this one.
# Called by path, never through the ~/.bashrc alias, which mangles arguments.
CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -x "$CLAUDE_BIN" ]; then
  if "$CLAUDE_BIN" mcp get salesforce-dx >/dev/null 2>&1; then
    echo ">> Claude Code: salesforce-dx already registered"
  else
    "$CLAUDE_BIN" mcp add --scope user salesforce-dx \
      -- "$HOME/.local/bin/sf-mcp-server-box" >/dev/null 2>&1 \
      && echo ">> Claude Code: registered salesforce-dx MCP server" \
      || echo ">> Claude Code: registration failed -- run: claude mcp add --scope user salesforce-dx -- ~/.local/bin/sf-mcp-server-box" >&2
  fi
else
  echo ">> Claude Code not found, skipping MCP registration"
fi

# --- 9. Scratch-org experiment helper ---------------------------------------
# A year of "spin up an org, try a design, throw it away" needs the boring
# parts automated and the interesting parts kept. Snapshots are plain files
# under experiments/, so comparing two designs is just diff, and the comparison
# is still readable in git eight months later.
cat > "$HOME/.local/bin/sfdx-exp" <<'EXPEOF'
#!/usr/bin/env bash
# Track scratch-org architecture experiments side by side.
#
#   sfdx-exp new  <name> [days]      scratch org exp-<name>, deploy source
#   sfdx-exp list                    every experiment, and whether its org lives
#   sfdx-exp snap <name>             retrieve the org's metadata into the experiment
#   sfdx-exp diff <a> <b>            diff two snapshots
#   sfdx-exp seed <name> [recipe]    generate fake data with Snowfakery
#   sfdx-exp open <name>             open the org in a browser
#   sfdx-exp rm   <name>             delete the scratch org, keep the snapshot
#
# Run from a Salesforce project root. Everything lands in ./experiments/<name>/.
set -euo pipefail

[ -f sfdx-project.json ] || {
  echo "no sfdx-project.json here -- run this in a Salesforce project root" >&2; exit 1; }

export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
export SF_USE_GENERIC_UNIX_KEYCHAIN=true

ROOT="experiments"
cmd="${1:-}"; name="${2:-}"
org() { echo "exp-$1"; }
usage() { sed -n '4,10p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 1; }
need() { [ -n "$name" ] || usage; }

case "$cmd" in
new)
  need
  DEF="config/project-scratch-def.json"
  [ -f "$DEF" ] || { echo "missing $DEF" >&2; exit 1; }
  # Scratch orgs come out of a Dev Hub. Without a default one the sf error is
  # a wall of flag help, so say the useful thing instead.
  sf config get target-dev-hub --json 2>/dev/null \
    | jq -e '.result[0].value // empty' >/dev/null || {
      echo "no default Dev Hub. Authorize one first (free Developer Edition org):" >&2
      echo "  sf org login web --set-default-dev-hub --alias devhub" >&2
      exit 1; }
  days="${3:-30}"
  sf org create scratch -f "$DEF" -a "$(org "$name")" -y "$days" -d -w 20
  mkdir -p "$ROOT/$name"
  [ -f "$ROOT/$name/NOTES.md" ] || cat > "$ROOT/$name/NOTES.md" <<NOTE
# $name

Created: $(date +%Y-%m-%d)  |  Org alias: $(org "$name")  |  Expires in $days days

## The design being tested

## What I expected

## What actually happened
NOTE
  # A starter recipe, because an empty org proves nothing about a data model.
  [ -f "$ROOT/$name/recipe.yml" ] || cat > "$ROOT/$name/recipe.yml" <<RECIPE
# Snowfakery recipe -- https://snowfakery.readthedocs.io
# Raise the counts until the design starts to hurt; that is the point.
- object: Account
  count: 200
  fields:
    Name:
      fake: Company
    BillingCountry:
      fake: Country
RECIPE
  echo ">> deploying source to $(org "$name")"
  sf project deploy start -o "$(org "$name")"
  echo ">> experiment ready: $ROOT/$name  (notes + recipe scaffolded)"
  ;;

list)
  [ -d "$ROOT" ] || { echo "no experiments yet"; exit 0; }
  sf org list --json 2>/dev/null \
    | jq -r '.result.scratchOrgs[]? | "\(.alias // "-")\t\(.status // "?")\t\(.expirationDate // "?")"' \
    > /tmp/.sfdx-exp-orgs || : > /tmp/.sfdx-exp-orgs
  printf '%-24s %-10s %-12s %s\n' EXPERIMENT ORG EXPIRES SNAPSHOT
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    line="$(grep -P "^exp-$n\t" /tmp/.sfdx-exp-orgs || true)"
    status="$(echo "$line" | cut -f2)"; exp="$(echo "$line" | cut -f3)"
    snap="no"; [ -d "$d/snapshot" ] && snap="yes"
    printf '%-24s %-10s %-12s %s\n' "$n" "${status:-gone}" "${exp:--}" "$snap"
  done
  rm -f /tmp/.sfdx-exp-orgs
  ;;

snap)
  need
  out="$ROOT/$name/snapshot"
  rm -rf "$out"; mkdir -p "$out"
  echo ">> building manifest from $(org "$name")"
  sf project generate manifest --from-org "$(org "$name")" -n package -d "$ROOT/$name"
  echo ">> retrieving into $out"
  sf project retrieve start -o "$(org "$name")" -x "$ROOT/$name/package.xml" -r "$out"
  echo ">> snapshot saved. commit it, then 'sfdx-exp diff <other> $name'"
  ;;

diff)
  b="${3:-}"
  [ -n "$name" ] && [ -n "$b" ] || usage
  for s in "$name" "$b"; do
    [ -d "$ROOT/$s/snapshot" ] || { echo "no snapshot for '$s' -- run: sfdx-exp snap $s" >&2; exit 1; }
  done
  diff -ru "$ROOT/$name/snapshot" "$ROOT/$b/snapshot" || true
  ;;

seed)
  need
  recipe="${3:-$ROOT/$name/recipe.yml}"
  [ -f "$recipe" ] || { echo "no recipe at $recipe" >&2; exit 1; }
  out="$ROOT/$name/data"
  mkdir -p "$out"
  command -v snowfakery >/dev/null 2>&1 || {
    echo "snowfakery not on PATH -- run this inside the sfdx toolbox" >&2; exit 1; }
  # Silence only Snowfakery's own pkg_resources deprecation warning (see the
  # setuptools pin in the Containerfile); everything else still surfaces.
  PYTHONWARNINGS="ignore::UserWarning:snowfakery.utils.versions" \
    snowfakery "$recipe" --output-format csv --output-folder "$out"
  echo
  echo ">> generated in $out. Load each object with Bulk API 2.0, parents first:"
  for f in "$out"/*.csv; do
    [ -f "$f" ] || continue
    echo "   sf data import bulk --sobject $(basename "$f" .csv) --file $f -o $(org "$name") --wait 10"
  done
  echo
  echo "   Two things to fix before those will load:"
  echo "   - drop the trailing 'id' column; it is Snowfakery's row counter, not a field"
  echo "   - lookups need External IDs to resolve across files -- add them to the"
  echo "     recipe, or use 'sf data import tree' for small related sets"
  ;;

open) need; sf org open -o "$(org "$name")" ;;
rm)   need; sf org delete scratch -o "$(org "$name")" -p; echo ">> org deleted. $ROOT/$name kept." ;;
*)    usage ;;
esac
EXPEOF
chmod +x "$HOME/.local/bin/sfdx-exp"
echo ">> helper: sfdx-exp"

echo ">> provisioning complete"
