-- Krom QuestHoard
-- Flags quest items you could vendor by accident (not soulbound, has a vendor value)
-- so you keep them until their quests are done, then tells you AH or vendor.
-- Soulbound items and things vendors won't buy are ignored on purpose.
--
-- Data: ns.items (Data.lua, generated from QuestieDB's Forever data) plus anything
-- the addon learns from your quest log. Works on Classic Era and modern clients.

local ADDON, ns = ...
ns.items = ns.items or {}

local PREFIX = "|cffffb000Krom QuestHoard:|r "
local function say(msg) print(PREFIX .. msg) end

-- Defined further down; declared here so UI handlers above them can call them.
local render, refresh, setCompactFn

-- Settings live in Krom_QuestHoardDB; these read them with defaults.
local function opt(key, default)
  local db = Krom_QuestHoardDB
  if not db or db[key] == nil then return default end
  return db[key]
end

-- Items you've right-click hidden from the lists (db.hidden[itemID] = true).
local function isHidden(iid)
  local db = Krom_QuestHoardDB
  return iid and db and db.hidden and db.hidden[iid] or false
end
local function hiddenFiltered(iid) return isHidden(iid) and not opt("showHidden", false) end

-- Can the client load this texture? (Some textures differ between Classic and Forever.)
local function textureExists(path)
  if not GetFileIDFromPath then return true end -- can't check: assume yes
  local ok, id = pcall(GetFileIDFromPath, path)
  return ok and id ~= nil
end

-- Text colors for the window. Light window styles (parchment, paper) swap in
-- dark ink so the text stays readable; see applyStyle().
local C = { header = "|cffffd100", muted = "|cff999999", text = "|cffffffff", good = "|cff55ff55", hidden = "|cff777777" }
local DARK_INK  = { header = "|cff7a1f0a", muted = "|cff5c4a32", text = "|cff22160a", good = "|cff1f6e12", hidden = "|cff8c7b63" }
local LIGHT_INK = { header = "|cffffd100", muted = "|cff999999", text = "|cffffffff", good = "|cff55ff55", hidden = "|cff777777" }

-- Data row layout: ns.items[itemID] = { name, { {questID, questName, level, zone, raceMask, classMask, requiredLevel, skillID, countNeeded}, ... }, soldByVendor }
local Q_ID, Q_NAME, Q_LEVEL, Q_ZONE, Q_RACES, Q_CLASSES, Q_REQLEVEL, Q_SKILL, Q_NEED, Q_PROF = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

-- Profession quests get a little icon. Keyed by profession skill ID.
local PROFESSIONS = {
  [171] = { "Alchemy", "Trade_Alchemy" },
  [164] = { "Blacksmithing", "Trade_BlackSmithing" },
  [185] = { "Cooking", "INV_Misc_Food_15" },
  [333] = { "Enchanting", "Trade_Engraving" },
  [202] = { "Engineering", "Trade_Engineering" },
  [129] = { "First Aid", "Spell_Holy_SealOfSacrifice" },
  [356] = { "Fishing", "Trade_Fishing" },
  [182] = { "Herbalism", "Spell_Nature_NatureTouchGrow" },
  [165] = { "Leatherworking", "INV_Misc_ArmorKit_17" },
  [186] = { "Mining", "Trade_Mining" },
  [393] = { "Skinning", "INV_Misc_Pelt_Wolf_01" },
  [197] = { "Tailoring", "Trade_Tailoring" },
}
-- Q_PROF > 0: the quest REQUIRES that profession. Q_PROF < 0: the quest is
-- only themed around it (open to anyone), shown with a dimmed icon.
-- Profession quests seen under a profession header in your quest log
-- (Blizzard's own grouping, so it beats any guess). questID -> skill ID.
local liveProf = {}
local function profInfo(q)
  local id = q and q[Q_PROF] or 0
  if q and id <= 0 then
    local db = Krom_QuestHoardDB
    id = liveProf[q[Q_ID]] or (db and db.profQuests and db.profQuests[q[Q_ID]]) or id
  end
  local p = PROFESSIONS[math.abs(id)]
  return p, id < 0
end
local function profIcon(q)
  local p, themed = profInfo(q)
  if not p then return "" end
  if themed then
    return ("|TInterface\\Icons\\%s:12:12:0:0:64:64:4:60:4:60:120:120:120|t "):format(p[2])
  end
  return ("|TInterface\\Icons\\%s:12:12|t "):format(p[2])
end
local function profName(q)
  local p, themed = profInfo(q)
  if not p then return nil end
  return themed and (p[1] .. " themed, not required") or (p[1] .. " required")
end

-- Window filter: show/hide normal quests and profession quests.
local function isProfQuest(q) return (profInfo(q)) ~= nil end
local profByName = {}  -- lowercase profession name -> skill ID (quest-log headers)
for id, p in pairs(PROFESSIONS) do profByName[p[1]:lower()] = id end
-- Localized names, so headers match on non-English clients too.
if GetSpellInfo then
  local spells = { [171] = 2259, [164] = 2018, [185] = 2550, [333] = 7411, [202] = 4036, [129] = 3273,
                   [356] = 7620, [182] = 2366, [165] = 2108, [186] = 2575, [393] = 8613, [197] = 3908 }
  for id, spell in pairs(spells) do
    local ok, n = pcall(GetSpellInfo, spell)
    if ok and type(n) == "string" then profByName[n:lower()] = id end
  end
end

-- Professions this character knows (skill IDs), read from the game.
-- Refreshed at login and whenever skills change.
local knownProfs = {}
local function scanProfessions()
  wipe(knownProfs)
  if GetProfessions and GetProfessionInfo then -- modern clients
    for _, idx in ipairs({ GetProfessions() }) do
      if idx then
        local ok, name, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, idx)
        if ok then
          if skillLine and PROFESSIONS[skillLine] then knownProfs[skillLine] = true end
          local id = name and profByName[name:lower()]
          if id then knownProfs[id] = true end
        end
      end
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then -- classic clients
    for i = 1, (GetNumSkillLines() or 0) do
      local name, isHeader = GetSkillLineInfo(i)
      local id = name and not isHeader and profByName[name:lower()]
      if id then knownProfs[id] = true end
    end
  end
end
local function knowsProfession(q)
  local p = q and PROFESSIONS[math.abs(q[Q_PROF] or 0)] and math.abs(q[Q_PROF])
  if not p then -- header-learned profession
    local db = Krom_QuestHoardDB
    p = q and (liveProf[q[Q_ID]] or (db and db.profQuests and db.profQuests[q[Q_ID]]))
  end
  return p and knownProfs[p] or false
end

-- Profession quests: "Profession" filter shows/hides them all; "only my
-- professions" (Options) further limits them to professions you know.
-- Quests already in your quest log are never filtered (callers skip this).
local function passesFilter(q)
  if isProfQuest(q) then
    if not opt("showProf", true) then return false end
    if opt("myProfOnly", false) and not knowsProfession(q) then return false end
    return true
  end
  return opt("showNormal", true)
end

-- ---------------------------------------------------------------------------
-- API shims (Classic Era uses older globals, modern clients use C_ namespaces)
-- ---------------------------------------------------------------------------
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local function itemInfo(id)
  -- name, link, sellPrice, bindType  (bindType 1 = soulbound on pickup, 4 = quest)
  local ok, name, link, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = pcall(GetInfo, id)
  if ok then return name, link, sellPrice, bindType end
end

local function isBound(bindType) return bindType == 1 or bindType == 4 end

-- How many you own: bags plus bank (the bank part needs the client to know your
-- bank, which it does after you've opened it at least once).
local CountItem = (C_Item and C_Item.GetItemCount) or GetItemCount
local function owned(itemID)
  if not CountItem then return 0 end
  local ok, n = pcall(CountItem, itemID, true)
  return ok and tonumber(n) or 0
end

-- "x3" colored by progress toward the quest's need.
-- Compact lines: "3/5" (or "x3" when the count needed is unknown), colored by progress.
local function haveNeed(have, need)
  local c = have == 0 and C.muted or (need > 0 and have >= need) and C.good or C.text
  return need > 0 and ("%s%d/%d|r"):format(c, have, need) or ("%sx%d|r"):format(c, have)
end
local function questNote(q, need)
  local where = (q[Q_LEVEL] or 0) > 0 and (" (%s, lvl %d)"):format(q[Q_ZONE], q[Q_LEVEL]) or ""
  return ("For: %s%s%s"):format(q[Q_NAME], need > 0 and (" - needs " .. need) or "", where)
end

local function haveText(have, need)
  local c = have == 0 and C.muted or (need > 0 and have >= need) and C.good or C.text
  return ("%sx%d|r"):format(c, have)
end

-- The rule: we only care about items that aren't soulbound AND that a vendor
-- will buy. If a vendor won't take it, you can't vendor it by accident.
-- Returns true/false, or nil when the client hasn't loaded the item yet
-- (asking also makes the client fetch it; GET_ITEM_INFO_RECEIVED refreshes us).
local function sellable(itemID)
  if not itemID then return nil end
  local name, _, sell, bind = itemInfo(itemID)
  if not name then return nil end
  return (not isBound(bind)) and (sell or 0) > 0
end

local function isDone(questID)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
  elseif IsQuestFlaggedCompleted then
    return IsQuestFlaggedCompleted(questID) and true or false
  end
  return false
end

local NumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local SlotItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local function slotCount(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    return info and info.stackCount or 1
  elseif GetContainerItemInfo then
    local _, n = GetContainerItemInfo(bag, slot)
    return n or 1
  end
  return 1
end

local function bagCounts()
  local counts = {}
  if not (NumSlots and SlotItemID) then return counts end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, (NumSlots(bag) or 0) do
      local id = SlotItemID(bag, slot)
      if id then counts[id] = (counts[id] or 0) + slotCount(bag, slot) end
    end
  end
  return counts
end

local function money(copper)
  copper = math.floor((copper or 0) + 0.5)
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and s then return s end
  end
  return ("%dg %ds %dc"):format(copper / 10000, (copper / 100) % 100, copper % 100)
end

-- Auctionator is optional. If it's installed and has scan data, we use it.
local function ahPrice(itemID)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if api and api.GetAuctionPriceByItemID then
    local ok, p = pcall(api.GetAuctionPriceByItemID, ADDON, itemID)
    if ok and type(p) == "number" and p > 0 then return p end
  end
end

local AH_CUT = 0.95 -- the AH keeps 5% of the sale

-- "ah" if the AH beats the vendor after the AH cut, "vendor" otherwise.
local function verdict(itemID)
  local _, _, sell = itemInfo(itemID)
  sell = sell or 0
  local ah = ahPrice(itemID)
  if ah and ah * AH_CUT > sell then return "ah", ah, sell end
  return "vendor", ah, sell
end

-- ---------------------------------------------------------------------------
-- Who am I (race/class filters for quests)
-- ---------------------------------------------------------------------------
local raceBit, classBit
local function setPlayerBits()
  local _, _, raceID = UnitRace("player")
  local _, _, classID = UnitClass("player")
  raceBit = (raceID and raceID >= 1 and raceID <= 32) and 2 ^ (raceID - 1) or nil
  classBit = (classID and classID >= 1 and classID <= 32) and 2 ^ (classID - 1) or nil
end
local function fits(mask, b)
  if not mask or mask == 0 or not b or not bit then return true end
  return bit.band(mask, b) ~= 0
end

-- ---------------------------------------------------------------------------
-- Indexes built once at load
-- ---------------------------------------------------------------------------
local nameIndex = {}   -- lowercase item name -> itemID
local zoneIndex = {}   -- zone name -> { {itemID, questRow}, ... }
local questIndex = {}  -- questID -> quest record (for profession/zone lookups)

local function buildIndexes()
  for iid, row in pairs(ns.items) do
    nameIndex[row[1]:lower()] = iid
    for _, q in ipairs(row[2]) do
      questIndex[q[Q_ID]] = questIndex[q[Q_ID]] or q
      local z = q[Q_ZONE]
      zoneIndex[z] = zoneIndex[z] or {}
      table.insert(zoneIndex[z], { iid, q })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Quest log scan
-- ---------------------------------------------------------------------------
local active = {}        -- questID -> true for quests in your log
local progress = {}      -- "questID:itemname" -> {have, need}
local activeItems = {}   -- ordered list of tradeable item objectives in your log

local function parseObjective(text)
  if type(text) ~= "string" then return end
  text = text:gsub("%s*%(Complete%)%s*$", "")
  local name, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)")
  if name then return name, tonumber(have), tonumber(need) end
  have, need, name = text:match("^(%d+)%s*/%s*(%d+)%s+(.+)$")
  if name then return name, tonumber(have), tonumber(need) end
end

-- Calls cb(title, questID, logIndex, headerName) for each quest in your log.
local function forEachQuest(cb)
  local header
  if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
    for i = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
      local info = C_QuestLog.GetInfo(i)
      if info and info.isHeader then header = info.title
      elseif info and info.title then cb(info.title, info.questID, i, header) end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    for i = 1, (GetNumQuestLogEntries() or 0) do
      local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
      if isHeader then header = title
      elseif title then cb(title, questID, i, header) end
    end
  end
end

local function getObjectives(questID, index)
  local out = {}
  if questID and C_QuestLog and C_QuestLog.GetQuestObjectives then
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if objs and #objs > 0 then
      for _, o in ipairs(objs) do
        out[#out + 1] = { text = o.text, type = o.type, finished = o.finished,
                          have = o.numFulfilled, need = o.numRequired }
      end
      return out
    end
  end
  if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
    for j = 1, (GetNumQuestLeaderBoards(index) or 0) do
      local text, otype, finished = GetQuestLogLeaderBoard(j, index)
      out[#out + 1] = { text = text, type = otype, finished = finished }
    end
  end
  return out
end

local function learn(lname, name, questID, title)
  local db = Krom_QuestHoardDB
  if not (db and questID) then return end
  db.learned = db.learned or {}
  local e = db.learned[lname] or { name = name, quests = {} }
  e.quests[questID] = title
  db.learned[lname] = e
end

-- Item ID from its name, if the client has seen the item (bags, bank, cache).
local function idFromName(name)
  local ok, _, link = pcall(GetInfo, name)
  return ok and type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function scan()
  wipe(active); wipe(progress); wipe(activeItems)
  forEachQuest(function(title, questID, index, header)
    if questID then active[questID] = true end
    local hp = header and profByName[header:lower()]
    if questID and hp then
      liveProf[questID] = hp
      local db = Krom_QuestHoardDB
      if db then db.profQuests = db.profQuests or {}; db.profQuests[questID] = hp end
    end
    for _, o in ipairs(getObjectives(questID, index)) do
      if o.type == "item" then
        local name, have, need = parseObjective(o.text)
        have = tonumber(o.have) or have or 0
        need = tonumber(o.need) or need
        if name and need and need > 0 then
          local lname = name:lower()
          progress[(questID or 0) .. ":" .. lname] = { have = have, need = need }
          local learnedEntry = Krom_QuestHoardDB and Krom_QuestHoardDB.learned and Krom_QuestHoardDB.learned[lname]
          if not nameIndex[lname] and not (learnedEntry and learnedEntry.tradeable == false) then
            learn(lname, name, questID, title)
          end
          local tradeable
          if nameIndex[lname] then
            tradeable = sellable(nameIndex[lname])
          elseif learnedEntry then
            tradeable = learnedEntry.tradeable
          end
          if tradeable then
            activeItems[#activeItems + 1] = { iid = nameIndex[lname] or (learnedEntry and learnedEntry.itemID) or idFromName(name),
                                              name = name, have = have, need = need, quest = title,
                                              q = (questID and questIndex[questID]) or { questID or 0, title, 0, "", 0, 0, 0, 0, 0, 0 },
                                              done = o.finished or have >= need }
          end
        end
      end
    end
  end)
end

local function currentZones()
  local z = {}
  if GetRealZoneText then z[GetRealZoneText() or ""] = true end
  if GetZoneText then z[GetZoneText() or ""] = true end
  if GetSubZoneText then z[GetSubZoneText() or ""] = true end
  return z
end

-- The zone(s) the window is "looking at": the picked zone, or where you are.
local function viewedZones()
  local picked = opt("showWatch", true) and Krom_QuestHoardDB and Krom_QuestHoardDB.watchZone
  if picked then return { [picked] = true } end
  return currentZones()
end

-- Quests (for this character) that want an item: from data, then learned.
local function questsFor(itemID, lname)
  local list = {}
  local row = itemID and ns.items[itemID]
  if row then
    -- row[3]: a vendor sells it. Only worth flagging for quests in the zone
    -- you're watching (unless "track vendor items everywhere" is on).
    local zones = row[3] and not opt("vendorItems", false) and viewedZones() or nil
    for _, q in ipairs(row[2]) do
      if fits(q[Q_RACES], raceBit) and fits(q[Q_CLASSES], classBit) and (not zones or zones[q[Q_ZONE]]) then
        list[#list + 1] = q
      end
    end
    return list
  end
  local learned = lname and Krom_QuestHoardDB and Krom_QuestHoardDB.learned and Krom_QuestHoardDB.learned[lname]
  if learned and learned.tradeable ~= false then
    for qid, title in pairs(learned.quests) do list[#list + 1] = { qid, title, 0, "learned", 0, 0, 0, 0 } end
  end
  return list
end

-- Done if this quest, or any alternate version / either-or quest / next quest
-- in its chain, is done (see ns.questAlts from the data file).
local function questState(questID)
  if active[questID] then return "active" end
  if isDone(questID) then return "done" end
  local alts = ns.questAlts and ns.questAlts[questID]
  if alts then
    for _, a in ipairs(alts) do if isDone(a) then return "done" end end
  end
  return "todo"
end

-- "Too high for now" filter: quests more than 10 levels above you are skipped
-- unless the "High level" box is ticked.
local LEVEL_GAP = 10 -- default; Options slider / /qh levels changes it (db.levelGap)
local function levelOK(q)
  if opt("showHigh", false) then return true end
  local my = UnitLevel and UnitLevel("player") or 60
  return (q[Q_LEVEL] or 0) <= my + opt("levelGap", LEVEL_GAP)
end

-- Quests that still need the item, active ones first. Empty when all are done.
local function openQuests(qs)
  local act, todo = {}, {}
  for _, q in ipairs(qs) do
    local st = questState(q[Q_ID])
    if st == "active" then act[#act + 1] = q elseif st == "todo" then todo[#todo + 1] = q end
  end
  for _, q in ipairs(todo) do act[#act + 1] = q end
  return act
end

-- ---------------------------------------------------------------------------
-- Bag tracking + loot pings
-- ---------------------------------------------------------------------------
local lastBags = {}
local primed = false
local keepList, sellList = {}, {}

local function scanBags()
  wipe(keepList); wipe(sellList)
  local bags = bagCounts()
  for iid, count in pairs(bags) do
    local name = itemInfo(iid)
    local lname = type(name) == "string" and name:lower() or nil
    local ok = sellable(iid)
    -- Learned items: (re)check whether they're worth tracking whenever we hold one.
    local learned = lname and Krom_QuestHoardDB and Krom_QuestHoardDB.learned and Krom_QuestHoardDB.learned[lname]
    if learned and ok ~= nil then learned.tradeable = ok; learned.itemID = iid end

    if ok then
      local qs = questsFor(iid, lname)
      if #qs > 0 then
        local open = openQuests(qs)
        local display = (ns.items[iid] and ns.items[iid][1]) or name or ("item " .. iid)
        -- Items for quests in your log already show in the quest-log section;
        -- this list is for the ones you're holding for LATER quests.
        local later
        for _, q in ipairs(open) do
          if not active[q[Q_ID]] and passesFilter(q) and levelOK(q) then later = q; break end
        end
        if later then
          keepList[#keepList + 1] = { iid = iid, name = display, count = count, quest = later }
          local old = lastBags[iid] or 0
          if primed and count > old then
            if opt("pings", true) and not isHidden(iid) then
              say(("|cffffb000KEEP|r %s x%d - needed later for %s"):format(display, count, later[Q_NAME]))
            end
          end
        elseif #open == 0 then
          sellList[#sellList + 1] = { iid = iid, name = display, count = count }
        end
      end
    end
  end
  lastBags = bags
end

-- Quest-log pings for items your active quests want.
local lastHave = {}
local function checkQuestPings()
  local seen = {}
  for _, e in ipairs(activeItems) do
    local k = e.quest .. "\0" .. e.name
    seen[k] = true
    local old = lastHave[k]
    if primed and old and e.have > old and opt("pings", true) and not isHidden(e.iid) then
      local color = e.have >= e.need and "|cff55ff55" or "|cffffffff"
      say(("%s%s %d/%d|r (%s)"):format(color, e.name, e.have, e.need, e.quest))
    end
    lastHave[k] = e.have
  end
  for k in pairs(lastHave) do if not seen[k] then lastHave[k] = nil end end
end

-- ---------------------------------------------------------------------------
-- Popup window
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "Krom_QuestHoardFrame", UIParent,
  BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(340, 60)
frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
frame:SetBackdrop({
  bgFile = "Interface\\Buttons\\WHITE8x8", -- solid fill: the tooltip texture is see-through by design
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.8)

frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self)
  if not (Krom_QuestHoardDB and Krom_QuestHoardDB.locked) then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  Krom_QuestHoardDB.pos = { p, rp, x, y }
end)
frame:Hide()

local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", 10, -9)
header:SetText("Krom QuestHoard")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function()
  frame:Hide(); Krom_QuestHoardDB.shown = false
  say("hidden. /qh or the minimap button brings it back.")
end)
-- "Compact" button next to close: swaps the window for the slim tracker list.
local slim = CreateFrame("Button", nil, frame)
slim:SetSize(28, 28)
slim:SetPoint("RIGHT", close, "LEFT", 4, 0)
slim:SetNormalTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Up")
slim:SetPushedTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Down")
slim:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
slim:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Compact mode")
  GameTooltip:AddLine("Swap to a slim list with no background.", 1, 1, 1)
  GameTooltip:Show()
end)
slim:SetScript("OnLeave", function() GameTooltip:Hide() end)
slim:SetScript("OnClick", function() if setCompactFn then setCompactFn(true) end end)

-- Scrollable content area (mouse wheel), with a resize grip in the corner.
local AUTO_MAX_HEIGHT = 480
local scroll = CreateFrame("ScrollFrame", nil, frame)
scroll:SetPoint("BOTTOMRIGHT", -6, 20)
if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(330, 1)
scroll:SetScrollChild(content)

local moreHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
moreHint:SetPoint("BOTTOMLEFT", 12, 6)
moreHint:SetText("scroll for more")
moreHint:Hide()

local function clampScroll(v)
  local max = math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0))
  v = math.max(0, math.min(v or scroll:GetVerticalScroll() or 0, max))
  scroll:SetVerticalScroll(v)
  if v < max - 1 then moreHint:Show() else moreHint:Hide() end
end
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(_, delta) clampScroll((scroll:GetVerticalScroll() or 0) - delta * 42) end)

frame:SetResizable(true)
if frame.SetResizeBounds then
  frame:SetResizeBounds(300, 110, 800, 1000)
elseif frame.SetMinResize then
  frame:SetMinResize(300, 110); frame:SetMaxResize(800, 1000)
end
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -3, 3)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
-- Hand-rolled resizing: the window follows the mouse by exactly how far you
-- drag, so a click without a drag changes nothing (StartSizing could creep).
local sizing = false
local function cursorPos()
  local x, y = GetCursorPosition()
  local sc = UIParent:GetEffectiveScale()
  return x / sc, y / sc
end
local function startDrag(target, grip, minW, maxW, minH, maxH, onDone)
  local left, top = target:GetLeft(), target:GetTop()
  if not (left and top) then return end
  target:ClearAllPoints()
  target:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top) -- pin top-left
  local sx, sy = cursorPos()
  local w0, h0 = target:GetWidth(), target:GetHeight()
  -- never past the right/bottom edge of the screen
  maxW = math.min(maxW, (UIParent:GetRight() or 2000) - left - 4)
  if maxH then maxH = math.min(maxH, top - (UIParent:GetBottom() or 0) - 4) end
  grip:SetScript("OnUpdate", function()
    local cx, cy = cursorPos()
    target:SetWidth(math.max(minW, math.min(maxW, w0 + (cx - sx))))
    if maxH then target:SetHeight(math.max(minH, math.min(maxH, h0 + (sy - cy)))) end
  end)
  grip.finish = function()
    grip:SetScript("OnUpdate", nil)
    grip.finish = nil
    onDone()
  end
end

grip:SetScript("OnMouseDown", function(self)
  if Krom_QuestHoardDB and Krom_QuestHoardDB.locked then return end
  sizing = true
  startDrag(frame, self, 300, 800, 110, 1000, function()
    sizing = false
    Krom_QuestHoardDB.height = math.floor(frame:GetHeight() + 0.5)
    Krom_QuestHoardDB.width = math.floor(frame:GetWidth() + 0.5)
    local p, _, rp, x, y = frame:GetPoint()
    Krom_QuestHoardDB.pos = { p, rp, x, y }
    clampScroll()
  end)
end)
grip:SetScript("OnMouseUp", function(self) if self.finish then self.finish() end end)
-- One font for the window's lists, resizable from Options (/qh font).
local listFont = CreateFont("Krom_QuestHoardListFont")
listFont:CopyFontObject(GameFontHighlightSmall)
local BASE_FONT, BASE_SIZE, BASE_FLAGS = GameFontHighlightSmall:GetFont()
BASE_SIZE = math.floor((BASE_SIZE or 10) + 0.5)
local function applyFont()
  listFont:SetFont(BASE_FONT, opt("fontSize", BASE_SIZE), BASE_FLAGS)
  if Krom_QuestHoardCompactFont then
    Krom_QuestHoardCompactFont:SetFont(BASE_FONT, opt("fontSize", BASE_SIZE), "OUTLINE")
  end
  if refresh then refresh() end
end

-- Each list row is a button: hover shows the item tooltip, right-click hides it.
local lines = {}
local function fitWidths()
  local w = (frame:GetWidth() or 340) - 26
  content:SetWidth(w)
  for _, row in ipairs(lines) do row:SetWidth(w - 8); row.fs:SetWidth(w - 8) end
end
frame:SetScript("OnSizeChanged", function() fitWidths(); clampScroll() end)

local function toggleHidden(iid)
  local db = Krom_QuestHoardDB
  db.hidden = db.hidden or {}
  db.hidden[iid] = (not db.hidden[iid]) or nil
  local name = (ns.items[iid] and ns.items[iid][1]) or itemInfo(iid) or ("item " .. iid)
  say(db.hidden[iid] and ("hid %s. Tick 'Hidden' in the window to see or unhide it."):format(name)
                     or ("%s is back on the list."):format(name))
  if refresh then refresh() end
end

-- ---------------------------------------------------------------------------
-- Row click actions: left = quest log, shift = link in chat, ctrl = AH search
-- ---------------------------------------------------------------------------
local LINK_CHANNELS = { "PARTY", "SAY", "GUILD", "RAID", "YELL" }
local CHANNEL_NAMES = { PARTY = "Party", SAY = "Say", GUILD = "Guild", RAID = "Raid", YELL = "Yell" }

local function itemLink(iid)
  local name, link = itemInfo(iid)
  return link or (name and ("[" .. name .. "]")) or ("item " .. iid)
end

-- Shift-click: link the item in chat. If a chat box is open, drop it in there
-- (normal WoW behavior); otherwise send to the chosen channel.
local function linkInChat(row)
  local link = itemLink(row.iid)
  local q = row.quest
  local need = q and (q[Q_NEED] or 0) or 0
  local msg = link .. " - have " .. owned(row.iid) .. (need > 0 and ("/" .. need) or "")
  if q and q[Q_NAME] then msg = msg .. " (" .. q[Q_NAME] .. ")" end
  local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
  if editBox and ChatEdit_InsertLink then ChatEdit_InsertLink(msg); return end
  local ch = opt("linkChannel", "PARTY")
  local inGroup = (IsInGroup and IsInGroup()) or (GetNumPartyMembers and GetNumPartyMembers() > 0)
  local inRaid = (IsInRaid and IsInRaid()) or (GetNumRaidMembers and GetNumRaidMembers() > 0)
  local inGuild = IsInGuild and IsInGuild()
  if (ch == "PARTY" and not inGroup) or (ch == "RAID" and not inRaid) or (ch == "GUILD" and not inGuild) then
    say(("you're not in a %s - opening chat with the link instead."):format(CHANNEL_NAMES[ch]:lower()))
    if ChatFrame_OpenChat then ChatFrame_OpenChat(msg) end
    return
  end
  SendChatMessage(msg, ch)
end

-- Ctrl-click: search the open Auction House (Auctionator if present).
local function searchAH(row)
  local name = itemInfo(row.iid) or (ns.items[row.iid] and ns.items[row.iid][1])
  if not name then return end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  local ahOpen = (AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and AuctionHouseFrame:IsShown())
  if not ahOpen then say("open the Auction House first, then Ctrl-click."); return end
  if api and api.MultiSearchExact and pcall(api.MultiSearchExact, ADDON, { name }) then return end
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame.SearchBar then
    local bar = AuctionHouseFrame.SearchBar
    if bar.SearchBox then bar.SearchBox:SetText(name) end
    if bar.StartSearch then pcall(bar.StartSearch, bar) end
    return
  end
  if BrowseName and AuctionFrameBrowse_Search then
    if AuctionFrameTab_OnClick and AuctionFrameTab1 then pcall(AuctionFrameTab_OnClick, AuctionFrameTab1) end
    BrowseName:SetText(name)
    pcall(AuctionFrameBrowse_Search)
    return
  end
  say("couldn't find the Auction House search box on this client.")
end

-- Left-click: open the quest log to this quest (if it's in your log).
local function showInQuestLog(row)
  local q = row.quest
  if type(q) ~= "table" then return end
  local qid = q[Q_ID]
  if not active[qid] then
    local where = (q[Q_LEVEL] or 0) > 0 and (" - %s, level %d"):format(q[Q_ZONE], q[Q_LEVEL]) or ""
    say(("%s isn't in your quest log yet%s."):format(q[Q_NAME], where))
    return
  end
  -- Same approach as Questie: prefer the classic-style log (Forever has it),
  -- fall back to the modern map quest log only if there isn't one.
  if InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() then
    say("open the quest log with your controller (addons can't in controller mode).")
    return
  end
  if InCombatLockdown and InCombatLockdown() then
    say("can't open the quest log in combat.")
    return
  end
  local questFrame = QuestLogExFrame or ClassicQuestLog or QuestLogFrame
  if not questFrame then
    -- Modern quest log lives in the world map. Try the direct call, then check
    -- that the map really opened; if not, open the map ourselves and select it.
    local tried = {}
    local function mapOpen() return WorldMapFrame and WorldMapFrame:IsShown() end
    if QuestMapFrame_OpenToQuestDetails then
      tried[#tried + 1] = "OpenToQuestDetails"
      local ok, err = pcall(QuestMapFrame_OpenToQuestDetails, qid)
      if not ok then tried[#tried] = "OpenToQuestDetails (error: " .. tostring(err) .. ")" end
    end
    C_Timer.After(0.15, function()
      if mapOpen() then return end
      if C_QuestLog and C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, qid) end
      if OpenWorldMap then
        tried[#tried + 1] = "OpenWorldMap"; pcall(OpenWorldMap)
      elseif ToggleWorldMap then
        tried[#tried + 1] = "ToggleWorldMap"; pcall(ToggleWorldMap)
      elseif WorldMapFrame then
        tried[#tried + 1] = "ShowUIPanel(WorldMapFrame)"; pcall(ShowUIPanel, WorldMapFrame)
      end
      if QuestMapFrame_ShowQuestDetails then
        tried[#tried + 1] = "ShowQuestDetails"; pcall(QuestMapFrame_ShowQuestDetails, qid)
      end
      C_Timer.After(0.15, function()
        if not mapOpen() and ToggleQuestLog then
          tried[#tried + 1] = "ToggleQuestLog"; pcall(ToggleQuestLog)
        end
        C_Timer.After(0.15, function()
          if not mapOpen() then
            say("couldn't open the quest log. Tried: " .. table.concat(tried, ", ") .. ". Please screenshot this for Krom.")
          end
        end)
      end)
    end)
    return
  end
  local idx = GetQuestLogIndexByID and GetQuestLogIndexByID(qid)
  if (not idx or idx == 0) and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
    idx = C_QuestLog.GetLogIndexForQuestID(qid)
  end
  if not idx or idx == 0 then
    say(("couldn't find %s in the quest log (quest %d)."):format(q[Q_NAME] or "that quest", qid))
    return
  end
  if C_QuestLog and C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, qid)
  elseif QuestLog_SetSelection then pcall(QuestLog_SetSelection, idx)
  elseif SelectQuestLogEntry then pcall(SelectQuestLogEntry, idx) end
  local bar = (QuestLogListScrollFrame and QuestLogListScrollFrame.ScrollBar) or QuestLogListScrollFrameScrollBar
  if bar and bar.GetValueStep and bar.SetValue then
    local step = bar:GetValueStep() or 0
    pcall(bar.SetValue, bar, idx * step - step * 3)
  end
  if not questFrame:IsShown() then
    local ok, err = pcall(ShowUIPanel, questFrame)
    if not ok then say("couldn't open the quest log: " .. tostring(err)) end
  end
  if QuestLog_UpdateQuestDetails then pcall(QuestLog_UpdateQuestDetails) end
  if QuestLog_Update then pcall(QuestLog_Update) end
end

-- Section collapse state (shared by both modes): db.collapsed[key] = true
local function isCollapsed(key)
  return key and Krom_QuestHoardDB and Krom_QuestHoardDB.collapsed and Krom_QuestHoardDB.collapsed[key] or false
end
local function toggleCollapsed(key)
  local db = Krom_QuestHoardDB
  db.collapsed = db.collapsed or {}
  db.collapsed[key] = (not db.collapsed[key]) or nil
  if refresh then refresh() end
end

-- A pool of clickable text rows. Item rows: hover = item tooltip, right-click
-- = hide. Header rows: left-click = collapse/expand that section.
local function makePool(parent, fontObj, widthFn)
  local pool = {}
  function pool.get(i)
    if not pool[i] then
      local row = CreateFrame("Button", nil, parent)
      row:SetHeight(14)
      row:SetWidth(widthFn())
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      local fs = row:CreateFontString(nil, "OVERLAY")
      fs:SetFontObject(fontObj)
      fs:SetPoint("TOPLEFT")
      fs:SetJustifyH("LEFT")
      fs:SetWidth(widthFn())
      row.fs = fs
      local hl = row:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.07)
      row:SetScript("OnClick", function(self, button)
        if self.collapseKey and button == "LeftButton" then toggleCollapsed(self.collapseKey)
        elseif button == "RightButton" and self.iid then toggleHidden(self.iid)
        elseif button == "LeftButton" and (self.iid or self.quest) then
          if self.iid and IsShiftKeyDown() then linkInChat(self)
          elseif self.iid and IsControlKeyDown() then searchAH(self)
          else showInQuestLog(self) end
        end
      end)
      row:SetScript("OnEnter", function(self)
        if self.collapseKey then
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(isCollapsed(self.collapseKey) and "Click to expand" or "Click to collapse")
          GameTooltip:Show()
        elseif self.iid then
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetHyperlink("item:" .. self.iid)
          GameTooltip:AddLine(" ")
          if self.quest then GameTooltip:AddLine("|cff999999Click: open in quest log|r") end
          GameTooltip:AddLine(("|cff999999Shift-click: link in %s chat|r"):format(CHANNEL_NAMES[opt("linkChannel", "PARTY")]))
          GameTooltip:AddLine("|cff999999Ctrl-click: search the Auction House|r")
          GameTooltip:AddLine(isHidden(self.iid) and "|cff999999Right-click: unhide|r" or "|cff999999Right-click: hide from QuestHoard|r")
          GameTooltip:Show()
        end
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      pool[i] = row
    end
    return pool[i]
  end
  return pool
end
local fullPool = makePool(content, listFont, function() return (frame:GetWidth() or 340) - 34 end)
lines = fullPool -- fitWidths() resizes these

-- ---------------------------------------------------------------------------
-- Compact tracker: no background, just an outlined list (Questie-tracker style)
-- ---------------------------------------------------------------------------
local COMPACT_W = 220 -- default; drag the corner grip to change (saved as db.cwidth)
local compactFont = CreateFont("Krom_QuestHoardCompactFont")
compactFont:CopyFontObject(GameFontHighlightSmall)
local compact = CreateFrame("Frame", "Krom_QuestHoardCompactFrame", UIParent)
compact:SetSize(COMPACT_W, 40)
compact:SetPoint("RIGHT", UIParent, "RIGHT", -60, 120)
compact:SetClampedToScreen(true)
compact:SetMovable(true)
compact:Hide()
local compactTitle = CreateFrame("Button", nil, compact)
compactTitle:SetHeight(16)
compactTitle:SetPoint("TOPLEFT")
compactTitle:SetPoint("TOPRIGHT")
compactTitle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
compactTitle:RegisterForDrag("LeftButton")
local compactTitleText = compactTitle:CreateFontString(nil, "OVERLAY")
compactTitleText:SetFontObject(compactFont)
compactTitleText:SetPoint("LEFT")
compactTitle:SetScript("OnDragStart", function()
  if not (Krom_QuestHoardDB and Krom_QuestHoardDB.locked) then compact:StartMoving() end
end)
compactTitle:SetScript("OnDragStop", function()
  compact:StopMovingOrSizing()
  local p, _, rp, x, y = compact:GetPoint()
  Krom_QuestHoardDB.cpos = { p, rp, x, y }
end)
compactTitle:SetScript("OnClick", function(_, button)
  if button == "RightButton" and setCompactFn then setCompactFn(false) end
end)
compactTitle:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Krom QuestHoard (compact)")
  GameTooltip:AddLine("Drag to move. Click a heading to collapse it.", 1, 1, 1)
  GameTooltip:AddLine("Right-click: switch to the full window.", 1, 1, 1)
  GameTooltip:Show()
end)
compactTitle:SetScript("OnLeave", function() GameTooltip:Hide() end)
local compactContent = CreateFrame("Frame", nil, compact)
compactContent:SetPoint("TOPLEFT", 0, -18)
compactContent:SetSize(COMPACT_W, 1)
local compactPool = makePool(compactContent, compactFont, function() return (compact:GetWidth() or COMPACT_W) - 4 end)

-- Width grip: only visible while the mouse is over the list.
compact:SetResizable(true)
if compact.SetResizeBounds then compact:SetResizeBounds(140, 30, 500, 2000)
elseif compact.SetMinResize then compact:SetMinResize(140, 30); compact:SetMaxResize(500, 2000) end
local cgrip = CreateFrame("Button", nil, compact)
cgrip:SetSize(14, 14)
cgrip:SetPoint("BOTTOMRIGHT", 0, 0)
cgrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
cgrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
cgrip:SetAlpha(0)
local function fitCompactWidths()
  local w = (compact:GetWidth() or COMPACT_W)
  compactContent:SetWidth(w)
  for _, row in ipairs(compactPool) do row:SetWidth(w - 4); row.fs:SetWidth(w - 4) end
end
local csizing = false
cgrip:SetScript("OnMouseDown", function(self)
  if Krom_QuestHoardDB and Krom_QuestHoardDB.locked then return end
  csizing = true
  startDrag(compact, self, 140, 500, nil, nil, function()
    csizing = false
    Krom_QuestHoardDB.cwidth = math.floor(compact:GetWidth() + 0.5)
    local p, _, rp, x, y = compact:GetPoint()
    Krom_QuestHoardDB.cpos = { p, rp, x, y }
    if refresh then refresh() end
  end)
end)
cgrip:SetScript("OnMouseUp", function(self) if self.finish then self.finish() end end)
compact:SetScript("OnSizeChanged", fitCompactWidths)
-- Reveal the grip while hovering anywhere on the list.
compact:SetScript("OnUpdate", function(self, elapsed)
  self.t = (self.t or 0) + elapsed
  if self.t < 0.1 then return end
  self.t = 0
  cgrip:SetAlpha((self:IsMouseOver() or csizing) and 1 or 0)
end)

local function isCompact() return opt("compact", false) end
local function activeFrame() return isCompact() and compact or frame end

local MAX_PER_SECTION = 25 -- the window scrolls now, so show plenty

-- ---------------------------------------------------------------------------
-- Zone picker: watch another zone's drops (e.g. plan Westfall from Northshire)
-- ---------------------------------------------------------------------------
local zoneBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
zoneBtn:SetHeight(20)
zoneBtn:SetPoint("TOPLEFT", 10, -26)
zoneBtn:SetPoint("TOPRIGHT", -10, -26)

-- Filter row: show/hide normal quests and profession quests in the lists.

local filterChecks = {}
local function filterCheck(label, key, x, default, tip)
  local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  cb:SetSize(20, 20)
  local txt = frame:CreateFontString(nil, "OVERLAY")
  txt:SetFontObject(listFont)
  txt:SetPoint("LEFT", cb, "RIGHT", 1, 0)
  txt:SetText(label)
  cb:SetScript("OnClick", function(self)
    Krom_QuestHoardDB[key] = self:GetChecked() and true or false
    if refresh then refresh() end
  end)
  cb.key, cb.x, cb.default, cb.label, cb.tip = key, x, default, txt, tip
  cb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(label .. (self:GetChecked() and "  |cff55ff55(on)|r" or "  |cff999999(off)|r"))
    local t = type(self.tip) == "function" and self.tip() or self.tip
    if t then GameTooltip:AddLine(t, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  filterChecks[#filterChecks + 1] = cb
  return cb
end
filterCheck("Quest log", "showLog", 10, true,
  "Show the \"In your quest log\" section: items your current quests need, with progress.")
filterCheck("Normal", "showNormal", 0, true,
  "Show items for regular quests (anything that isn't a profession quest).")
filterCheck("Profession", "showProf", 0, true,
  function()
    return "Show items for profession quests. Full-color icon = the quest requires that profession; dimmed icon = only themed around it, anyone can do it."
      .. (opt("myProfOnly", false) and "\nOnly your own professions are shown (change in Options)." or "")
  end)
filterCheck("Hidden", "showHidden", 0, false,
  "Show items you've right-click hidden, greyed out with (hidden). Right-click one again to unhide it.")
filterCheck("Done", "showDone", 0, false,
  "In the watch list, also show items whose quests you've already finished, greyed out with (done) - handy so you know not to keep them.")
filterCheck("High level", "showHigh", 0, false, function()
  return ("Show quests far above your level. When off, quests more than %d levels above you are hidden (change the number in Options)."):format(opt("levelGap", LEVEL_GAP))
end)
-- Lay the checkboxes out left to right by their label widths (fonts can change).
-- Wraps onto a second row when the window is narrow. Returns rows used.
local function placeFilters(y)
  local x, rows, maxX = 10, 1, (frame:GetWidth() or 340) - 10
  for _, cb in ipairs(filterChecks) do
    local w = 22 + math.ceil(cb.label:GetStringWidth() or 40) + 10
    if x > 10 and x + w - 10 > maxX then x, y, rows = 10, y - 20, rows + 1 end
    cb:ClearAllPoints()
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetChecked(opt(cb.key, cb.default))
    cb:SetHitRectInsets(0, -math.ceil(cb.label:GetStringWidth() or 40) - 2, 0, 0)
    x = x + w
  end
  return rows
end

local picker = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
picker:SetFrameStrata("DIALOG")
picker:SetBackdrop({
  bgFile = "Interface\\Buttons\\WHITE8x8", -- solid fill: the tooltip texture is see-through by design
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
picker:SetBackdropColor(0.06, 0.06, 0.08, 1) -- always solid so the zone list stays readable
picker:EnableMouse(true) -- clicks on the list never fall through to the window behind it
picker:Hide()
frame:HookScript("OnHide", function() picker:Hide() end)

local zoneChoices
local function getZoneChoices()
  if zoneChoices then return zoneChoices end
  zoneChoices = {}
  for z, list in pairs(zoneIndex) do
    if z ~= "Other" then
      local lo, hi
      for _, pr in ipairs(list) do
        local q = pr[2]
        if fits(q[Q_RACES], raceBit) and fits(q[Q_CLASSES], classBit) and (q[Q_SKILL] or 0) == 0 then
          local l = q[Q_LEVEL] or 0
          lo = math.min(lo or l, l); hi = math.max(hi or l, l)
        end
      end
      if lo then zoneChoices[#zoneChoices + 1] = { name = z, lo = lo, hi = hi } end
    end
  end
  table.sort(zoneChoices, function(a, b)
    if a.lo ~= b.lo then return a.lo < b.lo end
    return a.name < b.name
  end)
  return zoneChoices
end

local pickerButtons = {}
local function pickZone(name)
  Krom_QuestHoardDB.watchZone = name
  picker:Hide()
  refresh()
end

local COL_W, ROW_H, MAX_ROWS = 180, 16, 20
local GROUP_ORDER = { "Eastern Kingdoms", "Kalimdor", "Zephras Isle", "Dungeons & raids", "Battlegrounds", "Other" }
local pickerGroup -- nil = top-level menu, otherwise the group being browsed

local function groupedZones()
  local groups = {}
  for _, z in ipairs(getZoneChoices()) do
    local g = (ns.zoneGroup and ns.zoneGroup[z.name]) or "Other"
    groups[g] = groups[g] or {}
    table.insert(groups[g], z)
  end
  return groups
end

local showPicker
local function pickerEntries()
  local groups = groupedZones()
  local entries = {}
  if not pickerGroup then
    entries[#entries + 1] = { label = C.header .. "Current zone (auto)|r", pick = true }
    for _, g in ipairs(GROUP_ORDER) do
      if groups[g] then
        entries[#entries + 1] = { label = ("%s " .. C.muted .. "(%d)  >|r"):format(g, #groups[g]), open = g }
      end
    end
  else
    entries[#entries + 1] = { label = C.muted .. "< Back|r", back = true }
    entries[#entries + 1] = { label = C.header .. pickerGroup .. "|r", header = true }
    for _, z in ipairs(groups[pickerGroup] or {}) do
      local lv = z.lo == z.hi and tostring(z.lo) or (z.lo .. "-" .. z.hi)
      entries[#entries + 1] = { label = ("%s " .. C.muted .. "(%s)|r"):format(z.name, lv), pick = true, name = z.name }
    end
  end
  return entries
end

function showPicker()
  local entries = pickerEntries()
  local cols = math.ceil(#entries / MAX_ROWS)
  local rows = math.ceil(#entries / cols)
  for n, e in ipairs(entries) do
    local b = pickerButtons[n]
    if not b then
      b = CreateFrame("Button", nil, picker)
      b:SetSize(COL_W - 5, ROW_H)
      local fs = b:CreateFontString(nil, "OVERLAY")
      fs:SetFontObject(listFont)
      fs:SetPoint("LEFT", 4, 0)
      fs:SetJustifyH("LEFT")
      b:SetFontString(fs)
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.15)
      b.hl = hl
      pickerButtons[n] = b
    end
    local col, row = math.floor((n - 1) / rows), (n - 1) % rows
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 8 + col * COL_W, -8 - row * ROW_H)
    b:SetText(e.label)
    if C.text == DARK_INK.text then b:GetFontString():SetTextColor(0.13, 0.09, 0.04)
    else b:GetFontString():SetTextColor(1, 1, 1) end
    if e.header then
      b.hl:Hide(); b:SetScript("OnClick", nil)
    else
      b.hl:Show()
      b:SetScript("OnClick", function()
        if e.open then pickerGroup = e.open; showPicker()
        elseif e.back then pickerGroup = nil; showPicker()
        elseif e.pick then pickerGroup = nil; pickZone(e.name) end
      end)
    end
    b:Show()
  end
  for n = #entries + 1, #pickerButtons do pickerButtons[n]:Hide() end
  picker:SetSize(cols * COL_W + 16, rows * ROW_H + 16)
  -- Open toward the middle of the screen, and never off its edge.
  picker:ClearAllPoints()
  local mid = (UIParent:GetWidth() or 0) / 2
  local x = zoneBtn:GetCenter()
  if x and x > mid then
    picker:SetPoint("TOPRIGHT", zoneBtn, "BOTTOMRIGHT", 0, -2)
  else
    picker:SetPoint("TOPLEFT", zoneBtn, "BOTTOMLEFT", 0, -2)
  end
  picker:Show()
end
picker:SetClampedToScreen(true)
zoneBtn:SetScript("OnClick", function()
  if picker:IsShown() then picker:Hide() else pickerGroup = nil; showPicker() end
end)


-- ---------------------------------------------------------------------------
-- Window styles
-- ---------------------------------------------------------------------------
local BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
-- Window styles. All Blizzard UI textures, so nothing to ship. Any the client
-- doesn't have are skipped. light = pale background (dark ink text);
-- tint darkens busy art so white text stays readable.
local BROWN = { 0.55, 0.4, 0.2 }
local STYLES = {
  { key = "dark",       name = "Dark",               desc = "Plain solid dark. Clean and readable.",
    bg = "Interface\\Buttons\\WHITE8x8", tint = { 0.05, 0.05, 0.07 } },
  { key = "dialog",     name = "Dialog",             desc = "The black marble behind classic popup boxes.",
    bg = "Interface\\DialogFrame\\UI-DialogBox-Background", tile = 32 },
  { key = "marble",     name = "Marble",             desc = "Polished grey marble, used behind newer menus.",
    bg = "Interface\\FrameGeneral\\UI-Background-Marble", tile = 256 },
  { key = "rock",       name = "Rock",               desc = "Rough cave stone, used behind newer menus.",
    bg = "Interface\\FrameGeneral\\UI-Background-Rock", tile = 256 },
  { key = "stonebook",  name = "Stone tablet",       desc = "The stone page used for some in-game books.",
    bg = "Interface\\ItemTextFrame\\ItemText-Stone-TopLeft", tint = { 0.6, 0.6, 0.6 } },
  { key = "bronzebook", name = "Bronze plate",       desc = "The bronze page used for some in-game books.",
    bg = "Interface\\ItemTextFrame\\ItemText-Bronze-TopLeft", tint = { 0.55, 0.55, 0.55 } },
  { key = "marblebook", name = "White marble page",  desc = "The pale marble page used for some in-game books.",
    bg = "Interface\\ItemTextFrame\\ItemText-Marble-TopLeft", light = true, border = BROWN },
  { key = "spellbook",  name = "Spellbook page",     desc = "A page from your spellbook.",
    bg = "Interface\\Spellbook\\Spellbook-Page-1", light = true, border = BROWN },
  { key = "parchment",  name = "Quest parchment",    desc = "The quest log's paper (one picture, may stretch).",
    bg = "Interface\\QuestFrame\\QuestBG", light = true, border = BROWN },
  { key = "achieve",    name = "Achievement parchment", desc = "The achievement window's parchment.",
    bg = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal", light = true, border = BROWN },
  { key = "stationery", name = "Letter paper",       desc = "Plain in-game mail paper.",
    bg = "Interface\\Stationery\\StationeryTest1", light = true, border = BROWN },
  { key = "journal",    name = "Dungeon journal",    desc = "The adventure guide's book background.",
    bg = "Interface\\EncounterJournal\\UI-EJ-JournalBG", tint = { 0.5, 0.5, 0.5 } },
  { key = "collections", name = "Collections",       desc = "The tile behind the mounts and pets window.",
    bg = "Interface\\Collections\\CollectionsBackgroundTile", tile = 256 },
  { key = "map",        name = "Westfall map",       desc = "A slice of the Westfall world map, darkened.",
    bg = "Interface\\WorldMap\\Westfall\\Westfall1", tint = { 0.45, 0.45, 0.45 } },
}
local function availableStyles()
  local out = {}
  for _, st in ipairs(STYLES) do
    if st.key == "dark" or textureExists(st.bg) then out[#out + 1] = st end
  end
  return out
end
local function currentStyle()
  local want = opt("style", "dark")
  for _, st in ipairs(availableStyles()) do if st.key == want then return st end end
  return STYLES[1]
end

local function applyAlpha()
  local st = currentStyle()
  local t = st.tint or { 1, 1, 1 }
  frame:SetBackdropColor(t[1], t[2], t[3], opt("bgAlpha", st.light and 1 or 0.8))
end

local function applyStyle()
  local st = currentStyle()
  frame:SetBackdrop({
    bgFile = st.bg,
    edgeFile = BORDER,
    tile = st.tile ~= nil, tileSize = st.tile or 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  local b = st.border or { 1, 1, 1 }
  frame:SetBackdropBorderColor(b[1], b[2], b[3], 1)
  applyAlpha()
  local ink = st.light and DARK_INK or LIGHT_INK
  for k, v in pairs(ink) do C[k] = v end
  if st.light then
    header:SetTextColor(0.45, 0.12, 0.04)
    for _, cb in ipairs(filterChecks) do cb.label:SetTextColor(0.13, 0.09, 0.04) end
    moreHint:SetTextColor(0.36, 0.29, 0.2)
  else
    header:SetTextColor(1, 0.82, 0)
    for _, cb in ipairs(filterChecks) do cb.label:SetTextColor(1, 1, 1) end
    moreHint:SetTextColor(0.5, 0.5, 0.5)
  end
  -- The zone list wears the same style, but always fully opaque.
  picker:SetBackdrop({
    bgFile = st.bg,
    edgeFile = BORDER,
    tile = st.tile ~= nil, tileSize = st.tile or 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  local t = st.tint or { 1, 1, 1 }
  if st.key == "dark" then t = { 0.06, 0.06, 0.08 } end
  picker:SetBackdropColor(t[1], t[2], t[3], 1)
  picker:SetBackdropBorderColor(b[1], b[2], b[3], 1)
  if picker:IsShown() and showPicker then showPicker() end
  if refresh then refresh() end
end

local function cycleStyle(dir)
  local list, cur = availableStyles(), currentStyle()
  local idx = 1
  for n, st in ipairs(list) do if st.key == cur.key then idx = n end end
  local nxt = list[(idx - 1 + (dir or 1)) % #list + 1]
  Krom_QuestHoardDB.style = nxt.key
  Krom_QuestHoardDB.bgAlpha = nil -- each style starts at its own sensible opacity
  applyStyle()
  return nxt, (idx - 1 + (dir or 1)) % #list + 1, #list
end

function render()
  local compactMode = isCompact()
  -- Compact sits on the game world, so it always uses light text with an outline;
  -- the full window's ink follows its style.
  local ink = (compactMode or not currentStyle().light) and LIGHT_INK or DARK_INK
  for k, v in pairs(ink) do C[k] = v end
  local pool = compactMode and compactPool or fullPool
  local watching = opt("showWatch", true)
  local picked = watching and Krom_QuestHoardDB and Krom_QuestHoardDB.watchZone or nil
  if compactMode then
    -- nothing: compact has no zone button, filters or scroll area
  elseif watching then
    local label = picked and ("Watching: %s  |cff999999(click to change)|r"):format(picked)
                          or "Watching: current zone  |cff999999(click to change)|r"
    zoneBtn:SetText(label)
    zoneBtn:Show()
  else
    zoneBtn:Hide(); picker:Hide()
  end
  local top = watching and -68 or -46
  if not compactMode then
    local rows = placeFilters(watching and -47 or -25)
    top = top - (rows - 1) * 20
    scroll:SetPoint("TOPLEFT", 4, top)
  end
  local i, y = 0, -2
  local function add(text, gap, iid, collapseKey, note, quest)
    if gap then y = y - (compactMode and 8 or 4) end
    i = i + 1
    local row = pool.get(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", (compactMode and not collapseKey and iid) and 10 or (compactMode and 0 or 8), y)
    row.note, row.quest = note, quest
    row.fs:SetText(text)
    if C.text == DARK_INK.text then row.fs:SetTextColor(0.13, 0.09, 0.04) else row.fs:SetTextColor(1, 1, 1) end
    row.iid, row.collapseKey = iid, collapseKey
    row:Show()
    local h = math.max(12, (row.fs:GetStringHeight() or 14))
    row:SetHeight(h)
    y = y - h - (compactMode and 4 or 3) -- a little air between lines
  end
  local function section(key, title, rows, fmt)
    local shown = {}
    for _, r in ipairs(rows) do if not hiddenFiltered(r.iid) then shown[#shown + 1] = r end end
    if #shown == 0 then return end
    local collapsed = isCollapsed(key)
    add(("%s%s %s|r%s"):format(C.muted, collapsed and "[+]" or "[-]", C.header .. title,
      collapsed and (" " .. C.muted .. "(" .. #shown .. ")|r") or ""), i > 0, nil, key)
    if collapsed then return end
    for n, r in ipairs(shown) do
      if n > MAX_PER_SECTION then
        add(("   " .. C.muted .. "...and %d more|r"):format(#shown - MAX_PER_SECTION))
        break
      end
      local body, note = fmt(r)
      local text = (compactMode and "" or "   ") .. body
      if isHidden(r.iid) then text = text .. "  " .. C.hidden .. "(hidden)|r" end
      -- quest-log rows keep the quest's name in .quest and its record in .q
      add(text, false, r.iid, nil, note, (type(r.quest) == "table" and r.quest) or r.q)
    end
  end

  -- 1. Items your active quests want
  local showLog = compactMode and opt("compactLog", false) or (not compactMode and opt("showLog", true))
  section("log", "In your quest log", showLog and activeItems or {}, function(e)
    local c = e.done and C.good or C.text
    if compactMode then
      return ("%s%s %s%d/%d|r"):format(profIcon(e.q), e.name, c, e.have, e.need), "For: " .. e.quest
    end
    return ("%s%s  %s%d/%d|r  " .. C.muted .. "%s|r"):format(profIcon(e.q), e.name, c, e.have, e.need, e.quest)
  end)

  -- 2. In your bags, still needed by a quest you haven't done
  section("keep", compactMode and "Keep for later" or "Keep for later (in your bags)", keepList, function(e)
    local q = e.quest
    local need = q[Q_NEED] or 0
    if compactMode then
      return ("%s%s %s"):format(profIcon(q), e.name, haveNeed(owned(e.iid), need)), questNote(q, need)
    end
    local where = (q[Q_LEVEL] or 0) > 0 and ("%s lvl %d"):format(q[Q_ZONE], q[Q_LEVEL]) or q[Q_ZONE]
    return ("%s%s %s  " .. C.muted .. "%s%s (%s)|r"):format(profIcon(q), e.name, haveText(owned(e.iid), need), q[Q_NAME],
      need > 0 and (" x" .. need) or "", where)
  end)

  -- 3. Drops in this zone for quests you haven't picked up yet
  -- (skips profession quests and anything way above your level)
  local myLevel = UnitLevel and UnitLevel("player") or 60
  local watch, seen = {}, {}
  local zones = not watching and {} or picked and { [picked] = true } or currentZones()
  local wantDone = opt("showDone", false)
  -- When the quest-log section isn't shown, its items appear here instead.
  local wantActive = not showLog
  -- With the quest-log section hidden (e.g. compact), list every quest-log item
  -- here, whatever zone its quest is in, with live progress.
  if wantActive then
    for _, e in ipairs(activeItems) do
      local key = e.iid or e.name
      if not seen[key] then -- quest-log items ignore the Normal/Profession filters, like the full window
        seen[key] = true
        watch[#watch + 1] = { iid = e.iid, name = e.name, quest = e.q, active = true,
                              have = e.have, need = e.need, finished = e.done }
      end
    end
  end
  for z in pairs(zones) do
    for _, pair in ipairs(zoneIndex[z] or {}) do
      local iid, q = pair[1], pair[2]
      local st = questState(q[Q_ID])
      if not seen[iid] and fits(q[Q_RACES], raceBit) and fits(q[Q_CLASSES], classBit)
         and (picked or (q[Q_REQLEVEL] or 0) <= myLevel + 3) and passesFilter(q) and levelOK(q)
         and (st == "todo" or (st == "done" and wantDone)) then
        if sellable(iid) then
          seen[iid] = true
          watch[#watch + 1] = { iid = iid, name = ns.items[iid][1], quest = q, done = st == "done" }
        end
      end
    end
  end
  table.sort(watch, function(a, b)
    if (a.active or false) ~= (b.active or false) then return a.active and true or false end
    return (a.quest[Q_LEVEL] or 0) < (b.quest[Q_LEVEL] or 0)
  end)
  section("watch", picked and ("Watch for in " .. picked) or "Watch for (this zone)", watch, function(e)
    local q = e.quest
    local need = q[Q_NEED] or 0
    if e.active then
      local c = e.finished and C.good or C.text
      if compactMode then
        return ("%s%s %s%d/%d|r"):format(profIcon(q), e.name, c, e.have, e.need), "For: " .. (q[Q_NAME] or "")
      end
      return ("%s%s  %s%d/%d|r  " .. C.muted .. "%s|r"):format(profIcon(q), e.name, c, e.have, e.need, q[Q_NAME] or "")
    end
    if e.done then
      return ("%s%s%s  (done)|r"):format(C.hidden, e.name, compactMode and "" or ("  " .. q[Q_NAME])), questNote(q, need)
    end
    if compactMode then
      return ("%s%s %s"):format(profIcon(q), e.name, haveNeed(owned(e.iid), need)), questNote(q, need)
    end
    return ("%s%s %s  " .. C.muted .. "%s%s (lvl %d)|r"):format(profIcon(q), e.name, haveText(owned(e.iid), need), q[Q_NAME],
      need > 0 and (" x" .. need) or "", q[Q_LEVEL])
  end)
  if picked and #watch == 0 and not compactMode then
    add((C.header .. "Watch for in %s|r"):format(picked), i > 0)
    add("   " .. C.muted .. "Nothing sellable to keep for quests there.|r")
  end

  -- 4. Quests done: sell it
  section("sell", "Done with - sell", sellList, function(e)
    local kind, ah, sell = verdict(e.iid)
    if kind == "ah" then
      return ("%s x%d  " .. C.good .. "AH ~%s|r"):format(e.name, e.count, money(ah))
    end
    if sell <= 0 then return ("%s x%d  " .. C.muted .. "no vendor value|r"):format(e.name, e.count) end
    return ("%s x%d  vendor %s"):format(e.name, e.count, money(sell * e.count))
  end)

  if i == 0 then
    add(C.muted .. (compactMode and "Nothing to hoard." or "Nothing to hoard right now.\nGo loot something worth keeping.|r"))
    if not compactMode then y = y - 14 end
  end
  for j = i + 1, #pool do pool[j]:Hide() end
  if compactMode then
    compactTitleText:SetText(C.header .. "Krom QuestHoard|r")
    compactContent:SetHeight(-y + 2)
    if not csizing then compact:SetHeight(18 + (-y) + 6) end
    return
  end
  local contentH = -y + 4
  content:SetHeight(contentH)
  local saved = Krom_QuestHoardDB and Krom_QuestHoardDB.height
  if not sizing then
    local room = (frame:GetTop() or 1000) - (UIParent:GetBottom() or 0) - 10
    -- Saved or auto-fit, the window never extends below the bottom of the screen.
    frame:SetHeight(math.max(110, math.min(saved or math.min(-top + contentH + 24, AUTO_MAX_HEIGHT), room)))
  end
  clampScroll()
end

-- ---------------------------------------------------------------------------
-- Tooltip tags
-- ---------------------------------------------------------------------------
local MAX_TOOLTIP_QUESTS = 4
-- Quest level colored like the game colors quest difficulty, relative to you.
local function levelColor(level)
  if GetQuestDifficultyColor then
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if ok and type(c) == "table" and c.r then
      return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end
  end
  local d = level - (UnitLevel and UnitLevel("player") or level)
  if d >= 5 then return "|cffff1a1a" elseif d >= 3 then return "|cffff8040"
  elseif d >= -2 then return "|cffffff00" elseif d >= -8 then return "|cff40c040" end
  return "|cff808080"
end

local function questieLoaded()
  local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not f then return false end
  local ok, loaded = pcall(f, "Questie")
  return ok and loaded and true or false
end

local function tagTooltip(tt)
  if not tt or not tt.GetItem then return end
  local ok, name, link = pcall(tt.GetItem, tt)
  if not ok or type(link) ~= "string" then return end
  local iid = tonumber(link:match("item:(%d+)"))
  if not iid then return end
  if not sellable(iid) or isHidden(iid) then return end
  local lname = type(name) == "string" and name:lower() or nil
  local qs = questsFor(iid, lname)
  if #qs == 0 then return end

  local open = openQuests(qs)
  local anyOpen = #open > 0
  -- Questie already lists quests in your log on item tooltips; don't repeat them.
  if questieLoaded() then
    local rest = {}
    for _, q in ipairs(open) do if not active[q[Q_ID]] then rest[#rest + 1] = q end end
    open = rest
  end
  local shown = #open
  if shown > 0 then
    tt:AddLine("|cffffb000QuestHoard - keep for:|r")
  end
  for n, q in ipairs(open) do
    if n > MAX_TOOLTIP_QUESTS then break end
    local prof = profInfo(q) and (" " .. profIcon(q)) or ""
    if active[q[Q_ID]] then
      local p = lname and progress[q[Q_ID] .. ":" .. lname]
      tt:AddLine(("  %s%s|r%s"):format(p and (p.have .. "/" .. p.need .. " ") or "", q[Q_NAME], prof), 1, 1, 1)
    else
      local need = (q[Q_NEED] or 0) > 0 and (q[Q_NEED] .. "x ") or ""
      local where = ""
      if (q[Q_LEVEL] or 0) > 0 then
        where = (" |cff999999(%s|r %s%d|r|cff999999)|r"):format(q[Q_ZONE], levelColor(q[Q_LEVEL]), q[Q_LEVEL])
      end
      tt:AddLine(("  %s%s%s%s"):format(need, q[Q_NAME], where, prof), 1, 1, 1)
    end
  end
  open = anyOpen
  if shown > MAX_TOOLTIP_QUESTS then
    tt:AddLine(("  |cff999999+%d more|r"):format(shown - MAX_TOOLTIP_QUESTS))
  end
  -- Bank stock (the game only knows your bank after you've opened it once).
  if CountItem then
    local okB, bags = pcall(CountItem, iid, false)
    local okT, total = pcall(CountItem, iid, true)
    local bank = (okB and okT) and ((tonumber(total) or 0) - (tonumber(bags) or 0)) or 0
    if bank > 0 then
      tt:AddLine(("|cffffb000QuestHoard:|r %d in your bank"):format(bank), 1, 1, 1)
    end
  end
  if not open then
    local kind, ah, sell = verdict(iid)
    if kind == "ah" then
      tt:AddLine(("|cff55ff55QuestHoard: quests done - AH it (~%s)|r"):format(money(ah)))
    elseif ah then
      tt:AddLine(("|cff55ff55QuestHoard: quests done - vendor it|r (AH ~%s isn't worth it)"):format(money(ah)))
    else
      tt:AddLine("|cff55ff55QuestHoard: quests done - safe to sell|r")
    end
  end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, tagTooltip)
else
  GameTooltip:HookScript("OnTooltipSetItem", tagTooltip)
  if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", tagTooltip) end
end

-- ---------------------------------------------------------------------------
-- Refresh (throttled, and wrapped so a client quirk can't spam errors)
-- ---------------------------------------------------------------------------
local pending = false
local lastError
function refresh()
  if pending then return end
  pending = true
  C_Timer.After(0.3, function()
    pending = false
    local ok, err = pcall(function()
      scan()
      checkQuestPings()
      scanBags()
      primed = true
      if frame:IsShown() or compact:IsShown() then render() end
    end)
    if not ok and err ~= lastError then
      lastError = err
      say("|cffff5555error:|r " .. tostring(err))
    end
  end)
end


-- ---------------------------------------------------------------------------
-- Window toggle, settings panel, minimap button
-- ---------------------------------------------------------------------------
-- Goblin head where the client has it (Forever / modern clients); Classic Era
-- may not ship that icon, so it falls back to the loot bag there.
local GOBLIN_ICON = "Interface\\Icons\\Achievement_GoblinHead"
local ICON = textureExists(GOBLIN_ICON) and GOBLIN_ICON or "Interface\\Icons\\INV_Misc_Bag_10"

local function version()
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return getMeta and getMeta(ADDON, "Version") or "?"
end

-- Show/hide whichever mode is active (full window or compact tracker).
local function setShown(show)
  Krom_QuestHoardDB.shown = show
  frame:Hide(); compact:Hide(); picker:Hide()
  if show then activeFrame():Show(); refresh() end
end
local function toggleWindow() setShown(not activeFrame():IsShown()) end

local function setCompact(on)
  Krom_QuestHoardDB.compact = on and true or nil
  setShown(true)
end
setCompactFn = setCompact

local function resetPosition()
  Krom_QuestHoardDB.pos, Krom_QuestHoardDB.height, Krom_QuestHoardDB.width = nil, nil, nil
  Krom_QuestHoardDB.cpos, Krom_QuestHoardDB.cwidth = nil, nil
  compact:ClearAllPoints()
  compact:SetPoint("RIGHT", UIParent, "RIGHT", -60, 120)
  compact:SetWidth(COMPACT_W)
  frame:ClearAllPoints()
  frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
  frame:SetWidth(340)
  if refresh then refresh() end
end

local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)

local optionsPanel, optionsCategory
local function buildOptions()
  -- The registered page is a container with a scroll area; everything below
  -- is drawn on "panel", the scrolling content, so nothing spills off the page.
  local container = CreateFrame("Frame")
  container.name = "Krom QuestHoard"
  local sf = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 0, -4)
  sf:SetPoint("BOTTOMRIGHT", -28, 4)
  local panel = CreateFrame("Frame", nil, sf)
  panel:SetSize(600, 900)
  sf:SetScrollChild(panel)
  panel.name = container.name

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Krom QuestHoard")
  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetText("Version " .. version() .. " - keeps the quest items you'd otherwise vendor by mistake.")

  local y = -64
  local checks = {}
  local function check(label, get, set)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    y = y - 30
    local txt = cb.Text or cb.text
    if type(txt) ~= "table" then txt = nil end
    if not txt then
      txt = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    end
    txt:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.get = get
    checks[#checks + 1] = cb
  end

  check("Show the QuestHoard window", function() return activeFrame():IsShown() end, setShown)
  check("Compact mode (no background, just the list)", function() return isCompact() end, setCompact)
  check("Compact mode: also list quest log items", function() return opt("compactLog", false) end,
    function(v) Krom_QuestHoardDB.compactLog = v; refresh() end)
  check("Lock window position", function() return opt("locked", false) end,
    function(v) Krom_QuestHoardDB.locked = v end)
  check("Show minimap button", function() return not Krom_QuestHoardDB.minimap.hide end, function(v)
    Krom_QuestHoardDB.minimap.hide = not v
    if DBIcon then if v then DBIcon:Show(ADDON) else DBIcon:Hide(ADDON) end end
  end)
  check("Chat message when you loot something worth keeping", function() return opt("pings", true) end,
    function(v) Krom_QuestHoardDB.pings = v end)
  check("Show \"Watch for (this zone)\" in the window", function() return opt("showWatch", true) end,
    function(v) Krom_QuestHoardDB.showWatch = v; refresh() end)
  check("Only show profession quests for professions I have (quests in my log always show)",
    function() return opt("myProfOnly", false) end,
    function(v) Krom_QuestHoardDB.myProfOnly = v; scanProfessions(); refresh() end)
  check("Track vendor-sold items (water, vials...) in every zone, not just the watched one",
    function() return opt("vendorItems", false) end,
    function(v) Krom_QuestHoardDB.vendorItems = v; refresh() end)

  -- Background opacity slider (built by hand so it works on every client).
  local sl = CreateFrame("Slider", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  sl:SetOrientation("HORIZONTAL")
  sl:SetSize(220, 16)
  sl:SetPoint("TOPLEFT", 24, y - 18)
  if sl.SetBackdrop then
    sl:SetBackdrop({
      bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
  end
  sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  sl:SetMinMaxValues(0, 1)
  sl:SetValueStep(0.05)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  local slLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  slLabel:SetPoint("BOTTOMLEFT", sl, "TOPLEFT", 0, 3)
  sl:SetScript("OnValueChanged", function(_, v)
    v = math.floor(v * 20 + 0.5) / 20
    slLabel:SetText(("Window background opacity: %d%%"):format(v * 100))
    Krom_QuestHoardDB.bgAlpha = v
    applyAlpha()
  end)
  y = y - 48

  -- Font size slider for the window's text.
  local fsl = CreateFrame("Slider", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  fsl:SetOrientation("HORIZONTAL")
  fsl:SetSize(220, 16)
  fsl:SetPoint("TOPLEFT", 24, y - 18)
  if fsl.SetBackdrop then
    fsl:SetBackdrop({
      bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
  end
  fsl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  fsl:SetMinMaxValues(8, 18)
  fsl:SetValueStep(1)
  if fsl.SetObeyStepOnDrag then fsl:SetObeyStepOnDrag(true) end
  local fslLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  fslLabel:SetPoint("BOTTOMLEFT", fsl, "TOPLEFT", 0, 3)
  fsl:SetScript("OnValueChanged", function(_, v)
    v = math.floor(v + 0.5)
    fslLabel:SetText(("Window text size: %d%s"):format(v, v == BASE_SIZE and " (default)" or ""))
    if v ~= opt("fontSize", BASE_SIZE) then
      Krom_QuestHoardDB.fontSize = v
      applyFont()
    end
  end)
  y = y - 48

  -- "High level" cut-off: hide quests more than N levels above you.
  local lsl = CreateFrame("Slider", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  lsl:SetOrientation("HORIZONTAL")
  lsl:SetSize(220, 16)
  lsl:SetPoint("TOPLEFT", 24, y - 18)
  if lsl.SetBackdrop then
    lsl:SetBackdrop({
      bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
  end
  lsl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  lsl:SetMinMaxValues(1, 30)
  lsl:SetValueStep(1)
  if lsl.SetObeyStepOnDrag then lsl:SetObeyStepOnDrag(true) end
  local lslLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lslLabel:SetPoint("BOTTOMLEFT", lsl, "TOPLEFT", 0, 3)
  lsl:SetScript("OnValueChanged", function(_, v)
    v = math.floor(v + 0.5)
    lslLabel:SetText(("Hide quests more than %d levels above you%s"):format(v, v == LEVEL_GAP and " (default)" or ""))
    if v ~= opt("levelGap", LEVEL_GAP) then
      Krom_QuestHoardDB.levelGap = v
      if refresh then refresh() end
    end
  end)
  y = y - 48

  -- Style picker:  [<]  Style name  (3 of 12)  [>]   with a one-line description.
  local styleTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  styleTitle:SetPoint("TOPLEFT", 20, y)
  styleTitle:SetText("Window style")
  local prevBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  prevBtn:SetSize(28, 22)
  prevBtn:SetPoint("TOPLEFT", 20, y - 18)
  prevBtn:SetText("<")
  local styleName = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  styleName:SetPoint("LEFT", prevBtn, "RIGHT", 10, 0)
  styleName:SetWidth(230)
  styleName:SetJustifyH("CENTER")
  local nextBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  nextBtn:SetSize(28, 22)
  nextBtn:SetPoint("LEFT", styleName, "RIGHT", 10, 0)
  nextBtn:SetText(">")
  local styleDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  styleDesc:SetPoint("TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -6)
  styleDesc:SetJustifyH("LEFT")
  local function styleLabel()
    local list, cur, idx = availableStyles(), currentStyle(), 1
    for n, st in ipairs(list) do if st.key == cur.key then idx = n end end
    styleName:SetText(("%s  |cff999999(%d of %d)|r"):format(cur.name, idx, #list))
    styleDesc:SetText(cur.desc or "")
  end
  local function step(dir)
    cycleStyle(dir); styleLabel()
    if sl then sl:SetValue(opt("bgAlpha", currentStyle().light and 1 or 0.8)) end
  end
  prevBtn:SetScript("OnClick", function() step(-1) end)
  nextBtn:SetScript("OnClick", function() step(1) end)
  y = y - 66

  -- Shift-click chat channel: [<] Party [>]
  local chTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  chTitle:SetPoint("TOPLEFT", 20, y)
  chTitle:SetText("Shift-click links items in:")
  local chPrev = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  chPrev:SetSize(28, 22)
  chPrev:SetPoint("LEFT", chTitle, "RIGHT", 10, 0)
  chPrev:SetText("<")
  local chName = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  chName:SetPoint("LEFT", chPrev, "RIGHT", 8, 0)
  chName:SetWidth(60)
  local chNext = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  chNext:SetSize(28, 22)
  chNext:SetPoint("LEFT", chName, "RIGHT", 8, 0)
  chNext:SetText(">")
  local function chLabel() chName:SetText(CHANNEL_NAMES[opt("linkChannel", "PARTY")]) end
  local function chStep(dir)
    local cur, idx = opt("linkChannel", "PARTY"), 1
    for n, c in ipairs(LINK_CHANNELS) do if c == cur then idx = n end end
    Krom_QuestHoardDB.linkChannel = LINK_CHANNELS[(idx - 1 + dir) % #LINK_CHANNELS + 1]
    chLabel()
  end
  chPrev:SetScript("OnClick", function() chStep(-1) end)
  chNext:SetScript("OnClick", function() chStep(1) end)
  y = y - 34

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetSize(180, 24)
  reset:SetPoint("TOPLEFT", 20, y - 8)
  reset:SetText("Reset window size & position")
  reset:SetScript("OnClick", resetPosition)

  local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 20, y - 48)
  help:SetJustifyH("LEFT")
  help:SetWidth(560) -- wrap inside the options panel instead of running off it
  if help.SetWordWrap then help:SetWordWrap(true) end
  help:SetText("Commands: /qh (toggle window), /qh options, /qh lock, /qh reset, /qh compact, /qh full,\n" ..
               "/qh style, /qh opacity 0-100, /qh font 8-18, /qh levels N, /qh learned\n\n" ..
               "Minimap button: left-click toggles the window, Shift-click switches full / compact,\nright-click opens these options.\n" ..
               "Items in the window: click = open in quest log, Shift-click = link in chat,\n" ..
               "Ctrl-click = search the Auction House, right-click = hide (tick 'Hidden' to unhide).")

  -- Content height = everything above plus the help text.
  panel:SetHeight(-(y - 48) + (help:GetStringHeight() or 80) + 30)
  container:SetScript("OnSizeChanged", function(self) panel:SetWidth(math.max(400, (self:GetWidth() or 600) - 32)) end)

  container:SetScript("OnShow", function()
    for _, cb in ipairs(checks) do cb:SetChecked(cb.get()) end
    sl:SetValue(opt("bgAlpha", currentStyle().light and 1 or 0.8))
    fsl:SetValue(opt("fontSize", BASE_SIZE))
    lsl:SetValue(opt("levelGap", LEVEL_GAP))
    chLabel()
    styleLabel()
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(container, container.name)
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(container)
  end
  optionsPanel = container
end

local function openOptions()
  if optionsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(optionsCategory:GetID())
  elseif optionsPanel and InterfaceOptionsFrame_OpenToCategory then
    -- Old Blizzard quirk: the first call sometimes only opens the frame.
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
  end
end

local function buildMinimapButton()
  if not (LDB and DBIcon) then return end
  local launcher = LDB:NewDataObject(ADDON, {
    type = "launcher",
    text = "Krom QuestHoard",
    icon = ICON,
    OnClick = function(_, button)
      if button == "RightButton" then openOptions()
      elseif IsShiftKeyDown and IsShiftKeyDown() then setCompact(not isCompact())
      else toggleWindow() end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine("Krom QuestHoard |cff999999" .. version() .. "|r")
      tt:AddLine(("%d to keep for later, %d done and ready to sell"):format(#keepList, #sellList), 1, 1, 1)
      tt:AddLine(" ")
      tt:AddLine("|cffffd100Left-click|r toggle window", 0.8, 0.8, 0.8)
      tt:AddLine("|cffffd100Shift-click|r switch full / compact", 0.8, 0.8, 0.8)
      tt:AddLine("|cffffd100Right-click|r options", 0.8, 0.8, 0.8)
    end,
  })
  DBIcon:Register(ADDON, launcher, Krom_QuestHoardDB.minimap)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("ZONE_CHANGED")
pcall(ev.RegisterEvent, ev, "QUEST_TURNED_IN")
pcall(ev.RegisterEvent, ev, "BAG_UPDATE_DELAYED")
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
pcall(ev.RegisterEvent, ev, "SKILL_LINES_CHANGED")

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    Krom_QuestHoardDB = Krom_QuestHoardDB or {}
    local db = Krom_QuestHoardDB
    if db.shown == nil then db.shown = true end
    db.learned = db.learned or {}
    db.minimap = db.minimap or {}
    local p = db.pos
    if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
    if db.width then frame:SetWidth(db.width) end
    applyStyle()
    applyFont()
    buildIndexes()
  elseif event == "PLAYER_LOGIN" then
    setPlayerBits()
    scanProfessions()
    local ok, err = pcall(buildOptions)
    if not ok then say("|cffff5555options panel error:|r " .. tostring(err)) end
    ok, err = pcall(buildMinimapButton)
    if not ok then say("|cffff5555minimap button error:|r " .. tostring(err)) end
    if Krom_QuestHoardDB.cwidth then compact:SetWidth(Krom_QuestHoardDB.cwidth) end
    local cp = Krom_QuestHoardDB.cpos
    if cp then compact:ClearAllPoints(); compact:SetPoint(cp[1], UIParent, cp[2], cp[3], cp[4]) end
    if Krom_QuestHoardDB.shown then activeFrame():Show() end
    say(("online (%s). /qh toggles the list, right-click the minimap bag for options."):format(version()))
    refresh()
  elseif event ~= "ADDON_LOADED" then
    if event == "SKILL_LINES_CHANGED" then scanProfessions() end
    refresh()
  end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_KROMQUESTHOARD1 = "/qh"
SLASH_KROMQUESTHOARD2 = "/kromquesthoard"
SlashCmdList.KROMQUESTHOARD = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "lock" then
    Krom_QuestHoardDB.locked = not Krom_QuestHoardDB.locked
    say(Krom_QuestHoardDB.locked and "window locked." or "window unlocked - drag to move.")
  elseif msg == "reset" or msg == "fit" then
    resetPosition()
    say("window size and position reset.")
  elseif msg:match("^style") then
    local want = msg:match("^style%s+(%S+)")
    if want then
      local found
      for _, st in ipairs(availableStyles()) do
        if st.key == want then found = st; break end
        if not found and st.name:lower():find(want, 1, true) then found = st end
      end
      if found then Krom_QuestHoardDB.style = found.key; applyStyle(); say("window style: " .. found.name .. ".")
      else say("unknown style. Try: /qh style (cycles through them).") end
    else
      local st, n, total = cycleStyle(1)
      say(("window style %d of %d: %s - %s  (/qh style again for the next)"):format(n, total, st.name, st.desc or ""))
    end
  elseif msg == "debug" then
    local function yn(v) return v and "|cff55ff55yes|r" or "|cffff5555no|r" end
    say("---- debug ----")
    say(("mode: %s, compact quest log items: %s, quest log section: %s"):format(
      isCompact() and "compact" or "full", tostring(opt("compactLog", false)), tostring(opt("showLog", true))))
    say(("quest log frames: QuestLogFrame %s, ClassicQuestLog %s, QuestLogExFrame %s, QuestMapFrame_OpenToQuestDetails %s, C_QuestLog.GetLogIndexForQuestID %s"):format(
      yn(QuestLogFrame), yn(ClassicQuestLog), yn(QuestLogExFrame), yn(QuestMapFrame_OpenToQuestDetails),
      yn(C_QuestLog and C_QuestLog.GetLogIndexForQuestID)))
    say(("filters: normal %s, profession %s, hidden %s, done %s, high level %s"):format(
      tostring(opt("showNormal", true)), tostring(opt("showProf", true)), tostring(opt("showHidden", false)),
      tostring(opt("showDone", false)), tostring(opt("showHigh", false))))
    say(("map functions: WorldMapFrame %s, OpenWorldMap %s, ToggleWorldMap %s, ShowQuestDetails %s, ToggleQuestLog %s, gamepad UI %s"):format(
      yn(WorldMapFrame), yn(OpenWorldMap), yn(ToggleWorldMap), yn(QuestMapFrame_ShowQuestDetails), yn(ToggleQuestLog),
      yn(InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled())))
    local profs = {}
    for id in pairs(knownProfs) do profs[#profs + 1] = PROFESSIONS[id][1] end
    say(("your professions: %s (only-mine filter %s)"):format(#profs > 0 and table.concat(profs, ", ") or "none found",
      tostring(opt("myProfOnly", false))))
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    say(("quests in log: %d, quest-log items tracked: %d"):format(n, #activeItems))
    for _, e in ipairs(activeItems) do
      local qid = e.q and e.q[Q_ID] or 0
      say(("  %s (item %s) - quest %d %s, in log %s, prof filter %s, hidden %s"):format(
        e.name, tostring(e.iid), qid, e.quest or "?", yn(active[qid]), yn(passesFilter(e.q)), yn(isHidden(e.iid))))
    end
    say("---------------")
  elseif msg:match("^levels?") then
    local n = tonumber(msg:match("(%d+)"))
    if n then
      Krom_QuestHoardDB.levelGap = math.max(1, math.min(60, n))
      say(("hiding quests more than %d levels above you (tick 'High level' to show them)."):format(Krom_QuestHoardDB.levelGap))
      refresh()
    else
      say(("currently hiding quests more than %d levels above you. /qh levels N to change."):format(opt("levelGap", LEVEL_GAP)))
    end
  elseif msg:match("^font") then
    local n = tonumber(msg:match("(%d+)"))
    if n then
      Krom_QuestHoardDB.fontSize = math.max(8, math.min(18, n))
      applyFont()
      say(("text size %d."):format(Krom_QuestHoardDB.fontSize))
    else
      Krom_QuestHoardDB.fontSize = nil
      applyFont()
      say(("text size back to default (%d). Use /qh font 8-18 to change it."):format(BASE_SIZE))
    end
  elseif msg:match("^opacity") then
    local n = tonumber(msg:match("(%d+)"))
    if n then
      Krom_QuestHoardDB.bgAlpha = math.max(0, math.min(100, n)) / 100
      applyAlpha()
      say(("background opacity %d%%."):format(Krom_QuestHoardDB.bgAlpha * 100))
    else
      say("usage: /qh opacity 0-100")
    end
  elseif msg == "compact" or msg == "full" then
    setCompact(msg == "compact" or (msg ~= "full" and not isCompact()))
    say(isCompact() and "compact mode. /qh full for the full window." or "full window. /qh compact for the slim list.")
  elseif msg == "options" or msg == "config" then
    openOptions()
  elseif msg == "minimap" then
    local hide = not Krom_QuestHoardDB.minimap.hide
    Krom_QuestHoardDB.minimap.hide = hide
    if DBIcon then if hide then DBIcon:Hide(ADDON) else DBIcon:Show(ADDON) end end
    say(hide and "minimap button hidden. /qh minimap brings it back." or "minimap button shown.")
  elseif msg == "learned" then
    local n = 0
    for lname, e in pairs(Krom_QuestHoardDB.learned or {}) do
      n = n + 1
      local tag = e.tradeable == true and "tracked" or e.tradeable == false and "ignored: soulbound or no vendor value" or "not seen in bags yet"
      say(("learned: %s (%s)"):format(e.name or lname, tag))
    end
    if n == 0 then say("nothing learned yet - the built-in list has you covered so far.") end
  else
    toggleWindow()
  end
end
