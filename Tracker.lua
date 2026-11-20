-- QuestMates tracker: replaces the default objective tracker.
-- Two tabs: "My quests" (your watched quests) and "Party" (QuestMates friends, grouped by friend).
-- Click a quest = read it, right-click = show it on the map, click the quest icon = in-world marker.
local API = QuestMatesAPI
local WIDTH, HEADH = 255, 58
local ICON_PROGRESS = "Interface\\GossipFrame\\IncompleteQuestIcon"
local ICON_DONE = "Interface\\GossipFrame\\ActiveQuestIcon"

local db
local tab = "mine"
local collapsedFriend = {}
local hider = CreateFrame("Frame"); hider:Hide()
local blizzParent = {}
local pinnedOwn -- quest id I pinned from the tracker
local Place -- defined further down
local Untrack -- defined further down
local ProgressColor, CHECK -- defined further down
local scrollOff, viewH = 0, 600 -- pixels scrolled down, visible list height
local barHold = 0 -- seconds before the scroll bar fades

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
local f = CreateFrame("Frame", "QuestMatesQuestTracker", UIParent)
f:SetSize(WIDTH, 40); f:SetMovable(true); f:SetClampedToScreen(true); f:Hide()
-- lowest layer: every window, the minimap, unit frames and action bars draw on top of it
f:SetFrameStrata("BACKGROUND"); f:SetFrameLevel(1); f:SetToplevel(false)

f:EnableMouseWheel(true)
f:SetScript("OnMouseWheel", function(_, delta)
  if not f.maxOff or f.maxOff <= 0 then return end
  scrollOff = math.max(0, math.min(f.maxOff, scrollOff - delta * 40))
  barHold = 1.5; f.bar:SetAlpha(1)
  QuestMatesTracker_Refresh()
end)
-- slim scroll bar on the right: shows while scrolling / hovering, fades out after
local bar = CreateFrame("Frame", nil, f)
bar:SetWidth(4); bar:SetFrameLevel(f:GetFrameLevel() + 5); bar:SetAlpha(0); bar:Hide()
bar.track = bar:CreateTexture(nil, "BACKGROUND"); bar.track:SetAllPoints()
bar.track:SetColorTexture(0, 0, 0, 0.35)
local thumb = CreateFrame("Button", nil, bar)
thumb:SetWidth(12); thumb:SetPoint("LEFT", bar, "LEFT", -4, 0)
thumb.tex = thumb:CreateTexture(nil, "ARTWORK")
thumb.tex:SetPoint("TOP"); thumb.tex:SetPoint("BOTTOM"); thumb.tex:SetWidth(4)
thumb.tex:SetColorTexture(1, 0.82, 0, 0.75)
thumb:SetScript("OnEnter", function() thumb.tex:SetColorTexture(1, 0.9, 0.3, 1) end)
thumb:SetScript("OnLeave", function() if not thumb.drag then thumb.tex:SetColorTexture(1, 0.82, 0, 0.75) end end)
local function Poke() barHold = 1.5; bar:SetAlpha(1) end
thumb:RegisterForDrag("LeftButton")
thumb:SetScript("OnDragStart", function()
  local _, cy = GetCursorPosition()
  thumb.drag = { y = cy / thumb:GetEffectiveScale(), off = scrollOff }
end)
thumb:SetScript("OnDragStop", function() thumb.drag = nil; thumb.tex:SetColorTexture(1, 0.82, 0, 0.75) end)
bar:SetScript("OnUpdate", function(_, el)
  if thumb.drag and f.maxOff and f.maxOff > 0 then
    local _, cy = GetCursorPosition()
    cy = cy / thumb:GetEffectiveScale()
    local free = bar:GetHeight() - thumb:GetHeight()
    if free > 0 then
      local new = thumb.drag.off + (thumb.drag.y - cy) / free * f.maxOff
      new = math.floor(math.max(0, math.min(f.maxOff, new)) + 0.5)
      if new ~= scrollOff then scrollOff = new; QuestMatesTracker_Refresh() end
    end
    Poke()
  elseif f:IsMouseOver() then
    Poke()
  elseif barHold > 0 then
    barHold = barHold - el
  else
    local a = bar:GetAlpha() - el * 3
    bar:SetAlpha(a > 0 and a or 0)
  end
end)
f.bar, f.thumb = bar, thumb

local head = CreateFrame("Button", nil, f)
head:SetPoint("TOPLEFT"); head:SetPoint("TOPRIGHT"); head:SetHeight(26)
head:RegisterForDrag("LeftButton")
head:SetScript("OnDragStart", function() if IsShiftKeyDown() then f.moving = true; f:StartMoving() end end)
head:SetScript("OnDragStop", function()
  if not f.moving then return end -- only a real Shift-drag saves a position
  f.moving = false
  f:StopMovingOrSizing()
  local a, _, b, x, y = f:GetPoint(); db.utPos = { a, b, x, y }
end)
head:SetScript("OnEnter", function(s)
  GameTooltip:SetOwner(s, "ANCHOR_LEFT"); GameTooltip:AddLine("QuestMates tracker")
  GameTooltip:AddLine("Shift-drag to move.", 1, 1, 1)
  GameTooltip:AddLine("Click a quest to show it on the map, right-click to open it in the quest log.", 1, 1, 1, true)
  GameTooltip:AddLine("Click the quest icon to point the in-world marker at it.", 1, 1, 1, true)
  GameTooltip:Show()
end)
head:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- default-UI look: use the game's own tracker art when this client has it
local function HasAtlas(a)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(a) and true or false
end
local function FirstAtlas(list) for _, a in ipairs(list) do if HasAtlas(a) then return a end end end
local function HeaderArt(parent, list)
  local t = parent:CreateTexture(nil, "BACKGROUND")
  local a = FirstAtlas(list)
  if a then t:SetAtlas(a, false)
  else t:SetTexture("Interface\\QuestFrame\\ObjectiveTracker"); t:SetTexCoord(0, 0.6, 0.25, 0.35) end
  return t
