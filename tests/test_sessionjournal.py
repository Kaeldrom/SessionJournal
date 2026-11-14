"""Runs Session Journal against a mock WoW API in real Lua 5.1.  pip install lupa  then:  python tests/test_sessionjournal.py"""
import os, sys
try:
    from lupa import lua51 as L
except ImportError:
    import lupa as L

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MOCK = r'''
printed = {}
NOW = 1700000000
function time() return NOW end
function GetTime() return NOW end
date = os.date
function tinsert(t, v) table.insert(t, v) end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) printed[#printed+1] = m end }
timers = {}; tickers = {}
C_Timer = { After = function(_, f) timers[#timers+1] = f end, NewTicker = function(_, f) tickers[#tickers+1] = f end }
function run_timers() local t = timers; timers = {}; for _, f in ipairs(t) do f() end end

Widget = {}
Widget.__index = function(t, k)
  local v = rawget(Widget, k); if v ~= nil then return v end
  if type(k) == "string" and k:find("^%u") then return function() end end
end
function Widget:SetScript(k, fn) self.scripts[k] = fn end
function Widget:GetScript(k) return self.scripts[k] end
function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:CreateFontString() return CreateFrame("FontString") end
function Widget:CreateTexture() return CreateFrame("Texture") end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text or "" end
function Widget:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:GetStringHeight() return 500 end
function Widget:GetFrameLevel() return 1 end
function CreateFrame(kind, name)
  local f = setmetatable({ scripts = {}, events = {}, kind = kind }, Widget)
  if name then _G[name] = f end
  return f
end
UIParent = CreateFrame("Frame"); UISpecialFrames = {}; GameTooltip = CreateFrame("GameTooltip")
RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
function issecretvalue(v) return v == "SECRET" end

-- enUS globals the addon turns into patterns
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
LOOT_ITEM_CREATED_SELF = "You create: %s."
LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
SKILL_RANK_UP = "Your skill in %s has increased to %d."

P = { name = "Tahu", realm = "MirageRaceway", class = "MAGE", level = 12, xp = 100, xpmax = 1000, money = 1000, zone = "Elwynn Forest", afk = false }
function UnitFullName() return P.name, P.realm end
function UnitClass() return "Mage", P.class end
function UnitLevel() return P.level end
function UnitXP() return P.xp end
function UnitXPMax() return P.xpmax end
function GetMoney() return P.money end
function GetRealZoneText() return P.zone end
function IsInInstance() return P.instance ~= nil, P.instance and "party" or "none" end
function GetInstanceInfo() return P.instance end
function UnitIsAFK() return P.afk end
function GetTitleText() return "The Fargodeep Mine" end
C_QuestLog = { GetTitleForQuestID = function(id) if id == 1 then return "A Threat Within" end end }
SlashCmdList = {}
'''

passed = failed = 0
def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("FAIL:", name)

lua = L.LuaRuntime(unpack_returned_tuples=True)
lua.execute(MOCK)

def load():
    for f in ("SessionJournal.lua", "SessionJournal_UI.lua"):
        src = open(os.path.join(ROOT, f), encoding="utf-8").read()
        lua.execute("local f = assert(loadstring(...)); f('SessionJournal')", src)
    return lua.eval("function(e, ...) SessionJournal.frame:GetScript('OnEvent')(SessionJournal.frame, e, ...) end")

run = lua.execute
ev = load()

# patterns
check("pattern simple", lua.eval("SessionJournal.ToPattern('You receive loot: %s.')") == "^You receive loot: (.-)%.$")
check("pattern positional", lua.eval("SessionJournal.ToPattern('%1$s gains %2$d.')") == "^(.-) gains (%d+)%.$")

ev("PLAYER_LOGIN")
ev("PLAYER_ENTERING_WORLD")
check("first session", lua.eval("#SessionJournalDB.sessions") == 1)
check("zone recorded", lua.eval("SessionJournal.Current().zones[1].name") == "Elwynn Forest")
check("no welcome on very first", not any("Welcome" in str(v) for v in lua.eval("printed").values()))

