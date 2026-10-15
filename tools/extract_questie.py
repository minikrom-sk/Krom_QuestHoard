"""Build Krom_QuestHoard's data file from QuestieDB's merged Forever tables.

Keeps every item that some quest asks you to collect (objective or required
source item), except mounts. The addon filters in game to items that aren't
soulbound and have a vendor value.

Usage: python3 extract.py <QuestieDB/src/corrections/Forever/combined> <lookupZones.lua> <out.lua>
"""
import re, sys
import lupa

COMBINED, ZONES_LUA, OUT = sys.argv[1:4]
QUEST_CLASS, MISC_CLASS, MOUNT_SUB = 12, 15, 5

L = lupa.LuaRuntime(unpack_returned_tuples=True)

def run_file(path):
    return L.execute(open(path, encoding="utf-8").read())

quests = run_file(f"{COMBINED}/foreverQuestDB.lua")
items = run_file(f"{COMBINED}/foreverItemDB.lua")

# Zone names: parse  [40]="Westfall",  lines out of Questie's lookup file.
zone_names = {}
for m in re.finditer(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', open(ZONES_LUA, encoding="utf-8").read()):
    zone_names.setdefault(int(m.group(1)), m.group(2).replace('\\"', '"'))

def lst(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []

WORDNUM = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
           "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20}

def count_in_text(text, item_name):
    """Questie has no objective counts, but the quest text usually says them:
    'Bring 4 Chunks of Boar Meat', 'wants 3 Murloc Eyes'. Match the number in
    front of the item name, allowing plurals on any word. None if not found."""
    words = item_name.split()
    pat = r"\s+".join(re.escape(w) + r"(?:e?s)?" if w.lower() not in ("of", "the") else re.escape(w) for w in words)
    m = re.search(r"\b(\d+|" + "|".join(WORDNUM) + r")\s+(?:of\s+(?:the|their|its)\s+)?" + pat + r"\b", text, re.I)
    if not m:
        return None
    n = m.group(1).lower()
    return int(n) if n.isdigit() else WORDNUM[n]

out, skipped = {}, 0
for qid, q in quests.items():
    if q is None or q[1] is None:
        continue
    wanted = []
    obj = q[10]
    if obj is not None and obj[3] is not None:
        wanted += [o[1] for o in lst(obj[3])]
    if q[21] is not None:
        wanted += lst(q[21])
    if int(q[24] or 0) & 1:   # repeatable quests would nag forever; skip them
        continue
    req_level = int(q[4] or 0)
    skill = int(q[18][1]) if q[18] is not None and q[18][1] is not None else 0
    zone = q[17] or 0
    zname = zone_names.get(zone, "Other") if zone > 0 else "Other"
    races = int(q[6] or 0) & 0xFFFFFFFF   # low 32 bits = race bitmask; 0 = everyone
    classes = int(q[7] or 0) & 0xFFFFFFFF
    for iid in dict.fromkeys(wanted):
        it = items[iid]
        if it is None or it[1] is None:
            continue
        cls, sub = it[12], it[13]
        # Item type is NOT a reliable tradeable signal (Forever made Okra a "Quest"
        # type item and it still sells on the AH). The addon decides in game from
        # binding + vendor value. Only mounts are dropped here.
        if cls == MISC_CLASS and sub == MOUNT_SUB:
            skipped += 1
            continue
        e = out.setdefault(iid, {"name": it[1], "quests": [], "vendor": it[14] is not None and len(it[14]) > 0})
        text = " ".join(t for t in lst(q[8]) if t) if q[8] is not None else ""
        need = count_in_text(text, it[1]) or 0
        e["quests"].append((int(qid), q[1], int(q[5] or 0), zname, races, classes, req_level, skill, need))

def s(x):
    return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = [
    "-- AUTO-GENERATED from QuestieDB's Forever data (thanks, Questie team).",
    "-- Do not hand-edit: regenerate with the extractor instead.",
    "-- [itemID] = { name, { {questID, questName, questLevel, zone, raceMask, classMask, requiredLevel, skillID, countNeeded}, ... }, soldByVendor }",
    "local _, ns = ...",
    "ns.items = {",
]
for iid in sorted(out):
    e = out[iid]
    qs = ", ".join("{%d,%s,%d,%s,%d,%d,%d,%d,%d}" % (a, s(b), c, s(d), r, k, rl, sk, n) for a, b, c, d, r, k, rl, sk, n in sorted(e["quests"], key=lambda t: (t[2], t[0])))
    lines.append("[%d]={%s,{%s}%s}," % (iid, s(e["name"]), qs, ",true" if e["vendor"] else ""))
lines.append("}")
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")

links=[q for e in out.values() for q in e["quests"]]
print(f"counts found for {sum(1 for q in links if q[8])} of {len(links)} quest links")
print(f"vendor-sold: {sum(1 for e in out.values() if e['vendor'])}")
print(f"kept {len(out)} tradeable items across {sum(len(e['quests']) for e in out.values())} quest links; skipped {skipped} mount links")
for want in ("Westfall", "Elwynn Forest", "Northshire Valley"):
    hits = sorted({e["name"] for e in out.values() for q in e["quests"] if q[3] == want})
    print(f"  {want}: {', '.join(hits)}")
