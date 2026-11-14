--[[
    Session Journal window: the list of sessions on the left, the selected
    session's page on the right (item links can be hovered), and a box to
    write your own note on it.
]]

local SJ = SessionJournal
local UI = {}
SJ.UI = UI

local BLUE = "|cff99ccff"
local GOLD = "|cffffd100"
local GREY = "|cffaaaaaa"
local GREEN = "|cff33ff66"
local RED = "|cffff6666"

local LIST_ROWS = 13
local ROW_H = 30

local state = { selectedId = nil, onlyMe = true, offset = 0, scroll = 0 }
local win, list

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function ClassHex(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
end

local function Text(parent, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, label, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function Clock(t) return date("%H:%M", t) end

---------------------------------------------------------------------------
-- The page for one session
---------------------------------------------------------------------------
function UI.Page(s)
    local out = {}
    local function Add(line) out[#out + 1] = line or "" end
    local function Head(title) Add(""); Add(GOLD .. title .. "|r") end

    local live = s == SJ.Current()
    Add(BLUE .. date("%A %d %B %Y", s.start) .. "|r" .. (live and (GREEN .. "  (playing now)|r") or ""))
    local played = SJ.Duration(SJ.Played(s))
    local afk = (s.afk or 0) >= 60 and (GREY .. " (" .. SJ.Duration(s.afk) .. " away)|r") or ""
    Add(ClassHex(s.class) .. (s.name or s.char) .. "|r" .. GREY .. "  " .. Clock(s.start) .. " - " .. Clock(s.last) .. "|r  " .. played .. afk)
    if s.level2 and s.level1 and s.level2 > s.level1 then
        Add("Level " .. s.level1 .. " -> " .. GREEN .. s.level2 .. "|r")
    else
        Add(GREY .. "Level " .. (s.level1 or "?") .. "|r")
    end

    local hi = {}
    for _, l in ipairs(s.levels) do hi[#hi + 1] = { t = l.t, text = GREEN .. "Reached level " .. l.level .. "!|r" } end
    for _, d in ipairs(s.dungeons) do hi[#hi + 1] = { t = d.t, text = "Entered " .. GOLD .. d.name .. "|r" } end
    for _, d in ipairs(s.deaths) do hi[#hi + 1] = { t = d.t, text = RED .. "Died|r in " .. d.zone } end
    table.sort(hi, function(a, b) return a.t < b.t end)
    if #hi > 0 then
        Head("Big moments")
        for _, h in ipairs(hi) do Add(GREY .. Clock(h.t) .. "|r  " .. h.text) end
    end

    if #s.notes > 0 then
        Head("Notes")
        for _, n in ipairs(s.notes) do Add(GREY .. Clock(n.t) .. "|r  " .. n.text) end
    end

    if #s.zones > 0 then
        Head("Places")
        local names = {}
        for _, z in ipairs(s.zones) do names[#names + 1] = z.name end
        Add(table.concat(names, ", "))
    end

    if #s.quests > 0 then
        Head("Quests finished (" .. #s.quests .. ")")
        for _, q in ipairs(s.quests) do
            local reward = {}
            if (q.xp or 0) > 0 then reward[#reward + 1] = q.xp .. " xp" end
            if (q.money or 0) > 0 then reward[#reward + 1] = SJ.Money(q.money) end
            Add("  " .. q.title .. (#reward > 0 and (GREY .. "  (" .. table.concat(reward, ", ") .. ")|r") or ""))
        end
    end

    if s.killCount > 0 then
        Head("Monsters defeated (" .. s.killCount .. ")")
        for _, k in ipairs(SJ.TopKills(s, 8)) do Add("  " .. k.name .. GREY .. "  x" .. k.count .. "|r") end
    end

    if s.lootCount > 0 then
        Head("Loot (" .. s.lootCount .. " items)")
        if #s.loot == 0 then Add(GREY .. "  Nothing green or better this time.|r") end
        for _, l in ipairs(s.loot) do Add("  " .. l.link .. (l.count > 1 and (GREY .. " x" .. l.count .. "|r") or "")) end
    end

    if next(s.skills) then
        Head("Skills")
        local names = {}
        for name in pairs(s.skills) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do Add("  " .. name .. GREY .. " now " .. s.skills[name] .. "|r") end
    end

    local money = {}
    if s.earned > 0 then money[#money + 1] = GREEN .. "+" .. SJ.Money(s.earned) .. "|r earned" end
    if s.spent > 0 then money[#money + 1] = RED .. "-" .. SJ.Money(s.spent) .. "|r spent" end
    if #money > 0 or s.xp > 0 then
        Head("Totals")
        if s.xp > 0 then Add("  " .. s.xp .. " experience") end
        if #money > 0 then Add("  " .. table.concat(money, ",  ")) end
    end

    if #out <= 3 then Add(""); Add(GREY .. "Nothing written yet. Go on an adventure!|r") end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function Build()
    local ok, f = pcall(CreateFrame, "Frame", "SessionJournalFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", "SessionJournalFrame", UIParent, "BackdropTemplate")
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 } })
        end
    end
    win = f
    f:SetSize(720, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText(BLUE .. "Session Journal|r")
    f:Hide()
    tinsert(UISpecialFrames, "SessionJournalFrame")

    -- left: filter + session list ------------------------------------------
    f.mine = Button(f, "This character", 104, function() state.onlyMe = true; state.offset = 0; UI.Refresh() end)
    f.mine:SetPoint("TOPLEFT", 12, -30)
    f.all = Button(f, "Everyone", 80, function() state.onlyMe = false; state.offset = 0; UI.Refresh() end)
    f.all:SetPoint("LEFT", f.mine, "RIGHT", 4, 0)

    f.rows = {}
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetSize(196, ROW_H - 2)
        r:SetPoint("TOPLEFT", 12, -56 - (i - 1) * ROW_H)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints()
        r.sel:SetColorTexture(0.6, 0.8, 1, 0.18)
        r.top = Text(r, "GameFontHighlight")
        r.top:SetPoint("TOPLEFT", 6, -2)
        r.top:SetWidth(186)
        r.top:SetWordWrap(false)
        r.bottom = Text(r, "GameFontHighlightSmall")
        r.bottom:SetPoint("BOTTOMLEFT", 6, 2)
        r.bottom:SetWidth(186)
        r.bottom:SetWordWrap(false)
        r:SetScript("OnClick", function(self)
            state.selectedId = self.id
            state.scroll = 0
            UI.Refresh()
        end)
        f.rows[i] = r
    end
    f.listArea = CreateFrame("Frame", nil, f)
    f.listArea:SetPoint("TOPLEFT", 12, -56)
    f.listArea:SetSize(196, LIST_ROWS * ROW_H)
    f.listArea:SetFrameLevel(f:GetFrameLevel())
    f.listArea:EnableMouseWheel(true)
    f.listArea:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, math.min(state.offset - delta * 3, math.max(0, #list - LIST_ROWS)))
        UI.Refresh()
    end)
    for _, r in ipairs(f.rows) do
        r:EnableMouseWheel(true)
        r:SetScript("OnMouseWheel", f.listArea:GetScript("OnMouseWheel"))
    end
    f.count = Text(f, "GameFontHighlightSmall")
    f.count:SetPoint("BOTTOMLEFT", 16, 14)

    -- right: the page ------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 222, -32)
    scroll:SetSize(482, 380)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(470, 380)
    scroll:SetScrollChild(child)
    f.page = Text(child, "GameFontHighlight")
    f.page:SetPoint("TOPLEFT", 4, -4)
    f.page:SetWidth(462)
    f.page:SetJustifyV("TOP")
    f.page:SetSpacing(2)
    child:SetHyperlinksEnabled(true)
    child:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    child:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
    child:SetScript("OnHyperlinkClick", function(_, link, text)
        if IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then ChatEdit_InsertLink(text) end
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local h = f.page:GetStringHeight() or 0
        local max = math.max(0, h - 370)
        state.scroll = math.max(0, math.min(state.scroll - delta * 40, max))
        self:SetVerticalScroll(state.scroll)
    end)
    f.scroll, f.child = scroll, child

    -- bottom: note + delete -----------------------------------------------
    local note = CreateFrame("EditBox", "SessionJournalNote", f, "InputBoxTemplate")
    note:SetSize(300, 22)
    note:SetPoint("BOTTOMLEFT", 230, 12)
    note:SetAutoFocus(false)
    note:SetMaxLetters(200)
    note.hint = Text(note, "GameFontDisable")
    note.hint:SetPoint("LEFT", 4, 0)
    note.hint:SetText("Write a note on this page...")
    note:SetScript("OnTextChanged", function(self)
        if (self:GetText() or "") == "" then self.hint:Show() else self.hint:Hide() end
    end)
    local function Save()
        local s = state.selectedId and SJ.Find(state.selectedId)
        if s and SJ.AddNote(note:GetText(), s) then note:SetText("") end
        note:ClearFocus()
        UI.Refresh()
    end
    note:SetScript("OnEnterPressed", Save)
    note:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.note = note
    f.add = Button(f, "Add note", 80, Save)
    f.add:SetPoint("LEFT", note, "RIGHT", 6, 0)

    f.delete = Button(f, "Delete", 80, function(self)
        if not state.selectedId then return end
        if self.armed and GetTime() - self.armed < 4 then
            self.armed = nil
            SJ.Delete(state.selectedId)
            state.selectedId = nil
            UI.Refresh()
        else
            self.armed = GetTime()
            self:SetText("Sure?")
            C_Timer.After(4, function() self.armed = nil; self:SetText("Delete") end)
        end
    end)
    f.delete:SetPoint("BOTTOMRIGHT", -14, 12)

    f:SetScript("OnShow", function()
        state.selectedId = SJ.Current().id
        state.offset, state.scroll = 0, 0
        UI.Refresh()
    end)
end

function UI.Refresh()
    if not win or not win:IsShown() then return end
    list = SJ.List(state.onlyMe and SJ.MyKey() or nil)
    if state.selectedId and not SJ.Find(state.selectedId) then state.selectedId = nil end
    if not state.selectedId and list[1] then state.selectedId = list[1].id end

    if state.onlyMe then win.mine:Disable(); win.all:Enable() else win.mine:Enable(); win.all:Disable() end

    state.offset = math.max(0, math.min(state.offset, math.max(0, #list - LIST_ROWS)))
    for i, r in ipairs(win.rows) do
        local s = list[state.offset + i]
        if s then
            r.id = s.id
            local live = s == SJ.Current() and (GREEN .. " now|r") or ""
            r.top:SetText(date("%a %d %b  %H:%M", s.start) .. live)
            local lv = (s.level2 and s.level1 and s.level2 > s.level1) and (GREEN .. "  Lv " .. s.level2 .. "!|r") or ""
            r.bottom:SetText(ClassHex(s.class) .. (s.name or "?") .. "|r" .. GREY .. "  " .. SJ.Duration(SJ.Played(s)) .. "|r" .. lv)
            if s.id == state.selectedId then r.sel:Show() else r.sel:Hide() end
            r:Show()
        else
            r.id = nil
            r:Hide()
        end
    end
    win.count:SetText(GREY .. #list .. (#list == 1 and " session" or " sessions") .. "|r")

    local s = state.selectedId and SJ.Find(state.selectedId)
    win.page:SetText(s and UI.Page(s) or (GREY .. "No sessions yet.|r"))
    win.child:SetHeight(math.max(380, (win.page:GetStringHeight() or 0) + 10))
end

-- data changed: redraw at most once a second while the window is open
local pending = false
function UI.OnData()
    if pending or not win or not win:IsShown() then return end
    pending = true
    C_Timer.After(1, function()
        pending = false
        UI.Refresh()
    end)
end

function UI.Toggle()
    if not win then Build() end
    if win:IsShown() then win:Hide() else win:Show() end
end

function UI.IsShown() return win ~= nil and win:IsShown() end
function UI.State() return state end
function UI.Init() end