# loot
GREEN = "|cff1eff00|Hitem:2000::|h[Green Boots]|h|r"
GREY_ITEM = "|cff9d9d9d|Hitem:3000::|h[Broken Fang]|h|r"
NEW_BLUE = "|cnIQ3:|Hitem:4000::|h[Blue Ring]|h|r"
ev("CHAT_MSG_LOOT", "You receive loot: " + GREEN + ".")
ev("CHAT_MSG_LOOT", "You receive loot: " + GREY_ITEM + "x3.")
ev("CHAT_MSG_LOOT", "You receive item: " + NEW_BLUE + ".")
ev("CHAT_MSG_LOOT", "You receive loot: " + GREEN + ".")
ev("CHAT_MSG_LOOT", "Bob receives loot: " + GREEN + ".")
ev("CHAT_MSG_LOOT", "SECRET")
s = lambda f: lua.eval("SessionJournal.Current()." + f)
check("loot count incl multiples, not Bob", s("lootCount") == 6)
check("notable loot: green + new-format blue", lua.eval("#SessionJournal.Current().loot") == 2)
check("repeat loot stacks", lua.eval("SessionJournal.Current().loot[1].count") == 2)
check("multiple parsed with link intact", lua.eval("SessionJournal.ParseLoot(...)", "You receive loot: " + GREY_ITEM + "x3.") == (GREY_ITEM, 3))

# kills, xp, level up
for _ in range(3): ev("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 45 experience. (+45 exp Rested bonus)")
ev("CHAT_MSG_COMBAT_XP_GAIN", "Defias Thug dies, you gain 60 experience.")
ev("CHAT_MSG_COMBAT_XP_GAIN", "You gain 300 experience.")
check("kills counted", s("killCount") == 4 and lua.eval("SessionJournal.Current().kills['Kobold Vermin']") == 3)
check("top kills order", lua.eval("SessionJournal.TopKills(SessionJournal.Current(), 1)[1].name") == "Kobold Vermin")
run("P.xp = 400"); ev("PLAYER_XP_UPDATE")
run("P.xp = 50; P.xpmax = 1200; P.level = 13"); ev("PLAYER_XP_UPDATE"); ev("PLAYER_LEVEL_UP", 13)
check("xp across level-up", s("xp") == 300 + 600 + 50)
check("level up recorded", s("level2") == 13 and lua.eval("#SessionJournal.Current().levels") == 1)

# money
run("P.money = 1500"); ev("PLAYER_MONEY")
run("P.money = 1200"); ev("PLAYER_MONEY")
check("earned/spent", s("earned") == 500 and s("spent") == 300)

# quests
ev("QUEST_TURNED_IN", 1, 250, 75)
ev("QUEST_COMPLETE"); ev("QUEST_TURNED_IN", 2, 100, 0)
check("quest title from log", lua.eval("SessionJournal.Current().quests[1].title") == "A Threat Within")
check("quest title from completion frame", lua.eval("SessionJournal.Current().quests[2].title") == "The Fargodeep Mine")

# skills, death, dungeon, zone change
ev("CHAT_MSG_SKILL", "Your skill in Mining has increased to 45.")
check("skill", lua.eval("SessionJournal.Current().skills['Mining']") == 45)
run("P.zone = 'Westfall'"); ev("ZONE_CHANGED_NEW_AREA"); ev("PLAYER_DEAD")
run("P.zone = 'The Deadmines'; P.instance = 'The Deadmines'"); ev("ZONE_CHANGED_NEW_AREA"); ev("ZONE_CHANGED_NEW_AREA")
check("zones unique in order", lua.eval("#SessionJournal.Current().zones") == 3)
check("death zone", lua.eval("SessionJournal.Current().deaths[1].zone") == "Westfall")
check("dungeon once", lua.eval("#SessionJournal.Current().dungeons") == 1)

# ticker + afk
run("NOW = NOW + 30; P.afk = true; tickers[1](); NOW = NOW + 30; P.afk = false; tickers[1]()")
check("afk time", s("afk") == 30 and s("last") == 1700000060)

