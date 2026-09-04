# Keep Notes for Omarchy

A keyboard-first Google Keep panel for Omarchy.

Keep Notes opens as a standalone floating panel — nothing is added to the top
bar. It preserves Google Keep's note/checklist model while adding a dedicated
TODO workflow and Vim-style navigation.

> [!IMPORTANT]
> Keep Notes uses [`gkeepapi`](https://github.com/kiwiz/gkeepapi), an
> unofficial Google Keep client. It is not affiliated with or endorsed by
> Google. Google can change the underlying private API or authentication flow.

## Features

- Text notes and Google Keep checklist notes
- Dedicated **Keep Notes TODO** checklist
- Quick capture for TODOs, text notes, and checklists
- Edit checklist items without flattening them into standalone tasks
- Check/uncheck and delete checklist items from the keyboard
- Search, pin, archive, edit, and sync
- First-run Email + Master Token connection UI
- Master Token sent to the local bridge over stdin, not argv
- Vim-style keyboard navigation
- Theme-aware Omarchy / Quickshell UI
- No navbar widget

## Install

```bash
omarchy plugin add https://github.com/Azgmohammadd/omarchy-keep-notes.git --enable
```

Open it with:

```bash
omarchy-shell shell summon dev.zed.keep-notes '{}'
```

On first use the plugin creates a small Python virtual environment under
`~/.local/share/keep-notes/` and installs the pinned `gkeepapi` dependency.
No `sudo` or root access is used.

### Suggested Hyprland keybinding

Add this to your user keybindings file:

```ini
bindd = SUPER SHIFT, K, Keep Notes, exec, omarchy-shell shell summon dev.zed.keep-notes "{}"
```

## First connection

The first launch shows a connection screen inside the panel. Enter:

1. The Google account email used by Google Keep.
2. The Google Master Token (`aas_et/...`).

Then press **Connect & Sync**.

The token is masked in the UI and passed to the local bridge over stdin, so it
does not appear in the process argument list.

Credentials are stored locally at:

```text
~/.local/state/keep-notes/credentials.json
```

with private file permissions.

## Data model

Keep Notes does **not** turn checklist items from every note into global tasks.

A Keep checklist remains one checklist note:

```text
Shopping
  ○ Coffee
  ✓ Milk
  ○ Bread
```

The TODO tab is backed by one dedicated checklist:

```text
Keep Notes TODO
```

Quick TODO capture writes only to that checklist. Older plugin-managed lists
named `TODO` or `Omarchy Inbox` are reused and renamed instead of duplicated.

## Keyboard controls

### Main panel

| Key | Action |
| --- | --- |
| `j` / `k` | Next / previous item |
| `gg` / `G` | First / last item |
| `h` / `l` | Previous / next tab |
| `Enter` | Open note / edit selected TODO |
| `Space` or `x` | Toggle selected TODO |
| `e` | Edit selected TODO |
| `/` | Search |
| `a` | Quick capture |
| `t` | Quick TODO |
| `n` | Quick text note |
| `c` | Quick checklist |
| `r` | Sync |
| `Esc` | Back / close |

Arrow keys are available as fallbacks.

### Text note editor

| Key | Action |
| --- | --- |
| `Tab` or `↓` | Title → body |
| `Shift+Tab` | Body → title |
| `Esc` | Editor normal mode |
| `i`, `Enter`, `j`, `↓` | Focus body |
| `t`, `k`, `↑` | Focus title |

### Checklist editor

| Key | Action |
| --- | --- |
| `j` / `k` | Select next / previous item |
| `Space` or `x` | Check / uncheck |
| `d` | Delete selected item |
| `Enter` or `e` | Edit selected item |
| `a` | Add item |
| `t` | Edit title |
| `Esc` | Return to normal mode |

While editing an item, `Tab`/`↓` moves forward, `Shift+Tab`/`↑` moves back,
`Ctrl+Space` toggles the item, and `Ctrl+d` deletes it.

## Update

```bash
omarchy plugin update dev.zed.keep-notes
```

The panel is loaded on demand, so the next summon uses the updated plugin code.

## Remove

```bash
omarchy plugin remove dev.zed.keep-notes
```

Credentials and the Python environment live outside the Git checkout. To
remove those too:

```bash
rm -rf ~/.local/state/keep-notes ~/.local/share/keep-notes
```

## Development

```bash
python scripts/validate.py
omarchy plugin validate .
```

For a local development copy:

```bash
./scripts/dev-install.sh
```

## Security

- Your Google password is never requested or stored.
- Treat the Master Token like a password.
- Credentials are stored only in the local state directory.
- `gkeepapi` is unofficial and may break when Google changes private APIs.
- Omarchy plugins run as unsandboxed user code; review plugins before enabling.

## License

MIT
