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
local render, refresh

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
local function profInfo(q)
  local id = q and q[Q_PROF] or 0
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
local function passesFilter(q)
  if isProfQuest(q) then return opt("showProf", true) end
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
local function haveText(have, need)
  local c = have == 0 and "|cff999999" or (need > 0 and have >= need) and "|cff55ff55" or "|cffffffff"
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
local function buildIndexes()
  for iid, row in pairs(ns.items) do
    nameIndex[row[1]:lower()] = iid
    for _, q in ipairs(row[2]) do
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

local function forEachQuest(cb)
  if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
    for i = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.title then cb(info.title, info.questID, i) end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    for i = 1, (GetNumQuestLogEntries() or 0) do
      local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
      if title and not isHeader then cb(title, questID, i) end
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

local function scan()
  wipe(active); wipe(progress); wipe(activeItems)
  forEachQuest(function(title, questID, index)
    if questID then active[questID] = true end
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
            activeItems[#activeItems + 1] = { iid = nameIndex[lname] or (learnedEntry and learnedEntry.itemID),
                                              name = name, have = have, need = need, quest = title,
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

local function questState(questID)
  if active[questID] then return "active" end
  if isDone(questID) then return "done" end
  return "todo"
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
        for _, q in ipairs(open) do if not active[q[Q_ID]] and passesFilter(q) then later = q; break end end
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
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.8)
local function applyAlpha()
  frame:SetBackdropColor(0, 0, 0, opt("bgAlpha", 0.8))
end
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
  say("hidden. /qh or the minimap bag brings it back.")
end)

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
local sizing = false
grip:SetScript("OnMouseDown", function()
  if Krom_QuestHoardDB and Krom_QuestHoardDB.locked then return end
  -- Pin the top-left corner first, so dragging the corner only moves the
  -- bottom-right edge instead of stretching around the window's middle.
  local left, top = frame:GetLeft(), frame:GetTop()
  if left and top then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  end
  sizing = true
  frame:StartSizing("BOTTOMRIGHT")
end)
grip:SetScript("OnMouseUp", function()
  if not sizing then return end
  frame:StopMovingOrSizing()
  sizing = false
  Krom_QuestHoardDB.height = math.floor(frame:GetHeight() + 0.5)
  Krom_QuestHoardDB.width = math.floor(frame:GetWidth() + 0.5)
  local p, _, rp, x, y = frame:GetPoint()
  Krom_QuestHoardDB.pos = { p, rp, x, y }
  clampScroll()
end)
grip:SetScript("OnDoubleClick", function()
  Krom_QuestHoardDB.height = nil -- back to auto-fit (width stays)
  if refresh then refresh() end
end)
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

