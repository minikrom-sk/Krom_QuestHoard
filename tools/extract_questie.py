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
        e["quests"].append((int(qid), q[1], int(q[5] or 0), zname, races, classes, req_level, skill))

def s(x):
    return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = [
    "-- AUTO-GENERATED from QuestieDB's Forever data (thanks, Questie team).",
    "-- Do not hand-edit: regenerate with the extractor instead.",
    "-- [itemID] = { name, { {questID, questName, questLevel, zone, raceMask, classMask, requiredLevel, skillID}, ... }, soldByVendor }",
    "local _, ns = ...",
    "ns.items = {",
]
for iid in sorted(out):
    e = out[iid]
    qs = ", ".join("{%d,%s,%d,%s,%d,%d,%d,%d}" % (a, s(b), c, s(d), r, k, rl, sk) for a, b, c, d, r, k, rl, sk in sorted(e["quests"], key=lambda t: (t[2], t[0])))
    lines.append("[%d]={%s,{%s}%s}," % (iid, s(e["name"]), qs, ",true" if e["vendor"] else ""))
lines.append("}")
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")

print(f"vendor-sold: {sum(1 for e in out.values() if e['vendor'])}")
print(f"kept {len(out)} tradeable items across {sum(len(e['quests']) for e in out.values())} quest links; skipped {skipped} mount links")
for want in ("Westfall", "Elwynn Forest", "Northshire Valley"):
    hits = sorted({e["name"] for e in out.values() for q in e["quests"] if q[3] == want})
    print(f"  {want}: {', '.join(hits)}")
