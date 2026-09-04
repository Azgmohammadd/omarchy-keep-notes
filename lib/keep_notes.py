#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import getpass
import json
import os
import shutil
import stat
import sys
from pathlib import Path
from typing import Any
from uuid import getnode as get_mac

try:
    import gpsoauth
    import gkeepapi
    from gkeepapi import node as keep_node
except ImportError:
    print(json.dumps({
        "ok": False,
        "error": "gkeepapi is not installed. Run install.sh first."
    }))
    sys.exit(2)


APP_NAME = "keep-notes"
LEGACY_APP_NAME = "omarchy-keep"

STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))

STATE_DIR = STATE_HOME / APP_NAME
CONFIG_DIR = CONFIG_HOME / APP_NAME
LEGACY_STATE_DIR = STATE_HOME / LEGACY_APP_NAME
LEGACY_CONFIG_DIR = CONFIG_HOME / LEGACY_APP_NAME

CREDENTIALS_FILE = STATE_DIR / "credentials.json"
CONFIG_FILE = CONFIG_DIR / "config.json"
CACHE_FILE = STATE_DIR / "snapshot.json"
MIGRATION_MARKER = STATE_DIR / ".legacy-migrated"

DEFAULT_TODO_TITLE = "Keep Notes TODO"
LEGACY_TODO_TITLES = ("TODO", "Omarchy Inbox")

DEFAULT_CONFIG = {
    "todo_title": DEFAULT_TODO_TITLE,
    "max_notes": 250,
}


class KeepError(RuntimeError):
    pass


def emit(payload: dict[str, Any], exit_code: int = 0) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(exit_code)


def ensure_dirs() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        STATE_DIR.chmod(0o700)
        CONFIG_DIR.chmod(0o700)
    except OSError:
        pass
    migrate_legacy_files()


