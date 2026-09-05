#!/usr/bin/env python3
"""Merge the image's baked VS Code defaults into the user's settings.json.

Keys the user has already set are left untouched -- this only fills in what is
missing, so re-running provisioning never overwrites hand edits.
"""
import json
import os
import sys

defaults_path, settings_path = sys.argv[1:3]

with open(defaults_path) as fh:
    defaults = json.load(fh)

settings = {}
if os.path.exists(settings_path):
    raw = open(settings_path).read().strip()
    if raw:
        try:
            settings = json.loads(raw)
        except ValueError:
            os.replace(settings_path, settings_path + ".bak")
            print("   settings.json was not valid JSON -> saved as .bak")

added, kept = 0, 0
for key, value in defaults.items():
    if key in settings:
        kept += 1
        continue
    settings[key] = value
    added += 1

with open(settings_path, "w") as fh:
    json.dump(settings, fh, indent=2)

print("   settings: %d applied, %d already set by you" % (added, kept))
