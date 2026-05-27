# Knightmare Tower — Any% (Steam) auto-splitter

LiveSplit auto-splitter and splits template for Knightmare Tower on Steam,
Any% category.

## Files

All three files are named with a `<game>-<platform>-<category>` prefix so
multiple games can coexist in the same LiveSplit install without
collisions.

| File | What it is |
|---|---|
| `knightmare-tower-steam-any%.asl` | The auto-splitter script. Runs inside LiveSplit, reads game memory, fires start/split/reset. |
| `knightmare-tower-steam-any%.lsl` | LiveSplit layout. Loads the auto-splitter and provides the visual components (timer, splits list, Time + IGT columns). |
| `knightmare-tower-steam-any%.lss` | Splits file with the two segments and the cutscene offset pre-set, no history. Use this as the starting point for your splits. |

## One-time setup

1. **Place the `.asl` in a `scripts/` subfolder of your LiveSplit install.**
   Inside the directory that contains `LiveSplit.exe`, create a `scripts/`
   folder if it doesn't exist, and drop `knightmare-tower-steam-any%.asl`
   into it. The layout references the script as
   `scripts/knightmare-tower-steam-any%.asl`, and LiveSplit resolves
   relative paths against its own install dir, so this is the path that
   works out of the box. If you'd rather keep the script elsewhere, open
   the layout in LiveSplit, edit the *Scriptable Auto Splitter* component,
   and Browse to wherever you put the file.

2. **Open the `.lsl` in LiveSplit**: right-click LiveSplit → *Open Layout*
   → *From File…* → pick `knightmare-tower-steam-any%.lsl`.

3. **Open the `.lss` as your splits**: right-click LiveSplit → *Open
   Splits* → *From File…* → pick `knightmare-tower-steam-any%.lss`. Two
   segments appear: "Quests" and "Complete the game.". **Save the splits
   to your own filename** before running — otherwise your PBs will
   overwrite the template.

## Auto-splitter settings

In the layout's *Scriptable Auto Splitter* component (right-click LiveSplit
→ *Edit Layout* → *Scriptable Auto Splitter* → *Settings*):

| Setting | Default | What it does |
|---|---|---|
| `split_missions` | on | Splits when all 40 missions are complete (the key UI appears). Works for both normal completion and pay-to-skip. |
| `split_boss` | on | Splits at the last hit on the final boss (fires inside `BossBase.die()`, before the outro cinematic plays). |
| `reset_new_game` | on | Auto-resets when you accept a New Game from the title screen. |
| `start_new_game` | on | Auto-starts the timer at the end of the opening cutscene (the moment control returns to the player, after the 1.8s camera fade-in). The .lss carries a `+00:00:02.8` offset so the timer reads 2.8s at that moment — i.e. timing begins at the .mp4 last frame, including the post-movie black-fade + camera-tween in the run, per the SRC rule. Note: the timer is NOT visible during the cutscene; it appears at 2.8s when control returns. |
| `debug` | on | Verbose internal logging. You can leave this off — it's only useful when reporting a bug. |

## Timing

The script provides both **Real Time** (community-rule "RealTime to last hit
on boss") and **Game Time / IGT** (accumulated in-game frames across
attempts, divided by 60). A single split captures both at the same instant,
so the boss split records a correct value for either timing method.

The IGT column in the layout is configured to show Game Time alongside the
primary Time column.

## Known limitations

- **Timer keeps ticking when the game is unfocused or the cutscene is
  manually paused.** The script doesn't currently detect window focus loss.
  Uncommon during Any% but worth knowing.
- **Split 1 fires a few seconds after the underlying mission completes**,
  because the `finishedMissions` flag is set when the mission-completion UI
  finishes running its check. Same timing on the pay-to-skip path. Both are
  consistent across runs so segments compare cleanly.
- **Game must be in active play for the script to attach.** Mono lazy-loads
  the classes the script reads; if you start LiveSplit before the game
  reaches the main menu, init waits until enough classes are loaded.

## Tested against

- Knightmare Tower (Steam) — Unity 4.3.4f1, Mono 2.x, x86.
- LiveSplit 1.8.28.
