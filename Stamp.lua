local function Secret(v) -- chat hidden by the game (or faked by /cc secret)
  if CopyCatFakeSecret and CopyCatFakeSecret > GetTime() then return true end
  return issecretvalue ~= nil and issecretvalue(v) == true
end
-- QuestMates: Stamp module (formerly the QuestStamp addon)
-- Marks quest links in chat: green check = done, yellow ? = in your log
local ADDON = ...
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("QuestStamp") or (IsAddOnLoaded and IsAddOnLoaded("QuestStamp")) then
  print("|cff33d9ffQuestMates:|r QuestStamp is now built in - you can disable/delete the old QuestStamp addon.")
  return
end
local ICON_DONE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
local ICON_LOG  = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t"
local ICON_NEW  = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t"

local db
local function IsDone(id)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    return C_QuestLog.IsQuestFlaggedCompleted(id)
  elseif IsQuestFlaggedCompleted then
    return IsQuestFlaggedCompleted(id)
  end
  return false
end

local function InLog(id)
  if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
    return C_QuestLog.GetLogIndexForQuestID(id) ~= nil
  end
  for i = 1, (GetNumQuestLogEntries() or 0) do
    local _, _, _, isHeader, _, _, _, qid = GetQuestLogTitle(i)
    if not isHeader and qid == id then return true end
  end
  return false
end

local function Status(id)
  id = tonumber(id)
  if not id then return end
  if IsDone(id) then return "done" end
  if InLog(id) then return "log" end
  return "new"
end

local function Tag(id)
  local s = Status(id)
  if s == "done" then return " " .. ICON_DONE
  elseif s == "log" then return " " .. ICON_LOG
  elseif s == "new" and db.showNew then return " " .. ICON_NEW end
  return ""
end

local function Filter(self, event, msg, ...)
  if Secret(msg) then return false end
  if not db or not db.enabled or type(msg) ~= "string" or not msg:find("|Hquest:") then return false end
  -- link may be wrapped in a colour code: |cff...|Hquest:..|h[Name]|h|r
  local new = msg:gsub("(|Hquest:(%d+)[^|]*|h%[.-%]|h)", function(link, id)
    return link .. Tag(id)
  end)
  return false, new, ...
end

local events = {
  "CHAT_MSG_SAY","CHAT_MSG_YELL","CHAT_MSG_EMOTE","CHAT_MSG_PARTY","CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID","CHAT_MSG_RAID_LEADER","CHAT_MSG_RAID_WARNING","CHAT_MSG_GUILD","CHAT_MSG_OFFICER",
  "CHAT_MSG_WHISPER","CHAT_MSG_WHISPER_INFORM","CHAT_MSG_CHANNEL","CHAT_MSG_INSTANCE_CHAT",
  "CHAT_MSG_INSTANCE_CHAT_LEADER","CHAT_MSG_BN_WHISPER","CHAT_MSG_BN_WHISPER_INFORM",
}
for _, e in ipairs(events) do ChatFrame_AddMessageEventFilter(e, Filter) end

-- tooltip line when the link is clicked
hooksecurefunc(ItemRefTooltip, "SetHyperlink", function(tt, link)
  if not db or not db.enabled or type(link) ~= "string" then return end
  local id = link:match("^quest:(%d+)")
  if not id then return end
  local s = Status(id)
  if s == "done" then tt:AddLine(ICON_DONE .. " You have completed this quest", 0.2, 1, 0.2)
  elseif s == "log" then tt:AddLine(ICON_LOG .. " In your quest log", 1, 0.82, 0)
  else tt:AddLine(ICON_NEW .. " Not done yet", 1, 0.3, 0.3) end
  tt:Show()
end)

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  QuestMatesDB = QuestMatesDB or {}
  QuestMatesDB.stamp = QuestMatesDB.stamp or {}
  db = QuestMatesDB.stamp
  if db.enabled == nil then db.enabled = true end
  if db.showNew == nil then db.showNew = false end
end)

SLASH_QUESTSTAMP1 = "/qs"
SLASH_QUESTSTAMP2 = "/qmstamp"
SlashCmdList.QUESTSTAMP = function(msg)
  msg = (msg or ""):lower()
  if msg == "new" then
    db.showNew = not db.showNew
    print("|cff33d9ffQuestMates|r stamps: not-done marker " .. (db.showNew and "ON" or "OFF"))
  elseif msg == "toggle" then
    db.enabled = not db.enabled
    print("|cff33d9ffQuestMates|r stamps: " .. (db.enabled and "enabled" or "disabled"))
  else
    print("|cff33d9ffQuestMates|r stamps: " .. ICON_DONE .. " done  " .. ICON_LOG .. " in log")
    print("  /qs new - toggle red X on quests you haven't done")
    print("  /qs toggle - turn the addon on/off")
  end
end