local function getLine(i)
  if not lines[i] then
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(14)
    row:SetWidth((frame:GetWidth() or 340) - 34)
    row:RegisterForClicks("RightButtonUp")
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT")
    fs:SetJustifyH("LEFT")
    fs:SetWidth((frame:GetWidth() or 340) - 34)
    row.fs = fs
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.07)
    row:SetScript("OnClick", function(self, button)
      if button == "RightButton" and self.iid then toggleHidden(self.iid) end
    end)
    row:SetScript("OnEnter", function(self)
      if not self.iid then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("item:" .. self.iid)
      GameTooltip:AddLine(isHidden(self.iid) and "|cff999999Right-click: unhide|r" or "|cff999999Right-click: hide from QuestHoard|r")
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lines[i] = row
  end
  return lines[i]
end

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
local function filterCheck(label, key, x, default)
  local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  cb:SetSize(20, 20)
  local txt = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  txt:SetPoint("LEFT", cb, "RIGHT", 1, 0)
  txt:SetText(label)
  cb:SetScript("OnClick", function(self)
    Krom_QuestHoardDB[key] = self:GetChecked() and true or false
    if refresh then refresh() end
  end)
  cb.key, cb.x, cb.default = key, x, default
  filterChecks[#filterChecks + 1] = cb
  return cb
end
filterCheck("Normal", "showNormal", 10, true)
filterCheck("Profession", "showProf", 95, true)
filterCheck("Hidden items", "showHidden", 195, false)
local function placeFilters(y)
  for _, cb in ipairs(filterChecks) do
    cb:ClearAllPoints()
    cb:SetPoint("TOPLEFT", cb.x, y)
    cb:SetChecked(opt(cb.key, cb.default))
  end
end

local picker = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
picker:SetFrameStrata("DIALOG")
picker:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
picker:SetBackdropColor(0.04, 0.04, 0.06, 1) -- always solid so the zone list stays readable
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

local COL_W, ROW_H, MAX_ROWS = 175, 16, 24
local GROUP_ORDER = { "Eastern Kingdoms", "Kalimdor", "Zephras Isle", "Dungeons & raids", "Battlegrounds", "Other" }
local function showPicker()
  -- Build columns: each continent starts a new column (spilling into more
  -- columns if long); the small groups stack together in the last column.
  local groups = {}
  for _, z in ipairs(getZoneChoices()) do
    local g = (ns.zoneGroup and ns.zoneGroup[z.name]) or "Other"
    groups[g] = groups[g] or {}
    table.insert(groups[g], z)
  end
  local cells, col, row = {}, 0, 0
  local function put(e)
    if row >= MAX_ROWS then col, row = col + 1, 0 end
    cells[#cells + 1] = { e = e, col = col, row = row }
    row = row + 1
  end
  put({ label = "|cffffd100Current zone (auto)|r", auto = true })
  local maxRow = 0
  for gi, g in ipairs(GROUP_ORDER) do
    local list = groups[g]
    if list then
      local major = (g == "Eastern Kingdoms" or g == "Kalimdor")
      if row > 0 and (major or gi == 3 or row + 2 > MAX_ROWS) then
        maxRow = math.max(maxRow, row); col, row = col + 1, 0
      elseif row > 0 then
        row = row + 1 -- a little gap between stacked groups
      end
      put({ label = "|cffffd100" .. g .. "|r", header = true })
      for _, z in ipairs(list) do
        local lv = z.lo == z.hi and tostring(z.lo) or (z.lo .. "-" .. z.hi)
        put({ name = z.name, label = ("%s |cff999999(%s)|r"):format(z.name, lv) })
      end
    end
  end
  maxRow = math.max(maxRow, row)
  local cols = col + 1
  for n, c in ipairs(cells) do
    local b = pickerButtons[n]
    if not b then
      b = CreateFrame("Button", nil, picker)
      b:SetSize(COL_W - 5, ROW_H)
      local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", 4, 0)
      fs:SetJustifyH("LEFT")
      b:SetFontString(fs)
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.15)
      b.hl = hl
      pickerButtons[n] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 8 + c.col * COL_W, -8 - c.row * ROW_H)
    b:SetText(c.e.label)
    if c.e.header then
      b.hl:Hide(); b:SetScript("OnClick", nil)
    else
      b.hl:Show(); b:SetScript("OnClick", function() pickZone(c.e.name) end)
    end
    b:Show()
  end
  for n = #cells + 1, #pickerButtons do pickerButtons[n]:Hide() end
  picker:SetSize(cols * COL_W + 16, maxRow * ROW_H + 16)
  picker:ClearAllPoints()
  picker:SetPoint("TOPLEFT", zoneBtn, "BOTTOMLEFT", 0, -2)
  picker:Show()
end
zoneBtn:SetScript("OnClick", function()
  if picker:IsShown() then picker:Hide() else showPicker() end
end)


function render()
  local watching = opt("showWatch", true)
  local picked = watching and Krom_QuestHoardDB and Krom_QuestHoardDB.watchZone or nil
  if watching then
    local label = picked and ("Watching: %s  |cff999999(click to change)|r"):format(picked)
                          or "Watching: current zone  |cff999999(click to change)|r"
    zoneBtn:SetText(label)
    zoneBtn:Show()
  else
    zoneBtn:Hide(); picker:Hide()
  end
  placeFilters(watching and -47 or -25)
  local top = watching and -68 or -46
  scroll:SetPoint("TOPLEFT", 4, top)
  local i, y = 0, -2
  local function add(text, gap, iid)
    if gap then y = y - 4 end
    i = i + 1
    local row = getLine(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 8, y)
    row.fs:SetText(text)
    row.iid = iid
    row:Show()
    local h = math.max(14, (row.fs:GetStringHeight() or 14))
    row:SetHeight(h)
    y = y - h
  end
  local function section(title, rows, fmt)
    local shown = {}
    for _, r in ipairs(rows) do if not hiddenFiltered(r.iid) then shown[#shown + 1] = r end end
    if #shown == 0 then return end
    add("|cffffd100" .. title .. "|r", i > 0)
    for n, r in ipairs(shown) do
      if n > MAX_PER_SECTION then
        add(("   |cff999999...and %d more|r"):format(#shown - MAX_PER_SECTION))
        break
      end
      local text = "   " .. fmt(r)
      if isHidden(r.iid) then text = text .. "  |cff777777(hidden)|r" end
      add(text, false, r.iid)
    end
  end

  -- 1. Items your active quests want
  section("In your quest log", activeItems, function(e)
    local c = e.done and "|cff55ff55" or "|cffffffff"
    return ("%s  %s%d/%d|r  |cff999999%s|r"):format(e.name, c, e.have, e.need, e.quest)
  end)

  -- 2. In your bags, still needed by a quest you haven't done
  section("Keep for later (in your bags)", keepList, function(e)
    local q = e.quest
    local need = q[Q_NEED] or 0
    local where = (q[Q_LEVEL] or 0) > 0 and ("%s lvl %d"):format(q[Q_ZONE], q[Q_LEVEL]) or q[Q_ZONE]
    return ("%s%s %s  |cff999999%s%s (%s)|r"):format(profIcon(q), e.name, haveText(owned(e.iid), need), q[Q_NAME],
      need > 0 and (" x" .. need) or "", where)
  end)

  -- 3. Drops in this zone for quests you haven't picked up yet
  -- (skips profession quests and anything way above your level)
  local myLevel = UnitLevel and UnitLevel("player") or 60
  local watch, seen = {}, {}
  local zones = not watching and {} or picked and { [picked] = true } or currentZones()
  for z in pairs(zones) do
    for _, pair in ipairs(zoneIndex[z] or {}) do
      local iid, q = pair[1], pair[2]
      if not seen[iid] and fits(q[Q_RACES], raceBit) and fits(q[Q_CLASSES], classBit)
         and (picked or (q[Q_REQLEVEL] or 0) <= myLevel + 3) and passesFilter(q)
         and questState(q[Q_ID]) == "todo" then
        if sellable(iid) then
          seen[iid] = true
          watch[#watch + 1] = { iid = iid, name = ns.items[iid][1], quest = q }
        end
      end
    end
  end
  table.sort(watch, function(a, b) return a.quest[Q_LEVEL] < b.quest[Q_LEVEL] end)
  section(picked and ("Watch for in " .. picked) or "Watch for (this zone)", watch, function(e)
    local q = e.quest
    local need = q[Q_NEED] or 0
    return ("%s%s %s  |cff999999%s%s (lvl %d)|r"):format(profIcon(q), e.name, haveText(owned(e.iid), need), q[Q_NAME],
      need > 0 and (" x" .. need) or "", q[Q_LEVEL])
  end)
  if picked and #watch == 0 then
    add(("|cffffd100Watch for in %s|r"):format(picked), i > 0)
    add("   |cff999999Nothing sellable to keep for quests there.|r")
  end

  -- 4. Quests done: sell it
  section("Done with - sell", sellList, function(e)
    local kind, ah, sell = verdict(e.iid)
    if kind == "ah" then
      return ("%s x%d  |cff55ff55AH ~%s|r"):format(e.name, e.count, money(ah))
    end
    if sell <= 0 then return ("%s x%d  |cff999999no vendor value|r"):format(e.name, e.count) end
    return ("%s x%d  vendor %s"):format(e.name, e.count, money(sell * e.count))
  end)

  if i == 0 then
    add("|cff999999Nothing to hoard right now.\nGo loot something worth keeping.|r")
    y = y - 14
  end
  for j = i + 1, #lines do lines[j]:Hide() end
  local contentH = -y + 4
  content:SetHeight(contentH)
  local saved = Krom_QuestHoardDB and Krom_QuestHoardDB.height
  if not sizing then
    frame:SetHeight(saved or math.min(-top + contentH + 24, AUTO_MAX_HEIGHT))
  end
  clampScroll()
end

-- ---------------------------------------------------------------------------
-- Tooltip tags
-- ---------------------------------------------------------------------------
local MAX_TOOLTIP_QUESTS = 4
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
  local shown = #open
  for n, q in ipairs(open) do
    if n > MAX_TOOLTIP_QUESTS then break end
    if active[q[Q_ID]] then
      local p = lname and progress[q[Q_ID] .. ":" .. lname]
      tt:AddLine(("|cffffb000QuestHoard: KEEP|r %s%s"):format(q[Q_NAME], p and (" " .. p.have .. "/" .. p.need) or ""))
    else
      local where = (q[Q_LEVEL] or 0) > 0 and (" (%s, lvl %d)"):format(q[Q_ZONE], q[Q_LEVEL]) or ""
      local prof = profName(q) and (" " .. profIcon(q) .. "|cff999999" .. profName(q) .. "|r") or ""
      local need = (q[Q_NEED] or 0) > 0 and (q[Q_NEED] .. " ") or ""
      tt:AddLine(("|cffffb000QuestHoard: KEEP|r %sfor %s%s%s"):format(need, q[Q_NAME], where, prof))
    end
  end
  open = shown > 0
  if shown > MAX_TOOLTIP_QUESTS then
    tt:AddLine(("|cff999999QuestHoard: +%d more quests|r"):format(shown - MAX_TOOLTIP_QUESTS))
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
      if frame:IsShown() then render() end
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
local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local function version()
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return getMeta and getMeta(ADDON, "Version") or "?"
end

local function setShown(show)
  Krom_QuestHoardDB.shown = show
  if show then frame:Show(); refresh() else frame:Hide() end
end
local function toggleWindow() setShown(not frame:IsShown()) end

local function resetPosition()
  Krom_QuestHoardDB.pos = nil
  frame:ClearAllPoints()
  frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
end

local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)

local optionsPanel, optionsCategory
local function buildOptions()
  local panel = CreateFrame("Frame")
  panel.name = "Krom QuestHoard"

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

  check("Show the QuestHoard window", function() return frame:IsShown() end, setShown)
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

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetSize(180, 24)
  reset:SetPoint("TOPLEFT", 20, y - 8)
  reset:SetText("Reset window position")
  reset:SetScript("OnClick", resetPosition)

  local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 20, y - 48)
  help:SetJustifyH("LEFT")
  help:SetText("Commands: /qh (toggle window), /qh options, /qh lock, /qh reset, /qh opacity 0-100, /qh learned\n" ..
               "Minimap button: left-click toggles the window, right-click opens these options.\n" ..
               "Right-click an item in the window to hide it; tick 'Hidden items' to see or unhide them.")

  panel:SetScript("OnShow", function()
    for _, cb in ipairs(checks) do cb:SetChecked(cb.get()) end
    sl:SetValue(opt("bgAlpha", 0.8))
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
  optionsPanel = panel
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
      if button == "RightButton" then openOptions() else toggleWindow() end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine("Krom QuestHoard |cff999999" .. version() .. "|r")
      tt:AddLine(("%d to keep for later, %d done and ready to sell"):format(#keepList, #sellList), 1, 1, 1)
      tt:AddLine(" ")
      tt:AddLine("|cffffd100Left-click|r toggle window", 0.8, 0.8, 0.8)
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
    applyAlpha()
    buildIndexes()
  elseif event == "PLAYER_LOGIN" then
    setPlayerBits()
    local ok, err = pcall(buildOptions)
    if not ok then say("|cffff5555options panel error:|r " .. tostring(err)) end
    ok, err = pcall(buildMinimapButton)
    if not ok then say("|cffff5555minimap button error:|r " .. tostring(err)) end
    if Krom_QuestHoardDB.shown then frame:Show() end
    say(("online (%s). /qh toggles the list, right-click the minimap bag for options."):format(version()))
    refresh()
  elseif event ~= "ADDON_LOADED" then
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
  elseif msg == "reset" then
    resetPosition()
    say("window position reset.")
  elseif msg:match("^opacity") then
    local n = tonumber(msg:match("(%d+)"))
    if n then
      Krom_QuestHoardDB.bgAlpha = math.max(0, math.min(100, n)) / 100
      applyAlpha()
      say(("background opacity %d%%."):format(Krom_QuestHoardDB.bgAlpha * 100))
    else
      say("usage: /qh opacity 0-100")
    end
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
