"""Build Krom_QuestHoard's data file from QuestieDB's merged Forever tables.

Keeps every item that some quest asks you to collect (objective or required
source item), except mounts. The addon filters in game to items that aren't
soulbound and have a vendor value.

Usage: python3 extract.py <QuestieDB/src/corrections/Forever/combined> <lookupZones.lua> <out.lua>
"""
import re, sys
import lupa

COMBINED, ZONES_LUA, OUT = sys.argv[1:4]
GROUPS = {1: "Eastern Kingdoms", 2: "Kalimdor", 8: "Zephras Isle", 9: "Dungeons & raids", 10: "Battlegrounds"}
QUEST_CLASS, MISC_CLASS, MOUNT_SUB = 12, 15, 5

L = lupa.LuaRuntime(unpack_returned_tuples=True)

def run_file(path):
    return L.execute(open(path, encoding="utf-8").read())

quests = run_file(f"{COMBINED}/foreverQuestDB.lua")
items = run_file(f"{COMBINED}/foreverItemDB.lua")
npcs = run_file(f"{COMBINED}/foreverNpcDB.lua")
objects = run_file(f"{COMBINED}/foreverObjectDB.lua")

def giver_zone(starters, enders):
    """Zone of whoever starts (or failing that, ends) the quest: NPC or object."""
    for grp in (starters, enders):
        if grp is None:
            continue
        for slot, db, zkey in ((1, npcs, 9), (2, objects, 5)):
            ids = grp[slot]
            if ids is None:
                continue
            for i in range(1, len(ids) + 1):
                e = db[ids[i]]
                if e is not None and (e[zkey] or 0) > 0:
                    return e[zkey]
    return 0

# Zone names: parse  [40]="Westfall",  lines out of Questie's lookup file.
zone_names = {}
for m in re.finditer(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', open(ZONES_LUA, encoding="utf-8").read()):
    zone_names.setdefault(int(m.group(1)), m.group(2).replace('\\"', '"'))

# Zone -> continent group, from Questie's zone categories.
L.execute('''
l10n = {}
local exp = setmetatable({Current = 1, Era = 1, Tbc = 2, Wotlk = 3, Cata = 4, MoP = 5}, {__index = function() return false end})
QuestieLoader = { ImportModule = function(_, name) if name == "l10n" then return l10n end return exp end }
''')
L.execute(open(ZONES_LUA, encoding="utf-8").read())
zone_group = {}
_cats = L.eval("l10n.zoneCategoryLookup")
for gid, gname in GROUPS.items():
    t = _cats[gid]
    if t is not None:
        for k in t:
            zone_group.setdefault(t[k], gname)

def lst(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []

PROF_SKILLS = {171, 164, 185, 333, 202, 129, 356, 182, 165, 186, 393, 197}
# A real profession requirement gives the skill ID. Quests that merely mention a
# profession's trainer (Forever's "My First Alchemy Set" is open to everyone but
# is for budding alchemists) get the NEGATIVE skill ID: "themed, not required".
PROF_WORDS = [(171, r"\balchemist"), (164, r"\bblacksmith"), (333, r"\benchanter"), (202, r"\bengineer"),
              (165, r"\bleatherworker"), (197, r"\btailor"), (182, r"\bherbalist"), (186, r"\bminer\b"),
              (356, r"\bfisherman\b"), (393, r"\bskinner\b"), (129, r"\bfirst aid\b"), (185, r"\bcooking\b")]

# Blizzard files profession quests under a profession category ("sort") instead
# of a zone; that's what puts them under a "Blacksmithing" header in the quest log.
SORT_PROF = {-121: 164, -181: 171, -182: 165, -201: 202, -264: 197, -304: 185, -324: 129, -101: 356, -24: 182}

def profession(skill, name, text, sort=0):
    if skill in PROF_SKILLS:
        return skill
    if sort in SORT_PROF:
        return SORT_PROF[sort]
    hay = (name + " " + text).lower()
    for sid, pat in PROF_WORDS:
        if re.search(pat, hay):
            return -sid
    return 0

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
    sort = zone if zone < 0 else 0
    if zone <= 0:
        # Category quests (professions, war effort, class...): use the zone the
        # quest-giver stands in.
        zone = giver_zone(q[2], q[3])
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
        prof = profession(skill, q[1], text, sort)
        e["quests"].append((int(qid), q[1], int(q[5] or 0), zname, races, classes, req_level, skill, need, prof))

def s(x):
    return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = [
    "-- AUTO-GENERATED from QuestieDB's Forever data (thanks, Questie team).",
    "-- Do not hand-edit: regenerate with the extractor instead.",
    "-- [itemID] = { name, { {questID, questName, questLevel, zone, raceMask, classMask, requiredLevel, skillID, countNeeded, professionSkillID}, ... }, soldByVendor }",
    "local _, ns = ...",
    "ns.items = {",
]
for iid in sorted(out):
    e = out[iid]
    qs = ", ".join("{%d,%s,%d,%s,%d,%d,%d,%d,%d,%d}" % (a, s(b), c, s(d), r, k, rl, sk, n, pf) for a, b, c, d, r, k, rl, sk, n, pf in sorted(e["quests"], key=lambda t: (t[2], t[0])))
    lines.append("[%d]={%s,{%s}%s}," % (iid, s(e["name"]), qs, ",true" if e["vendor"] else ""))
lines.append("}")
used = sorted({q[3] for e in out.values() for q in e["quests"]})
lines.append("ns.zoneGroup = {")
for z in used:
    lines.append("[%s]=%s," % (s(z), s(zone_group.get(z, "Other"))))
lines.append("}")
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")

links=[q for e in out.values() for q in e["quests"]]
print(f"profession links: required {sum(1 for q in links if q[9] > 0)}, themed {sum(1 for q in links if q[9] < 0)}")
print("zone groups:", {g: sum(1 for z in used if zone_group.get(z, "Other") == g) for g in set(list(GROUPS.values()) + ["Other"])})
print(f"counts found for {sum(1 for q in links if q[8])} of {len(links)} quest links")
print(f"vendor-sold: {sum(1 for e in out.values() if e['vendor'])}")
print(f"kept {len(out)} tradeable items across {sum(len(e['quests']) for e in out.values())} quest links; skipped {skipped} mount links")
for want in ("Westfall", "Elwynn Forest", "Northshire Valley"):
    hits = sorted({e["name"] for e in out.values() for q in e["quests"] if q[3] == want})
    print(f"  {want}: {', '.join(hits)}")