end
-- Blizzard-style minimize button: atlas names straight from the default tracker (/qmt icons)
local function MinButton(parent, w, h, collapse, expand, highlight)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  function b:SetCollapsed(c)
    local base = (c and HasAtlas(expand)) and expand or collapse
    if HasAtlas(base) then
      self:SetNormalAtlas(base)
      self:SetPushedAtlas(HasAtlas(base .. "-Pressed") and (base .. "-Pressed") or base)
      if HasAtlas(highlight) then self:SetHighlightAtlas(highlight, "ADD") end
      local t = self:GetNormalTexture()
      if t and t.SetTexCoord then
        -- no "expand" art in this client: flip the collapse art so it reads as "open"
        if c and base == collapse then t:SetTexCoord(0, 1, 1, 0) else t:SetTexCoord(0, 1, 0, 1) end
      end
    else
      self:SetNormalTexture(c and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
      self:SetPushedTexture(c and "Interface\\Buttons\\UI-PlusButton-Down" or "Interface\\Buttons\\UI-MinusButton-Down")
      self:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    end
  end
  return b
end

-- top bar: "All Objectives" + collapse-all button
local hbg = HeaderArt(head, { "UI-QuestTracker-Primary-Objective-Header", "Objective-Header" })
hbg:SetPoint("TOPLEFT", -12, 7); hbg:SetPoint("BOTTOMRIGHT", 12, -7)
local minBtn = MinButton(head, 17, 18, "UI-QuestTrackerButton-Collapse-All", "UI-QuestTrackerButton-Expand-All", "UI-QuestTrackerButton-Red-Highlight")
minBtn:SetPoint("RIGHT", -2, 0)
minBtn:SetScript("OnClick", function() db.utMin = not db.utMin; QuestMatesTracker_Refresh() end)
local title = head:CreateFontString(nil, "OVERLAY", "GameFontNormalMed2" and _G.GameFontNormalMed2 and "GameFontNormalMed2" or "GameFontNormal")
title:SetPoint("LEFT", 6, 0); title:SetText("All Objectives")

-- section bar: "Quests" / "Party Quests", click to collapse, party button to switch
local sec = CreateFrame("Button", nil, f)
sec:SetPoint("TOPLEFT", 0, -30); sec:SetPoint("TOPRIGHT", 0, -30); sec:SetHeight(24)
local sbg = HeaderArt(sec, { "UI-QuestTracker-Secondary-Objective-Header", "Objective-Header" })
sbg:SetPoint("TOPLEFT", -12, 3); sbg:SetPoint("BOTTOMRIGHT", 12, -3)
local secMin = MinButton(sec, 16, 15, "UI-QuestTrackerButton-Secondary-Collapse", "UI-QuestTrackerButton-Secondary-Expand", "UI-QuestTrackerButton-Yellow-Highlight")
secMin:SetPoint("RIGHT", -2, 0)
local secText = sec:CreateFontString(nil, "OVERLAY", "GameFontNormal")
secText:SetPoint("LEFT", 6, 0)
local function ToggleSection() db.utSecMin = not db.utSecMin; scrollOff = 0; QuestMatesTracker_Refresh() end
sec:SetScript("OnClick", ToggleSection)
secMin:SetScript("OnClick", ToggleSection)

local partyBtn = CreateFrame("Button", nil, sec)
partyBtn:SetSize(20, 20); partyBtn:SetPoint("RIGHT", secMin, "LEFT", -6, 0)
partyBtn.icon = partyBtn:CreateTexture(nil, "ARTWORK"); partyBtn.icon:SetAllPoints()
partyBtn.icon:SetTexture("Interface\\AddOns\\QuestMates\\PartyIcon")
partyBtn.ring = partyBtn:CreateTexture(nil, "OVERLAY")
partyBtn.ring:SetTexture("Interface\\Buttons\\CheckButtonHilight"); partyBtn.ring:SetBlendMode("ADD")
partyBtn.ring:SetPoint("TOPLEFT", -4, 4); partyBtn.ring:SetPoint("BOTTOMRIGHT", 4, -4)
partyBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
partyBtn.count = partyBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
partyBtn.count:SetPoint("BOTTOMRIGHT", 3, -2)
partyBtn:SetScript("OnClick", function()
  tab = (tab == "party") and "mine" or "party"; scrollOff = 0; db.utSecMin = false; QuestMatesTracker_Refresh()
end)
partyBtn:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_LEFT")
  GameTooltip:AddLine(tab == "party" and "Show my quests" or "Show party quests", 1, 0.82, 0)
  GameTooltip:Show()
end)
partyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

