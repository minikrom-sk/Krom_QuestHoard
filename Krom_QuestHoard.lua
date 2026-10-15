-- Krom QuestHoard v0.1.2
-- Tracks items your current quests need: popup list, tooltip tags, loot pings.
-- Works on Classic Era (legacy quest API) and modern clients like Forever (C_QuestLog).

local ADDON = ...

local PREFIX = "|cffffb000Krom QuestHoard:|r "
local function say(msg) print(PREFIX .. msg) end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------
local byItem = {}      -- lowercase item name -> { entry, entry, ... }
local order = {}       -- entries in quest-log order (for the popup)
local lastHave = {}    -- "quest\0item" -> count seen last scan
local primed = false   -- skip loot pings on the very first scan

-- Pull "Tough Wolf Meat", 3, 8 out of "Tough Wolf Meat: 3/8" or "3/8 Tough Wolf Meat"
local function parseObjective(text)
  if type(text) ~= "string" then return end
  text = text:gsub("%s*%(Complete%)%s*$", "")
  local name, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)")
  if name then return name, tonumber(have), tonumber(need) end
  have, need, name = text:match("^(%d+)%s*/%s*(%d+)%s+(.+)$")
  if name then return name, tonumber(have), tonumber(need) end
end

-- Walk the quest log, newer API first, legacy fallback.
local function forEachQuest(cb)
  if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.title then
        cb(info.title, info.questID, i)
      end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    local n = GetNumQuestLogEntries() or 0
    for i = 1, n do
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

local function scan()
  wipe(byItem); wipe(order)
  forEachQuest(function(title, questID, index)
    for _, o in ipairs(getObjectives(questID, index)) do
      if o.type == "item" then
        local name, have, need = parseObjective(o.text)
        have = tonumber(o.have) or have or 0
        need = tonumber(o.need) or need
        if name and need and need > 0 then
          local e = { name = name, have = have, need = need, quest = title,
                      done = o.finished or have >= need }
          local key = name:lower()
          byItem[key] = byItem[key] or {}
          table.insert(byItem[key], e)
          order[#order + 1] = e
        end
      end
    end
  end)
end

-- Ping in chat when a tracked count goes up.
local function checkPings()
  local seen = {}
  for _, e in ipairs(order) do
    local k = e.quest .. "\0" .. e.name
    seen[k] = true
    local old = lastHave[k]
    if primed and old and e.have > old then
      if e.have >= e.need then
        say(("|cff55ff55%s %d/%d - done!|r (%s)"):format(e.name, e.have, e.need, e.quest))
      else
        say(("%s %d/%d (%s)"):format(e.name, e.have, e.need, e.quest))
      end
    end
    lastHave[k] = e.have
  end
  for k in pairs(lastHave) do if not seen[k] then lastHave[k] = nil end end
  primed = true
end

-- ---------------------------------------------------------------------------
-- Popup window
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "Krom_QuestHoardFrame", UIParent,
  BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(270, 60)
frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
frame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
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
header:SetText("Krom QuestHoard - Keep These")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function()
  frame:Hide(); Krom_QuestHoardDB.shown = false
  say("hidden. /qh to bring it back.")
end)

local lines = {}
local function getLine(i)
  if not lines[i] then
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWidth(250)
    lines[i] = fs
  end
  return lines[i]
end

local function render()
  local i, lastQuest, y = 0, nil, -28
  local function add(text)
    i = i + 1
    local fs = getLine(i)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", 12, y)
    fs:SetText(text)
    fs:Show()
    y = y - 14
  end

  if #order == 0 then
    add("|cff999999No item quests right now.\nGo bully some wolves.|r")
    y = y - 14
  else
    for _, e in ipairs(order) do
      if e.quest ~= lastQuest then
        if lastQuest then y = y - 4 end
        add("|cffffd100" .. e.quest .. "|r")
        lastQuest = e.quest
      end
      if e.done then
        add(("   |cff55ff55%s  %d/%d  (done)|r"):format(e.name, e.have, e.need))
      else
        add(("   %s  |cffffffff%d/%d|r"):format(e.name, e.have, e.need))
      end
    end
  end

  for j = i + 1, #lines do lines[j]:Hide() end
  frame:SetHeight(-y + 10)
end

-- ---------------------------------------------------------------------------
-- Tooltip tags
-- ---------------------------------------------------------------------------
local function tagTooltip(tt)
  if not tt or not tt.GetItem then return end
  local ok, name = pcall(tt.GetItem, tt)
  if not ok or type(name) ~= "string" then return end
  local list = byItem[name:lower()]
  if not list then return end
  for _, e in ipairs(list) do
    if e.done then
      tt:AddLine(("|cff55ff55QuestHoard: done|r - %s"):format(e.quest))
    else
      tt:AddLine(("|cffffb000QuestHoard: KEEP|r %d/%d - %s"):format(e.have, e.need, e.quest))
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
local function refresh()
  if pending then return end
  pending = true
  C_Timer.After(0.3, function()
    pending = false
    local ok, err = pcall(function()
      scan()
      checkPings()
      if frame:IsShown() then render() end
    end)
    if not ok then say("|cffff5555scan error:|r " .. tostring(err)) end
  end)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
pcall(ev.RegisterEvent, ev, "BAG_UPDATE_DELAYED")

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    Krom_QuestHoardDB = Krom_QuestHoardDB or {}
    if Krom_QuestHoardDB.shown == nil then Krom_QuestHoardDB.shown = true end
    local p = Krom_QuestHoardDB.pos
    if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
  elseif event == "PLAYER_LOGIN" then
    if Krom_QuestHoardDB.shown then frame:Show() end
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ver = getMeta and getMeta(ADDON, "Version") or "?"
    say(("online (%s). /qh to toggle the list."):format(ver))
    refresh()
  else
    refresh()
  end
end)

-- ---------------------------------------------------------------------------
-- Slash commands: /qh, /qh lock, /qh reset
-- ---------------------------------------------------------------------------
SLASH_KROMQUESTHOARD1 = "/qh"
SLASH_KROMQUESTHOARD2 = "/kromquesthoard"
SlashCmdList.KROMQUESTHOARD = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "lock" then
    Krom_QuestHoardDB.locked = not Krom_QuestHoardDB.locked
    say(Krom_QuestHoardDB.locked and "window locked." or "window unlocked - drag to move.")
  elseif msg == "reset" then
    Krom_QuestHoardDB.pos = nil
    frame:ClearAllPoints()
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
    say("window position reset.")
  else
    if frame:IsShown() then
      frame:Hide(); Krom_QuestHoardDB.shown = false
    else
      frame:Show(); Krom_QuestHoardDB.shown = true
      scan(); render()
    end
  end
end
