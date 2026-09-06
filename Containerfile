# Toolbox image: VS Code + JDK for Salesforce DX development.
# Everything user-specific (orgs, extensions, settings) lives in $HOME and is
# NOT baked in here -- that is what makes rebuilds cheap and auth persistent.
FROM registry.fedoraproject.org/fedora-toolbox:44

# --- Visual Studio Code (Microsoft build, so the MS marketplace works) -------
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    printf '%s\n' \
      '[code]' \
      'name=Visual Studio Code' \
      'baseurl=https://packages.microsoft.com/yumrepos/vscode' \
      'enabled=1' \
      'gpgcheck=1' \
      'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' \
      > /etc/yum.repos.d/vscode.repo

# --- Temurin 21 -------------------------------------------------------------
# The Apex Language Server supports JDK 11/17/21. Fedora 44 ships only JDK 25+,
# which is outside that range, so pull the LTS from Adoptium instead.
RUN rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public && \
    printf '%s\n' \
      '[adoptium]' \
      'name=Eclipse Temurin' \
      'baseurl=https://packages.adoptium.net/artifactory/rpm/fedora/44/x86_64' \
      'enabled=1' \
      'gpgcheck=1' \
      'gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public' \
      > /etc/yum.repos.d/adoptium.repo

RUN dnf -y install \
      code \
      temurin-21-jdk \
      nodejs24 \
      nodejs24-npm \
      git \
      gh \
      libsecret \
      xdg-utils \
      google-noto-sans-fonts \
      google-noto-sans-mono-fonts \
      python3-pip \
      jq \
    && dnf clean all

# --- Salesforce CLI ---------------------------------------------------------
# Pinned to the version already in use via nvm, so the two cannot drift.
# Bump this line (and re-run build.sh) to upgrade.
# Note: ~/.bashrc sources nvm, which prepends ~/.nvm to PATH -- so in an
# interactive shell nvm's sf still wins. This copy is what VS Code and a
# fresh $HOME get, and it is what makes the container self-contained.
RUN npm install -g @salesforce/cli@2.150.6 && npm cache clean --force

# sf keeps its auth key in ~/.sf/key.json instead of a D-Bus keyring the
# container cannot reach. This is what survives container rebuilds.
RUN printf '%s\n' 'export SF_USE_GENERIC_UNIX_KEYCHAIN=true' \
      > /etc/profile.d/sf-keychain.sh
ENV SF_USE_GENERIC_UNIX_KEYCHAIN=true

# --- Salesforce DX MCP Server -----------------------------------------------
# Lets an MCP client (Claude Code) drive orgs directly: create scratch orgs,
# retrieve metadata, run Apex and agent tests. Pinned and baked rather than
# npx-resolved at run time, so it starts instantly and cannot drift mid-project.
# provision-home.sh writes a launcher and registers it with Claude Code.
RUN npm install -g @salesforce/mcp@0.30.15 && npm cache clean --force

# --- Snowfakery -------------------------------------------------------------
# Recipe-driven fake data. Architecture experiments (sharing, LDV, skinny
# tables) are meaningless against ten records, and hand-writing 100k is worse.
# Fedora marks its python3 as externally managed (PEP 668), so use a venv
# instead of fighting pip.
#
# setuptools is pinned below 81 on purpose: Snowfakery 4.2.1 still imports
# pkg_resources, which setuptools removed in 81. Fedora 44 ships Python 3.14,
# whose venvs no longer seed setuptools at all, so without this pin snowfakery
# installs cleanly and then dies with ModuleNotFoundError on first run.
RUN python3 -m venv /opt/snowfakery && \
    /opt/snowfakery/bin/pip install --no-cache-dir --disable-pip-version-check \
      snowfakery "setuptools<81" && \
    /opt/snowfakery/bin/python -c "import pkg_resources" && \
    ln -s /opt/snowfakery/bin/snowfakery /usr/local/bin/snowfakery

