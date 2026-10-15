# Krom QuestHoard

Stops you vendoring the tradeable quest items you'll need later (Murloc Eyes,
Goretusk Snouts, Hops...), then tells you whether to AH or vendor them once
their quests are done. Soulbound quest items are ignored, since you can't sell those anyway.

- **Tooltips:** "KEEP Westfall Stew 2/3", "KEEP for <quest> (zone, level)", or
  "quests done - AH it (~1g 20s)" / "vendor it"
- **Popup (`/qh`):** your quest-log items, bag items to keep for later quests,
  drops to watch for in your current zone, and finished items to sell
- **Chat pings** when you loot something worth keeping
- **Auctionator (optional):** if installed, its scan prices drive the AH-vs-vendor verdict
- **Self-learning:** quest items missing from the built-in list get recorded as you see them

## Install (WowUp)

1. In WowUp, select your WoW install.
2. **Get Addons -> Install from URL**, paste this repo's link, install.
3. Restart the game. Updates show up in WowUp.

## Commands

- `/qh` toggle the list
- `/qh lock` lock/unlock the window
- `/qh reset` reset the window position
- `/qh learned` list items the addon learned on its own

## Data

`Data.lua` is generated from [QuestieDB](https://github.com/Questie/QuestieDB)'s
Forever data by `tools/extract_questie.py`. Thanks to the Questie team.