def migrate_legacy_files() -> None:
    # Migration must be one-shot. Without a marker, `disconnect` could remove
    # the new credentials and the next command would silently copy the legacy
    # credentials back, effectively logging the user in again.
    if MIGRATION_MARKER.exists():
        return

    migrations = (
        (LEGACY_STATE_DIR / "credentials.json", CREDENTIALS_FILE),
        (LEGACY_CONFIG_DIR / "config.json", CONFIG_FILE),
        (LEGACY_STATE_DIR / "snapshot.json", CACHE_FILE),
    )

    for old_path, new_path in migrations:
        if new_path.exists() or not old_path.exists():
            continue
        try:
            new_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(old_path, new_path)
            os.chmod(new_path, stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass

    try:
        MIGRATION_MARKER.touch(exist_ok=True)
        os.chmod(MIGRATION_MARKER, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    ensure_dirs()
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    os.replace(tmp, path)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def load_json(path: Path, default: dict[str, Any] | None = None) -> dict[str, Any]:
    if not path.exists():
        return dict(default or {})
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else dict(default or {})
    except (OSError, json.JSONDecodeError):
        return dict(default or {})


def config() -> dict[str, Any]:
    saved = load_json(CONFIG_FILE)
    result = dict(DEFAULT_CONFIG)
    result.update(saved)

    todo_title = str(result.get("todo_title", "") or "").strip()
    if not todo_title or todo_title in LEGACY_TODO_TITLES:
        result["todo_title"] = DEFAULT_TODO_TITLE

    return result


def credentials() -> tuple[str, str]:
    data = load_json(CREDENTIALS_FILE)
    email = str(data.get("email", "")).strip()
    token = str(data.get("master_token", "")).strip()
    if not email or not token:
        raise KeepError("Google Keep is not connected. Run: keep-notes auth")
    return email, token


def connect(sync: bool = True) -> gkeepapi.Keep:
    email, token = credentials()
    keep = gkeepapi.Keep()
    try:
        keep.authenticate(email, token, sync=sync)
    except Exception as exc:
        raise KeepError(f"Google Keep authentication failed: {exc}") from exc
    return keep


def top_labels(n: Any) -> list[str]:
    try:
        return sorted(label.name for label in n.labels.all())
    except Exception:
        return []


def is_trashed(n: Any) -> bool:
    return bool(getattr(n, "trashed", False))


def is_archived(n: Any) -> bool:
    return bool(getattr(n, "archived", False))


def is_pinned(n: Any) -> bool:
    return bool(getattr(n, "pinned", False))


def node_id(n: Any) -> str:
    return str(getattr(n, "id", "") or "")


def item_id(n: Any) -> str:
    return str(getattr(n, "id", "") or "")


def active_nodes(keep: gkeepapi.Keep) -> list[Any]:
    return [
        node for node in keep.all()
        if not is_trashed(node) and not is_archived(node)
    ]


def list_items_payload(lst: Any) -> list[dict[str, Any]]:
    return [
        {
            "itemId": item_id(item),
            "itemText": str(getattr(item, "text", "") or ""),
            "checked": bool(getattr(item, "checked", False)),
        }
        for item in getattr(lst, "items", [])
        if not bool(getattr(item, "deleted", False))
    ]


def checklist_preview(items: list[dict[str, Any]], limit: int = 3) -> str:
    lines: list[str] = []
    for item in items[:limit]:
        marker = "✓" if item["checked"] else "○"
        lines.append(f"{marker} {item['itemText']}")
    if len(items) > limit:
        lines.append(f"… +{len(items) - limit} more")
    return "\n".join(lines)


def note_payload(n: Any) -> dict[str, Any]:
    labels_text = "  ".join("#" + label for label in top_labels(n))
    base = {
        "noteId": node_id(n),
        "noteTitle": str(getattr(n, "title", "") or ""),
        "pinned": is_pinned(n),
        "labelsText": labels_text,
    }

    if isinstance(n, keep_node.List):
        items = list_items_payload(n)
        done = sum(1 for item in items if item["checked"])
        base.update({
            "noteType": "list",
            "noteText": "",
            "previewText": checklist_preview(items),
            "checklistTotal": len(items),
            "checklistDone": done,
            "itemsJson": json.dumps(items, ensure_ascii=False, separators=(",", ":")),
        })
    else:
        text = str(getattr(n, "text", "") or "")
        base.update({
            "noteType": "text",
            "noteText": text,
            "previewText": text,
            "checklistTotal": 0,
            "checklistDone": 0,
            "itemsJson": "[]",
        })

    return base


def find_todo_list(keep: gkeepapi.Keep, title: str) -> Any | None:
    for node in active_nodes(keep):
        if (
            isinstance(node, keep_node.List)
            and str(getattr(node, "title", "") or "").strip() == title
        ):
            return node
    return None


def find_or_create_todo_list(keep: gkeepapi.Keep, title: str) -> Any:
    existing = find_todo_list(keep, title)
    if existing is not None:
        return existing

    # Upgrade path from earlier Keep Notes versions: reuse the old dedicated
    # checklist instead of creating a second TODO note.
    if title == DEFAULT_TODO_TITLE:
        for legacy_title in LEGACY_TODO_TITLES:
            legacy = find_todo_list(keep, legacy_title)
            if legacy is not None:
                legacy.title = title
                legacy.pinned = True
                return legacy

    todo = keep.createList(title, [])
    todo.pinned = True
    return todo


def snapshot(keep: gkeepapi.Keep, cfg: dict[str, Any]) -> dict[str, Any]:
    todo_title = str(cfg.get("todo_title", DEFAULT_TODO_TITLE) or DEFAULT_TODO_TITLE).strip()
    max_notes = max(1, int(cfg.get("max_notes", 250)))

    todo_list = find_todo_list(keep, todo_title)
    if todo_list is None and todo_title == DEFAULT_TODO_TITLE:
        for legacy_title in LEGACY_TODO_TITLES:
            legacy = find_todo_list(keep, legacy_title)
            if legacy is not None:
                legacy.title = todo_title
                legacy.pinned = True
                keep.sync()
                todo_list = legacy
                break
    todo_payload = {
        "listId": node_id(todo_list) if todo_list is not None else "",
        "title": todo_title,
        "items": list_items_payload(todo_list) if todo_list is not None else [],
    }

    notes: list[dict[str, Any]] = []
    pinned: list[dict[str, Any]] = []

    for node in active_nodes(keep)[:max_notes]:
        # The dedicated TODO checklist gets its own tab and should not be
        # duplicated in Notes/Pinned.
        if todo_list is not None and node_id(node) == node_id(todo_list):
            continue

        payload = note_payload(node)
        notes.append(payload)
        if payload["pinned"]:
            pinned.append(payload)

    return {
        "ok": True,
        "todo": todo_payload,
        "notes": notes,
        "pinned": pinned,
        "labels": sorted(label.name for label in keep.labels()),
        "syncedAt": dt.datetime.now().astimezone().strftime("%H:%M"),
    }


def save_cache(payload: dict[str, Any]) -> None:
    try:
        write_private_json(CACHE_FILE, payload)
    except OSError:
        pass


def get_node_or_fail(keep: gkeepapi.Keep, node_id_value: str) -> Any:
    try:
        node = keep.get(node_id_value)
    except Exception:
        node = None
    if node is None:
        raise KeepError("The requested Keep note no longer exists.")
    return node


def get_list_or_fail(keep: gkeepapi.Keep, node_id_value: str) -> Any:
    node = get_node_or_fail(keep, node_id_value)
    if not isinstance(node, keep_node.List):
        raise KeepError("The requested note is not a checklist.")
    return node


def find_list_item(lst: Any, item_id_value: str) -> Any:
    for item in getattr(lst, "items", []):
        if item_id(item) == item_id_value:
            return item
    raise KeepError("The requested checklist item no longer exists.")


def parse_items_json(raw: str) -> list[dict[str, Any]]:
    try:
        items = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise KeepError("Checklist payload is invalid.") from exc
    if not isinstance(items, list):
        raise KeepError("Checklist payload must be an array.")

    normalized: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            raise KeepError("Checklist item payload is invalid.")
        normalized.append({
            "itemId": str(item.get("itemId", "") or ""),
            "itemText": str(item.get("itemText", "") or ""),
            "checked": bool(item.get("checked", False)),
        })
    return normalized


def authenticate_and_store(email: str, token: str) -> None:
    email = email.strip()
    token = token.strip()

    if not email or not token:
        raise KeepError("Email and master token are required.")

    write_private_json(CREDENTIALS_FILE, {
        "email": email,
        "master_token": token,
    })

    try:
        keep = connect(sync=True)
        payload = snapshot(keep, config())
        save_cache(payload)
    except Exception:
        try:
            CREDENTIALS_FILE.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def cmd_auth(args: argparse.Namespace) -> None:
    email = (args.email or "").strip()
    token = (args.master_token or "").strip()

    if not email:
        email = input("Google email: ").strip()
    if not token:
        token = getpass.getpass("Google master token: ").strip()

    authenticate_and_store(email, token)
    emit({"ok": True, "email": email})


def cmd_auth_stdin(_: argparse.Namespace) -> None:
    """Authenticate from one JSON line on stdin so secrets never enter argv."""
    raw = sys.stdin.readline()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise KeepError("Authentication payload is invalid.") from exc

    if not isinstance(payload, dict):
        raise KeepError("Authentication payload is invalid.")

    email = str(payload.get("email", "") or "")
    token = str(payload.get("master_token", "") or "")

    authenticate_and_store(email, token)
    emit({"ok": True, "email": email.strip()})


def cmd_bootstrap_stdin(_: argparse.Namespace) -> None:
    """Exchange a short-lived EmbeddedSetup oauth_token for a master token."""
    raw = sys.stdin.readline()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise KeepError("Connection payload is invalid.") from exc

    if not isinstance(payload, dict):
        raise KeepError("Connection payload is invalid.")

    email = str(payload.get("email", "") or "").strip()
    oauth_token = str(payload.get("oauth_token", "") or "").strip()

    if not email:
        raise KeepError("Google account email is required.")
    if not oauth_token:
        raise KeepError("The oauth_token cookie value is required.")
    if not oauth_token.startswith(("oauth2_4/", "oauth2_1/")):
        raise KeepError(
            "That does not look like an oauth_token cookie. "
            "Copy the value that starts with oauth2_4/ (or oauth2_1/)."
        )

    # Match gkeepapi's default device-id calculation so the exchanged master
    # token and future Keep.authenticate() calls use the same client identity.
    device_id = f"{get_mac():x}"

    try:
        result = gpsoauth.exchange_token(email, oauth_token, device_id)
    except Exception as exc:
        raise KeepError(f"Could not exchange the Google oauth_token: {exc}") from exc

    master_token = str(result.get("Token", "") or "").strip()
    if not master_token:
        detail = result.get("ErrorDetail") or result.get("Error") or "Unknown Google authentication error"
        raise KeepError(
            f"Google rejected the temporary oauth_token: {detail}. "
            "The cookie is short-lived and single-use; get a fresh one and try again."
        )

    authenticate_and_store(email, master_token)
    emit({"ok": True, "email": email})


def cmd_disconnect(_: argparse.Namespace) -> None:
    # Remove both current and legacy credentials. Older Keep Notes versions
    # stored credentials under `omarchy-keep`; leaving that file behind would
    # allow an old installation or a pre-marker migration path to restore it.
    paths = (
        CREDENTIALS_FILE,
        CACHE_FILE,
        LEGACY_STATE_DIR / "credentials.json",
        LEGACY_STATE_DIR / "snapshot.json",
    )

    for path in paths:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass

    # Keep the marker so legacy credentials can never be auto-imported again.
    try:
        MIGRATION_MARKER.touch(exist_ok=True)
        os.chmod(MIGRATION_MARKER, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass

    emit({"ok": True})


def cmd_status(_: argparse.Namespace) -> None:
    data = load_json(CREDENTIALS_FILE)
    emit({
        "ok": True,
        "connected": bool(data.get("email") and data.get("master_token")),
        "email": data.get("email", ""),
        "config": config(),
    })


def cmd_snapshot(args: argparse.Namespace) -> None:
    if not args.sync and CACHE_FILE.exists():
        cached = load_json(CACHE_FILE)
        if cached:
            emit(cached)

    keep = connect(sync=True)
    payload = snapshot(keep, config())
    save_cache(payload)
    emit(payload)


def cmd_add_todo(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    cfg = config()
    todo = find_or_create_todo_list(keep, str(cfg["todo_title"]))
    todo.add(args.text, False, keep_node.NewListItemPlacementValue.Top)
    keep.sync()
    emit({"ok": True, "listId": node_id(todo)})


def cmd_toggle_todo(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    todo = get_list_or_fail(keep, args.list_id)
    item = find_list_item(todo, args.item_id)
    item.checked = args.checked.lower() == "true"
    keep.sync()
    emit({"ok": True})


def cmd_update_todo(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    todo = get_list_or_fail(keep, args.list_id)
    item = find_list_item(todo, args.item_id)
    item.text = args.text
    keep.sync()
    emit({"ok": True})


def cmd_delete_todo(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    todo = get_list_or_fail(keep, args.list_id)
    item = find_list_item(todo, args.item_id)
    item.delete()
    keep.sync()
    emit({"ok": True})


def cmd_add_note(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = keep.createNote(args.title, args.text)
    keep.sync()
    emit({"ok": True, "noteId": node_id(note)})


def cmd_create_list(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = keep.createList(args.title, [])
    if args.item:
        for text in args.item:
            note.add(text, False, keep_node.NewListItemPlacementValue.Bottom)
    keep.sync()
    emit({"ok": True, "noteId": node_id(note)})


def cmd_update_note(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = get_node_or_fail(keep, args.note_id)
    if not isinstance(note, keep_node.Note):
        raise KeepError("The requested note is a checklist.")
    note.title = args.title
    note.text = args.text
    keep.sync()
    emit({"ok": True})


def cmd_update_list(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = get_list_or_fail(keep, args.note_id)
    incoming = parse_items_json(args.items_json)

    note.title = args.title

    existing = {
        item_id(item): item
        for item in getattr(note, "items", [])
        if not bool(getattr(item, "deleted", False))
    }

    keep_ids = {
        item["itemId"]
        for item in incoming
        if item["itemId"] and item["itemId"] in existing
    }

    for existing_id, existing_item in existing.items():
        if existing_id not in keep_ids:
            existing_item.delete()

    for item in incoming:
        text = item["itemText"]
        checked = item["checked"]
        incoming_id = item["itemId"]

        if incoming_id and incoming_id in existing:
            existing[incoming_id].text = text
            existing[incoming_id].checked = checked
        elif text.strip():
            note.add(text, checked, keep_node.NewListItemPlacementValue.Bottom)

    keep.sync()
    emit({"ok": True})


def cmd_archive(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = get_node_or_fail(keep, args.note_id)
    note.archived = True
    keep.sync()
    emit({"ok": True})


def cmd_pin(args: argparse.Namespace) -> None:
    keep = connect(sync=True)
    note = get_node_or_fail(keep, args.note_id)
    note.pinned = args.pinned.lower() == "true"
    keep.sync()
    emit({"ok": True})


def cmd_config(args: argparse.Namespace) -> None:
    cfg = config()
    if args.todo_title is not None:
        value = args.todo_title.strip()
        if not value:
            raise KeepError("TODO note title cannot be empty.")
        cfg["todo_title"] = value
    write_private_json(CONFIG_FILE, cfg)
    emit({"ok": True, "config": cfg})


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="keep-notes",
        description="Google Keep bridge for the Keep Notes Omarchy panel",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("auth", help="Store credentials and verify Keep access")
    p.add_argument("email", nargs="?")
    p.add_argument("master_token", nargs="?")
    p.set_defaults(func=cmd_auth)

    p = sub.add_parser(
        "auth-stdin",
        help="Authenticate from a master token supplied as JSON on stdin",
    )
    p.set_defaults(func=cmd_auth_stdin)

    p = sub.add_parser(
        "bootstrap-stdin",
        help="Exchange an EmbeddedSetup oauth_token supplied as JSON on stdin",
    )
    p.set_defaults(func=cmd_bootstrap_stdin)

    p = sub.add_parser("disconnect", help="Remove local Google Keep credentials")
    p.set_defaults(func=cmd_disconnect)

    p = sub.add_parser("status", help="Show connection status")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("snapshot", help="Return TODO and notes as JSON")
    p.add_argument("--sync", action="store_true")
    p.set_defaults(func=cmd_snapshot)

    p = sub.add_parser("add-todo", help="Add an item to the dedicated TODO checklist")
    p.add_argument("text")
    p.set_defaults(func=cmd_add_todo)

    p = sub.add_parser("toggle-todo", help="Set TODO item checked state")
    p.add_argument("list_id")
    p.add_argument("item_id")
    p.add_argument("checked", choices=["true", "false"])
    p.set_defaults(func=cmd_toggle_todo)

    p = sub.add_parser("update-todo", help="Edit a TODO item")
    p.add_argument("list_id")
    p.add_argument("item_id")
    p.add_argument("text")
    p.set_defaults(func=cmd_update_todo)

    p = sub.add_parser("delete-todo", help="Delete a TODO item")
    p.add_argument("list_id")
    p.add_argument("item_id")
    p.set_defaults(func=cmd_delete_todo)

    p = sub.add_parser("add-note", help="Create a text note")
    p.add_argument("--title", default="")
    p.add_argument("--text", default="")
    p.set_defaults(func=cmd_add_note)

    p = sub.add_parser("create-list", help="Create a checklist note")
    p.add_argument("--title", default="")
    p.add_argument("--item", action="append")
    p.set_defaults(func=cmd_create_list)

    p = sub.add_parser("update-note", help="Update a text note")
    p.add_argument("note_id")
    p.add_argument("--title", default="")
    p.add_argument("--text", default="")
    p.set_defaults(func=cmd_update_note)

    p = sub.add_parser("update-list", help="Update a checklist note")
    p.add_argument("note_id")
    p.add_argument("--title", default="")
    p.add_argument("--items-json", required=True)
    p.set_defaults(func=cmd_update_list)

    p = sub.add_parser("archive", help="Archive a note/checklist")
    p.add_argument("note_id")
    p.set_defaults(func=cmd_archive)

    p = sub.add_parser("pin", help="Set note/checklist pinned state")
    p.add_argument("note_id")
    p.add_argument("pinned", choices=["true", "false"])
    p.set_defaults(func=cmd_pin)

    p = sub.add_parser("config", help="Update Keep Notes configuration")
    p.add_argument("--todo-title")
    p.set_defaults(func=cmd_config)

    return parser


def main() -> None:
    ensure_dirs()
    args = build_parser().parse_args()
    try:
        args.func(args)
    except KeepError as exc:
        emit({"ok": False, "error": str(exc)}, 1)
    except KeyboardInterrupt:
        emit({"ok": False, "error": "Canceled."}, 130)
    except Exception as exc:
        emit({"ok": False, "error": f"Unexpected Keep error: {exc}"}, 1)


if __name__ == "__main__":
    main()