------------------------------------------------------------------------
-- My watched quests
------------------------------------------------------------------------
local function Watched(qid, idx)
  if C_QuestLog and C_QuestLog.GetQuestWatchType then
    local ok, w = pcall(C_QuestLog.GetQuestWatchType, qid); if ok and w ~= nil then return true end
  end
  if C_QuestLog and C_QuestLog.IsQuestWatched then
    local ok, w = pcall(C_QuestLog.IsQuestWatched, qid); if ok and w then return true end
  end
  if IsQuestWatched and idx then
    local ok, w = pcall(IsQuestWatched, idx); if ok and w then return true end
  end
  if QuestLedgerForever_IsWatched then
    local ok, w = pcall(QuestLedgerForever_IsWatched, qid, idx); if ok and w then return true end
  end
  return false
end

local function Tag(qid)
  if C_QuestLog and C_QuestLog.GetQuestTagInfo then
    local ok, t = pcall(C_QuestLog.GetQuestTagInfo, qid)
    if ok and type(t) == "table" and t.tagName and t.tagName ~= "" then return t.tagName end
  end
end

local function MyObjectives(qid, idx)
  local out = {}
  if C_QuestLog and C_QuestLog.GetQuestObjectives then
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    if ok and type(objs) == "table" then
      for _, o in ipairs(objs) do
        if o.text and o.text ~= "" then
          local h, nd = o.numFulfilled, o.numRequired
          if not nd or nd == 0 then local a, b = tostring(o.text):match("(%d+)%s*/%s*(%d+)"); h, nd = tonumber(a), tonumber(b) end
          out[#out + 1] = { text = o.text, done = o.finished and true or false, have = h, need = nd }
        end
      end
    end
  end
  if #out == 0 and idx and GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
    for j = 1, (GetNumQuestLeaderBoards(idx) or 0) do
      local text, _, finished = GetQuestLogLeaderBoard(j, idx)
      if text and text ~= "" then
        local a, b = tostring(text):match("(%d+)%s*/%s*(%d+)")
        out[#out + 1] = { text = text, done = finished and true or false, have = tonumber(a), need = tonumber(b) }
      end
    end
  end
  return out
end

-- quests with no counted objectives show the short "what to do" text, like the default tracker
local function ShortText(idx)
  if not (GetQuestLogQuestText and idx) then return nil end
  if SelectQuestLogEntry then
    local prev = GetQuestLogSelection and GetQuestLogSelection()
    pcall(SelectQuestLogEntry, idx)
    local ok, _, objText = pcall(GetQuestLogQuestText)
    if prev and prev > 0 then pcall(SelectQuestLogEntry, prev) end
    if ok then return objText end
  else
    local ok, _, objText = pcall(GetQuestLogQuestText, idx)
    if ok then return objText end
  end
end

local function MyQuests()
  local list = {}
  local logFlag
  local function add(qid, title, level, complete, idx)
    if not qid or qid == 0 or not Watched(qid, idx) then return end
    local objs = MyObjectives(qid, idx)
    if #objs == 0 then
      complete = (complete == 1 or complete == true) and logFlag
    else
      local all = true
      for _, o in ipairs(objs) do if not o.done then all = false end end
      complete = all or (logFlag and true or false)
    end
    list[#list + 1] = { id = qid, title = title or ("Quest " .. qid), level = level or 0, complete = complete and true or false,
      objs = objs, desc = (#objs == 0 and not complete) and ShortText(idx) or nil, tag = Tag(qid) }
  end
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
    for i = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.questID then
        logFlag = (info.isComplete == 1 or info.isComplete == true)
        add(info.questID, info.title, info.level, logFlag, i)
      end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    for i = 1, (GetNumQuestLogEntries() or 0) do
      local t, lvl, _, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
      logFlag = (isComplete == 1 or isComplete == true)
      if t and not isHeader then add(qid, t, lvl, logFlag, i) end
    end
  end
  table.sort(list, function(a, b)
    if a.level ~= b.level then return a.level < b.level end -- lowest level first
    return a.title < b.title
  end)
  return list
end

------------------------------------------------------------------------
-- Clicks
------------------------------------------------------------------------
local function LevelColor(level)
  if GetQuestDifficultyColor then
    local c = GetQuestDifficultyColor(level or 0)
    if c then return c.r, c.g, c.b end
  end
  return 1, 0.82, 0
end

local function QuestMapID(q, who)
  local src = who and API.FriendQuest(who, q.id) or API.MyQuest(q.id) or q
  local p = src and src.pois and src.pois[1]
  if p then return p.m end
  if not who and GetQuestUiMapID then
    local ok, m = pcall(GetQuestUiMapID, q.id); if ok and m and m > 0 then return m end
  end
end

local function ShowOnMap(q, who)
  local m = QuestMapID(q, who)
  if not m then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33d9ffQuestMates:|r No map location known for " .. q.title .. " yet.")
    return
  end
  if OpenWorldMap then OpenWorldMap(m)
  elseif WorldMapFrame then
    if not WorldMapFrame:IsShown() then ToggleWorldMap() end
    WorldMapFrame:SetMapID(m)
  end
end

Untrack = function(qid)
  local idx = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qid)
  if not idx and GetQuestLogIndexByID then idx = GetQuestLogIndexByID(qid) end
  local function try(fn, ...) if fn then return (pcall(fn, ...)) end end
  if not (C_QuestLog and C_QuestLog.RemoveQuestWatch and try(C_QuestLog.RemoveQuestWatch, qid)) then
    if idx then try(RemoveQuestWatch, idx) end
  end
  if QuestWatch_Update then pcall(QuestWatch_Update) end
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_CLOSE then pcall(PlaySound, SOUNDKIT.IG_QUEST_LIST_CLOSE) end
  QuestMatesTracker_Refresh()
end

local function TogglePin(q, who)
  local key, hold = API.Pinned()
  if who then
    if key == (who .. ":" .. q.id) then API.Unpin() return end
    local fq = API.FriendQuest(who, q.id)
    if not (fq and fq.pois and #fq.pois > 0) then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33d9ffQuestMates:|r No location known for " .. who .. "'s " .. q.title .. " yet.")
      return
    end
    API.PinFriend(who, fq)
  else
    local cur = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if hold and cur == q.id then
      API.Unpin()
      if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then pcall(C_SuperTrack.SetSuperTrackedQuestID, 0) end
      return
    end
    if not (C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID) then return end
    API.Unpin()
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    pcall(C_SuperTrack.SetSuperTrackedQuestID, q.id)
    API.HoldPointer(true); pinnedOwn = q.id
    if SetCVar and GetCVar and GetCVar("showInGameNavigation") ~= "1" then pcall(SetCVar, "showInGameNavigation", "1") end
  end
  QuestMatesTracker_Refresh()
end

local function IsPinned(q, who)
  local key, hold = API.Pinned()
  if who then return key == (who .. ":" .. q.id) end
  if not hold then return false end
  local cur = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
  return cur == q.id
end

------------------------------------------------------------------------
-- Lines
------------------------------------------------------------------------
local pool, n, y = {}, 0, 0

local function GetLine()
  n = n + 1
  local l = pool[n]
  if not l then
    l = CreateFrame("Button", nil, f)
    l:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    l.fs = l:CreateFontString(nil, "OVERLAY")
    l.fs:SetJustifyH("LEFT"); l.fs:SetWordWrap(true)
    l.icon = CreateFrame("Button", nil, l)
    l.icon:SetSize(16, 16); l.icon:SetPoint("TOPLEFT", 0, 1)
    l.icon.tex = l.icon:CreateTexture(nil, "ARTWORK"); l.icon.tex:SetAllPoints()
    l.icon.glow = l.icon:CreateTexture(nil, "OVERLAY")
    l.icon.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight"); l.icon.glow:SetBlendMode("ADD")
    l.icon.glow:SetPoint("TOPLEFT", -3, 3); l.icon.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    l.icon:SetScript("OnClick", function(b)
      local d = b:GetParent().data
      if d and d.q then TogglePin(d.q, d.who) elseif d and d.recipe then b:GetParent():Click("LeftButton") end
    end)
    l.icon:SetScript("OnEnter", function(b)
      if not (b:GetParent().data and b:GetParent().data.q) then return end
      GameTooltip:SetOwner(b, "ANCHOR_LEFT")
      GameTooltip:AddLine(IsPinned(b:GetParent().data.q, b:GetParent().data.who) and "Click to remove the marker" or "Click to point the marker here", 1, 1, 1)
      GameTooltip:Show()
    end)
    l.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    l:SetScript("OnClick", function(b, button)
      local d = b.data; if not d then return end
      if d.kind == "friend" then collapsedFriend[d.who] = not collapsedFriend[d.who]; QuestMatesTracker_Refresh() return end
      if d.recipe then
        if IsShiftKeyDown() then
          local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
          local link = C_TradeSkillUI and C_TradeSkillUI.GetRecipeLink and C_TradeSkillUI.GetRecipeLink(d.recipe.id)
          if eb and link then ChatEdit_InsertLink(link) return end
          if C_TradeSkillUI and C_TradeSkillUI.SetRecipeTracked then pcall(C_TradeSkillUI.SetRecipeTracked, d.recipe.id, false, d.recipe.recraft) end
          QuestMatesTracker_Refresh()
        elseif C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
          pcall(C_TradeSkillUI.OpenRecipe, d.recipe.id)
        end
        return
      end
      if not d.q then return end
      if IsShiftKeyDown() then
        -- chat box open: link the quest; otherwise Shift-click untracks my own quest (like the default tracker)
        local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if eb or d.who then API.OpenQuest(d.q, d.who) return end
        Untrack(d.q.id)
        return
      end
      if button == "RightButton" then
        -- my quest: my quest log (Quest Ledger Forever); friend's quest: the QuestMates reader
        API.OpenQuest(d.q, d.who, d.who ~= nil)
      else
        ShowOnMap(d.q, d.who)
      end
    end)
    l:SetScript("OnEnter", function(b)
      local d = b.data
      if d and d.recipe then
        b.fs:SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(b, "ANCHOR_LEFT")
        local ok = d.recipe.link and pcall(GameTooltip.SetHyperlink, GameTooltip, d.recipe.link)
        if not ok then GameTooltip:AddLine(d.recipe.name, 1, 0.82, 0) end
        GameTooltip:AddLine("Click to open the profession - Shift-click to stop tracking", 0.5, 0.8, 1)
        GameTooltip:Show()
      elseif d and d.q then
        b.fs:SetTextColor(1, 1, 1)
        if d.who then API.QuestTooltip(b, d.q, d.who, "Click for the map - right-click to read it")
        else
          GameTooltip:SetOwner(b, "ANCHOR_LEFT")
          GameTooltip:AddLine(string.format("[%d] %s", d.q.level or 0, d.q.title), 1, 0.82, 0)
          for _, fr in ipairs(API.FriendsOnQuest(d.q.id)) do
            local c = fr.color
            local prog = {}
            for _, o in ipairs(fr.objs) do if o.need and o.need > 0 then prog[#prog + 1] = o.have .. "/" .. o.need end end
            GameTooltip:AddLine(fr.who .. ": " .. (fr.complete and "done" or table.concat(prog, " ")), c[1], c[2], c[3])
          end
          GameTooltip:AddLine("Click for the map - right-click for the quest log", 0.5, 0.8, 1)
          GameTooltip:AddLine("Shift-click to stop tracking", 0.5, 0.8, 1)
          GameTooltip:Show()
        end
      end
    end)
    l:SetScript("OnLeave", function(b) if b.r then b.fs:SetTextColor(b.r, b.g, b.b) end; GameTooltip:Hide() end)
    l.flash = l:CreateTexture(nil, "BACKGROUND")
    l.flash:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight"); l.flash:SetBlendMode("ADD")
    l.flash:SetPoint("TOPLEFT", -6, 2); l.flash:SetPoint("BOTTOMRIGHT", 4, -2); l.flash:SetAlpha(0)
    l.flashEnd = 0
    l:SetScript("OnUpdate", function(b)
      local left = (b.flashEnd or 0) - GetTime()
      if left > 0 then b.flash:SetAlpha(math.min(1, left / 0.8)) elseif b.flash:GetAlpha() > 0 then b.flash:SetAlpha(0) end
    end)
    local ok, ag = pcall(l.fs.CreateAnimationGroup, l.fs)
    if ok and ag then
      local up = ag:CreateAnimation("Scale"); up:SetScale(1.12, 1.12); up:SetDuration(0.12); up:SetOrder(1)
      if up.SetOrigin then up:SetOrigin("LEFT", 0, 0) end
      local down = ag:CreateAnimation("Scale"); down:SetScale(1 / 1.12, 1 / 1.12); down:SetDuration(0.18); down:SetOrder(2)
      if down.SetOrigin then down:SetOrigin("LEFT", 0, 0) end
      l.pop = ag
    end
    pool[n] = l
  end
  return l
end

local function Line(font, text, indent, r, g, b, data, icon, pinned, flashEnd, pop)
  local l = GetLine()
  l.flashEnd = flashEnd or 0
  if not flashEnd then l.flash:SetAlpha(0) end
  if pop and l.pop then l.pop:Stop(); l.pop:Play() end
  l.data = data
  l.fs:SetFontObject(font); l.fs:SetText(text)
  l.r, l.g, l.b = r, g, b; l.fs:SetTextColor(r, g, b)
  l.fs:ClearAllPoints()
  l.fs:SetPoint("TOPLEFT", icon and 20 or 0, 0); l.fs:SetPoint("RIGHT", l, "RIGHT", 0, 0)
  if icon then
    l.icon.tex:SetTexture(icon); l.icon.tex:SetTexCoord(0, 1, 0, 1)
    if data and data.recipe then l.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    l.icon.glow:SetShown(pinned and true or false); l.icon:Show()
  else l.icon:Hide() end
  l:ClearAllPoints()
  l:SetPoint("TOPLEFT", f, "TOPLEFT", indent, y + scrollOff); l:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  local h = math.max(icon and 16 or 12, l.fs:GetStringHeight() or 12)
  l:SetHeight(h); l:EnableMouse(data ~= nil)
  -- only the text itself catches clicks; the empty rest of the row clicks through to the world
  local rowW = WIDTH - indent - 10
  local used = (icon and 20 or 0) + math.min(l.fs:GetStringWidth() or rowW, rowW - (icon and 20 or 0))
  l:SetHitRectInsets(0, math.max(0, rowW - used), 0, 0)
  -- scrolled list: only lines fully inside the visible area (below the header) are shown
  local top = -(y + scrollOff)
  l:SetShown(top >= HEADH and top + h <= HEADH + viewH)
  y = y - h - 2
  return true
end

------------------------------------------------------------------------
-- Tracked recipes (the game's own profession tracking)
------------------------------------------------------------------------
local function ItemCount(id)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, true, false, true, true) or 0 end
  return GetItemCount and GetItemCount(id, true) or 0
end
local function ItemName(id)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if not name and GetItemInfo then name = GetItemInfo(id) end
  return name
end
local function TrackedRecipes()
  local out = {}
  if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipesTracked and C_TradeSkillUI.GetRecipeSchematic) then return out end
  for _, recraft in ipairs({ false, true }) do
    local ok, ids = pcall(C_TradeSkillUI.GetRecipesTracked, recraft)
    if ok and type(ids) == "table" then
      for _, id in ipairs(ids) do
        local ok2, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, id, recraft)
        if ok2 and sch then
          local r = { id = id, recraft = recraft, name = sch.name or ("Recipe " .. id), icon = sch.icon, objs = {} }
          if C_TradeSkillUI.GetRecipeLink then r.link = C_TradeSkillUI.GetRecipeLink(id) end
          for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
            local rg = slot.reagents and slot.reagents[1]
            local need = slot.quantityRequired or 0
            if rg and rg.itemID and need > 0 and slot.required ~= false then
              local have = 0
              for _, alt in ipairs(slot.reagents) do if alt.itemID then have = have + ItemCount(alt.itemID) end end
              local nm = ItemName(rg.itemID) or ("item " .. rg.itemID)
              r.objs[#r.objs + 1] = { text = string.format("%s %d/%d", nm, math.min(have, need), need),
                have = math.min(have, need), need = need, done = have >= need }
            end
          end
          out[#out + 1] = r
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- "Professions" section bar, laid out inside the scrolling list
local pbar = CreateFrame("Button", nil, f)
pbar:SetHeight(24)
local pbg = HeaderArt(pbar, { "UI-QuestTracker-Secondary-Objective-Header", "Objective-Header" })
pbg:SetPoint("TOPLEFT", -12, 3); pbg:SetPoint("BOTTOMRIGHT", 12, -3)
local pMin = MinButton(pbar, 16, 15, "UI-QuestTrackerButton-Secondary-Collapse", "UI-QuestTrackerButton-Secondary-Expand", "UI-QuestTrackerButton-Yellow-Highlight")
pMin:SetPoint("RIGHT", -2, 0)
local pText = pbar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
pText:SetPoint("LEFT", 6, 0); pText:SetText("Professions")
local function ToggleProf() db.utProfMin = not db.utProfMin; QuestMatesTracker_Refresh() end
pbar:SetScript("OnClick", ToggleProf); pMin:SetScript("OnClick", ToggleProf)
pbar:Hide()

local function ProfessionSection()
  local list = TrackedRecipes()
  if #list == 0 then pbar:Hide() return end
  y = y - 8
  pbar:ClearAllPoints()
  pbar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y + scrollOff); pbar:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  local top = -(y + scrollOff)
  pbar:SetShown(top >= HEADH and top + 24 <= HEADH + viewH)
  pMin:SetCollapsed(db.utProfMin)
  y = y - 28
  if db.utProfMin then return end
  for _, r in ipairs(list) do
    Line("GameFontNormal", r.name, 4, 1, 0.82, 0, { recipe = r }, r.icon)
    for _, o in ipairs(r.objs) do
      local r2, g2, b2 = ProgressColor(o)
      Line("GameFontHighlightSmall", (o.done and CHECK or "- ") .. o.text, 24, r2, g2, b2)
    end
    y = y - 4
  end
end

-- progress memory: [who or "me"][qid][objective index] = have; flashes when it goes up
local seen, flashUntil = {}, {}
CHECK = "|A:UI-QuestTracker-Tracker-Check:12:12|a "
local function Lerp(a, b, t) return a + (b - a) * t end
ProgressColor = function(o, who)
  if o.done then
    if who then local c = API.Color(who); return c[1], c[2], c[3] end
    return 0.3, 1, 0.3
  end
  local t = (o.need and o.need > 0) and math.min(1, (o.have or 0) / o.need) or 0
  if who then -- white -> friend's color
    local c = API.Color(who)
    return Lerp(0.9, c[1], t), Lerp(0.9, c[2], t), Lerp(0.9, c[3], t)
  end
  if t < 0.5 then -- white -> yellow -> green
    local u = t / 0.5; return Lerp(0.9, 1, u), Lerp(0.9, 0.82, u), Lerp(0.9, 0.1, u)
  end
  local u = (t - 0.5) / 0.5; return Lerp(1, 0.45, u), Lerp(0.82, 1, u), Lerp(0.1, 0.3, u)
end

local function QuestBlock(q, who, extra)
  local r, g, b = LevelColor(q.level)
  local lvl = tostring(q.level or 0) .. ((q.tag == ELITE or q.tag == "Elite") and "+" or "")
  local name = string.format("[%s] %s%s", lvl, q.title, q.tag and (" (" .. q.tag .. ")") or "")
  if not Line("GameFontNormal", name .. (extra or ""), 4, r, g, b, { q = q, who = who },
    q.complete and ICON_DONE or ICON_PROGRESS, IsPinned(q, who)) then return false end
  if q.complete then
    Line("GameFontHighlightSmall", "- Ready for turn-in", 24, 0.3, 1, 0.3)
  elseif q.desc and q.desc ~= "" then
    Line("GameFontHighlightSmall", q.desc, 24, 0.85, 0.85, 0.85)
  else
    local owner = who or "me"
    seen[owner] = seen[owner] or {}
    local prev = seen[owner][q.id]
    local now = {}
    for i, o in ipairs(q.objs or {}) do
      local key = owner .. ":" .. q.id .. ":" .. i
      now[i] = o.have
      local pop = false
      if prev and prev[i] and o.have and o.have > prev[i] then
        flashUntil[key] = GetTime() + 1.2; pop = true
      end
      local fe = flashUntil[key]
      if fe and fe <= GetTime() then flashUntil[key] = nil; fe = nil end
      local r2, g2, b2 = ProgressColor(o, who)
      Line("GameFontHighlightSmall", (o.done and CHECK or "- ") .. (o.text or ""), 24, r2, g2, b2, nil, nil, nil, fe, pop)
    end
    seen[owner][q.id] = now
  end
  y = y - 4
  return true
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------
local function Enabled() return db and db.unifiedTracker ~= false end

function QuestMatesTracker_Refresh()
  if not Enabled() then f:Hide() return end
  for _, l in ipairs(pool) do l:Hide() end
  n, y = 0, -HEADH
  -- room from the tracker's top down to just above the bottom action bars
  local ftop = f:GetTop()
  local fs = f:GetScale() or 1
  viewH = ftop and math.max(120, ftop - 150 / fs - HEADH) or 600

  local friends = API.Friends()
  local inParty = #friends > 0
  if not inParty then tab = "mine" end
  partyBtn:SetShown(inParty)
  partyBtn.count:SetText(inParty and #friends or "")
  partyBtn.ring:SetShown(tab == "party")
  secText:SetText(tab == "party" and "Party Quests" or "Quests")
  minBtn:SetCollapsed(db.utMin); secMin:SetCollapsed(db.utSecMin)
  sec:SetShown(not db.utMin)
  f:SetScale(db.utScale or 1)
  Place()

  if db.utMin then y = -26 end
  if not db.utMin and not db.utSecMin then
    if tab == "mine" then
      local qs = MyQuests()
      if #qs == 0 then Line("GameFontHighlightSmall", "No tracked quests", 4, 0.6, 0.6, 0.6) end
      for i, q in ipairs(qs) do
        local shared = inParty and #API.FriendsOnQuest(q.id) or 0
        local extra = shared > 0 and string.format(" |cff5dcaa5shared %d|r", shared) or nil
        if not QuestBlock(q, nil, extra) then
          break
        end
      end
    else
      for _, who in ipairs(friends) do
        local fq = API.FriendQuests(who)
        local c = API.Color(who)
        local count = #fq
        y = y - 2
        if not Line("GameFontNormal", who .. " |cff888888- " .. count .. (count == 1 and " quest|r" or " quests|r")
          .. (collapsedFriend[who] and " |cff888888(+)|r" or ""), 4, c[1], c[2], c[3], { kind = "friend", who = who }) then break end
        if not collapsedFriend[who] then
          if count == 0 then Line("GameFontHighlightSmall", "No quests", 24, 0.6, 0.6, 0.6) end
          for _, q in ipairs(fq) do
            local extra = API.MyQuest(q.id) and " |cff5dcaa5you have this|r" or nil
            local view = { id = q.id, title = q.title, level = q.level, complete = q.complete, objs = q.objs }
            if not QuestBlock(view, who, extra) then break end
          end
        end
      end
    end
  end
  if not db.utMin and tab == "mine" then ProfessionSection() else pbar:Hide() end
  local total = math.max(0, -y - HEADH)
  local maxOff = math.max(0, total - viewH)
  if scrollOff > maxOff then scrollOff = maxOff; QuestMatesTracker_Refresh() return end
  f.maxOff = maxOff
  f:EnableMouseWheel(maxOff > 0 and not db.utMin)
  f:SetHeight((db.utMin and 26 or HEADH) + math.min(total, viewH) + 4)
  local shownH = math.min(total, viewH)
  if maxOff > 0 and not db.utMin then
    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -HEADH)
    bar:SetHeight(shownH)
    local th = math.max(20, shownH * shownH / total)
    thumb:SetHeight(th)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", bar, "TOP", 0, -(shownH - th) * scrollOff / maxOff)
    bar:Show()
  else
    bar:Hide()
  end
  f:Show()
end

------------------------------------------------------------------------
-- Hiding / restoring Blizzard's tracker
------------------------------------------------------------------------
local function BlizzFrames()
  local out = {}
  for _, name in ipairs({ "ObjectiveTrackerFrame", "QuestWatchFrame", "WatchFrame" }) do
    if _G[name] then out[#out + 1] = _G[name] end
  end
  return out
end

-- right edge that keeps clear of the side action bars (and anything else docked on the right)
local SIDE_BARS = { "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7" }
local function RightEdge()
  local edge = UIParent:GetRight() or 0
  local us = UIParent:GetEffectiveScale() or 1
  local half = (UIParent:GetWidth() or 0) / 2
  local function check(fr)
    if fr and fr:IsVisible() and fr:GetLeft() then
      local left = fr:GetLeft() * (fr:GetEffectiveScale() or 1) / us
      if left > half and left < edge then edge = left end
    end
  end
  for _, name in ipairs(SIDE_BARS) do
    check(_G[name])
    for i = 1, 12 do check(_G[name .. "Button" .. i]) end
  end
  return edge - 8
end

Place = function()
  if f.moving then return end
  f:ClearAllPoints()
  local scale = f:GetScale() or 1
  local edge = RightEdge()
  if db.utPos then
    f:SetPoint(db.utPos[1], UIParent, db.utPos[2], db.utPos[3], db.utPos[4])
    -- even a saved spot never sits on top of the side bars
    local right, top = f:GetRight(), f:GetTop()
    if right and top and right * scale > edge then
      f:ClearAllPoints()
      f:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", edge / scale, top)
    end
    return
  end
  local x = edge - (UIParent:GetRight() or 0)
  -- start right under the minimap (higher than Blizzard's spot)
  local y
  local mm = MinimapCluster or Minimap
  local bottom = mm and mm:IsShown() and mm:GetBottom()
  if bottom then
    y = bottom * (mm:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1) - (UIParent:GetTop() or 0) - 2
  end
  y = y or db.utTop or -200
  f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x / scale, y / scale)
end

-- watch the right edge (bar 4 / bar 5 switched on or off in settings, bars moved) and follow it
local lastEdge, watchT = nil, 0
f:SetScript("OnUpdate", function(_, el)
  watchT = watchT + el
  if watchT < 0.5 then return end
  watchT = 0
  if not db then return end
  local e = math.floor(RightEdge() + 0.5)
  if e ~= lastEdge then lastEdge = e; Place() end
end)

local pendingApply = false
function QuestMatesTracker_Apply()
  if not db then return end
  if InCombatLockdown and InCombatLockdown() then pendingApply = true return end
  pendingApply = false
  for _, bf in ipairs(BlizzFrames()) do
    if Enabled() then
      if bf:GetParent() ~= hider then
        local top = bf:GetTop()
        if top and not db.utTop then
          db.utTop = top * (bf:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1) - (UIParent:GetTop() or 0)
        end
        blizzParent[bf] = bf:GetParent(); bf:SetParent(hider)
      end
    elseif bf:GetParent() == hider then
      bf:SetParent(blizzParent[bf] or UIParent)
    end
  end
  QuestMatesTracker_Refresh()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local pending = false
local function Soon()
  if pending then return end
  pending = true
  C_Timer.After(0.2, function() pending = false; QuestMatesTracker_Refresh() end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
ev:RegisterEvent("QUEST_WATCH_UPDATE")
ev:RegisterEvent("SUPER_TRACKING_CHANGED")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
for _, e in ipairs({ "TRACKED_RECIPE_UPDATE", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED" }) do pcall(ev.RegisterEvent, ev, e) end
for _, e in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "CVAR_UPDATE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e)
  if e == "PLAYER_LOGIN" then
    db = QuestMatesDB
    if not db then return end
    -- older build saved a spot on any drag (even without Shift); forget that once
    if not db.utPosFixed then db.utPos = nil; db.utPosFixed = true end
    for _, name in ipairs(SIDE_BARS) do
      local bar = _G[name]
      if bar then
        bar:HookScript("OnShow", function() C_Timer.After(0, function() if not db.utPos then Place() end end) end)
        bar:HookScript("OnHide", function() C_Timer.After(0, function() if not db.utPos then Place() end end) end)
      end
    end
    QuestMatesTracker_Apply()
    Place()
    C_Timer.After(1, function() if not db.utPos then Place() end end)
    C_Timer.After(4, function() if not db.utPos then Place() end end)
    return
  end
  if not db then return end
  if e == "UI_SCALE_CHANGED" or e == "DISPLAY_SIZE_CHANGED" or e == "ACTIONBAR_SHOWGRID" or e == "ACTIONBAR_HIDEGRID" or e == "CVAR_UPDATE" then
    C_Timer.After(0.1, function() if db and not db.utPos then Place() end end)
    return
  end
  if e == "SUPER_TRACKING_CHANGED" and pinnedOwn then
    local _, hold = API.Pinned()
    local cur = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if hold and cur ~= pinnedOwn then API.Unpin() end
    if cur ~= pinnedOwn then pinnedOwn = nil end
  end
  if e == "PLAYER_REGEN_ENABLED" then
    if pendingApply then QuestMatesTracker_Apply() end
    return
  end
  Soon()
end)

SLASH_QUESTMATESTRACKER1 = "/qmt"
SlashCmdList.QUESTMATESTRACKER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "icons" then
    -- lists the art Blizzard's own tracker uses, so QuestMates can copy it exactly
    local bf = _G.ObjectiveTrackerFrame
    if not bf then print("|cff33d9ffQuestMates:|r No ObjectiveTrackerFrame in this client.") return end
    local seen, count = {}, 0
    local function walk(fr, depth)
      if depth > 8 then return end
      for _, r in ipairs({ fr:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then
          local atlas = r.GetAtlas and r:GetAtlas()
          local tex = r:GetTexture()
          local key = tostring(atlas or tex)
          if key ~= "nil" and not seen[key] then
            seen[key] = true; count = count + 1
            print(("  %s  %dx%d  (%s)"):format(atlas and ("atlas " .. atlas) or ("file " .. tostring(tex)),
              r:GetWidth() or 0, r:GetHeight() or 0, (fr:GetDebugName() or "?"):match("[^%.]+%.?[^%.]*$") or "?"))
          end
        end
      end
      for _, c in ipairs({ fr:GetChildren() }) do walk(c, depth + 1) end
    end
    print("|cff33d9ffQuestMates:|r Blizzard tracker art:")
    walk(bf, 0)
    if count == 0 then print("  (nothing found - track a quest and try again)") end
    return
  end
  if msg == "debug" then
    local us = UIParent:GetEffectiveScale() or 1
    print(("|cff33d9ffQuestMates:|r screen right %.0f, tracker right %.0f, bar edge %.0f, saved spot: %s"):format(
      UIParent:GetRight() or 0, (f:GetRight() or 0) * (f:GetEffectiveScale() or 1) / us, RightEdge(), db.utPos and "yes" or "no"))
    for _, name in ipairs(SIDE_BARS) do
      local bar, b1 = _G[name], _G[name .. "Button1"]
      print(("  %s: %s, visible %s, left %s"):format(name, bar and "found" or "missing", tostring(bar and bar:IsVisible()),
        tostring(b1 and b1:GetLeft() and math.floor(b1:GetLeft() * (b1:GetEffectiveScale() or 1) / us))))
    end
    return
  end
  if msg == "reset" then
    db.utPos = nil; Place(); print("|cff33d9ffQuestMates:|r Tracker moved back to the default spot.")
  elseif msg:match("^scale") then
    local v = tonumber(msg:match("^scale%s+([%d%.]+)"))
    if v and v >= 0.5 and v <= 2 then db.utScale = v; QuestMatesTracker_Refresh()
    else print("|cff33d9ffQuestMates:|r Use /qmt scale 0.5 - 2") end
  else
    db.unifiedTracker = (db.unifiedTracker == false)
    QuestMatesTracker_Apply()
    print("|cff33d9ffQuestMates:|r Tracker " .. (db.unifiedTracker and "on" or "off (default tracker back)"))
  end
end
