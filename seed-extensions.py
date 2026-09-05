#!/usr/bin/env python3
"""Merge the image's baked extension index into the user's.

VS Code stores absolute paths in extensions.json, so entries copied out of the
baked seed dir must be retargeted at $HOME before VS Code will load them.
Extensions the user already has are left alone -- their copy always wins.
"""
import json
import os
import sys

seed_idx, user_idx, seed_dir, user_dir = sys.argv[1:5]


def load(path):
    if not os.path.exists(path):
        return []
    try:
        with open(path) as fh:
            return json.load(fh)
    except ValueError:
        return []


def retarget(node):
    if isinstance(node, dict):
        return {k: retarget(v) for k, v in node.items()}
    if isinstance(node, list):
        return [retarget(v) for v in node]
    if isinstance(node, str) and seed_dir in node:
        return node.replace(seed_dir, user_dir)
    return node


user = load(user_idx)
have = {e.get("identifier", {}).get("id") for e in user}

added = 0
for entry in load(seed_idx):
    if entry.get("identifier", {}).get("id") in have:
        continue
    user.append(retarget(entry))
    added += 1

with open(user_idx, "w") as fh:
    json.dump(user, fh)

print("   %d seeded, %d already present" % (added, len(user) - added))
