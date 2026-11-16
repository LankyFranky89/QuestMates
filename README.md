# QuestMates

A World of Warcraft (WoW Forever) addon that shows your party's quests on the world map, each friend in their own color.

![QuestMates icon](icon.png)

## Features
- Friends' quest areas on the world map as colored dots with their initial (**?** when ready to turn in)
- Small dots where friends made quest progress
- Gold ring and gold text for quests you share
- QuestMates button in the Map & Quest Log title bar: swaps your quest list for your group's quests (collapsible per friend, hover for objectives)
- Floating tracker when the map is closed, styled like the normal quest tracker (Tracker button in the party view, or classic box style in options)
- Click a friend's quest (side panel or floating list) to read it; Shift-click to link it in chat
- Alert + sound when a friend picks up the same quest as you
- Chat message whenever a friend loots a quest item
- Arrow on screen pointing to the nearest quest a friend is tracking (in their color, with yards; click to cycle)
- Warning when you pull a named quest mob (rare, elite, boss, or a quest needing just that one) and a party member doesn't have that quest
- Quest links in chat get a stamp: green check = done, yellow **?** = in your log (formerly the QuestStamp addon)

**Everyone in the group needs QuestMates installed.**

## Install
Download the repo, put the `QuestMates` folder in `Interface\AddOns`, then `/reload`.

## Commands
| Command | What it does |
|---|---|
| `/qm` | Show/hide the floating list |
| `/qm options` | Settings window (also under Esc > Options > AddOns), incl. classic side tab / side panel style |
| `/qm arrow` | Friend quest arrow on/off |
| `/qm tracker` | Floating tracker on/off |
| `/qm map` | Map markers on/off |
| `/qm shared` | Shared-quest highlight on/off |
| `/qm progress` | Progress dots on/off |
| `/qm alert` | Same-quest alerts on/off |
| `/qm items` | Quest item messages on/off |
| `/qm pull` | Missing-quest pull warning on/off |
| `/qm dock` | Map title-bar button on/off |
| `/qm scale 1.3` | Size of the floating list |
| `/qm sync` | Ask the group to resend quests |
| `/qm clear` | Clear your progress spots |
| `/qm debug` | Diagnostics |
| `/qs` | Quest link stamp help |
| `/qs new` | Red X on quests you haven't done on/off |
| `/qs toggle` | Quest link stamps on/off |
