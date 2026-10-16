# Krom QuestHoard

Stops you vendoring the tradeable quest items you'll need later (Murloc Eyes,
Goretusk Snouts, Hops...), then tells you whether to AH or vendor them once
their quests are done. Only tracks items that are not soulbound and that a vendor will buy (if a vendor won't take it, you can't vendor it by accident).

- **Tooltips:** "KEEP Westfall Stew 2/3", "KEEP for <quest> (zone, level)", or
  "quests done - AH it (~1g 20s)" / "vendor it"
- **Popup (`/qh`):** your quest-log items, bag items to keep for later quests,
  drops to watch for in your current zone (or any zone you pick), and finished items to sell
- **Chat pings** when you loot something worth keeping
- **Auctionator (optional):** if installed, its scan prices drive the AH-vs-vendor verdict
- **Minimap button:** left-click toggles the window, right-click opens options
  (also under the game's Options -> AddOns)
- **Right-click an item** in the window to hide it; tick "Hidden items" to see or unhide
- **Filters** for normal vs profession quests; profession icons are full color when the
  quest requires the profession, dimmed when it's only themed around it
- **Self-learning:** quest items missing from the built-in list get recorded as you see them

## Install (WowUp)

1. In WowUp, select your WoW install.
2. **Get Addons -> Install from URL**, paste this repo's link, install.
3. Restart the game. Updates show up in WowUp.

## Commands

- `/qh` toggle the list
- `/qh lock` lock/unlock the window
- `/qh reset` reset the window size and position
- `/qh options` open the settings panel
- `/qh minimap` show/hide the minimap button
- `/qh opacity 0-100` window background opacity
- `/qh learned` list items the addon learned on its own

## Data

`Data.lua` is generated from [QuestieDB](https://github.com/Questie/QuestieDB)'s
Forever data by `tools/extract_questie.py`. Thanks to the Questie team.

Minimap button uses LibStub, CallbackHandler, LibDataBroker and LibDBIcon (see `Libs/`).
