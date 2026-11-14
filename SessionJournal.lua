--[[
    Session Journal
    Quietly writes a diary of every play session: where you went, levels,
    quests, monsters, loot, deaths, dungeons, skills, gold and XP. Read it
    back in a window, add your own notes, and get a "last time you..." hello.

    SessionJournalDB (account-wide):
      sessions = { session, ... }  oldest first
      active[Name-Realm] = id of that character's current/last session
      nextId, settings = { welcome, max }
]]

local ADDON = ...
local SJ = {}
SessionJournal = SJ

local RESUME_WINDOW = 15 * 60   -- a relog or /reload within 15 minutes continues the same session
local TICK = 30
local MAX_LOOT, MAX_QUESTS, MAX_KILL_NAMES = 80, 150, 150
local DEFAULT_SETTINGS = { welcome = true, max = 300 }

local db, cur, myKey, myFull
local lastXP, lastXPMax, lastMoney, lastQuestTitle

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffSession Journal|r: " .. tostring(msg))
end
SJ.Print = Print

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

---------------------------------------------------------------------------
-- Turning Blizzard's chat message formats into Lua patterns
---------------------------------------------------------------------------
function SJ.ToPattern(fmt, openEnd)
    local p = fmt:gsub("%%%d%$", "%%")                         -- %1$s -> %s
    p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")           -- escape magic chars (not %)
    p = p:gsub("%%s", "(.-)"):gsub("%%d", "(%%d+)")
    if openEnd then return "^" .. p end
    return "^" .. p .. "$"
end

local LOOT_PATTERNS, KILL_PATTERN, SKILL_PATTERN = {}, nil, nil

local function BuildPatterns()
    LOOT_PATTERNS = {}
    -- multiples first so "x3" isn't swallowed into the link
    for _, g in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF_MULTIPLE",
                         "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_CREATED_SELF" }) do
        local fmt = _G[g]
        if type(fmt) == "string" then LOOT_PATTERNS[#LOOT_PATTERNS + 1] = SJ.ToPattern(fmt) end
    end
    if type(COMBATLOG_XPGAIN_FIRSTPERSON) == "string" then
        -- "%s dies, you gain %d experience." (+ optional rested text after) - only need the name
        local head = COMBATLOG_XPGAIN_FIRSTPERSON:match("^(.-%%d)") or COMBATLOG_XPGAIN_FIRSTPERSON
        KILL_PATTERN = SJ.ToPattern(head, true)
    end
    if type(SKILL_RANK_UP) == "string" then SKILL_PATTERN = SJ.ToPattern(SKILL_RANK_UP) end
end

function SJ.ParseLoot(msg)
    for _, p in ipairs(LOOT_PATTERNS) do
        local link, n = msg:match(p)
        if link then return link, tonumber(n) or 1 end
    end
end

local QUALITY_BY_HEX = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5, e6cc80 = 6 }

function SJ.LinkQuality(link)
    local q = link:match("|cnIQ(%d):")
    if q then return tonumber(q) end
    local hex = link:match("|cff(%x%x%x%x%x%x)")
    if hex and QUALITY_BY_HEX[hex:lower()] then return QUALITY_BY_HEX[hex:lower()] end
    if C_Item and C_Item.GetItemInfo then
        local _, _, quality = C_Item.GetItemInfo(link)
        if quality then return quality end
    end
    return 1
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
function SJ.Duration(sec)
    sec = math.max(0, sec or 0)
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return ("%dh %02dm"):format(h, m) end
    if m > 0 then return m .. "m" end
    return "under a minute"
end

function SJ.Money(copper)
    copper = math.abs(copper or 0)
    if GetMoneyString then return GetMoneyString(copper, true) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
    if s > 0 then return ("%ds %dc"):format(s, c) end
    return c .. "c"
end

function SJ.Played(s) return (s.last or s.start) - s.start end

-- has anything happened worth keeping?
function SJ.IsEmpty(s)
    return SJ.Played(s) < 120 and #s.quests == 0 and #s.levels == 0 and s.killCount == 0
        and s.lootCount == 0 and #s.deaths == 0 and #s.notes == 0
end