# --- Baked VS Code extensions ----------------------------------------------
# Installed at build time into a read-only seed dir so creating a container
# needs no network and always yields the same extension set. VS Code only ever
# loads extensions from $HOME, so provision-home.sh copies this seed across.
RUN mkdir -p /opt/code-extensions /opt/code-defaults && \
    for ext in salesforce.salesforcedx-vscode esbenp.prettier-vscode; do \
      code --no-sandbox --user-data-dir /tmp/vscode-build \
           --extensions-dir /opt/code-extensions \
           --install-extension "$ext" --force; \
    done && \
    rm -rf /tmp/vscode-build && \
    chmod -R a+rX /opt/code-extensions

# --- Baked default VS Code settings ----------------------------------------
# The complete file, generated at build time: Apex Language Server JDK plus
# Prettier as default formatter with format-on-save. Language ids are the ones
# the installed Salesforce extensions register (Aura/LWC markup is html).
# provision-home.sh merges this into the user's settings.json; user edits win.
RUN test -d /usr/lib/jvm/java-21-temurin-jdk && python3 -c "\
import json; \
p='esbenp.prettier-vscode'; \
langs=['apex','apex-anon','visualforce','html','javascript','json','jsonc','xml','css','yaml','markdown']; \
d={'salesforcedx-vscode-apex.java.home':'/usr/lib/jvm/java-21-temurin-jdk', \
   'editor.formatOnSave':True,'editor.defaultFormatter':p}; \
d.update({'[%s]'%l:{'editor.defaultFormatter':p} for l in langs}); \
json.dump(d, open('/opt/code-defaults/settings.json','w'), indent=2)"

# --- Browser handoff to the host --------------------------------------------
# There is no browser in the container, so every URL-opening path fails and
# 'sf org login web' surfaces it as:
#   CannotOpenBrowserError: Unable to open the browser you specified (undefined)
# The "(undefined)" is a red herring -- sf interpolates the unset --browser flag
# into the message; the real failure is a non-zero exit from the opener.
#
# The opener is NOT the system xdg-open: the npm 'open' package that sf uses
# ships its own copy and prefers it, so a PATH shim never gets consulted. That
# bundled script detects GNOME by querying org.gnome.SessionManager over the
# host's D-Bus socket -- which succeeds even with XDG_CURRENT_DESKTOP cleared --
# and then calls 'gio open', which fails with "Failed to find default
# application for content type 'text/html'".
#
# So give the container a real handler for http/https/text-html that forwards
# to the host. Done entirely in the image: /etc/xdg and /usr/share/applications
# are container-only, so the host's own default browser is untouched. ($HOME is
# shared with the host -- a mimeapps.list or desktop entry there would change
# the host's default browser too, and the wrapper would recurse into itself.)
#
# The OAuth round trip still completes because toolbox uses host networking:
# the callback server listens on localhost:1717 in here, and the host browser's
# redirect to localhost:1717 reaches it.
RUN printf '%s\n' \
      '#!/usr/bin/env bash' \
      '# Hand a URL to the host browser from inside a toolbox. Falls through to' \
      '# the real xdg-open on the host, so the file is safe either side.' \
      'if [ -f /run/.containerenv ] && command -v flatpak-spawn >/dev/null 2>&1; then' \
      '  exec flatpak-spawn --host xdg-open "$@"' \
      'fi' \
      'exec /usr/bin/xdg-open "$@"' \
      > /usr/local/bin/host-browser && \
    chmod 0755 /usr/local/bin/host-browser

RUN printf '%s\n' \
      '[Desktop Entry]' \
      'Type=Application' \
      'Name=Host Browser' \
      'Exec=/usr/local/bin/host-browser %U' \
      'Terminal=false' \
      'NoDisplay=true' \
      'MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;' \
      > /usr/share/applications/host-browser.desktop && \
    printf '%s\n' \
      '[Default Applications]' \
      'x-scheme-handler/http=host-browser.desktop' \
      'x-scheme-handler/https=host-browser.desktop' \
      'text/html=host-browser.desktop' \
      > /etc/xdg/mimeapps.list && \
    update-desktop-database /usr/share/applications
