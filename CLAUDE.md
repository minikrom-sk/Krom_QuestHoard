# Krom QuestHoard (Krom_QuestHoard)

WoW addon for **WoW Forever** (Blizzard's Classic+; modern client) that also loads on
Classic Era. Built for Krom and a 3-4 person crew. Stops you vendoring tradeable quest
items you'll need later, then says AH or vendor once their quests are done. See README.md
for the feature list and commands.

## The person
- Former military, Director in film/TV/games. Not a programmer: keep answers short,
  plain-English, dry humour welcome. He tests in game and sends screenshots.
- Installs/updates via **WowUp** ("Install from URL", Forever client selected).

## Shipping (how every change goes out)
1. Edit, then syntax-check: `for f in *.lua; do lua5.1 -e "assert(loadfile('$f'))"; done`.
2. Bump `VERSION` (currently 0.9.0) and push to `main`.
3. `.github/workflows/release.yml` tags `vX` and runs `package.yml` (BigWigsMods/packager@v2)
   -> GitHub release with zip + release.json for WowUp. Pushing tags directly from a Claude
   session is blocked (403), so the workflow tags. Verify via REST:
   `gh api repos/minikrom-sk/Krom_QuestHoard/releases/tags/vX` (gh GraphQL is blocked).
4. Commit as: `git -c user.name="minikrom-sk" -c user.email="minikrom-sk@users.noreply.github.com" commit ...`
   Commit messages in the style "v0.9.0: <what changed>".
- `.pkgmeta`: package-as Krom_QuestHoard; ignores README.md, VERSION, CLAUDE.md, tools.

## Naming
- Display "Krom QuestHoard"; folders/files/zips/repos `Krom_QuestHoard`. Slash `/qh`
  (alias `/kromquesthoard`). Chat prefix "Krom QuestHoard:". SavedVariables `Krom_QuestHoardDB`.
- TOCs: `.toc`, `_Vanilla.toc` (Interface 11509), `_Camelot.toc` (Interface 16001 = Forever).

## Files
- **Krom_QuestHoard.lua** - everything (~2000 lines): tooltips, popup (full + compact modes),
  sections (quest log items, keep for later, watch in zone with zone picker, sell), filters
  (normal/profession, only my professions, level gap, hidden, done), 14 window styles, click
  actions (open quest / shift-link / ctrl-search AH), options panel (sectioned), minimap
  button, `/qh` commands incl. `/qh debug`. Locals forward-declared at top (render, refresh,
  setCompactFn) - watch for use-before-definition when adding code.
- **Data.lua** - GENERATED, don't hand-edit. `ns.items[itemID] = { name, { {questID, questName,
  questLevel, zone, raceMask, classMask, requiredLevel, skillID, countNeeded, professionSkillID}, ... },
  soldByVendor }`, plus `ns.questAlts` and `ns.zoneGroup`.
- **tools/extract_questie.py** - builds Data.lua from QuestieDB's Forever data with `lupa`:
  `python3 tools/extract_questie.py <QuestieDB/src/corrections/Forever/combined> <Questie lookupZones.lua> Data.lua`
  (clone github.com/Questie/QuestieDB and github.com/Questie/Questie). Keeps every item some quest
  asks for except mounts; tradeability is decided in game (not soulbound + has vendor price).

## Forever quirks learned the hard way
- No classic QuestLogFrame: use QuestMapFrame_OpenToQuestDetails / C_QuestLog.GetLogIndexForQuestID.
- Item type isn't a tradeable signal (Forever made Okra a "Quest" item and it still sells).
- Profession quests: required profession = full-colour icon, merely themed = dimmed.
- Auctionator (optional dep) prices drive the AH-vs-vendor verdict.

## User's WoW install (when the desktop link is available)
`F:\World of Warcraft\_classic_beta_\` - SavedVariables in
`WTF\Account\1331739#1\SavedVariables\`. Read-only; never edit his files.

## Sibling addon
Krom_TheSearchForMoreMoney (AH price tracker, /money) lives in its own repo and chat.
Keep the two separate.
