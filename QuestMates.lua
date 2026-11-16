-- QuestMates: see your party members' quests on the world map in their own color.
-- Every player who wants to SHARE quests needs QuestMates installed.
local ADDON = ...
local PREFIX = "QMATES1"
local MEDIA = "Interface\\AddOns\\QuestMates\\"
local SEP, OSEP, FSEP, PSEP = "~", "`", "^", ";"

local db, cdb
local friends = {}        -- [name] = { quests = { [qid] = q }, last = time }
local myQuests = {}       -- [qid] = q (my current log, for "shared" checks)
local mySnapshot = {}     -- [qid] = { [objIndex] = numFulfilled } for progress pins
local lastSent = {}       -- [qid] = payload string
local scanned = false
local Alert -- defined further down, used by ScanLog
local MakeOptions -- defined further down

local PALETTE = {
  { 0.20, 0.85, 1.00 }, -- cyan
  { 1.00, 0.35, 0.85 }, -- pink
  { 0.40, 1.00, 0.30 }, -- lime
  { 1.00, 0.55, 0.10 }, -- orange
  { 0.45, 0.50, 1.00 }, -- blue
  { 1.00, 0.25, 0.25 }, -- red
  { 0.75, 0.45, 1.00 }, -- purple
  { 0.20, 1.00, 0.75 }, -- teal
}
local GOLD = { 1.00, 0.82, 0.00 }

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33d9ffQuestMates:|r " .. tostring(msg)) end

local function Short(name)
  if not name then return nil end
  if Ambiguate then return Ambiguate(name, "none") end
  return (name:gsub("%-.*$", ""))
end

local function Clean(s)
  s = tostring(s or "")
  return (s:gsub("[~`%^;|\n\r]", " "))
end

------------------------------------------------------------------------
-- Group helpers
------------------------------------------------------------------------
local function GroupMembers()
  local set = {}
  local me = Short(GetUnitName("player", true))
  if IsInRaid and IsInRaid() then
    for i = 1, 40 do
      local n = GetUnitName("raid" .. i, true)
      if n then set[Short(n)] = "raid" .. i end
    end
  else
    for i = 1, 4 do
      local n = GetUnitName("party" .. i, true)
      if n then set[Short(n)] = "party" .. i end
    end
  end
  set[me] = nil
  return set
end

local function Channel()
  if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
     and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
    return "INSTANCE_CHAT"
  end
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
  return nil
end

