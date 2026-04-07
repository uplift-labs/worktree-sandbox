#!/usr/bin/env python3
"""Sandbox JSON merge tool.

Merges hook definitions into an existing Claude Code settings.json.
Idempotent: running twice produces the same result.

Usage:
    python3 json-merge.py <target_settings.json> <hooks_source.json> [--uninstall]
"""
import json
import sys
from pathlib import Path

MARKER = ".sandbox/adapter/hooks/"


def hook_key(hook):
    """Unique key for deduplication."""
    if hook.get("command"):
        return ("command", hook["command"])
    if hook.get("prompt"):
        return ("prompt", hook["prompt"])
    return ("unknown", id(hook))


def is_sandbox_hook(hook):
    """Check if a hook was installed by sandbox."""
    return MARKER in hook.get("command", "")


def merge_matcher_group(existing_group, new_group):
    """Merge hooks within a matcher group, skipping duplicates."""
    existing_hooks = existing_group.get("hooks", [])
    existing_keys = {hook_key(h): i for i, h in enumerate(existing_hooks)}

    for hook in new_group.get("hooks", []):
        key = hook_key(hook)
        if key in existing_keys:
            if is_sandbox_hook(hook):
                existing_hooks[existing_keys[key]] = hook
        else:
            existing_hooks.append(hook)

    existing_group["hooks"] = existing_hooks
    return existing_group


def merge_event(existing_entries, new_entries):
    """Merge matcher groups for one event type."""
    existing_matchers = {e.get("matcher", ""): e for e in existing_entries}

    for new_entry in new_entries:
        matcher = new_entry.get("matcher", "")
        if matcher in existing_matchers:
            merge_matcher_group(existing_matchers[matcher], new_entry)
        else:
            existing_entries.append(new_entry)

    return existing_entries


def merge_hooks(target, source):
    """Merge source hooks into target settings."""
    if "hooks" not in source:
        return target

    if "hooks" not in target:
        target["hooks"] = source["hooks"]
        return target

    for event, entries in source["hooks"].items():
        if event not in target["hooks"]:
            target["hooks"][event] = entries
        else:
            target["hooks"][event] = merge_event(
                target["hooks"][event], entries
            )

    return target


def uninstall_hooks(target):
    """Remove all sandbox hooks."""
    if "hooks" not in target:
        return target

    for event in list(target["hooks"]):
        groups = target["hooks"][event]
        for group in groups:
            group["hooks"] = [
                h for h in group.get("hooks", [])
                if not is_sandbox_hook(h)
            ]
        target["hooks"][event] = [g for g in groups if g.get("hooks")]

    target["hooks"] = {k: v for k, v in target["hooks"].items() if v}
    if not target["hooks"]:
        del target["hooks"]

    return target


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <target.json> <source.json> [--uninstall]")
        sys.exit(1)

    target_path = Path(sys.argv[1])
    source_path = Path(sys.argv[2])
    do_uninstall = "--uninstall" in sys.argv

    if target_path.exists():
        target = json.loads(target_path.read_text(encoding="utf-8"))
    else:
        target = {}

    if do_uninstall:
        result = uninstall_hooks(target)
    else:
        source = json.loads(source_path.read_text(encoding="utf-8"))
        result = merge_hooks(target, source)

    if result == {}:
        target_path.unlink(missing_ok=True)
    else:
        target_path.parent.mkdir(parents=True, exist_ok=True)
        target_path.write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
