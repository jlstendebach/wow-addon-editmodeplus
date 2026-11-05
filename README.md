# Edit Mode Plus

Edit Mode Plus for World of Warcraft: Forever. Open Edit Mode, click anything, and change its visibility, opacity and draw order alongside Blizzard's own settings.

## Install

Copy the `EditModePlus` folder into `World of Warcraft\_forever_\Interface\AddOns\`. Everything in it is the addon. Everything outside it (this README, `tests/`) is for development only.

```
wow-addon-editmodeplus/
    EditModePlus/     <- the addon; copy this folder as-is
    tests/            <- stubbed-client tests
    README.md
```

The folder must stay named `EditModePlus` to match `EditModePlus.toc`.

For development, a local `deploy.bat` (kept out of git, since its paths are machine-specific) mirrors the folder into AddOns. Run it, then `/reload` in game, or restart WoW if files were added or removed.

## Use

**In Edit Mode**
- Click any system (action bars, gryphons, minimap, unit frames, ...). An Edit Mode Plus panel docks under Blizzard's settings dialog.
- **Visibility:** Default, Hidden, or Always shown. Hidden things stay visible at 30% while Edit Mode is open so you can still find them.
- **Opacity:** multiplies Blizzard's own opacity setting where one exists.
- **Strata / Frame level:** strata decides what draws on top. Frame level only orders frames within the same strata.
- **Pick any frame** (under the Edit Mode window) selects things Edit Mode can't, such as textures, minimap buttons and other addons' frames.
- Changes preview live and follow Edit Mode: **Save** keeps them and **Revert All Changes** undoes them. Closing Edit Mode with unsaved Edit Mode Plus changes asks whether to save them.

**Layouts**
- Settings are saved per Edit Mode layout and switch when the layout switches.
- New and copied layouts start with the settings of the layout they came from. Renaming or deleting a layout carries its settings along.
- Presets (Modern, Classic) can't be saved, same as in Edit Mode: Save asks for a new layout name.

**Outside Edit Mode**
- `/emp` or `/editmodeplus` lists every change in the current layout. Changes made there save immediately.
- `/emp pick` starts the picker. `/emp debug` toggles debug messages.
- Changes to protected frames, such as action bars, wait until combat ends.

**The gryphons:** in Forever they're Edit Mode systems at frame level 100, above the action bars at 50. Select one, set **Strata** to LOW, and the bars draw over it. Use strata, not frame level: Blizzard places some action button effects relative to the gryphons' level.

## How it works

- Each object is saved by path: a global name plus parentKey steps, such as `MainActionBar.EndCaps.LeftEndCap`.
- Hidden objects are reparented to a hidden frame, so Blizzard calling `Show()` on them has no effect.
- Hooks on `SetParent`, `Hide`, `SetAlpha`, `SetFrameStrata`, `SetFrameLevel` and `SetDrawLayer` re-apply settings when Blizzard's code changes them. The value Blizzard set is remembered and restored on **Default**.
- The Edit Mode integration only reads Edit Mode's state and hooks it with `hooksecurefunc`/`HookScript`. It never writes into Blizzard's frames or tables, to keep Edit Mode and the action bars free of taint. Its one action on Blizzard's UI is enabling the Save and Revert buttons when only Edit Mode Plus has changes.
- Saved data: `EditModePlusDB.profiles[layoutKey].entries[path]`.

## Tests

`tests/` loads the addon into a stubbed WoW client running real Lua 5.1. The stub follows the call order of Blizzard's Forever Edit Mode source (build 1.60.1.70790):

```powershell
pip install lupa
python tests/test.py
```

The stub is not the real client. Anything it passes still needs checking in game.