local function ColorFor(name)
  db.colors = db.colors or {}
  local idx = db.colors[name]
  if not idx then
    local used = {}
    for n in pairs(GroupMembers()) do if db.colors[n] then used[db.colors[n]] = true end end
    for i = 1, #PALETTE do if not used[i] then idx = i; break end end
    idx = idx or (math.random(#PALETTE))
    db.colors[name] = idx
  end
  return PALETTE[idx]
end

local function Hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

------------------------------------------------------------------------
-- Reading my own quest log
------------------------------------------------------------------------
local function PlayerPos()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local m = C_Map.GetBestMapForUnit("player")
  if not m then return nil end
  local p = C_Map.GetPlayerMapPosition(m, "player")
  if not p then return nil end
  local x, y = p.x, p.y
  if p.GetXY then x, y = p:GetXY() end
  if not x or (x == 0 and y == 0) then return nil end
  return m, x, y
end

local function ParseCount(text)
  local have, need = tostring(text or ""):match("(%d+)%s*/%s*(%d+)")
  return tonumber(have), tonumber(need)
end

local function Objectives(qid, logIndex)
  local out = {}
  if C_QuestLog and C_QuestLog.GetQuestObjectives then
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    if ok and type(objs) == "table" and #objs > 0 then
      for i, o in ipairs(objs) do
        local have, need = o.numFulfilled, o.numRequired
        if not need or need == 0 then
          local h, n = ParseCount(o.text); have, need = h or have, n or need
        end
        out[i] = { text = o.text or "", have = have or 0, need = need or 0, done = o.finished and true or false, type = o.type }
      end
      return out
    end
  end
  if logIndex and GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
    local n = GetNumQuestLeaderBoards(logIndex) or 0
    for j = 1, n do
      local text, otype, finished = GetQuestLogLeaderBoard(j, logIndex)
      local have, need = ParseCount(text)
      out[j] = { text = text or "", have = have or 0, need = need or 0, done = finished and true or false, type = otype }
    end
  end
  return out
end

-- Quest area points from the game's own map data (the same data the default map uses).
local function QuestPOIs(qid, onMapCache)
  local pts = {}
  for mapID, list in pairs(onMapCache) do
    for _, e in ipairs(list) do
      if e.questID == qid and e.x and e.y and (e.x > 0 or e.y > 0) then
        pts[#pts + 1] = { m = mapID, x = e.x, y = e.y }
      end
    end
  end
  if #pts == 0 and C_QuestLog and C_QuestLog.GetNextWaypoint then
    local ok, m, x, y = pcall(C_QuestLog.GetNextWaypoint, qid)
    if ok and m and x and y and (x > 0 or y > 0) then pts[1] = { m = m, x = x, y = y } end
  end
  return pts
end

local function BuildOnMapCache()
  local cache = {}
  if not (C_QuestLog and C_QuestLog.GetQuestsOnMap and C_Map) then return cache end
  local maps = {}
  local m = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if m then maps[m] = true end
  -- Also zones I've recorded progress in, so quests in neighbouring zones still show.
  for _, list in pairs(cdb.pins or {}) do
    for _, p in ipairs(list) do maps[p.m] = true end
  end
  for mapID in pairs(maps) do
    local ok, list = pcall(C_QuestLog.GetQuestsOnMap, mapID)
    if ok and type(list) == "table" then cache[mapID] = list end
  end
  return cache
end

local function AddProgressPin(qid)
  local m, x, y = PlayerPos()
  if not m then return end
  cdb.pins[qid] = cdb.pins[qid] or {}
  local list = cdb.pins[qid]
  for _, p in ipairs(list) do
    if p.m == m and math.abs(p.x - x) < 0.01 and math.abs(p.y - y) < 0.01 then return end
  end
  table.insert(list, { m = m, x = x, y = y })
  while #list > 6 do table.remove(list, 1) end
end

local function IsTracked(qid, logIndex)
  if C_QuestLog and C_QuestLog.GetQuestWatchType then return C_QuestLog.GetQuestWatchType(qid) ~= nil end
  if C_QuestLog and C_QuestLog.IsQuestWatched then return C_QuestLog.IsQuestWatched(qid) and true or false end
  if IsQuestWatched and logIndex then return IsQuestWatched(logIndex) and true or false end
  return false
end

local function ScanLog()
  local quests = {}
  local onMap = BuildOnMapCache()
  local function add(qid, title, level, complete, logIndex)
    if not qid or qid == 0 then return end
    local objs = Objectives(qid, logIndex)
    quests[qid] = { id = qid, title = title or ("Quest " .. qid), level = level or 0,
      complete = complete and true or false, objs = objs, pois = QuestPOIs(qid, onMap),
      tracked = IsTracked(qid, logIndex) }
    -- progress pins: an objective count went up since last scan
    local prev = mySnapshot[qid]
    local snap = {}
    for i, o in ipairs(objs) do
      snap[i] = o.have
      if scanned and prev and prev[i] and o.have > prev[i] then AddProgressPin(qid) end
    end
    mySnapshot[qid] = snap
  end

  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.questID then
        local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
        add(info.questID, info.title, info.level, complete, i)
      end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    local n = GetNumQuestLogEntries() or 0
    for i = 1, n do
      local title, level, _, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
      if title and not isHeader then add(qid, title, level, isComplete == 1 or isComplete == true, i) end
    end
  end

  for qid in pairs(mySnapshot) do if not quests[qid] then mySnapshot[qid] = nil end end
  for qid in pairs(cdb.pins) do if not quests[qid] then cdb.pins[qid] = nil end end
  for _, q in pairs(quests) do q.pins = cdb.pins[q.id] or {} end
  if scanned and db.alerts then
    local members = GroupMembers()
    for qid, q in pairs(quests) do
      if not myQuests[qid] then
        for who, fr in pairs(friends) do
          if members[who] and fr.synced and fr.quests[qid] then Alert(who, q.title) end
        end
      end
    end
  end
  myQuests = quests
  scanned = true
end

------------------------------------------------------------------------
-- Messaging (chunked + throttled)
------------------------------------------------------------------------
local sendQueue, sending, seq = {}, false, 0
local CHUNK = 230

local function RawSend(text, chan)
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(PREFIX, text, chan)
  elseif SendAddonMessage then
    SendAddonMessage(PREFIX, text, chan)
  end
end

local function Pump()
  local item = table.remove(sendQueue, 1)
  if not item then sending = false; return end
  local chan = Channel()
  if chan then RawSend(item, chan) end
  C_Timer.After(0.2, Pump)
end

local function Send(msg)
  if not Channel() then return end
  seq = (seq % 999) + 1
  local n = math.ceil(#msg / CHUNK)
  if n < 1 then n = 1 end
  for i = 1, n do
    sendQueue[#sendQueue + 1] = seq .. ":" .. i .. ":" .. n .. ":" .. msg:sub((i - 1) * CHUNK + 1, i * CHUNK)
  end
  if not sending then sending = true; Pump() end
end

local function Num(v) return string.format("%.3f", v) end

local function Encode(q)
  local objs = {}
  for i, o in ipairs(q.objs) do
    objs[i] = Clean(o.text) .. FSEP .. (o.have or 0) .. FSEP .. (o.need or 0) .. FSEP .. (o.done and 1 or 0) .. FSEP .. Clean(o.type or "")
  end
  local pois, pins = {}, {}
  for i, p in ipairs(q.pois) do pois[i] = p.m .. "," .. Num(p.x) .. "," .. Num(p.y) end
  for i, p in ipairs(q.pins or {}) do pins[i] = p.m .. "," .. Num(p.x) .. "," .. Num(p.y) end
  return table.concat({ "Q", q.id, q.level or 0, q.complete and 1 or 0, Clean(q.title),
    table.concat(objs, OSEP), table.concat(pois, PSEP), table.concat(pins, PSEP), q.tracked and 1 or 0 }, SEP)
end

local function Broadcast(force)
  if not Channel() then return end
  ScanLog()
  if force then wipe(lastSent) end
  local ids = {}
  for qid, q in pairs(myQuests) do
    ids[#ids + 1] = qid
    local payload = Encode(q)
    if lastSent[qid] ~= payload then lastSent[qid] = payload; Send(payload) end
  end
  for qid in pairs(lastSent) do if not myQuests[qid] then lastSent[qid] = nil end end
  Send("S" .. SEP .. table.concat(ids, ","))
end

local pendingBroadcast, pendingForce = false, false
local function ScheduleBroadcast(force, delay)
  if force then pendingForce = true end
  if pendingBroadcast then return end
  pendingBroadcast = true
  C_Timer.After(delay or 1.5, function()
    pendingBroadcast = false
    local f = pendingForce; pendingForce = false
    Broadcast(f)
  end)
end

local function Split(s, sep)
  local out = {}
  if s == nil or s == "" then return out end
  local start = 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + #sep
  end
  return out
end

local function DecodePoints(s)
  local out = {}
  for _, part in ipairs(Split(s, PSEP)) do
    local m, x, y = part:match("^(%d+),([%d%.]+),([%d%.]+)$")
    if m then out[#out + 1] = { m = tonumber(m), x = tonumber(x), y = tonumber(y) } end
  end
  return out
end

local RefreshAll -- forward

Alert = function(who, title)
  if not db.alerts then return end
  local c = ColorFor(who)
  local text = Hex(c) .. who .. "|r is on the same quest: |cffffd100" .. title .. "|r"
  Print(text)
  if RaidNotice_AddMessage and RaidWarningFrame then
    pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 1, b = 1 })
  end
  local kit = SOUNDKIT and (SOUNDKIT.READY_CHECK or SOUNDKIT.RAID_WARNING)
  if not (kit and pcall(PlaySound, kit, "Master")) then pcall(PlaySound, 8960, "Master") end
end

local function Handle(sender, msg)
  local f = Split(msg, SEP)
  local kind = f[1]
  if kind == "H" then
    ScheduleBroadcast(true, 1 + math.random() * 2)
    return
  end
  local fr = friends[sender] or { quests = {} }
  friends[sender] = fr
  fr.last = GetTime()
  if kind == "Q" then
    local qid = tonumber(f[2]); if not qid then return end
    local objs = {}
    for _, o in ipairs(Split(f[6], OSEP)) do
      local p = Split(o, FSEP)
      objs[#objs + 1] = { text = p[1] or "", have = tonumber(p[2]) or 0, need = tonumber(p[3]) or 0, done = p[4] == "1", type = p[5] }
    end
    if fr.synced and not fr.quests[qid] and myQuests[qid] then Alert(sender, f[5] or "?") end
    local prev = fr.quests[qid]
    if fr.synced and prev and db.itemAlerts then
      for i, o in ipairs(objs) do
        local old = prev.objs[i]
        local isItem = (o.type == "item") or (o.type == nil or o.type == "")
        if isItem and old and o.have > old.have then
          Print(Hex(ColorFor(sender)) .. sender .. "|r looted " .. o.text
            .. (o.done and " |cff4dff4d(done)|r" or "") .. " |cffaaaaaa- " .. (f[5] or "?") .. "|r")
        end
      end
    end
    fr.quests[qid] = { id = qid, level = tonumber(f[3]) or 0, complete = f[4] == "1", title = f[5] or "?",
      objs = objs, pois = DecodePoints(f[7]), pins = DecodePoints(f[8]), tracked = f[9] == "1" }
  elseif kind == "S" then
    local keep = {}
    for _, id in ipairs(Split(f[2], ",")) do keep[tonumber(id) or 0] = true end
    for qid in pairs(fr.quests) do if not keep[qid] then fr.quests[qid] = nil end end
    fr.synced = true
  end
  RefreshAll()
end

local inbox = {}
local function OnAddonMessage(prefix, text, _, sender)
  if prefix ~= PREFIX then return end
  sender = Short(sender)
  if not sender or sender == Short(GetUnitName("player", true)) then return end
  if not GroupMembers()[sender] then return end
  local id, i, n, body = text:match("^(%d+):(%d+):(%d+):(.*)$")
  if not id then return end
  i, n = tonumber(i), tonumber(n)
  local key = sender .. "#" .. id
  local buf = inbox[key]
  if not buf then buf = { n = n, parts = {}, got = 0, t = GetTime() }; inbox[key] = buf end
  if not buf.parts[i] then buf.parts[i] = body; buf.got = buf.got + 1 end
  if buf.got >= buf.n then
    inbox[key] = nil
    Handle(sender, table.concat(buf.parts))
  end
  for k, b in pairs(inbox) do if GetTime() - b.t > 30 then inbox[k] = nil end end
end

------------------------------------------------------------------------
-- World map pins (same method as TrekTime, which works in WoW Forever)
------------------------------------------------------------------------
local pins = {}

local function Project(m, x, y, viewMap)
  if m == viewMap then return x, y end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  local ok, contID, world = pcall(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
  if not ok or not world then return nil end
  local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, contID, world, viewMap)
  if not ok2 or not pos then return nil end
  local px, py = pos.x, pos.y
  if pos.GetXY then px, py = pos:GetXY() end
  if not px or px < 0 or px > 1 or py < 0 or py > 1 then return nil end
  return px, py
end

local function ShowPinTooltip(p)
  GameTooltip:SetOwner(p, "ANCHOR_RIGHT")
  local c = ColorFor(p.who)
  GameTooltip:AddLine(p.who, c[1], c[2], c[3])
  for idx, q in ipairs(p.list) do
    if idx > 1 then GameTooltip:AddLine(" ") end
    GameTooltip:AddLine(string.format("[%d] %s", q.level or 0, q.title), 1, 1, 1)
    if myQuests[q.id] then GameTooltip:AddLine("You have this quest too", GOLD[1], GOLD[2], GOLD[3]) end
    if q.complete then
      GameTooltip:AddLine("Ready to turn in", 0.3, 1, 0.3)
    else
      for _, o in ipairs(q.objs) do
        local col = o.done and 0.5 or 0.9
        GameTooltip:AddLine("  " .. o.text, col, col, col)
      end
    end
  end
  if p.isProgress then GameTooltip:AddLine("Spot where they made progress", 0.6, 0.6, 0.6) end
  GameTooltip:Show()
end

local function GetPin(i, parent)
  local p = pins[i]
  if not p then
    p = CreateFrame("Button", nil, parent)
    p.ring = p:CreateTexture(nil, "ARTWORK", nil, 1)
    p.ring:SetTexture(MEDIA .. "Ring"); p.ring:SetPoint("CENTER"); p.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    p.disc = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.disc:SetTexture(MEDIA .. "Disc"); p.disc:SetAllPoints()
    p.txt = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.txt:SetPoint("CENTER", 0, 0); p.txt:SetTextColor(0, 0, 0); p.txt:SetShadowColor(0, 0, 0, 0)
    p:SetScript("OnEnter", ShowPinTooltip)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pins[i] = p
  end
  return p
end

local function RefreshPins()
  for _, p in ipairs(pins) do p:Hide() end
  if not db or not db.mapPins or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  local viewMap = WorldMapFrame:GetMapID()
  local child = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
  if not viewMap or not child then return end
  local w, h = child:GetWidth(), child:GetHeight()
  local members = GroupMembers()
  local i = 0
  local function place(who, list, x, y, isProgress)
    i = i + 1
    local p = GetPin(i, child)
    p.who, p.list, p.isProgress = who, list, isProgress
    local c = ColorFor(who)
    local size = isProgress and 12 or 20
    p:SetSize(size, size)
    p.ring:SetSize(size * 1.7, size * 1.7)
    p.disc:SetVertexColor(c[1], c[2], c[3])
    local shared = false
    for _, q in ipairs(list) do if myQuests[q.id] then shared = true end end
    p.ring:SetShown(shared and db.highlightShared ~= false)
    local allDone = true
    for _, q in ipairs(list) do if not q.complete then allDone = false end end
    if isProgress then p.txt:SetText("")
    elseif allDone then p.txt:SetText("?")
    else p.txt:SetText(who:sub(1, 1):upper()) end
    p:SetFrameLevel(child:GetFrameLevel() + 2100)
    p:ClearAllPoints()
    p:SetPoint("CENTER", child, "TOPLEFT", x * w, -y * h)
    p:Show()
  end
  for who, fr in pairs(friends) do
    if members[who] then
      -- group quest areas that land on the same spot into one pin
      local spots = {}
      local prog = {}
      for _, q in pairs(fr.quests) do
        for _, pt in ipairs(q.pois) do
          local x, y = Project(pt.m, pt.x, pt.y, viewMap)
          if x then
            local merged
            for _, s in ipairs(spots) do
              if math.abs((s.x - x) * w) < 12 and math.abs((s.y - y) * h) < 12 then
                s.list[#s.list + 1] = q; merged = true; break
              end
            end
            if not merged then spots[#spots + 1] = { x = x, y = y, list = { q } } end
          end
        end
        if db.progressPins ~= false and not q.complete then
          for _, pt in ipairs(q.pins or {}) do
            local x, y = Project(pt.m, pt.x, pt.y, viewMap)
            if x then prog[#prog + 1] = { x = x, y = y, list = { q } } end
          end
        end
      end
      for _, s in ipairs(prog) do place(who, s.list, s.x, s.y, true) end
      for _, s in ipairs(spots) do place(who, s.list, s.x, s.y, false) end
    end
  end
end

------------------------------------------------------------------------
-- Shared row builder (used by the side panel and the floating list)
------------------------------------------------------------------------
local collapsed = {}

local function BuildRows()
  local rows, members = {}, GroupMembers()
  local names = {}
  for who in pairs(friends) do if members[who] then names[#names + 1] = who end end
  table.sort(names)
  for _, who in ipairs(names) do
    local fr = friends[who]
    local qs = {}
    for _, q in pairs(fr.quests) do qs[#qs + 1] = q end
    table.sort(qs, function(a, b)
      local sa, sb = myQuests[a.id] and 1 or 0, myQuests[b.id] and 1 or 0
      if sa ~= sb then return sa > sb end
      if a.level ~= b.level then return a.level < b.level end
      return a.title < b.title
    end)
    rows[#rows + 1] = { kind = "header", who = who, count = #qs }
    if not collapsed[who] then
      if #qs == 0 then rows[#rows + 1] = { kind = "note", text = "No quests" } end
      for _, q in ipairs(qs) do
        local prog = {}
        for _, o in ipairs(q.objs) do if o.need and o.need > 0 then prog[#prog + 1] = o.have .. "/" .. o.need end end
        local status = q.complete and " |cff4dff4d(done)|r" or (#prog > 0 and (" |cffaaaaaa" .. table.concat(prog, " ") .. "|r") or "")
        local shared = myQuests[q.id] and db.highlightShared ~= false
        local name = shared and ("|cffffd100* " .. q.title .. "|r") or ("|cffffffff" .. q.title .. "|r")
        rows[#rows + 1] = { kind = "quest", q = q, who = who,
          text = string.format("|cffaaaaaa[%d]|r %s%s", q.level or 0, name, status) }
      end
    end
  end
  return rows, #names
end

local function QuestTooltip(owner, q, who)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  local c = ColorFor(who)
  GameTooltip:AddLine(string.format("[%d] %s", q.level or 0, q.title), 1, 0.82, 0)
  GameTooltip:AddLine(who, c[1], c[2], c[3])
  GameTooltip:AddLine("Click to read the quest - Shift-click to link it", 0.5, 0.8, 1)
  if myQuests[q.id] then GameTooltip:AddLine("You have this quest too", GOLD[1], GOLD[2], GOLD[3]) end
  if q.complete then GameTooltip:AddLine("Ready to turn in", 0.3, 1, 0.3)
  else for _, o in ipairs(q.objs) do GameTooltip:AddLine("  " .. o.text, o.done and 0.5 or 0.9, o.done and 0.5 or 0.9, o.done and 0.5 or 0.9) end end
  GameTooltip:Show()
end

local RefreshList -- forward

-- Click a friend's quest: read it. Shift-click: link it in chat.
local function QuestLink(q)
  local link = GetQuestLink and GetQuestLink(q.id)
  return link or string.format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", q.id, q.level or 0, q.title)
end

local function OpenQuest(q, who)
  if IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
    if ChatEdit_InsertLink(QuestLink(q)) then return end
  end
  if myQuests[q.id] and not IsShiftKeyDown() then
    if QuestLedgerForever_OpenQuest and QuestLedgerForever_OpenQuest(q.id) then return end
    if QuestMapFrame_OpenToQuestDetails then QuestMapFrame_OpenToQuestDetails(q.id) return end
    if QuestLog_OpenToQuestIndex and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
      local idx = C_QuestLog.GetLogIndexForQuestID(q.id)
      if idx then QuestLog_OpenToQuestIndex(idx) return end
    end
  end
  local tt = ItemRefTooltip
  if not tt then return end
  if tt:IsShown() and tt.qmQuest == q.id then tt:Hide(); tt.qmQuest = nil; return end
  ShowUIPanel(tt)
  if not tt:IsShown() then tt:SetOwner(UIParent, "ANCHOR_PRESERVE") end
  tt:SetHyperlink("quest:" .. q.id .. ":" .. (q.level or 0))
  if tt:NumLines() == 0 then tt:AddLine(string.format("[%d] %s", q.level or 0, q.title), 1, 0.82, 0) end
  local c = ColorFor(who)
  tt:AddLine(" ")
  tt:AddLine(who .. (q.complete and " - ready to turn in" or "'s progress:"), c[1], c[2], c[3])
  if not q.complete then
    for _, o in ipairs(q.objs) do tt:AddLine("  " .. o.text, o.done and 0.5 or 0.9, o.done and 0.5 or 0.9, o.done and 0.5 or 0.9) end
  end
  tt:Show()
  tt.qmQuest = q.id
end

------------------------------------------------------------------------
-- Side panel attached to the Map & Quest Log, opened by a tab button
------------------------------------------------------------------------
local panel, tab, scroll, content
local panelRows = {}

local function QuestListArea()
  local q = QuestMapFrame or (WorldMapFrame and WorldMapFrame.QuestLog)
  if q and q:IsVisible() and (q:GetWidth() or 0) > 100 then return q end
end

local function AnchorPanel()
  if not panel then return end
  panel:ClearAllPoints()
  local q = (db.panelStyle ~= "side") and QuestListArea() or nil
  if q then
    panel:SetAllPoints(q)            -- sits on top of your quest list
    panel.inMap = true
  else                                -- map minimized / quest list hidden: show beside the map
    panel:SetWidth(300)
    panel:SetPoint("TOPLEFT", WorldMapFrame, "TOPRIGHT", -2, 0)
    panel:SetPoint("BOTTOMLEFT", WorldMapFrame, "BOTTOMRIGHT", -2, 0)
    panel.inMap = false
  end
  -- one strata above the map so the quest log's own scroll lists can never draw on top
  local up = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG", DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG" }
  panel:SetFrameStrata(up[WorldMapFrame:GetFrameStrata()] or "DIALOG")
  panel:SetFrameLevel(50)
  panel:Raise()
end

local function FindQuestToggle()
  local t = WorldMapFrame.SidePanelToggle or (WorldMapFrame.BorderFrame and WorldMapFrame.BorderFrame.SidePanelToggle)
  if t then return t end
  local function scan(f, depth)
    if depth > 3 then return end
    for _, c in ipairs({ f:GetChildren() }) do
      if (c.OpenButton and c.CloseButton) then return c end
      local hit = scan(c, depth + 1); if hit then return hit end
    end
  end
  return scan(WorldMapFrame, 0)
end

local function MakePanel()
  if panel or not WorldMapFrame then return end
  local f = CreateFrame("Frame", "QuestMatesPanel", WorldMapFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.08, 0.06, 0.03, 1)
    f:SetBackdropBorderColor(0.75, 0.6, 0.3, 1)
  end
  f:SetFrameStrata(WorldMapFrame:GetFrameStrata())
  f:EnableMouse(true)
  f:Hide()

  local head = f:CreateTexture(nil, "ARTWORK")
  head:SetTexture(MEDIA .. "PartyIcon"); head:SetSize(22, 22); head:SetPoint("TOPLEFT", 8, -7)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", head, "RIGHT", 6, 0); title:SetText("Party quests")
  local back = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  back:SetSize(84, 20); back:SetPoint("TOPRIGHT", -6, -7); back:SetText("My quests")
  back:SetScript("OnClick", function() db.panelOpen = false; RefreshList() end)
  f.CloseButton = back
  local tb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  tb:SetSize(70, 20); tb:SetPoint("RIGHT", back, "LEFT", -4, 0); tb:SetText("Tracker")
  tb:SetScript("OnClick", function() db.listShown = not db.listShown; RefreshList()
    Print("Floating tracker " .. (db.listShown and "on (shows when the map is closed)" or "off")) end)
  tb:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:AddLine("Floating tracker on/off")
    GameTooltip:AddLine("Shows your group's quests under the normal quest tracker when the map is closed.", 1, 1, 1, true); GameTooltip:Show() end)
  tb:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 8, -34)
  sf:SetPoint("BOTTOMRIGHT", -28, 8)
  local c = CreateFrame("Frame", nil, sf)
  c:SetSize(240, 10)
  sf:SetScrollChild(c)
  scroll, content, panel = sf, c, f

  -- small button in the map's title bar, next to maximize/close
  local border = WorldMapFrame.BorderFrame or WorldMapFrame
  local anchor = (border.MaximizeMinimizeFrame) or (WorldMapFrame.MaximizeMinimizeFrame) or border.CloseButton or WorldMapFrame.CloseButton
  local b = CreateFrame("Button", "QuestMatesTab", border)
  b.Reanchor = function(self)
    self:ClearAllPoints()
    local toggle = FindQuestToggle()
    if (db.buttonStyle == "stack" or db.buttonStyle == nil) and toggle then  -- stacked above the map's quest-log "?" toggle
      self:SetParent(toggle:GetParent() or WorldMapFrame)
      local w, h = toggle:GetSize()
      self:SetSize(w > 0 and w or 32, h > 0 and h or 32)
      self:SetPoint("BOTTOM", toggle, "TOP", 0, 2)
      self:SetFrameStrata(toggle:GetFrameStrata())
      self:SetFrameLevel(toggle:GetFrameLevel() + 1)
      self.icon:Hide()
      if not self.skinned then self.skinned = true; self:SkinLike(toggle) end
      self.inner:SetShown(not self.native); self.q:SetShown(not self.native)
      if self.native then self.edge:Hide() end
    elseif db.buttonStyle == "side" then         -- classic: tab sticking out of the map's right edge
      self.icon:Show(); self.inner:Hide(); self.q:Hide()
      self.edge:Show(); if self.nat then for _, t in pairs(self.nat) do t:Hide() end end
      self:SetParent(WorldMapFrame)
      self:SetSize(34, 44)
      local edgeOf = (panel and panel:IsShown() and not panel.inMap) and panel or WorldMapFrame
      self:SetPoint("TOPLEFT", edgeOf, "TOPRIGHT", -4, -70)
      self:SetFrameStrata(edgeOf:GetFrameStrata())
      self:SetFrameLevel(edgeOf:GetFrameLevel() + 20)
    else                                      -- title bar, next to maximize/close
      self.icon:Show(); self.inner:Hide(); self.q:Hide()
      self.edge:Show(); if self.nat then for _, t in pairs(self.nat) do t:Hide() end end
      self:SetParent(border)
      self:SetSize(22, 22)
      if anchor then self:SetPoint("RIGHT", anchor, "LEFT", -2, 0) else self:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -60, -2) end
      self:SetFrameStrata((anchor or border):GetFrameStrata())
      self:SetFrameLevel((anchor or border):GetFrameLevel() + 5)
    end
  end
  local edge = b:CreateTexture(nil, "BACKGROUND")
  edge:SetTexture("Interface\\Buttons\\WHITE8X8"); edge:SetVertexColor(0.75, 0.6, 0.3, 1); edge:SetAllPoints()
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MEDIA .. "PartyIcon")
  icon:SetPoint("TOPLEFT", 1, -1); icon:SetPoint("BOTTOMRIGHT", -1, 1)
  -- "stack" look: dark square with a green ? (matches the map's own ? toggle)
  b.inner = b:CreateTexture(nil, "BORDER")
  b.inner:SetTexture("Interface\\Buttons\\WHITE8X8"); b.inner:SetVertexColor(0.05, 0.04, 0.02, 1)
  b.inner:SetPoint("TOPLEFT", 2, -2); b.inner:SetPoint("BOTTOMRIGHT", -2, 2)
  b.q = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  b.q:SetPoint("CENTER", 1, 0); b.q:SetText("?"); b.q:SetTextColor(0.35, 1, 0.3)
  b.q:SetShadowOffset(1, -1)
  b.icon = icon
  b.edge = edge
  -- copy the look of the map's own ? toggle, tinted green
  function b:SkinLike(toggle)
    local src = (toggle.OpenButton and toggle.OpenButton:IsShown() and toggle.OpenButton) or toggle.OpenButton or toggle.CloseButton or toggle
    local function copy(getter, layer)
      local t = src[getter] and src[getter](src)
      if not t then return end
      local n = self:CreateTexture(nil, layer)
      local atlas = t.GetAtlas and t:GetAtlas()
      if atlas then n:SetAtlas(atlas) else
        local file = t:GetTexture(); if not file then return end
        n:SetTexture(file); n:SetTexCoord(t:GetTexCoord())
      end
      n:SetAllPoints()
      return n
    end
    self.nat = {
      normal = copy("GetNormalTexture", "ARTWORK"),
      hl = copy("GetHighlightTexture", "HIGHLIGHT"),
    }
    if self.nat.normal then
      self.native = true
      self.nat.normal:SetDesaturated(true)
      self.nat.normal:SetVertexColor(0.45, 1, 0.35)
      if self.nat.hl then self.nat.hl:SetBlendMode("ADD") end
      local p = copy("GetPushedTexture", "ARTWORK")
      if p then
        p:SetDesaturated(true); p:SetVertexColor(0.45, 1, 0.35); p:Hide()
        self:HookScript("OnMouseDown", function() p:Show(); self.nat.normal:Hide() end)
        self:HookScript("OnMouseUp", function() p:Hide(); self.nat.normal:Show() end)
        self.nat.pushed = p
      end
      self:SetHighlightTexture("")
    end
  end
  b.on = b:CreateTexture(nil, "OVERLAY")
  b.on:SetTexture("Interface\\Buttons\\CheckButtonHilight"); b.on:SetBlendMode("ADD"); b.on:SetAllPoints()
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b.badge = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  b.badge:SetPoint("BOTTOMRIGHT", 2, -2)
  b:SetScript("OnClick", function()
    db.panelOpen = not db.panelOpen
    RefreshList()
  end)
  b:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    GameTooltip:AddLine("QuestMates")
    GameTooltip:AddLine(db.panelOpen and "Back to your quests" or "Show your group's quests", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  tab = b
  if QuestMapFrame then
    QuestMapFrame:HookScript("OnShow", function() C_Timer.After(0, RefreshList) end)
    QuestMapFrame:HookScript("OnHide", function() C_Timer.After(0, RefreshList) end)
  end
end

local function PanelRow(i)
  local r = panelRows[i]
  if r then return r end
  r = CreateFrame("Button", nil, content)
  r:SetHeight(20)
  r.bar = r:CreateTexture(nil, "BACKGROUND")
  r.bar:SetAllPoints(); r.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
  r.line = r:CreateTexture(nil, "BORDER")
  r.line:SetTexture("Interface\\Buttons\\WHITE8X8"); r.line:SetVertexColor(0.55, 0.42, 0.2, 1)
  r.line:SetPoint("BOTTOMLEFT"); r.line:SetPoint("BOTTOMRIGHT"); r.line:SetHeight(1)
  r.dot = r:CreateTexture(nil, "ARTWORK")
  r.dot:SetTexture(MEDIA .. "Disc"); r.dot:SetSize(12, 12); r.dot:SetPoint("LEFT", 6, 0)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
  r.sign = r:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  r.sign:SetPoint("RIGHT", -6, 0)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r:SetScript("OnClick", function(s)
    if s.data and s.data.kind == "header" then collapsed[s.data.who] = not collapsed[s.data.who]; RefreshList()
    elseif s.data and s.data.kind == "quest" then OpenQuest(s.data.q, s.data.who) end
  end)
  r:SetScript("OnEnter", function(s)
    if s.data and s.data.kind == "quest" then QuestTooltip(s, s.data.q, s.data.who) end
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panelRows[i] = r
  return r
end

local function RefreshPanel()
  if not panel then return end
  local mapOpen = WorldMapFrame and WorldMapFrame:IsShown()
  -- Quest Ledger Forever "pure map": no quest-log elements on the map (pins stay)
  if QuestLedgerForever_IsPureMap and QuestLedgerForever_IsPureMap() then
    tab:Hide(); panel:Hide(); return
  end
  tab:SetShown(mapOpen and db.dock ~= false)
  local rows, nFriends = BuildRows()
  tab.badge:SetText(nFriends > 0 and nFriends or "")
  tab.on:SetShown(db.panelOpen and true or false)
  if not (mapOpen and db.panelOpen and db.dock ~= false) then panel:Hide(); tab:Reanchor(); return end
  AnchorPanel()
  panel:Show()
  tab:Reanchor()
  local w = scroll:GetWidth()
  if not w or w < 50 then
    w = 250
    C_Timer.After(0, function() if scroll:GetWidth() and scroll:GetWidth() >= 50 then RefreshPanel() end end)
  end
  content:SetWidth(w)
  for _, r in ipairs(panelRows) do r:Hide() end
  local y = 0
  if #rows == 0 then
    local r = PanelRow(1); r.data = nil
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -4); r:SetPoint("RIGHT", content, "RIGHT")
    r.bar:SetVertexColor(0, 0, 0, 0); r.line:Hide(); r.dot:Hide(); r.sign:SetText("")
    r.text:SetFontObject("GameFontDisableSmall")
    r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 4, 0); r.text:SetPoint("RIGHT", -4, 0)
    r.text:SetText(IsInGroup() and "No one in your group has QuestMates yet." or "Join a group to see their quests.")
    r:Show()
    content:SetHeight(30)
    return
  end
  for i, d in ipairs(rows) do
    local r = PanelRow(i)
    r.data = d
    r:ClearAllPoints()
    r.text:ClearAllPoints()
    if d.kind == "header" then
      r:SetHeight(24)
      r:SetPoint("TOPLEFT", 0, -y - (i > 1 and 6 or 0)); r:SetPoint("RIGHT", content, "RIGHT")
      y = y + 24 + (i > 1 and 6 or 0)
      r.bar:SetVertexColor(0.24, 0.15, 0.07, 0.95); r.line:Show()
      local c = ColorFor(d.who)
      r.dot:Show(); r.dot:SetVertexColor(c[1], c[2], c[3])
      r.text:SetFontObject("GameFontNormal")
      r.text:SetPoint("LEFT", 24, 0); r.text:SetPoint("RIGHT", -24, 0)
      r.text:SetText(d.who .. " |cffaaaaaa(" .. d.count .. ")|r")
      r.sign:SetText(collapsed[d.who] and "|cffffd100+|r" or "|cffffd100-|r")
    else
      r:SetHeight(18)
      r:SetPoint("TOPLEFT", 0, -y - 2); r:SetPoint("RIGHT", content, "RIGHT")
      y = y + 20
      r.bar:SetVertexColor(0, 0, 0, 0); r.line:Hide(); r.dot:Hide(); r.sign:SetText("")
      r.text:SetFontObject(d.kind == "note" and "GameFontDisableSmall" or "GameFontHighlight")
      r.text:SetPoint("LEFT", 12, 0); r.text:SetPoint("RIGHT", -4, 0)
      r.text:SetText(d.text)
    end
    r:Show()
  end
  content:SetHeight(y + 8)
end

------------------------------------------------------------------------
-- Floating list (for when the map is closed)
------------------------------------------------------------------------
local list = CreateFrame("Frame", "QuestMatesList", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
list:SetSize(380, 60)
list:SetMovable(true); list:EnableMouse(true); list:RegisterForDrag("LeftButton")
list:SetClampedToScreen(true)
list:SetScript("OnDragStart", list.StartMoving)
list:SetScript("OnDragStop", function(s)
  s:StopMovingOrSizing()
  local a, _, b, x, y = s:GetPoint()
  db.pos = { a, b, x, y }
end)
if list.SetBackdrop then
  list:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, tile = true, tileSize = 32,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  list:SetBackdropBorderColor(0.75, 0.6, 0.3, 1)
end
list:Hide()
local title = list:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 10, -9); title:SetText("QuestMates")
local close = CreateFrame("Button", nil, list, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function() db.listShown = false; list:Hide() end)
local lines = {}

local function PlaceList()
  list:ClearAllPoints()
  if db.pos then list:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
  else list:SetPoint("RIGHT", UIParent, "RIGHT", -40, 80) end
  list:SetScale(db.scale or 1.15)
end

------------------------------------------------------------------------
-- Arrow in the world pointing to the nearest quest a friend is tracking
------------------------------------------------------------------------
local arrow = CreateFrame("Button", "QuestMatesArrow", UIParent)
arrow:SetSize(56, 56)
arrow:SetMovable(true); arrow:SetClampedToScreen(true)
arrow:RegisterForClicks("LeftButtonUp", "RightButtonUp")
arrow:RegisterForDrag("LeftButton")
arrow:Hide()
arrow.tex = arrow:CreateTexture(nil, "ARTWORK")
arrow.tex:SetTexture("Interface\\Minimap\\MinimapArrow")
arrow.tex:SetAllPoints()
arrow.who = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
arrow.who:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
arrow.quest = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.quest:SetPoint("TOP", arrow.who, "BOTTOM", 0, -1)
arrow.dist = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.dist:SetPoint("TOP", arrow.quest, "BOTTOM", 0, -1)
arrow:SetScript("OnDragStart", function(s) if IsShiftKeyDown() then s:StartMoving() end end)
arrow:SetScript("OnDragStop", function(s)
  s:StopMovingOrSizing()
  local a, _, b, x, y = s:GetPoint(); db.arrowPos = { a, b, x, y }
end)

local arrowSkip = 0       -- left-click cycles to the next-nearest target
local arrowTarget         -- current target, for click-to-read
arrow:SetScript("OnClick", function(_, btn)
  if btn == "RightButton" then
    if arrowTarget then OpenQuest(arrowTarget.q, arrowTarget.who) end
  else
    arrowSkip = arrowSkip + 1
  end
end)
arrow:SetScript("OnEnter", function(s)
  GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("QuestMates arrow")
  GameTooltip:AddLine("Points to the nearest quest a friend is tracking.", 1, 1, 1, true)
  GameTooltip:AddLine("Left-click: next friend quest  Right-click: read quest", 0.5, 0.8, 1)
  GameTooltip:AddLine("Shift-drag: move  /qm arrow: turn off", 0.5, 0.8, 1)
  GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function PlaceArrow()
  arrow:ClearAllPoints()
  if db.arrowPos then arrow:SetPoint(db.arrowPos[1], UIParent, db.arrowPos[2], db.arrowPos[3], db.arrowPos[4])
  else arrow:SetPoint("TOP", UIParent, "TOP", 0, -140) end
end

-- player position expressed on another map (so we can measure against quest points on that map)
local function PlayerOnMap(pm, px, py, target)
  if pm == target then return px, py end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
  local cont, world = C_Map.GetWorldPosFromMapPos(pm, CreateVector2D(px, py))
  if not (cont and world) then return end
  local _, pos = C_Map.GetMapPosFromWorldPos(cont, world, target)
  if not pos then return end
  local x, y = pos.x, pos.y
  if pos.GetXY then x, y = pos:GetXY() end
  return x, y
end

local function MapSize(m)
  if C_Map.GetMapWorldSize then
    local w, h = C_Map.GetMapWorldSize(m)
    if w and w > 0 then return w, h end
  end
end

local function ArrowTargets()
  local list = {}
  local pm, px, py = PlayerPos()
  if not pm then return list end
  local members = GroupMembers()
  for who, fr in pairs(friends) do
    if members[who] then
      for _, q in pairs(fr.quests) do
        if q.tracked then
          local best
          for _, p in ipairs(q.pois or {}) do
            local x, y = PlayerOnMap(pm, px, py, p.m)
            local w, h = MapSize(p.m)
            if x and w then
              local dxE, dyS = (p.x - x) * w, (p.y - y) * h
              local d = math.sqrt(dxE * dxE + dyS * dyS)
              if not best or d < best.d then best = { d = d, dxE = dxE, dyS = dyS } end
            end
          end
          if best then list[#list + 1] = { who = who, q = q, d = best.d, dxE = best.dxE, dyS = best.dyS } end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  return list
end

local arrowElapsed = 0
arrow.driver = CreateFrame("Frame")
arrow.driver:SetScript("OnUpdate", function(_, el)
  arrowElapsed = arrowElapsed + el
  if arrowElapsed < 0.05 then return end
  arrowElapsed = 0
  if not db or not db.pointer or not Channel() or (IsInInstance and IsInInstance()) then arrow:Hide(); return end
  local list = ArrowTargets()
  if #list == 0 then arrow:Hide(); arrowTarget = nil; return end
  if not arrow.placed then PlaceArrow(); arrow.placed = true end
  local t = list[(arrowSkip % #list) + 1]
  arrowTarget = t
  local c = ColorFor(t.who)
  arrow.tex:SetVertexColor(c[1], c[2], c[3])
  arrow.who:SetText(t.who .. (#list > 1 and string.format(" |cffaaaaaa(%d/%d)|r", (arrowSkip % #list) + 1, #list) or ""))
  arrow.who:SetTextColor(c[1], c[2], c[3])
  arrow.quest:SetText("|cffffd100" .. t.q.title .. "|r")
  if t.d < 15 then
    arrow.dist:SetText("|cff4dff4dYou're there|r")
    arrow.tex:SetRotation(0)
  else
    arrow.dist:SetText(string.format("%d yds", t.d))
    local angle = math.atan2(-t.dxE, -t.dyS)          -- 0 = north, counter-clockwise like GetPlayerFacing
    arrow.tex:SetRotation(angle - (GetPlayerFacing and GetPlayerFacing() or 0))
  end
  arrow:Show()
end)

------------------------------------------------------------------------
-- Native-style floating tracker (looks like Blizzard's quest tracker)
------------------------------------------------------------------------
local trk = CreateFrame("Frame", "QuestMatesTracker", UIParent)
trk:SetSize(250, 40)
trk:SetMovable(true); trk:EnableMouse(false); trk:SetClampedToScreen(true)
trk:Hide()
local trkHead = CreateFrame("Button", nil, trk)
trkHead:SetPoint("TOPLEFT"); trkHead:SetPoint("TOPRIGHT"); trkHead:SetHeight(26)
trkHead:RegisterForDrag("LeftButton")
trkHead:SetScript("OnDragStart", function() if IsShiftKeyDown() or not db.trackerLocked then trk:StartMoving() end end)
trkHead:SetScript("OnDragStop", function()
  trk:StopMovingOrSizing()
  local a, _, b, x, y = trk:GetPoint(); db.trkPos = { a, b, x, y }
end)
local hbg = trkHead:CreateTexture(nil, "BACKGROUND")
hbg:SetAtlas("Objective-Header", true)
if not hbg:GetAtlas() then
  hbg:SetTexture("Interface\\QuestFrame\\ObjectiveTracker"); hbg:SetTexCoord(0, 0.6, 0.25, 0.35)
end
hbg:SetPoint("TOPLEFT", -20, 8); hbg:SetPoint("BOTTOMRIGHT", 20, -10); hbg:SetAlpha(0.9)
local htxt = trkHead:CreateFontString(nil, "OVERLAY", "GameFontNormal")
if _G.GameFontNormalMed2 then htxt:SetFontObject(GameFontNormalMed2) end
htxt:SetPoint("LEFT", 6, 0); htxt:SetText("Party Quests")
local minBtn = CreateFrame("Button", nil, trkHead)
minBtn:SetSize(16, 16); minBtn:SetPoint("RIGHT", -4, 0)
minBtn:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
minBtn:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
minBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
minBtn:SetScript("OnClick", function() db.trackerMin = not db.trackerMin; RefreshList() end)
trkHead:SetScript("OnEnter", function(s)
  GameTooltip:SetOwner(s, "ANCHOR_LEFT"); GameTooltip:AddLine("QuestMates")
  GameTooltip:AddLine("Drag to move. Click a quest to read it.", 1, 1, 1); GameTooltip:Show()
end)
trkHead:SetScript("OnLeave", function() GameTooltip:Hide() end)
local trkLines = {}

local function PlaceTracker()
  trk:ClearAllPoints()
  if db.trkPos then trk:SetPoint(db.trkPos[1], UIParent, db.trkPos[2], db.trkPos[3], db.trkPos[4])
  else trk:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -330) end
end

local trkPlaced = false
local function RefreshTracker(rows)
  if not trkPlaced then PlaceTracker(); trkPlaced = true end
  for _, l in ipairs(trkLines) do l:Hide() end
  trk:SetScale(db.trackerScale or 1)
  minBtn:SetNormalTexture(db.trackerMin and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
  minBtn:SetPushedTexture(db.trackerMin and "Interface\\Buttons\\UI-PlusButton-Down" or "Interface\\Buttons\\UI-MinusButton-Down")
  local y, n = -30, 0
  local function line(font, text, indent, data, r, g, b)
    n = n + 1
    local l = trkLines[n]
    if not l then
      l = CreateFrame("Button", nil, trk)
      l.fs = l:CreateFontString(nil, "OVERLAY")
      l.fs:SetPoint("TOPLEFT"); l.fs:SetPoint("RIGHT"); l.fs:SetJustifyH("LEFT"); l.fs:SetWordWrap(true)
      l:SetScript("OnClick", function(bt)
        local d = bt.data; if not d then return end
        if d.kind == "header" then collapsed[d.who] = not collapsed[d.who]; RefreshList()
        elseif d.kind == "quest" then OpenQuest(d.q, d.who) end
      end)
      l:SetScript("OnEnter", function(bt)
        if bt.data and bt.data.kind == "quest" then bt.fs:SetTextColor(1, 1, 1); QuestTooltip(bt, bt.data.q, bt.data.who) end
      end)
      l:SetScript("OnLeave", function(bt) if bt.r then bt.fs:SetTextColor(bt.r, bt.g, bt.b) end; GameTooltip:Hide() end)
      trkLines[n] = l
    end
    l.data = data
    l.fs:SetFontObject(font)
    l.fs:SetText(text)
    l.r, l.g, l.b = r, g, b
    if r then l.fs:SetTextColor(r, g, b) end
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", indent, y); l:SetPoint("RIGHT", trk, "RIGHT", 0, 0)
    local h = math.max(14, l.fs:GetStringHeight() or 14)
    l:SetHeight(h); l:EnableMouse(data ~= nil); l:Show()
    y = y - h - 2
  end
  if not db.trackerMin then
    for i, d in ipairs(rows) do
      if d.kind == "header" then
        if i > 1 then y = y - 6 end
        local c = ColorFor(d.who)
        line("GameFontNormal", d.who .. (collapsed[d.who] and " |cff888888(" .. d.count .. ")|r" or ""), 6, d, c[1], c[2], c[3])
      elseif d.kind == "note" then
        line("GameFontHighlightSmall", d.text, 16, nil, 0.6, 0.6, 0.6)
      else
        local q = d.q
        local shared = myQuests[q.id] and db.highlightShared ~= false
        line("GameFontNormal", (shared and "* " or "") .. q.title, 16, d, 1, 0.82, 0)
        if q.complete then
          line("GameFontHighlightSmall", "- Ready for turn-in", 26, nil, 0.3, 1, 0.3)
        else
          for _, o in ipairs(q.objs) do
            line("GameFontHighlightSmall", "- " .. (o.text or ""), 26, nil, o.done and 0.6 or 0.8, o.done and 0.6 or 0.8, o.done and 0.6 or 0.8)
          end
        end
      end
    end
  end
  trk:SetHeight(-y + 4)
  trk:Show()
end

local function RefreshFloating()
  for _, l in ipairs(lines) do l:Hide() end
  local mapOpen = WorldMapFrame and WorldMapFrame:IsShown()
  local rows, nFriends = BuildRows()
  if not db.listShown or nFriends == 0 or mapOpen then list:Hide(); trk:Hide(); return end
  if db.trackerStyle ~= "box" then list:Hide(); RefreshTracker(rows); return end
  trk:Hide()
  list:SetScale(db.scale or 1.15)
  local y, n = -32, 0
  local function line(text, indent, data)
    n = n + 1
    local l = lines[n]
    if not l then
      l = CreateFrame("Button", nil, list)
      l:SetHeight(18)
      l.fs = l:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      l.fs:SetAllPoints(); l.fs:SetJustifyH("LEFT"); l.fs:SetWordWrap(false)
      l:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      l:SetScript("OnClick", function(b)
        local d = b.data; if not d then return end
        if d.kind == "header" then collapsed[d.who] = not collapsed[d.who]; RefreshList()
        elseif d.kind == "quest" then OpenQuest(d.q, d.who) end
      end)
      l:SetScript("OnEnter", function(b) if b.data and b.data.kind == "quest" then QuestTooltip(b, b.data.q, b.data.who) end end)
      l:SetScript("OnLeave", function() GameTooltip:Hide() end)
      lines[n] = l
    end
    l.data = data
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", 10 + (indent or 0), y)
    l:SetPoint("RIGHT", list, "RIGHT", -10, 0)
    l.fs:SetText(text); l:Show()
    y = y - 18
  end
  for i, d in ipairs(rows) do
    if d.kind == "header" then
      if i > 1 then y = y - 6 end
      line(Hex(ColorFor(d.who)) .. d.who .. "|r" .. (collapsed[d.who] and " |cffaaaaaa(" .. d.count .. ")|r" or ""), 0, d)
    elseif d.kind == "note" then line("|cff888888" .. d.text .. "|r", 14)
    else line(d.text, 14, d) end
  end
  list:SetHeight(-y + 8)
  list:Show()
end

RefreshList = function()
  if not db then return end
  RefreshPanel()
  RefreshFloating()
  if QuestLedgerForever_OnMatesUpdate then pcall(QuestLedgerForever_OnMatesUpdate) end
end

RefreshAll = function()
  RefreshPins()
  RefreshList()
end

------------------------------------------------------------------------
-- Public API (used by Quest Ledger Forever)
------------------------------------------------------------------------
QuestMatesAPI = {
  -- party members (with QuestMates) who also have this quest
  FriendsOnQuest = function(qid)
    local out = {}
    if not db or not qid then return out end
    local members = GroupMembers()
    for who, fr in pairs(friends) do
      local q = members[who] and fr.quests[qid]
      if q then out[#out + 1] = { who = who, color = ColorFor(who), complete = q.complete, objs = q.objs or {} } end
    end
    table.sort(out, function(a, b) return a.who < b.who end)
    return out
  end,
  Rows = function() if db then return BuildRows() end return {}, 0 end,
  ToggleCollapsed = function(who) collapsed[who] = not collapsed[who]; RefreshList() end,
  IsCollapsed = function(who) return collapsed[who] end,
  OpenQuest = function(q, who) OpenQuest(q, who) end,
  QuestTooltip = function(owner, q, who) QuestTooltip(owner, q, who) end,
  Color = function(who) return ColorFor(who) end,
  Disc = MEDIA .. "Disc",
  Refresh = function() RefreshList() end,
}

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function PruneFriends()
  local members = GroupMembers()
  for who in pairs(friends) do if not members[who] then friends[who] = nil end end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
ev:RegisterEvent("QUEST_WATCH_UPDATE")

local lastGroupSize = 0
ev:SetScript("OnEvent", function(_, e, a1, a2, a3, a4)
  if e == "ADDON_LOADED" and a1 == ADDON then
    QuestMatesDB = QuestMatesDB or {}
    QuestMatesCharDB = QuestMatesCharDB or {}
    db, cdb = QuestMatesDB, QuestMatesCharDB
    if db.mapPins == nil then db.mapPins = true end
    if db.listShown == nil then db.listShown = true end
    if db.highlightShared == nil then db.highlightShared = true end
    if db.progressPins == nil then db.progressPins = true end
    if db.alerts == nil then db.alerts = true end
    if db.itemAlerts == nil then db.itemAlerts = true end
    if db.combatWarn == nil then db.combatWarn = true end
    if db.pointer == nil then db.pointer = true end
    if not db.stackDefaulted then db.buttonStyle = "stack"; db.stackDefaulted = true end
    db.panelStyle = db.panelStyle or "inside"
    db.trackerStyle = db.trackerStyle or "native"
    C_Timer.After(0, MakeOptions)
    db.colors = db.colors or {}
    cdb.pins = cdb.pins or {}
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
      RegisterAddonMessagePrefix(PREFIX)
    end
    PlaceList()
    if WorldMapFrame then
      MakePanel()
      WorldMapFrame:HookScript("OnShow", function() C_Timer.After(0, RefreshList) end)
      WorldMapFrame:HookScript("OnHide", function() C_Timer.After(0, RefreshList) end)
      WorldMapFrame:HookScript("OnShow", RefreshPins)
      if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", RefreshPins) end
      WorldMapFrame:HookScript("OnSizeChanged", function() C_Timer.After(0, RefreshAll) end)
      if WorldMapFrame.Maximize then hooksecurefunc(WorldMapFrame, "Maximize", function() C_Timer.After(0, RefreshAll) end) end
      if WorldMapFrame.Minimize then hooksecurefunc(WorldMapFrame, "Minimize", function() C_Timer.After(0, RefreshAll) end) end
    end
  elseif not db then
    return
  elseif e == "PLAYER_ENTERING_WORLD" then
    ScanLog()
    if Channel() then Send("H"); ScheduleBroadcast(true, 3) end
  elseif e == "GROUP_ROSTER_UPDATE" then
    PruneFriends()
    local size = GetNumGroupMembers and GetNumGroupMembers() or 0
    if size > lastGroupSize and Channel() then
      Send("H")              -- ask everyone (incl. newcomers) for their quests
      ScheduleBroadcast(true, 2)
    end
    lastGroupSize = size
    RefreshAll()
  elseif e == "QUEST_LOG_UPDATE" or (e == "UNIT_QUEST_LOG_CHANGED" and a1 == "player") then
    ScheduleBroadcast(false, 1.5)
    C_Timer.After(1.6, RefreshAll) -- shared-quest highlights follow my own log
  elseif e == "QUEST_WATCH_LIST_CHANGED" or e == "QUEST_WATCH_UPDATE" then
    ScheduleBroadcast(false, 0.5)
  elseif e == "ZONE_CHANGED_NEW_AREA" then
    ScheduleBroadcast(false, 2)
  elseif e == "CHAT_MSG_ADDON" then
    OnAddonMessage(a1, a2, a3, a4)
  end
end)

------------------------------------------------------------------------
-- Combat reminder: you pull a quest mob, a party member lacks that quest
------------------------------------------------------------------------
local scanTip
local function UnitLines(unit)
  local lines = {}
  if C_TooltipInfo and C_TooltipInfo.GetUnit then
    local data = C_TooltipInfo.GetUnit(unit)
    if data and data.lines then
      for _, l in ipairs(data.lines) do if l.leftText then lines[#lines + 1] = l.leftText end end
      return lines
    end
  end
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "QuestMatesScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
  end
  scanTip:ClearLines()
  scanTip:SetUnit(unit)
  for i = 1, scanTip:NumLines() do
    local fs = _G["QuestMatesScanTipTextLeft" .. i]
    local t = fs and fs:GetText()
    if t then lines[#lines + 1] = t end
  end
  return lines
end

local function MobQuests(unit)
  local found = {}
  if not UnitExists(unit) or UnitIsPlayer(unit) or not UnitCanAttack("player", unit) then return found end
  local name = UnitName(unit)
  local lines = UnitLines(unit)
  for qid, q in pairs(myQuests) do
    if not q.complete then
      local hit = false
      for _, l in ipairs(lines) do
        if l == q.title then hit = true break end
      end
      if not hit and name then
        for _, o in ipairs(q.objs or {}) do
          if not o.done and o.text and o.text:find(name, 1, true) then hit = true break end
        end
      end
      if hit then found[qid] = q end
    end
  end
  return found
end

local warned = {} -- [guid..qid] = true
local function CheckPull()
  if not db or db.combatWarn == false or not Channel() then return end
  local unit = "target"
  if not UnitExists(unit) or not UnitAffectingCombat(unit) then
    if UnitExists("mouseover") and UnitCanAttack("player", "mouseover") then unit = "mouseover" else return end
  end
  local guid = UnitGUID(unit) or "?"
  local members = GroupMembers()
  for qid, q in pairs(MobQuests(unit)) do
    local key = guid .. qid
    if not warned[key] then
      local missing, unknown = {}, {}
      for who in pairs(members) do
        if who ~= Short(UnitName("player")) then
          local fr = friends[who]
          if not fr or not fr.synced then unknown[#unknown + 1] = who
          elseif not fr.quests[qid] then missing[#missing + 1] = Hex(ColorFor(who)) .. who .. "|r" end
        end
      end
      if #missing > 0 then
        warned[key] = true
        local names = table.concat(missing, ", ")
        Print("|cffff5555Heads up:|r " .. names .. " " .. (#missing == 1 and "doesn't" or "don't")
          .. " have |cffffd100" .. q.title .. "|r")
        if RaidNotice_AddMessage and RaidWarningFrame then
          RaidNotice_AddMessage(RaidWarningFrame, names .. " missing: " .. q.title, ChatTypeInfo["RAID_WARNING"])
        end
        if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
      end
    end
  end
end

local combatEv = CreateFrame("Frame")
combatEv:RegisterEvent("PLAYER_REGEN_DISABLED")
combatEv:RegisterEvent("PLAYER_REGEN_ENABLED")
combatEv:SetScript("OnEvent", function(_, e)
  if e == "PLAYER_REGEN_DISABLED" then
    CheckPull()
    C_Timer.After(0.5, CheckPull) -- target often set a moment after combat starts
  else
    wipe(warned)
  end
end)

------------------------------------------------------------------------
-- Options (Esc > Options > AddOns > QuestMates)
------------------------------------------------------------------------
local optionsCategory
MakeOptions = function()
  if optionsCategory ~= nil then return end
  local p = CreateFrame("Frame")
  p.name = "QuestMates"
  local y = -16
  local function header(text)
    local h = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", 16, y); h:SetText(text); y = y - 28
  end
  local refreshers = {}
  local function check(label, get, set, tip)
    local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y); y = y - 28
    local t = cb.Text or cb.text or cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    if not (cb.Text or cb.text) then t:SetPoint("LEFT", cb, "RIGHT", 2, 0) end
    t:SetText(label)
    cb:SetScript("OnClick", function(s) set(s:GetChecked() and true or false); RefreshAll() end)
    if tip then
      cb:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show() end)
      cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    refreshers[#refreshers + 1] = function() cb:SetChecked(get()) end
  end
  local function choice(label, key, opts)
    local l = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    l:SetPoint("TOPLEFT", 20, y - 4); l:SetText(label)
    local x = 200
    for _, o in ipairs(opts) do
      local rb = CreateFrame("CheckButton", nil, p, "UIRadioButtonTemplate")
      rb:SetPoint("TOPLEFT", x, y - 2)
      local t = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      t:SetPoint("LEFT", rb, "RIGHT", 4, 0); t:SetText(o[2])
      rb:SetScript("OnClick", function() db[key] = o[1]; for _, f in ipairs(refreshers) do f() end; RefreshAll() end)
      refreshers[#refreshers + 1] = function() rb:SetChecked(db[key] == o[1]) end
      x = x + 40 + t:GetStringWidth() + 20
    end
    y = y - 30
  end

  header("Map window")
  check("Show the QuestMates button on the map", function() return db.dock ~= false end, function(v) db.dock = v end)
  choice("Button style", "buttonStyle", { { "stack", "Above the ? button" }, { "title", "Title bar" }, { "side", "Side tab (classic)" } })
  choice("Party quests show", "panelStyle", { { "inside", "Over my quest list" }, { "side", "Beside the map (classic)" } })
  y = y - 6
  header("Map")
  check("Friends' quest areas on the map", function() return db.mapPins end, function(v) db.mapPins = v end)
  check("Highlight quests we share (gold)", function() return db.highlightShared ~= false end, function(v) db.highlightShared = v end)
  check("Spots where friends made progress", function() return db.progressPins end, function(v) db.progressPins = v end)
  y = y - 6
  header("Floating tracker")
  check("Show the floating tracker when the map is closed", function() return db.listShown end, function(v) db.listShown = v end)
  choice("Tracker style", "trackerStyle", { { "native", "Like the quest tracker" }, { "box", "Box (classic)" } })
  y = y - 6
  header("Alerts")
  check("Alert when a friend picks up the same quest", function() return db.alerts end, function(v) db.alerts = v end)
  check("Chat message when a friend loots a quest item", function() return db.itemAlerts end, function(v) db.itemAlerts = v end)
  check("Warn when I pull a quest mob a friend doesn't have the quest for", function() return db.combatWarn end, function(v) db.combatWarn = v end)
  check("Arrow pointing to quests my friends track", function() return db.pointer end, function(v) db.pointer = v end)
  check("Stamp quest links in chat (done / in log)", function() return not (db.stamp and db.stamp.enabled == false) end,
    function(v) db.stamp = db.stamp or {}; db.stamp.enabled = v end)

  p:SetScript("OnShow", function() for _, f in ipairs(refreshers) do f() end end)
  if Settings and Settings.RegisterCanvasLayoutCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(p, "QuestMates")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(p); optionsCategory = p
  else
    optionsCategory = false
  end
end

local function OpenOptions()
  if not optionsCategory then Print("Options window isn't available in this client.") return end
  if Settings and Settings.OpenToCategory and type(optionsCategory) == "table" and optionsCategory.GetID then
    Settings.OpenToCategory(optionsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(optionsCategory); InterfaceOptionsFrame_OpenToCategory(optionsCategory)
  end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
SLASH_QUESTMATES1 = "/qm"
SLASH_QUESTMATES2 = "/questmates"
SlashCmdList.QUESTMATES = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "" then
    db.listShown = not db.listShown
    if db.listShown and not list:IsShown() then
      local any = false
      for who in pairs(friends) do if GroupMembers()[who] then any = true end end
      if not any then Print("No QuestMates data yet. Your group members need QuestMates installed too.") end
    end
    RefreshList()
  elseif msg == "map" then
    db.mapPins = not db.mapPins; RefreshPins()
    Print("Map markers " .. (db.mapPins and "on" or "off"))
  elseif msg == "shared" then
    db.highlightShared = not db.highlightShared; RefreshAll()
    Print("Shared quest highlight " .. (db.highlightShared and "on" or "off"))
  elseif msg == "progress" then
    db.progressPins = not db.progressPins; RefreshPins()
    Print("Progress spots " .. (db.progressPins and "on" or "off"))
  elseif msg == "alert" then
    db.alerts = not db.alerts
    Print("Same-quest alerts " .. (db.alerts and "on" or "off"))
  elseif msg == "items" then
    db.itemAlerts = not db.itemAlerts
    Print("Friend quest item messages " .. (db.itemAlerts and "on" or "off"))
  elseif msg == "pull" then
    db.combatWarn = not db.combatWarn
    Print("Missing-quest pull warning " .. (db.combatWarn and "on" or "off"))
  elseif msg == "dock" then
    db.dock = (db.dock == false); RefreshList()
    Print("Map title-bar button " .. (db.dock ~= false and "on" or "off"))
  elseif msg:match("^scale") then
    local v = tonumber(msg:match("^scale%s+([%d%.]+)"))
    if v and v >= 0.5 and v <= 2.5 then db.scale = v; RefreshList(); Print("Size set to " .. v)
    else Print("Use /qm scale 0.5 - 2.5 (now " .. (db.scale or 1.15) .. ")") end
  elseif msg == "sync" then
    if not Channel() then Print("You're not in a group.") return end
    Send("H"); ScheduleBroadcast(true, 0.5); Print("Asking your group for their quests...")
  elseif msg == "debug" then
    ScanLog()
    local nq, npoi, npin = 0, 0, 0
    for _, q in pairs(myQuests) do
      nq = nq + 1; npoi = npoi + #q.pois; npin = npin + #(q.pins or {})
    end
    Print(string.format("My quests: %d, quest-area points found: %d, progress spots: %d", nq, npoi, npin))
    Print("APIs: GetQuestsOnMap=" .. tostring(C_QuestLog and C_QuestLog.GetQuestsOnMap ~= nil)
      .. " GetNextWaypoint=" .. tostring(C_QuestLog and C_QuestLog.GetNextWaypoint ~= nil)
      .. " GetQuestObjectives=" .. tostring(C_QuestLog and C_QuestLog.GetQuestObjectives ~= nil))
    Print("Group channel: " .. tostring(Channel()))
    Print("Side panel: " .. (panel and "ready" or "not created") .. ", in quest list: " .. tostring(panel and panel.inMap))
    for who, fr in pairs(friends) do
      local c = 0; for _ in pairs(fr.quests) do c = c + 1 end
      Print(string.format("  %s: %d quests received", who, c))
    end
  elseif msg == "pointer" or msg == "arrow" then
    db.pointer = not db.pointer
    Print("Friend quest arrow " .. (db.pointer and "on" or "off"))
  elseif msg == "tracker" then
    db.listShown = not db.listShown; RefreshList()
    Print("Floating tracker " .. (db.listShown and "on" or "off"))
  elseif msg == "options" or msg == "config" or msg == "settings" then
    OpenOptions()
  elseif msg == "clear" then
    wipe(cdb.pins); ScheduleBroadcast(true, 0.5); Print("Cleared your progress spots.")
  else
    Print("/qm options - settings window | /qm tracker | /qm arrow | /qm - show/hide the floating list (or the QuestMates button in the map title bar) | /qm map | /qm shared | /qm progress | /qm alert | /qm items | /qm pull (missing-quest warning) | /qm dock (map button on/off) | /qm scale 1.3 | /qm sync | /qm clear | /qm debug")
  end
end