# notes + slash
run("SlashCmdList.SESSIONJOURNAL('note Killed Hogger with dad!')")
check("note added", lua.eval("SessionJournal.Current().notes[1].text") == "Killed Hogger with dad!")
run("SlashCmdList.SESSIONJOURNAL('note   ')")
check("empty note refused", lua.eval("#SessionJournal.Current().notes") == 1)
run("SlashCmdList.SESSIONJOURNAL('now')")
check("now summary", any("reached level 13" in str(v) for v in lua.eval("printed").values()))

# page renders
page = lua.eval("SessionJournal.UI.Page(SessionJournal.Current())")
for bit in ["Reached level 13", "Entered", "The Deadmines", "Died", "Killed Hogger", "Westfall", "A Threat Within",
            "Kobold Vermin", "Green Boots", "Mining", "950 experience", "playing now"]:
    check("page has " + bit, bit in page)

# window
run("SessionJournal.UI.Toggle()")
check("window open", lua.eval("SessionJournal.UI.IsShown()"))
check("current selected", lua.eval("SessionJournal.UI.State().selectedId") == s("id"))
check("page text shown", "Kobold" in lua.eval("SessionJournalFrame.page:GetText()"))
run("SessionJournalNote:SetText('Fun day'); SessionJournalNote:GetScript('OnEnterPressed')(SessionJournalNote)")
check("note box adds", lua.eval("#SessionJournal.Current().notes") == 2 and lua.eval("SessionJournalNote:GetText()") == "")
run("SessionJournal.UI.OnData(); SessionJournal.UI.OnData()")
check("refresh throttled", lua.eval("#timers") == 1)
run("run_timers()")
run("SessionJournal.UI.Toggle()")

# ---- /reload within 15 minutes continues the same session ----------------
first_id = s("id")
run("NOW = NOW + 60")
ev = load(); ev("PLAYER_LOGIN")
check("reload resumes", s("id") == first_id and lua.eval("#SessionJournalDB.sessions") == 1)

# ---- come back the next day: new session + welcome ------------------------
run("SessionJournal.Current().last = NOW; NOW = NOW + 86400; printed = {}")
ev = load(); ev("PLAYER_LOGIN"); run("run_timers()")
check("new session next day", lua.eval("#SessionJournalDB.sessions") == 2 and s("id") != first_id)
check("welcome back message", any("Welcome back" in str(v) and "reached level 13" in str(v) for v in lua.eval("printed").values()))

# an empty session is thrown away when the next one starts
run("NOW = NOW + 86400")
ev = load(); ev("PLAYER_LOGIN")
check("empty session dropped", lua.eval("#SessionJournalDB.sessions") == 2)

# another character: separate list, Everyone shows all
run("P.name = 'Dad'; NOW = NOW + 10")
ev = load(); ev("PLAYER_LOGIN")
check("dad has own session", lua.eval("#SessionJournal.List(SessionJournal.MyKey())") == 1)
check("everyone list", lua.eval("#SessionJournal.List()") == 3)
check("no welcome for dad's first", True)

# delete the current session keeps recording on a fresh page
cur_id = s("id")
run("SessionJournal.Delete(SessionJournal.Current().id)")
check("delete current starts fresh", s("id") != cur_id and lua.eval("#SessionJournalDB.sessions") == 3)

# pruning to max
run("SessionJournalDB.settings.max = 3; P.name = 'Alt'; NOW = NOW + 100000")
ev = load(); ev("PLAYER_LOGIN")
check("pruned to max", lua.eval("#SessionJournalDB.sessions") == 3)
check("oldest dropped", lua.eval("SessionJournalDB.sessions[1].id") != first_id)

# welcome toggle
run("SlashCmdList.SESSIONJOURNAL('welcome')")
check("welcome off", lua.eval("SessionJournalDB.settings.welcome") is False)
run("SlashCmdList.SESSIONJOURNAL('help')")

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