-- one-line "what happened" for chat
function SJ.Summary(s)
    local bits = {}
    if s.level2 and s.level1 and s.level2 > s.level1 then bits[#bits + 1] = "reached level " .. s.level2 end
    if #s.quests > 0 then bits[#bits + 1] = "finished " .. #s.quests .. (#s.quests == 1 and " quest" or " quests") end
    if s.killCount > 0 then bits[#bits + 1] = "defeated " .. s.killCount .. " monsters" end
    if #s.dungeons > 0 then bits[#bits + 1] = "explored " .. s.dungeons[#s.dungeons].name end
    if #s.zones > 0 then bits[#bits + 1] = "were last in " .. s.zones[#s.zones].name end
    if #bits == 0 then return "you had a quick look around" end
    if #bits == 1 then return "you " .. bits[1] end
    local last = table.remove(bits)
    return "you " .. table.concat(bits, ", ") .. " and " .. last
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
local function Find(id)
    for i = #db.sessions, 1, -1 do
        if db.sessions[i].id == id then return db.sessions[i], i end
    end
end
SJ.Find = function(id) return (Find(id)) end

function SJ.Current() return cur end
function SJ.MyKey() return myKey end
function SJ.DB() return db end

-- newest first, optionally only one character
function SJ.List(onlyKey)
    local list = {}
    for i = #db.sessions, 1, -1 do
        local s = db.sessions[i]
        if not onlyKey or s.char == onlyKey then list[#list + 1] = s end
    end
    return list
end

local function NewSession()
    local name = UnitFullName("player")
    local _, class = UnitClass("player")
    local s = {
        id = db.nextId, char = myKey, name = name, full = myFull, class = class,
        start = time(), last = time(), afk = 0,
        level1 = UnitLevel("player"), level2 = UnitLevel("player"),
        xp = 0, earned = 0, spent = 0,
        zones = {}, levels = {}, quests = {}, loot = {}, lootCount = 0,
        kills = {}, killCount = 0, deaths = {}, dungeons = {}, skills = {}, notes = {},
    }
    db.nextId = db.nextId + 1
    db.sessions[#db.sessions + 1] = s
    db.active[myKey] = s.id
    while #db.sessions > (db.settings.max or 300) do table.remove(db.sessions, 1) end
    return s
end

function SJ.Delete(id)
    local s, i = Find(id)
    if not s then return end
    table.remove(db.sessions, i)
    if s == cur then
        -- start a fresh page so recording carries on
        cur = NewSession()
    end
end

local function Previous(key, beforeId)
    for i = #db.sessions, 1, -1 do
        local s = db.sessions[i]
        if s.char == key and s.id ~= beforeId then return s end
    end
end
SJ.Previous = Previous

local function StartOrResume()
    local old = db.active[myKey] and Find(db.active[myKey])
    if old and time() - (old.last or 0) <= RESUME_WINDOW then
        cur = old
        cur.last = time()
        return false
    end
    if old and SJ.IsEmpty(old) then SJ.Delete(old.id) end
    cur = NewSession()
    return true
end

local function Refresh()
    if SJ.UI and SJ.UI.OnData then SJ.UI.OnData() end
end

local function AddUnique(list, name, extra)
    if not name or name == "" or IsSecret(name) then return end
    for _, z in ipairs(list) do if z.name == name then return end end
    local e = { name = name, t = time() }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    list[#list + 1] = e
    return e
end

local function NoteZone()
    local zone = GetRealZoneText and GetRealZoneText()
    if AddUnique(cur.zones, zone) then Refresh() end
    local inInstance, kind = IsInInstance()
    if inInstance and (kind == "party" or kind == "raid") then
        local name = GetInstanceInfo()
        if AddUnique(cur.dungeons, name, { kind = kind }) then Refresh() end
    end
end

local function ResetBaselines()
    lastXP, lastXPMax = UnitXP("player"), UnitXPMax("player")
    lastMoney = GetMoney()
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------
local H = {}

function H.PLAYER_XP_UPDATE()
    local xp, max = UnitXP("player"), UnitXPMax("player")
    if IsSecret(xp) or not lastXP then return end
    if xp >= lastXP then
        cur.xp = cur.xp + (xp - lastXP)
    elseif (lastXPMax or 0) > 0 then
        cur.xp = cur.xp + (lastXPMax - lastXP) + xp -- levelled up in between
    end
    lastXP, lastXPMax = xp, max
end

function H.PLAYER_LEVEL_UP(level)
    level = tonumber(level) or UnitLevel("player")
    cur.levels[#cur.levels + 1] = { level = level, t = time() }
    cur.level2 = level
    Refresh()
end

function H.PLAYER_MONEY()
    local m = GetMoney()
    if lastMoney then
        if m > lastMoney then cur.earned = cur.earned + (m - lastMoney)
        else cur.spent = cur.spent + (lastMoney - m) end
    end
    lastMoney = m
end

function H.QUEST_COMPLETE()
    local t = GetTitleText and GetTitleText()
    if t and not IsSecret(t) then lastQuestTitle = t end
end

function H.QUEST_TURNED_IN(questID, xp, money)
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
    title = title or lastQuestTitle or ("Quest " .. tostring(questID))
    lastQuestTitle = nil
    if #cur.quests < MAX_QUESTS then
        cur.quests[#cur.quests + 1] = { title = title, id = questID, xp = xp or 0, money = money or 0, t = time() }
    end
    Refresh()
end

function H.CHAT_MSG_LOOT(msg, ...)
    if not msg or IsSecret(msg) then return end
    -- only our own loot: the self patterns don't match other people's lines
    local link, n = SJ.ParseLoot(msg)
    if not link then return end
    cur.lootCount = cur.lootCount + n
    if SJ.LinkQuality(link) >= 2 then
        for _, l in ipairs(cur.loot) do
            if l.link == link then l.count = l.count + n; Refresh(); return end
        end
        if #cur.loot < MAX_LOOT then cur.loot[#cur.loot + 1] = { link = link, count = n, t = time() } end
    end
    Refresh()
end

function H.CHAT_MSG_COMBAT_XP_GAIN(msg)
    if not msg or IsSecret(msg) or not KILL_PATTERN then return end
    local name = msg:match(KILL_PATTERN)
    if not name then return end
    cur.killCount = cur.killCount + 1
    if cur.kills[name] or SJ.CountKeys(cur.kills) < MAX_KILL_NAMES then
        cur.kills[name] = (cur.kills[name] or 0) + 1
    end
    Refresh()
end

function H.CHAT_MSG_SKILL(msg)
    if not msg or IsSecret(msg) or not SKILL_PATTERN then return end
    local skill, rank = msg:match(SKILL_PATTERN)
    if skill then
        cur.skills[skill] = tonumber(rank)
        Refresh()
    end
end

function H.PLAYER_DEAD()
    cur.deaths[#cur.deaths + 1] = { zone = GetRealZoneText and GetRealZoneText() or "?", t = time() }
    Refresh()
end

function H.ZONE_CHANGED_NEW_AREA() NoteZone() end
function H.PLAYER_ENTERING_WORLD() NoteZone() end

function H.PLAYER_LOGOUT()
    cur.last = time()
end

function SJ.CountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- kills sorted by count
function SJ.TopKills(s, n)
    local list = {}
    for name, c in pairs(s.kills) do list[#list + 1] = { name = name, count = c } end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    while n and #list > n do table.remove(list) end
    return list
end

function SJ.AddNote(text, s)
    s = s or cur
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    s.notes[#s.notes + 1] = { text = text, t = time() }
    Refresh()
    return true
end

function SJ.Tick()
    cur.last = time()
    if UnitIsAFK and UnitIsAFK("player") then cur.afk = cur.afk + TICK end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Slash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "show" then
        SJ.UI.Toggle()
    elseif cmd == "now" then
        SJ.Tick()
        Print(SJ.Duration(SJ.Played(cur)) .. " so far: " .. SJ.Summary(cur) .. ".")
    elseif cmd == "note" then
        if SJ.AddNote(rest) then Print("Added to today's page.") else Print("Type /sj note and then what you want to remember.") end
    elseif cmd == "welcome" then
        db.settings.welcome = not db.settings.welcome
        Print("Welcome-back message " .. (db.settings.welcome and "on." or "off."))
    else
        Print("/sj - open the journal")
        Print("/sj now - how this session is going")
        Print("/sj note <text> - write something on today's page")
        Print("/sj welcome - the 'last time you...' message on/off")
    end
end

function SessionJournal_Open() SJ.UI.Toggle() end -- addon compartment

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
SJ.frame = frame

local function OnLogin()
    SessionJournalDB = SessionJournalDB or {}
    db = SessionJournalDB
    db.sessions = db.sessions or {}
    db.active = db.active or {}
    db.nextId = db.nextId or 1
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULT_SETTINGS) do if db.settings[k] == nil then db.settings[k] = v end end

    local name, realm = UnitFullName("player")
    if not realm or realm == "" then realm = GetNormalizedRealmName and GetNormalizedRealmName() or "" end
    myKey = name .. "-" .. realm
    if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
        -- WoW Forever: no realms, names are "First Surname". 1.0.0 used "First-<realm slot>";
        -- re-file those sessions under the full name.
        local first, surname = (UnitNameUnmodified or UnitName)("player")
        local full = (surname and surname ~= "") and (first .. " " .. surname) or first
        local old = myKey
        myKey = full
        for _, s in ipairs(db.sessions) do
            if s.char == old then s.char = full end
            if s.char == full then s.full = full end
        end
        if db.active[old] and not db.active[full] then db.active[full] = db.active[old] end
        db.active[old] = nil
        myFull = full
    end

    BuildPatterns()
    local isNew = StartOrResume()
    ResetBaselines()

    for ev in pairs(H) do pcall(frame.RegisterEvent, frame, ev) end
    C_Timer.NewTicker(TICK, SJ.Tick)

    SLASH_SESSIONJOURNAL1 = "/sj"
    SLASH_SESSIONJOURNAL2 = "/journal"
    SlashCmdList.SESSIONJOURNAL = Slash

    if isNew and db.settings.welcome then
        local prev = Previous(myKey, cur.id)
        if prev then
            C_Timer.After(6, function()
                Print(("Welcome back! Last time (%s, %s) %s."):format(
                    date("%a %d %b", prev.start), SJ.Duration(SJ.Played(prev)), SJ.Summary(prev)))
            end)
        end
    end
    if SJ.UI and SJ.UI.Init then SJ.UI.Init() end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        OnLogin()
    elseif cur and H[event] then
        H[event](...)
    end
end)
frame:RegisterEvent("PLAYER_LOGIN")
