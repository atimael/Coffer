local ADDON_NAME = ...

--------------------------------------------------
-- BAGKEEPER
-- Bag and bank windows, items grouped by category, in four looks: FlareUI, Forever, Modern and
-- Blizzard.
-- No scrolling and no jumping: categories flow one after another through a single grid with a small
-- name tag where each begins. The grid reserves room for the slots and the category breaks.
-- Its size follows capacity and layout settings, never what is in the bags.
-- Live item buttons are Blizzard's own ContainerFrameItemButtonTemplate under a plain holder frame
-- whose ID is the bag, as FlareUI does for its keyring section: clicking, dragging, selling, using and
-- moving items to and from the bank all run Blizzard's code.
-- The bank is remembered: away from the banker the bank window shows the last saved copy.
--------------------------------------------------

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local tinsert, sort = table.insert, table.sort

--------------------------------------------------
-- 1. LOOK
--------------------------------------------------
-- FlareUI's palette (Core.lua ns.PALETTE)
local P = {
    bronze1  = { 0.32, 0.24, 0.13 },   -- shadow: slider tracks
    bronze2  = { 0.50, 0.38, 0.21 },   -- chrome: dividers, idle controls
    bronze3  = { 0.65, 0.49, 0.27 },   -- frame: every border
    bronze4  = { 0.80, 0.60, 0.34 },   -- accent: titles, category tags
    bronze5  = { 0.85, 0.68, 0.47 },   -- light: hovered text
    goldOn   = { 1, 0.82, 0.25 },      -- switched-on states
    warmGrey = { 0.56, 0.51, 0.46 },   -- counts, inactive things
    ground   = { 0.05, 0.04, 0.03 },   -- backgrounds
    gold     = { 1, 0.82, 0 },         -- Blizzard's own title yellow
    grey     = { 0.55, 0.55, 0.55 },
}

local FLARE = "Interface\\AddOns\\FlareUI\\Media\\"
local hasFlare = false
do
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        local ok, title = pcall(C_AddOns.GetAddOnMetadata, "FlareUI", "Title")
        hasFlare = ok and title ~= nil
    end
end
local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ROCK = "Interface\\FrameGeneral\\UI-Background-Rock"
local GEAR = hasFlare and FLARE .. "Icons\\DMSettings.tga" or "Interface\\Buttons\\UI-OptionsButton"
-- FlareUI's own border art when it is installed, the tooltip border otherwise
local THICK_BORDER = hasFlare and { file = FLARE .. "Borders\\FlareUI-Thick.tga", edge = 16 }
                              or { file = TOOLTIP_BORDER, edge = 16 }
local THIN_BORDER = hasFlare and { file = FLARE .. "Borders\\FlareUI-Thin.tga", edge = 8 }
                             or { file = TOOLTIP_BORDER, edge = 12 }
-- slot rims: edge size and outset so the art's bright band lands on the slot's edge (FlareUI Bags.lua)
local SLOT_RIM = hasFlare and { file = FLARE .. "Borders\\FlareUI-Thin.tga", edge = 8, outset = 3 }
                          or { file = WHITE, edge = 1, outset = 1 }
local SLOT_FLAT = { file = WHITE, edge = 1, outset = 0 }

-- The themes. bg: rock (FlareUI's bronze-tinted rock), natural (the rock as it is), flat (a dark
-- gradient) or blizzard (Blizzard's window); slot: rim (FlareUI Thin), flat (1 px) or blizzard
-- (Blizzard's slot art and quality glow)
local THEMES = {
    { key = "flareui", label = "FlareUI",
      tip = "FlareUI's look: a bronze edge over dark rock, thin bronze rims round the slots." },
    { key = "forever", label = "Forever",
      tip = "Forever's heavy bronze frame with rivets, over natural rock." },
    { key = "modern", label = "Modern",
      tip = "Plain dark frames with a thin edge and flat slot borders." },
    { key = "blizzard", label = "Blizzard",
      tip = "The game's own window frame and item slots." },
}
local THEME = {
    flareui  = { bg = "rock", border = THICK_BORDER, borderColor = P.bronze3, slot = "rim",
                 accent = P.bronze4, sep = P.bronze3, topH = 38 },
    forever  = { bg = "natural", heavy = true, slot = "rim",
                 accent = P.bronze4, sep = P.bronze3, topH = 38 },
    modern   = { bg = "flat", border = THIN_BORDER, borderColor = P.bronze3, slot = "flat",
                 accent = P.bronze4, sep = P.bronze2, topH = 38 },
    blizzard = { bg = "blizzard", blizzard = true, slot = "blizzard",
                 accent = P.gold, sep = P.grey, topH = 54, rowY = -38 },
}
local heavyOK, blizzOK = false, false
local db

local function Theme()
    local key = db and db.theme or "flareui"
    if (key == "forever" and not heavyOK) or (key == "blizzard" and not blizzOK) or not THEME[key] then
        key = "flareui"
    end
    return THEME[key], key
end

local function RowY(t) return t.rowY or -t.topH / 2 end

local SLOT = 37          -- Blizzard's item button size; Icon Size scales the buttons from it
local PAD = 10           -- window edge to content
local MIN_COLS, MAX_COLS = 8, 24

-- The grid's measures from the Layout settings: S the icon size, G the space between slots, CG the
-- extra space between two categories in a row, L the category tag strip above each row
local function M()
    local S = db.iconSize
    local G = db.spacing
    local L = db.labelSize + 5
    return {
        S = S, G = G, CG = db.categoryGap, L = L,
        step = S + G,
        rowH = L + S + G,
        foot = S + 14,      -- footer: free-slot tiles, money
    }
end

--------------------------------------------------
-- 2. SAVED SETTINGS
-- The bag window's own settings sit at the top level (columns, point); the bank window's in
-- db.bankWindow. Saved banks: db.banks["Name-Realm"].
--------------------------------------------------
local DEFAULTS = {
    theme = "flareui",
    columns = 12,
    scale = 1,
    locked = false,
    itemLevel = true,
    rarity = true,
    emptyEach = true,       -- every empty slot in the grid; off: one tile per bag type in the footer
    -- Layout
    iconSize = 37,          -- Blizzard's own
    spacing = 4,            -- between slots
    categoryGap = 10,       -- extra space between two categories sharing a row
    labelSize = 11,         -- category name font size
    newRow = false,         -- every category starts its own row
    groupStyle = "cards",   -- how a category is set apart: cards | lines | plain
    catOff = {},            -- categories folded into Miscellaneous
    point = { "BOTTOMRIGHT", "BOTTOMRIGHT", -90, 120 },
    bankWindow = {
        columns = 14,
        point = { "TOPLEFT", "TOPLEFT", 40, -110 },
    },
    settingsPoint = { "CENTER", "CENTER", 0, 0 },
    banks = {}, seen = {},
}

local function FillDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(target[k]) ~= type(v) then
            target[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and next(v) ~= nil and k ~= "point" and k ~= "settingsPoint" then
            FillDefaults(target[k], v)
        end
    end
end

local function LoadDB()
    if type(BagkeeperDB) ~= "table" then BagkeeperDB = {} end
    FillDefaults(BagkeeperDB, DEFAULTS)
    db = BagkeeperDB
    db.columns = floor(max(MIN_COLS, min(MAX_COLS, db.columns)))
    db.iconSize = floor(max(24, min(56, db.iconSize)))
    db.scale = max(0.6, min(1.5, db.scale))
    db.spacing = floor(max(0, min(12, db.spacing)))
    db.categoryGap = floor(max(0, min(40, db.categoryGap)))
    db.labelSize = floor(max(8, min(16, db.labelSize)))
    -- the earlier shading switch: off meant plain
    if db.shade == false then db.groupStyle = "plain" end
    db.shade = nil
    db.bankWindow.columns = floor(max(MIN_COLS, min(MAX_COLS, db.bankWindow.columns)))
    db.rows, db.rowsKey, db.bankWindow.rows, db.bankWindow.rowsKey = nil, nil, nil, nil
end

local function CharacterKey()
    local name, realm = UnitName("player"), GetRealmName()
    if name and realm and realm ~= "" then return name .. "-" .. realm end
end

--------------------------------------------------
-- 3. BAGS AND CATEGORIES
--------------------------------------------------
local BAG_INDEX = Enum.BagIndex or {}
local KEYRING = BAG_INDEX.Keyring
local REAGENT = BAG_INDEX.ReagentBag
local NUM_BAGS = NUM_BAG_SLOTS or 4

local IC = Enum.ItemClass or {}
local CLASS = {
    Consumable = IC.Consumable or 0, Container = IC.Container or 1, Weapon = IC.Weapon or 2,
    Gem = IC.Gem or 3, Armor = IC.Armor or 4, Reagent = IC.Reagent or 5, Projectile = IC.Projectile or 6,
    Tradegoods = IC.Tradegoods or 7, ItemEnhancement = IC.ItemEnhancement or 8, Recipe = IC.Recipe or 9,
    Quiver = IC.Quiver or 11, Questitem = IC.Questitem or 12, Key = IC.Key or 13,
}

-- shown in this order; an empty category is left out; empty slots come last
local CATEGORIES = {
    { key = "quest",      label = "Quest" },
    { key = "equipment",  label = "Equipment" },
    { key = "consumable", label = "Consumables" },
    { key = "trade",      label = "Trade Goods" },
    { key = "recipe",     label = "Recipes" },
    { key = "container",  label = "Bags" },
    { key = "ammo",       label = "Ammo" },
    { key = "key",        label = "Keys" },
    { key = "misc",       label = "Miscellaneous" },
    { key = "junk",       label = "Junk" },
}
local CATEGORY_LABEL = { empty = "Empty" }
for _, c in ipairs(CATEGORIES) do CATEGORY_LABEL[c.key] = c.label end

local function SlotCount(bag)
    if bag == KEYRING and GetKeyRingSize then return GetKeyRingSize() or 0 end
    return C_Container.GetContainerNumSlots(bag) or 0
end

-- every bag the bag window shows: the backpack, the four bags, the crafting bag and the keyring
local function BagList()
    local list = {}
    for bag = 0, NUM_BAGS do list[#list + 1] = bag end
    if REAGENT and (REAGENT < 0 or REAGENT > NUM_BAGS) then list[#list + 1] = REAGENT end
    if KEYRING then list[#list + 1] = KEYRING end
    return list
end

-- the bank's bags: Forever's bank keeps each bank bag as a character bank tab (Syndicator's
-- Constants.lua); a client without them has the old bank and bank bags
local function BankList()
    local list = {}
    if BAG_INDEX.CharacterBankTab_1 then
        local tabs = C_Bank and C_Bank.FetchPurchasedBankTabData and Enum.BankType and Enum.BankType.Character
            and C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
        for i = 1, tabs and #tabs or 9 do
            local id = BAG_INDEX["CharacterBankTab_" .. i]
            if id and SlotCount(id) > 0 then list[#list + 1] = id end
        end
    else
        local bank = BAG_INDEX.Bank or BANK_CONTAINER or -1
        if SlotCount(bank) > 0 then list[#list + 1] = bank end
        for i = 1, (NUM_BANKBAGSLOTS or 7) do
            local id = NUM_BAGS + i
            if SlotCount(id) > 0 then list[#list + 1] = id end
        end
    end
    return list
end

-- the bags whose Blizzard windows Bagkeeper replaces
local OWN_BAGS = {}
for bag = 0, NUM_BAGS do OWN_BAGS[bag] = true end
if REAGENT then OWN_BAGS[REAGENT] = true end
if KEYRING then OWN_BAGS[KEYRING] = true end

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local GetDetailedItemLevelInfo = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo

-- an item in the grid: where it is, what it is, and the fields it sorts by
local function MakeEntry(bag, slot, info, cat)
    local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(info.itemID)
    local name = info.hyperlink and info.hyperlink:match("%[(.-)%]") or ""
    return {
        bag = bag, slot = slot, info = info, cat = cat,
        classID = classID or 99, subclassID = subclassID or 0, equipLoc = equipLoc or "",
        name = name, lname = name:lower(),
    }
end

local function EmptyEntry(bag, slot)
    return { bag = bag, slot = slot, cat = "empty", empty = true, lname = "" }
end

-- a category the settings turned off folds into Miscellaneous
local function On(key) return not db.catOff[key] end
local function Shown(cat) return (cat ~= "empty" and CATEGORY_LABEL[cat] and On(cat)) and cat or "misc" end

local function CategoryOf(bag, info, quest)
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(info.itemID)
    if bag == KEYRING or classID == CLASS.Key then return "key" end
    if classID == CLASS.Questitem or (quest and (quest.isQuestItem or quest.questID)) then return "quest" end
    if info.quality == 0 then return "junk" end
    if equipLoc == "INVTYPE_BAG" or equipLoc == "INVTYPE_QUIVER"
        or classID == CLASS.Container or classID == CLASS.Quiver then return "container" end
    if classID == CLASS.Projectile or equipLoc == "INVTYPE_AMMO" then return "ammo" end
    if classID == CLASS.Weapon or classID == CLASS.Armor
        or (equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE") then return "equipment" end
    if classID == CLASS.Consumable then return "consumable" end
    if classID == CLASS.Tradegoods or classID == CLASS.Reagent or classID == CLASS.Gem
        or classID == CLASS.ItemEnhancement then return "trade" end
    if classID == CLASS.Recipe then return "recipe" end
    return "misc"
end

-- a fixed order, so items keep their places between updates: best quality first, then kind, name,
-- bigger stacks, and the slot as the last word
local function SortItems(a, b)
    local qa, qb = a.info.quality or 1, b.info.quality or 1
    if qa ~= qb then return qa > qb end
    if a.classID ~= b.classID then return a.classID < b.classID end
    if a.subclassID ~= b.subclassID then return a.subclassID < b.subclassID end
    if a.equipLoc ~= b.equipLoc then return a.equipLoc < b.equipLoc end
    if a.name ~= b.name then return a.name < b.name end
    local ca, cb = a.info.stackCount or 1, b.info.stackCount or 1
    if ca ~= cb then return ca > cb end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
end

-- itemID -> how many, over every live item in the groups
local function TotalsOf(groups)
    local totals = {}
    for _, list in pairs(groups) do
        for _, e in ipairs(list) do
            local id = e.info.itemID
            totals[id] = (totals[id] or 0) + (e.info.stackCount or 1)
        end
    end
    return totals
end

local function NewGroups()
    local groups = {}
    for _, c in ipairs(CATEGORIES) do groups[c.key] = {} end
    return groups
end

-- Every bag's items and free space, live from the game. Returns
--   groups: category -> entries; emptyList: one entry per empty slot;
--   tiles: one per bag type (the first empty slot and how many); free; total;
--   cells: capacity, including the keyring even when it has no keys
local function CollectLive(bagList)
    local groups, emptyList, tiles, byKey = NewGroups(), {}, {}, {}
    local free, total, cells, ready = 0, 0, 0, true
    for _, bag in ipairs(bagList) do
        local slots = SlotCount(bag)
        cells = cells + slots
        local reported, family
        if slots > 0 then reported, family = C_Container.GetContainerNumFreeSlots(bag) end
        local before = free
        if slots == 0 and bag > 0 and OWN_BAGS[bag] and C_Container.ContainerIDToInventoryID and GetInventoryItemID then
            local invSlot = C_Container.ContainerIDToInventoryID(bag)
            if invSlot and GetInventoryItemID("player", invSlot) then ready = false end
        end
        if bag ~= KEYRING then total = total + slots end
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local cat = CategoryOf(bag, info, C_Container.GetContainerItemQuestInfo(bag, slot))
                local e = MakeEntry(bag, slot, info, Shown(cat))
                e.category = cat
                e.live = true
                tinsert(groups[e.cat], e)
            else
                if info or (C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot)) then ready = false end
            end
            if bag ~= KEYRING and not (info and info.itemID) then
                free = free + 1
                local e = EmptyEntry(bag, slot)
                e.live = true
                emptyList[#emptyList + 1] = e
                local key = bag == REAGENT and "reagent" or (family or 0)
                local g = byKey[key]
                if not g then
                    g = { bag = bag, slot = slot, count = 0, key = key }
                    byKey[key] = g
                    tiles[#tiles + 1] = g
                end
                g.count = g.count + 1
            end
        end
        if bag ~= KEYRING and slots > 0 and reported ~= free - before then ready = false end
    end
    -- the general bags' free space first, then special bags, the crafting bag last
    sort(tiles, function(a, b)
        local ka = a.key == "reagent" and 1e9 or a.key
        local kb = b.key == "reagent" and 1e9 or b.key
        return ka < kb
    end)
    return { groups = groups, emptyList = emptyList, tiles = tiles, free = free, total = total, cells = cells,
             live = true, ready = ready and total > 0 }
end

--------------------------------------------------
-- 4. ITEM BUTTONS
--------------------------------------------------
local function Try(obj, method, ...)
    local f = obj[method]
    if f then pcall(f, obj, ...) end
end

local function HideBlizzardNew(b)
    -- Stopping an idle animation can light its flash. Keep the textures dark even if Blizzard
    -- updates the button again after it is shown.
    if b.newitemglowAnim and b.newitemglowAnim:IsPlaying() then b.newitemglowAnim:Stop() end
    if b.flashAnim and b.flashAnim:IsPlaying() then b.flashAnim:Stop() end
    for _, key in ipairs({ "NewItemTexture", "BattlepayItemTexture", "flash" }) do
        if b[key] then b[key]:SetAlpha(0) b[key]:Hide() end
    end
end

local function FreeTip(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetText(b.bagkeeperFreeLabel)
    GameTooltip:AddLine(("%d free"):format(b.bagkeeperFreeCount), 1, 1, 1)
    if not b.bagkeeperCached then
        GameTooltip:AddLine("Drop an item here to put it in this bag.", P.warmGrey[1], P.warmGrey[2], P.warmGrey[3], true)
    end
    GameTooltip:Show()
end

local function SkinButton(b)
    if b.bagkeeperSkinned then return end
    b.bagkeeperSkinned = true
    b:SetSize(SLOT, SLOT)
    b.bagkeeperIcon = b.icon or b.Icon or (b.GetItemButtonIconTexture and b:GetItemButtonIconTexture())
    -- the slot's own ground, seen when it is empty
    b.bagkeeperBg = b:CreateTexture(nil, "BACKGROUND", nil, -2)
    b.bagkeeperBg:SetAllPoints()
    -- the rim, on an overlay so it draws over the icon
    local ov = CreateFrame("Frame", nil, b)
    ov:SetAllPoints()
    ov:SetFrameLevel(b:GetFrameLevel() + 2)
    b.bagkeeperRim = CreateFrame("Frame", nil, ov, "BackdropTemplate")
    local ilvl = ov:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    ilvl:SetPoint("BOTTOMLEFT", 3, 3)
    b.bagkeeperLevel = ilvl
    local free = ov:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    free:SetPoint("CENTER")
    free:SetTextColor(P.bronze5[1], P.bronze5[2], P.bronze5[3])
    free:Hide()
    b.bagkeeperFree = free
    -- New items: a soft pink glow that breathes, until the window closes. Pink is no item quality,
    -- quest or junk colour, so it never reads as one.
    local glow = ov:CreateTexture(nil, "OVERLAY", nil, 2)
    glow:SetPoint("TOPLEFT", -6, 6)
    glow:SetPoint("BOTTOMRIGHT", 6, -6)
    glow:SetAtlas("bags-glow-white")
    if not glow:GetAtlas() then glow:SetTexture("Interface\\Buttons\\CheckButtonHilight") end
    glow:SetVertexColor(1, 0.3, 0.75)
    glow:SetBlendMode("ADD")
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.9)
    fade:SetSmoothing("IN_OUT")
    b.bagkeeperNew, b.bagkeeperPulse = glow, pulse
    if b.UpdateNewItem then hooksecurefunc(b, "UpdateNewItem", HideBlizzardNew) end
    b:HookScript("OnShow", HideBlizzardNew)
    b:HookScript("OnHide", function(self)
        if self.bagkeeperPulse:IsPlaying() then self.bagkeeperPulse:Stop() end
        self.bagkeeperNew:Hide()
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    b:HookScript("OnEnter", function(self)
        if self.bagkeeperBankSlot then
            -- a bank bag slot with no bag in it
            if not C_Container.GetContainerItemInfo(self:GetBagID(), self:GetID()) then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Empty bank bag slot")
                GameTooltip:AddLine("Drag a bag here to use it in your bank.", 1, 1, 1, true)
                GameTooltip:Show()
            end
        elseif self.bagkeeperFreeCount and not self.bagkeeperCached then
            FreeTip(self)
        end
    end)
end

-- a slot's look for the theme: rim, flat or Blizzard's own
local function ApplySlotStyle(b, style)
    b.bagkeeperStyle = style
    local rim, icon, bg = b.bagkeeperRim, b.bagkeeperIcon, b.bagkeeperBg
    if style == "blizzard" then
        rim:Hide()
        bg:SetAtlas("bags-item-slot64")
        bg:SetVertexColor(1, 1, 1, 1)
        if icon then
            icon:ClearAllPoints()
            icon:SetAllPoints(b)
        end
        return
    end
    local def = style == "flat" and SLOT_FLAT or SLOT_RIM
    rim:ClearAllPoints()
    rim:SetPoint("TOPLEFT", -def.outset, def.outset)
    rim:SetPoint("BOTTOMRIGHT", def.outset, -def.outset)
    rim:SetBackdrop({ edgeFile = def.file, edgeSize = def.edge })
    rim:Show()
    bg:SetColorTexture(P.ground[1], P.ground[2], P.ground[3], 0.75)
    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
    end
end

local function NewLiveButton(holder, slot)
    local b = CreateFrame("ItemButton", nil, holder, "ContainerFrameItemButtonTemplate")
    b:SetID(slot)
    SkinButton(b)
    b:Hide()
    return b
end

-- a saved bank item, away from the banker: a picture with its tooltip; shift-click links it
local function NewCachedButton(parent)
    local b = CreateFrame("ItemButton", nil, parent)
    b.bagkeeperCached = true
    SkinButton(b)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
        if self.bagkeeperFreeCount then FreeTip(self) return end
        if not self.bagkeeperLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.bagkeeperLink)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        if self.bagkeeperLink and IsModifiedClick() then HandleModifiedItemClick(self.bagkeeperLink) end
    end)
    b:Hide()
    return b
end

local function Holder(list, parent, bag)
    local h = list[bag]
    if not h then
        h = CreateFrame("Frame", nil, parent)
        h:SetSize(1, 1)
        h:SetPoint("TOPLEFT")
        h:SetID(bag)
        list[bag] = h
    end
    return h
end

local function ItemLevelText(b, entry)
    local fs = b.bagkeeperLevel
    if not (db.itemLevel and GetDetailedItemLevelInfo and entry and (entry.classID == CLASS.Weapon or entry.classID == CLASS.Armor)
        and entry.info and entry.info.hyperlink) then
        fs:Hide()
        return
    end
    local ok, level = pcall(GetDetailedItemLevelInfo, entry.info.hyperlink)
    if not ok or type(level) ~= "number" or level <= 1 then fs:Hide() return end
    local r, g, bl = C_Item.GetItemQualityColor(entry.info.quality or 1)
    fs:SetText(level)
    fs:SetTextColor(r, g, bl)
    fs:Show()
end

local function Dress(b, info, entry)
    local t = Theme()
    if b.bagkeeperStyle ~= t.slot then ApplySlotStyle(b, t.slot) end
    local normal = b:GetNormalTexture()
    if t.slot == "blizzard" then
        -- Blizzard's slot frame and quality glow, as its own bags have them
        if b.IconBorder then b.IconBorder:SetAlpha(db.rarity and info and (info.quality or 0) >= 2 and 1 or 0) end
        if normal then normal:SetAlpha(1) end
        if b.bagkeeperIcon then b.bagkeeperIcon:SetTexCoord(0, 1, 0, 1) end
    else
        -- Bagkeeper's rim replaces Blizzard's quality glow and slot frame
        if b.IconBorder then b.IconBorder:SetAlpha(0) end
        if normal then normal:SetAlpha(0) end
        if b.bagkeeperIcon then b.bagkeeperIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
        local quality = info and info.quality
        local base = t.slot == "flat" and P.bronze2 or P.bronze3
        local r, g, bl, a = base[1], base[2], base[3], 1
        if db.rarity and quality and quality >= 2 then
            r, g, bl = C_Item.GetItemQualityColor(quality)
        elseif not info then
            a = 0.55   -- empty slots: a quieter rim
        end
        b.bagkeeperRim:SetBackdropBorderColor(r, g, bl, a)
    end
    ItemLevelText(b, entry)
    local isNew = entry and entry.isNew or false
    b.bagkeeperNew:SetShown(isNew)
    if isNew then
        if not b.bagkeeperPulse:IsPlaying() then b.bagkeeperPulse:Play() end
    elseif b.bagkeeperPulse:IsPlaying() then
        b.bagkeeperPulse:Stop()
    end
end

-- Both kinds of button can be filled again with an empty slot. Reset the template's state too.
local function FillItem(b, info)
    local texture = info and info.iconFileID
    if ClearItemButtonOverlay then pcall(ClearItemButtonOverlay, b) end
    Try(b, "SetHasItem", texture)
    if b.SetItemButtonTexture then b:SetItemButtonTexture(texture)
    elseif SetItemButtonTexture then SetItemButtonTexture(b, texture) end
    Try(b, "SyncAppearanceWithHasItem")
    if SetItemButtonQuality then
        pcall(SetItemButtonQuality, b, info and info.quality, info and info.hyperlink, false, info and info.isBound)
    end
    if SetItemButtonCount then pcall(SetItemButtonCount, b, info and info.stackCount) end
    if SetItemButtonDesaturated then SetItemButtonDesaturated(b, info and info.isLocked or false) end
    Try(b, "SetMatchesSearch", true)
    for _, key in ipairs({ "searchOverlay", "ItemContextOverlay", "JunkIcon", "UpgradeIcon", "IconQuestTexture", "BagIndicator" }) do
        if b[key] then b[key]:Hide() end
    end
    if not info and b.IconOverlay then b.IconOverlay:Hide() end
    if b.IconBorder and not (info and info.quality) then b.IconBorder:Hide() end
    if b.bagkeeperIcon then b.bagkeeperIcon:SetVertexColor(1, 1, 1) end
    HideBlizzardNew(b)
end

local function FillLive(b, info, entry)
    FillItem(b, info)
    if info then
        Try(b, "UpdateCooldown", info.iconFileID)
    elseif b.Cooldown then
        Try(b.Cooldown, "Clear")
        b.Cooldown:Hide()
    end
    if not (InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()) then
        Try(b, "SetReadable", info and info.isReadable or false)
    end
    if b.UpdateQuestItem then
        local q = info and C_Container.GetContainerItemQuestInfo(b:GetBagID(), b:GetID())
        Try(b, "UpdateQuestItem", q and q.isQuestItem, q and q.questID, q and q.isActive)
    end
    Dress(b, info, entry)
end

local function FillCached(b, info, entry)
    b.bagkeeperLink = info and info.hyperlink
    FillItem(b, info)
    Dress(b, info, entry)
end

--------------------------------------------------
-- 5. WINDOW SKINS
-- Every window carries all four looks and shows the chosen one, so the theme switches live.
--------------------------------------------------
local themed = {}   -- windows to restyle when the theme changes: { frame, apply }

local function BuildSkin(f)
    local s = {}
    -- FlareUI: the game's rock tile in warm dark bronze, a glow under the title, a shade toward the
    -- bottom (Settings\Panel.lua BuildWindow); Forever: the same rock as it is
    s.art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    s.art:SetTexture(ROCK, "REPEAT", "REPEAT")
    s.art:SetHorizTile(true)
    s.art:SetVertTile(true)
    s.wash = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    s.wash:SetAllPoints(s.art)
    s.glow = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    s.glow:SetPoint("TOPLEFT", s.art)
    s.glow:SetPoint("TOPRIGHT", s.art)
    s.glow:SetHeight(140)
    s.glow:SetColorTexture(1, 1, 1)
    s.glow:SetGradient("VERTICAL", CreateColor(0.55, 0.41, 0.22, 0), CreateColor(0.55, 0.41, 0.22, 0.20))
    s.shade = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    s.shade:SetPoint("BOTTOMLEFT", s.art)
    s.shade:SetPoint("BOTTOMRIGHT", s.art)
    s.shade:SetHeight(160)
    s.shade:SetColorTexture(1, 1, 1)
    s.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.45), CreateColor(0, 0, 0, 0))
    local function FitShading(_, _, height)
        local inside = max(1, (height or 0) - 6)
        s.glow:SetHeight(min(140, inside))
        s.shade:SetHeight(min(160, inside))
    end
    f:HookScript("OnSizeChanged", FitShading)
    FitShading(f, nil, f:GetHeight())
    -- Modern: FlareUI's window gradient, warm dark top to near black (Core.lua ns.WINDOW_STYLE)
    s.flat = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    s.flat:SetPoint("TOPLEFT", 2, -2)
    s.flat:SetPoint("BOTTOMRIGHT", -2, 2)
    s.flat:SetColorTexture(1, 1, 1)
    s.flat:SetGradient("VERTICAL", CreateColor(0.015, 0.015, 0.015, 0.96), CreateColor(0.085, 0.075, 0.060, 0.96))
    -- Forever: the character select's heavy bronze frame, stretched past the edges as Blizzard draws
    -- it, rivets top left and bottom right (FlareUI Settings\Panel.lua TryFrame)
    if heavyOK then
        local h = CreateFrame("Frame", nil, f)
        h:SetAllPoints()
        h:SetFrameLevel(f:GetFrameLevel() + 30)
        local edge = h:CreateTexture(nil, "BORDER")
        edge:SetAtlas("heavybronze-frame-basic")
        edge:SetPoint("TOPLEFT", -9, 15)
        edge:SetPoint("BOTTOMRIGHT", 9, -15)
        for _, c in ipairs({ { "TL", "TOPLEFT" }, { "BR", "BOTTOMRIGHT" } }) do
            local t = h:CreateTexture(nil, "ARTWORK")
            t:SetAtlas("heavybronze-horz-cornerbracket-" .. c[1], true)
            t:SetPoint(c[2], edge, c[2])
        end
        h:Hide()
        s.heavy = h
    end
    -- Blizzard: its own window, under everything else in the frame
    local ok, blizz = pcall(CreateFrame, "Frame", nil, f, "ButtonFrameTemplate")
    if ok and blizz then
        blizz:SetAllPoints()
        blizz:SetFrameLevel(f:GetFrameLevel())
        blizz:EnableMouse(false)
        if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, blizz) end
        if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, blizz) end
        if blizz.Inset then blizz.Inset:Hide() end
        if blizz.CloseButton then blizz.CloseButton:Hide() end
        blizz:Hide()
        s.blizz = blizz
        blizzOK = true
    end
    f.bagkeeperSkin = s
end

local function ApplySkin(f)
    local s, t = f.bagkeeperSkin, Theme()
    if t.border then
        f:SetBackdrop({ edgeFile = t.border.file, edgeSize = t.border.edge })
        f:SetBackdropBorderColor(t.borderColor[1], t.borderColor[2], t.borderColor[3], 1)
    else
        f:SetBackdrop(nil)
    end
    local rock = t.bg == "rock" or t.bg == "natural"
    s.art:SetShown(rock)
    s.wash:SetShown(rock)
    s.glow:SetShown(t.bg == "rock")
    s.shade:SetShown(rock)
    if rock then
        s.art:ClearAllPoints()
        -- under the heavy frame's top and bottom bars; inside the border otherwise
        local under = t.heavy and 8 or -3
        s.art:SetPoint("TOPLEFT", 3, under)
        s.art:SetPoint("BOTTOMRIGHT", -3, -under)
        local natural = t.bg == "natural"
        s.art:SetDesaturated(not natural)
        if natural then s.art:SetVertexColor(1, 1, 1) else s.art:SetVertexColor(P.bronze5[1], P.bronze5[2], P.bronze5[3]) end
        s.wash:SetColorTexture(0.05, 0.038, 0.026, natural and 0.35 or 0.55)
    end
    s.flat:SetShown(t.bg == "flat")
    if s.heavy then s.heavy:SetShown(t.heavy == true) end
    if s.blizz then s.blizz:SetShown(t.blizzard == true) end
    if t.heavy then f:SetClampRectInsets(-9, 9, 15, -15) else f:SetClampRectInsets(0, 0, 0, 0) end
end

-- the close button in each theme's spot: on the heavy frame's corner, Blizzard's own spot, or the
-- title bar's end
local function PlaceClose(close, f, t)
    close:ClearAllPoints()
    if t.blizzard then
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 0)
    elseif t.heavy then
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 7, 13)
    else
        close:SetPoint("RIGHT", f, "TOPRIGHT", -5, RowY(t))
    end
end

--------------------------------------------------
-- 6. SHARED PIECES: dividers, small buttons, the gear
--------------------------------------------------
local function Divider(parent)
    local d = parent:CreateTexture(nil, "ARTWORK")
    d:SetHeight(1)
    d:SetColorTexture(P.bronze2[1], P.bronze2[2], P.bronze2[3], 0.6)
    return d
end

local function PlaceDivider(d, parent, anchor, y)
    d:ClearAllPoints()
    d:SetPoint(anchor .. "LEFT", parent, anchor .. "LEFT", 4, y)
    d:SetPoint(anchor .. "RIGHT", parent, anchor .. "RIGHT", -4, y)
    d:SetShown(not Theme().blizzard)
end

local function ShowTip(owner, text, anchor)
    if not text then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

-- a small dark button with a thin edge; selected ones light up
local smallButtons = {}
local function PaintSmall(b, hover)
    local t = Theme()
    local edge = t.blizzard and P.grey or P.bronze2
    local text = t.accent
    if b.selected then edge, text = P.goldOn, P.goldOn
    elseif hover then edge, text = (t.blizzard and P.gold or P.bronze4), (t.blizzard and { 1, 1, 1 } or P.bronze5) end
    b:SetBackdropColor(P.ground[1], P.ground[2], P.ground[3], 0.8)
    b:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
    b.text:SetTextColor(text[1], text[2], text[3])
end

local function SmallButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 20)
    b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    b.text = fs
    b:SetScript("OnEnter", function(self)
        PaintSmall(self, true)
        ShowTip(self, self.tip, "ANCHOR_BOTTOM")
    end)
    b:SetScript("OnLeave", function(self)
        PaintSmall(self, false)
        GameTooltip:Hide()
    end)
    PaintSmall(b, false)
    smallButtons[#smallButtons + 1] = b
    return b
end

local accentTexts = {}   -- titles and section names: the theme's accent colour
local function Accent(fs)
    accentTexts[#accentTexts + 1] = fs
    local c = Theme().accent
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

local OpenSettings   -- section 10

local gears = {}
local function PaintGear(b, hover)
    local c = Theme().accent
    local lift = hover and 0.2 or 0
    b.icon:SetVertexColor(min(1, c[1] + lift), min(1, c[2] + lift), min(1, c[3] + lift))
end

local function GearButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexture(GEAR)
    b:SetScript("OnEnter", function(self)
        PaintGear(self, true)
        ShowTip(self, "Bagkeeper settings", "ANCHOR_BOTTOM")
    end)
    b:SetScript("OnLeave", function(self)
        PaintGear(self, false)
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function() OpenSettings() end)
    PaintGear(b, false)
    gears[#gears + 1] = b
    return b
end

--------------------------------------------------
-- 7. ITEM WINDOWS
-- One builder for both windows: the skin, a title bar with search and the gear, the grid and a
-- footer. Each window brings its own Collect / ButtonFor / FillButton / TileFor / UpdateFooter.
--------------------------------------------------
local View = {}
View.__index = View

local function ContentWidth(cols)
    local m = M()
    return cols * m.S + (cols - 1) * m.G
end
local function WindowWidth(cols) return PAD * 2 + ContentWidth(cols) end
-- gridH: the grid's height in pixels (rows can sit further apart when categories start new rows)
local function WindowHeight(gridH, foot)
    local m = M()
    return Theme().topH + 6 + gridH + 8 + (foot or m.foot)
end

local function SavePosition(f, cfg, key)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then cfg[key] = { point, relPoint, x, y } end
end

local function RestorePosition(f, cfg, key, fallback)
    local p = cfg[key]
    f:ClearAllPoints()
    if not (type(p[1]) == "string" and type(p[2]) == "string" and type(p[3]) == "number"
        and type(p[4]) == "number" and pcall(f.SetPoint, f, p[1], UIParent, p[2], p[3], p[4])) then
        p = CopyTable(fallback)
        cfg[key] = p
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end
end

function View:ApplyGeometry()
    if InCombatLockdown() then self.geometryPending = true return end
    self.geometryPending = nil
    self.frame:SetScale(db.scale)
    self.frame:SetWidth(WindowWidth(self.cfg.columns))
    RestorePosition(self.frame, self.cfg, "point", self.cfg == db and DEFAULTS.point or DEFAULTS.bankWindow.point)
end

-- the title bar's pieces for the theme: Blizzard's title sits centred in its title strip with the
-- search row below; the others keep everything on one row
function View:ApplyTheme()
    if InCombatLockdown() then self.themePending = true return end
    self.themePending = nil
    local t = Theme()
    local f, top = self.frame, self.top
    ApplySkin(f)
    top:SetHeight(t.topH)
    local y = RowY(t)
    PlaceClose(self.close, f, t)
    self.title:ClearAllPoints()
    self.gear:ClearAllPoints()
    if t.blizzard then
        self.title:SetPoint("TOP", f, "TOP", 0, -5)
        self.gear:SetPoint("RIGHT", f, "TOPRIGHT", -PAD - 2, y)
    elseif t.heavy then
        self.title:SetPoint("LEFT", f, "TOPLEFT", PAD + 2, y)
        self.gear:SetPoint("RIGHT", f, "TOPRIGHT", -PAD - 2, y)
    else
        self.title:SetPoint("LEFT", f, "TOPLEFT", PAD + 2, y)
        self.gear:SetPoint("RIGHT", self.close, "LEFT", -4, 0)
    end
    local lead = self.bankButton
    if lead then
        lead:ClearAllPoints()
        if t.blizzard then lead:SetPoint("LEFT", f, "TOPLEFT", PAD + 2, y)
        else lead:SetPoint("LEFT", self.title, "RIGHT", 10, 0) end
    end
    self.search:ClearAllPoints()
    if lead then
        self.search:SetPoint("LEFT", lead, "RIGHT", 14, 0)
    elseif t.blizzard then
        self.search:SetPoint("LEFT", f, "TOPLEFT", PAD + 8, y)
    else
        self.search:SetPoint("LEFT", self.title, "RIGHT", 14, 0)
    end
    self.search:SetPoint("RIGHT", self.gear, "LEFT", -8, 0)
    -- Blizzard's search box art, or a dark field with a thin bronze edge
    for _, key in ipairs({ "Left", "Right", "Middle", "Mid" }) do
        if self.search[key] then self.search[key]:SetAlpha(t.blizzard and 1 or 0) end
    end
    self.searchField:SetShown(not t.blizzard)
    PlaceDivider(self.topDivider, f, "TOP", -t.topH)
    PlaceDivider(self.footDivider, f, "BOTTOM", M().foot)
    self.grid:ClearAllPoints()
    self.grid:SetPoint("TOPLEFT", PAD, -(t.topH + 6))
end

function View:ApplySearch()
    local text = (self.search:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    for b, entry in pairs(self.shown) do
        local match = text == "" or entry.lname:find(text, 1, true)
            or CATEGORY_LABEL[entry.cat]:lower():find(text, 1, true)
        b:SetAlpha(match and 1 or 0.22)
    end
end

local TAG_FONT = (GameFontNormalSmall and GameFontNormalSmall:GetFont()) or STANDARD_TEXT_FONT

function View:Tag(i)
    local t = self.tags[i]
    if not t then
        t = self.grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetJustifyH("LEFT")
        t:SetJustifyV("MIDDLE")
        t:SetWordWrap(false)
        self.tags[i] = t
    end
    return t
end

function View:Separator(i)
    local s = self.seps[i]
    if not s then
        s = self.grid:CreateTexture(nil, "ARTWORK")
        self.seps[i] = s
    end
    return s
end

-- Cards: a dark panel with a thin edge behind one category's stretch of a row. Drawn on the grid
-- itself, so it always sits under the item buttons.
local CARD_PARTS = { "fill", "top", "bottom", "left", "right" }

function View:Card(i)
    local c = self.cards[i]
    if not c then
        local g = self.grid
        c = { fill = g:CreateTexture(nil, "BACKGROUND", nil, 1) }
        for _, k in ipairs({ "top", "bottom", "left", "right" }) do c[k] = g:CreateTexture(nil, "BORDER") end
        self.cards[i] = c
    end
    return c
end

local function ShowParts(obj, parts, shown)
    for _, k in ipairs(parts) do obj[k]:SetShown(shown) end
end

local function Rect(tex, grid, x, y, w, h, c, a)
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", grid, "TOPLEFT", x, -y)
    tex:SetSize(w, h)
    tex:SetColorTexture(c[1], c[2], c[3], a)
end

local function PlaceCard(c, grid, x, y, w, h, fill, fillA, edge, edgeA)
    Rect(c.fill, grid, x, y, w, h, fill, fillA)
    Rect(c.top, grid, x, y, w, 1, edge, edgeA)
    Rect(c.bottom, grid, x, y + h - 1, w, 1, edge, edgeA)
    Rect(c.left, grid, x, y, 1, h, edge, edgeA)
    Rect(c.right, grid, x + w - 1, y, 1, h, edge, edgeA)
    ShowParts(c, CARD_PARTS, true)
end

-- Lines: a thin rule from the category's name to the end of its stretch, with a small tick down
local RULE_PARTS = { "line", "tick" }

function View:Rule(i)
    local r = self.rules[i]
    if not r then
        r = { line = self.grid:CreateTexture(nil, "BORDER"), tick = self.grid:CreateTexture(nil, "BORDER") }
        self.rules[i] = r
    end
    return r
end

-- The baseline belongs to the last close, independent of the bank snapshot, which can change
-- while the window is still open. An incomplete read must never become the starting inventory.
function View:Track(data)
    if not data.ready then return end
    local key = CharacterKey()
    if not key then return end
    local totals = TotalsOf(data.groups)
    local seen = db.seen[key]
    self.baseline = self.baseline or (seen and seen[self.name])
        or (self.InitialBaseline and self:InitialBaseline()) or totals
    for _, list in pairs(data.groups) do
        for _, e in ipairs(list) do
            local id = e.info.itemID
            e.isNew = totals[id] > (self.baseline[id] or 0)
        end
    end
    self.lastTotals = totals
end

function View:MarkSeen(data)
    if not data.ready then return end
    self:Track(data)
    if not self.lastTotals then return end
    self.baseline = self.lastTotals
    local key = CharacterKey()
    if key then
        db.seen[key] = db.seen[key] or {}
        db.seen[key][self.name] = self.baseline
    end
end

function View:RefreshFooter(data)
    local free = self.footer.free
    free:SetText(data.total > 0 and ("%d / %d free"):format(data.free, data.total) or "")
    if data.total > 0 and data.free == 0 then free:SetTextColor(1, 0.3, 0.25)
    else free:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3]) end
    self:UpdateFooter()
end

-- Real buttons keep their bag and slot in combat. Repaint those slots as their contents change
-- and let the normal layout place the categories and the footer again after combat.
function View:RefreshInPlace(data)
    if not data.live or not self.laidOutLive then return end
    local entries = {}
    for _, list in pairs(data.groups) do
        for _, e in ipairs(list) do
            entries[e.bag] = entries[e.bag] or {}
            entries[e.bag][e.slot] = e
        end
    end
    for b, old in pairs(self.shown) do
        local e = entries[old.bag] and entries[old.bag][old.slot] or EmptyEntry(old.bag, old.slot)
        e.live = true
        self.shown[b] = e
        FillLive(b, e.info, e)
    end
    for _, b in ipairs(self.shownTiles) do
        local bag, slot = b:GetBagID(), b:GetID()
        local e = entries[bag] and entries[bag][slot]
        FillLive(b, e and e.info, e)
        b.bagkeeperFreeCount = nil
        for _, tile in ipairs(data.tiles) do
            if not e and tile.key == b.bagkeeperFamily then b.bagkeeperFreeCount = tile.count end
        end
        b.bagkeeperFree:SetText(b.bagkeeperFreeCount or "")
    end
    if self.RefreshBankSlots then self:RefreshBankSlots() end
    self:RefreshFooter(data)
    self:ApplySearch()
end

function View:Layout(warm)
    if not warm and not self.frame:IsShown() then self.dirty = true return end
    self.dirty = false
    if self.Prepare then self:Prepare() end

    local theme = Theme()
    local cols = self.cfg.columns
    local data = self:Collect()

    self:Track(data)
    if data.live and not data.ready and self.laidOutLive then
        self.dirty = true
        return
    end
    if InCombatLockdown() then
        self.dirty = true
        self:RefreshInPlace(data)
        return
    end
    if self.geometryPending then self:ApplyGeometry() end
    if self.themePending then self:ApplyTheme() end
    self.laidOutLive = data.live
    self.hasLayout = true

    for b in pairs(self.shown) do b:Hide() end
    wipe(self.shown)
    for _, b in ipairs(self.shownTiles) do b:Hide() end
    wipe(self.shownTiles)
    -- pairs, not ipairs: separators and rules exist only for some segments, so these lists have holes
    for _, t in pairs(self.tags) do t:Hide() end
    for _, s in pairs(self.seps) do s:Hide() end
    for _, c in pairs(self.cards) do ShowParts(c, CARD_PARTS, false) end
    for _, r in pairs(self.rules) do ShowParts(r, RULE_PARTS, false) end
    if self.ReleaseAll then self:ReleaseAll() end

    -- the runs, in category order; empty slots last when each is shown
    local runs = {}
    for _, c in ipairs(CATEGORIES) do
        local list = data.groups[c.key]
        if #list > 0 then
            sort(list, SortItems)
            runs[#runs + 1] = { label = c.label, list = list }
        end
    end
    if db.emptyEach and #data.emptyList > 0 then
        runs[#runs + 1] = { label = "Empty", list = data.emptyList, quiet = true }
    end

    -- where everything goes: items flow left to right; a category starts after a gap (or on its own
    -- row), and wraps to the next row when the row is full. A segment is one category's stretch of
    -- one row: it gets the tag and the shading. A segment is at least as wide as its name, so the
    -- name always sits inside its box. "Space between categories" is the gap beside a category
    -- and, when a category starts a new row, the gap above it.
    local m = M()
    local S, G, L, step = m.S, m.G, m.L, m.step
    local width = ContentWidth(cols)
    local inset = db.groupStyle == "cards" and 3 or 1
    local measure = self.measure
    measure:SetFont(TAG_FONT, db.labelSize, "")
    local function NameWidth(text)
        measure:SetText(text)
        return min(width, ceil(measure:GetStringWidth()) + inset * 2 + 2)
    end
    local places, segs, rowTop = {}, {}, { [0] = 0 }
    local x, row = 0, 0
    -- every row break gets the category gap, so categories are as far apart vertically as they
    -- are side by side (a category wrapping onto the next row ends up under another one)
    local function NextRow()
        rowTop[row + 1] = rowTop[row] + m.rowH + m.CG
        x, row = 0, row + 1
    end
    for ri, run in ipairs(runs) do
        run.full = run.label .. " |cff8f8275" .. #run.list .. "|r"
        local nameW = NameWidth(run.full)
        if x > 0 then
            -- the next category goes beside this one only if its name fits there too; empty slots
            -- always start on a row of their own, below the items
            if db.newRow or run.quiet or x + m.CG + max(S, nameW) > width + 0.5 then NextRow()
            else x = x + m.CG end
        end
        local seg
        for i, e in ipairs(run.list) do
            if x + S > width + 0.5 then
                NextRow()
                seg = nil
            end
            if not seg then
                seg = { run = run, ri = ri, row = row, x1 = x, first = i == 1 }
                seg.nameW = seg.first and nameW or NameWidth(run.label)
                segs[#segs + 1] = seg
            end
            seg.x2 = x + S
            places[#places + 1] = { e = e, x = x, row = row }
            x = x + step
        end
        -- widen a short stretch to its name; the next category starts after it
        if seg and seg.x2 - seg.x1 < seg.nameW then
            seg.x2 = min(width, seg.x1 + seg.nameW)
            x = max(x, seg.x2 + G)
        end
    end

    -- The grid's height: what this layout needs, and at least room for every slot. It only grows
    -- while the bags and the layout settings stay the same (saved), so items moving in and out
    -- never make the window jump; it fits itself again when a setting or the bag slots change.
    local usedH = #places > 0 and rowTop[row] + m.rowH - G or 0
    local gridH = max(usedH, (self.minRows or 1) * m.rowH - G, ceil(data.cells / cols) * m.rowH - G)
    local key = table.concat({ data.cells, cols, S, G, m.CG, L, db.newRow and 1 or 0, db.emptyEach and 1 or 0,
        db.groupStyle }, ":")
    if self.cfg.gridKey == key and type(self.cfg.gridH) == "number" then gridH = max(gridH, self.cfg.gridH) end
    self.cfg.gridH, self.cfg.gridKey = gridH, key
    -- The text owns the right end of the last footer row. Reserve rows for all possible tiles
    -- so a bag filling up, or the purchase button disappearing, cannot change the height.
    local footSlots = (self.maxLead or 0) + (db.emptyEach and 0 or self.maxTiles)
    local textSlots = min(cols, ceil(130 / step))
    local footRows = max(1, ceil((footSlots + textSlots) / cols))
    local foot = m.foot + (footRows - 1) * step
    local f = self.frame
    f:SetWidth(WindowWidth(cols))
    f:SetHeight(WindowHeight(gridH, foot))
    self.grid:SetSize(width, gridH)
    self.footer:SetHeight(foot)
    self.footer.top:ClearAllPoints()
    -- (clear of the corner grip)
    self.footer.top:SetPoint("RIGHT", self.footer, "BOTTOMRIGHT", -(PAD + 14), m.foot / 2 + 8)
    PlaceDivider(self.footDivider, f, "BOTTOM", foot)

    local accent, sepC = theme.accent, theme.sep
    local style = db.groupStyle
    -- cards: the same dark panel for every category (empty slots fainter), a thin edge in the
    -- theme's line colour
    local cardFill = theme.blizzard and { 0, 0, 0 } or P.ground
    for si, seg in ipairs(segs) do
        local y = rowTop[seg.row]
        local w = seg.x2 - seg.x1
        local quiet = seg.run.quiet
        -- the tag: name and count where the category begins, the name in grey where it continues
        local t = self:Tag(si)
        t:SetFont(TAG_FONT, db.labelSize, "")
        t:SetHeight(L)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", self.grid, "TOPLEFT", seg.x1 + inset, -y)
        t:SetWidth(max(8, w - inset))
        if seg.first then
            t:SetText(seg.run.full)
            local c = quiet and P.warmGrey or accent
            t:SetTextColor(c[1], c[2], c[3])
        else
            t:SetText(seg.run.label)
            t:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3])
        end
        t:Show()

        if style == "cards" then
            PlaceCard(self:Card(si), self.grid, seg.x1 - 2, y - 1, w + 4, L + S + 3,
                cardFill, quiet and 0.2 or 0.45, sepC, quiet and 0.25 or 0.6)
        elseif style == "lines" then
            -- from just past the name to the stretch's end, at the name's middle
            local textEnd = seg.x1 + inset + min(t:GetStringWidth(), w - inset) + 6
            if seg.x2 - textEnd > 4 then
                local r = self:Rule(si)
                local a = quiet and 0.35 or 0.8
                local mid = y + floor(L / 2)
                Rect(r.line, self.grid, textEnd, mid, seg.x2 - textEnd, 1, sepC, a)
                Rect(r.tick, self.grid, seg.x2 - 1, mid, 1, 5, sepC, a)
                ShowParts(r, RULE_PARTS, true)
            end
        end
        if style ~= "cards" and seg.first and seg.x1 > 0 then
            -- a line between two categories sharing a row
            local s = self:Separator(si)
            s:SetColorTexture(sepC[1], sepC[2], sepC[3], 0.85)
            s:SetSize(2, L + S)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", self.grid, "TOPLEFT", seg.x1 - (m.CG + G) / 2 - 1, -y)
            s:Show()
        end
    end

    -- the buttons, scaled to the icon size (Blizzard's art inside scales with them); a scaled
    -- button's offsets are in its own scale
    local scale = S / SLOT
    for _, p in ipairs(places) do
        local b = self:ButtonFor(p.e)
        if b then
            b:SetScale(scale)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.grid, "TOPLEFT", p.x / scale, -(rowTop[p.row] + L) / scale)
            b.bagkeeperFreeCount = nil
            b.bagkeeperFree:Hide()
            b:Show()
            self:FillButton(b, p.e.info, p.e)
            self.shown[b] = p.e
        end
    end
    self.emptyText:SetShown(self.emptyMessage ~= nil)
    if self.emptyMessage then self.emptyText:SetText(self.emptyMessage) end

    -- footer tiles: one per bag type, when empty slots aren't shown one by one
    local fi = 0
    local function PlaceFooter(b)
        b:SetScale(scale)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self.footer, "TOPLEFT", (PAD + fi % cols * step) / scale,
            -(7 + floor(fi / cols) * step) / scale)
        b:SetAlpha(1)
        b:Show()
        fi = fi + 1
    end
    -- the window's own footer pieces first (the bank's bag slots)
    if self.FooterLead then self:FooterLead(PlaceFooter) end
    if not db.emptyEach then
        for _, g in ipairs(data.tiles) do
            local b = self:TileFor(g)
            if b then
                PlaceFooter(b)
                self:FillButton(b, nil, { live = data.live })
                b.bagkeeperFamily = g.key
                b.bagkeeperFreeCount = g.count
                b.bagkeeperFreeLabel = g.key == 0 and "Free slots" or g.key == "reagent" and "Crafting bag" or "Special bag"
                b.bagkeeperFree:SetText(g.count)
                b.bagkeeperFree:Show()
                self.shownTiles[#self.shownTiles + 1] = b
            end
        end
    end
    self:RefreshFooter(data)
    self:ApplySearch()
end

function View:RequestLayout()
    if not self.frame:IsShown() then self.dirty = true return end
    if self.queued then return end
    self.queued = true
    C_Timer.After(0.05, function()
        self.queued = false
        self:Layout()
    end)
end

-- a live button's item changed in place (lock): update it
function View:RefreshSlot(bag, slot)
    if not self.frame:IsVisible() then return end
    local b = self.buttons[bag] and self.buttons[bag][slot]
    local entry = b and self.shown[b]
    if entry and entry.live then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and entry.info and info.itemID == entry.info.itemID then
            entry.info = info
            FillLive(b, info, entry)
        else
            self:RequestLayout()
        end
    end
end

function View:RefreshCooldowns()
    if not self.frame:IsVisible() then return end
    for b, entry in pairs(self.shown) do
        if entry.live and not entry.empty then Try(b, "UpdateCooldown", b.bagkeeperIcon and b.bagkeeperIcon:GetTexture()) end
    end
end

-- every slot of these bags gets its live button ahead of time, out of combat (Blizzard's template is
-- made there only), and every bag a footer tile
function View:EnsureLiveButtons(bagList)
    if InCombatLockdown() then return end
    for _, bag in ipairs(bagList) do
        local h = Holder(self.holders, self.grid, bag)
        self.buttons[bag] = self.buttons[bag] or {}
        local list = self.buttons[bag]
        for slot = 1, SlotCount(bag) do
            if not list[slot] then list[slot] = NewLiveButton(h, slot) end
        end
        if bag ~= KEYRING and not self.tiles[bag] then
            self.tiles[bag] = NewLiveButton(Holder(self.footHolders, self.footer, bag), 1)
        end
    end
end

function View:LiveButtonFor(e)
    return self.buttons[e.bag] and self.buttons[e.bag][e.slot]
end

function View:LiveTileFor(g)
    local b = self.tiles[g.bag]
    if b then b:SetID(g.slot) end
    return b
end

function View:SetOpen(open)
    if InCombatLockdown() and (self.frame:IsProtected() or (open and (not self.hasLayout
        or (self.ModeChanged and self:ModeChanged())))) then
        self.pendingOpen = open
        return
    end
    self.pendingOpen = nil
    self.frame:SetShown(open)
    if not open then self:Closed() end  -- OnHide does not fire when UIParent is already hidden
end

function View:Closed()
    if not self.active then return end
    self.active = nil
    if self.search:GetText() ~= "" then self.search:SetText("") end
    self:MarkSeen(self:Collect())
    for b in pairs(self.shown) do
        if b.bagkeeperPulse:IsPlaying() then b.bagkeeperPulse:Stop() end
        b.bagkeeperNew:Hide()
    end
    if self.OnHide then self:OnHide() end
end

function View:Toggle()
    if self.pendingOpen ~= nil then self:SetOpen(not self.pendingOpen)
    else self:SetOpen(not self.frame:IsShown()) end
end

local function CreateView(name, titleText, cfg)
    local self = setmetatable({
        name = name, cfg = cfg, shown = {}, shownTiles = {}, tags = {}, seps = {}, cards = {}, rules = {},
        holders = {}, buttons = {}, footHolders = {}, tiles = {}, dirty = true,
    }, View)

    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    self.frame = f
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:Hide()
    tinsert(UISpecialFrames, name)   -- Escape closes it
    BuildSkin(f)
    local base = f:GetFrameLevel()

    -- title bar: drag to move
    local top = CreateFrame("Frame", nil, f)
    self.top = top
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetFrameLevel(base + 10)
    top:EnableMouse(true)
    top:RegisterForDrag("LeftButton")
    top:SetScript("OnDragStart", function() if not db.locked and not InCombatLockdown() then f:StartMoving() end end)
    top:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        f:SetUserPlaced(false)
        SavePosition(f, self.cfg, "point")
    end)
    self.title = Accent(top:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    self.title:SetText(titleText)
    local close = CreateFrame("Button", nil, top, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetFrameLevel(base + 40)   -- above the heavy frame
    close:SetScript("OnClick", function() self:SetOpen(false) end)
    self.close = close
    self.gear = GearButton(top)

    local search = CreateFrame("EditBox", name .. "SearchBox", top, "SearchBoxTemplate")
    self.search = search
    search:SetHeight(20)
    search:HookScript("OnTextChanged", function() self:ApplySearch() end)
    local field = CreateFrame("Frame", nil, search, "BackdropTemplate")
    field:SetPoint("TOPLEFT", -6, 1)
    field:SetPoint("BOTTOMRIGHT", 0, -1)
    field:SetFrameLevel(max(0, search:GetFrameLevel() - 1))
    field:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    field:SetBackdropColor(P.ground[1], P.ground[2], P.ground[3], 0.8)
    field:SetBackdropBorderColor(P.bronze2[1], P.bronze2[2], P.bronze2[3], 0.9)
    self.searchField = field
    self.topDivider = Divider(f)
    self.footDivider = Divider(f)

    -- the grid
    local grid = CreateFrame("Frame", nil, f)
    self.grid = grid
    grid:SetFrameLevel(base + 4)
    grid:SetSize(ContentWidth(cfg.columns), M().rowH)
    local emptyText = grid:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("TOPLEFT", 4, -8)
    emptyText:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -4, -8)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3])
    emptyText:Hide()
    self.emptyText = emptyText
    -- measures category names before they are placed
    self.measure = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.measure:Hide()

    -- footer: free-slot tiles (real slots: drop items on them), free count, the window's own extras
    local footer = CreateFrame("Frame", nil, f)
    self.footer = footer
    footer:SetPoint("BOTTOMLEFT")
    footer:SetPoint("BOTTOMRIGHT")
    footer:SetHeight(M().foot)
    footer:SetFrameLevel(base + 10)
    footer.top = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    footer.top:SetPoint("RIGHT", -(PAD + 2), 8)
    footer.top:SetJustifyH("RIGHT")
    footer.free = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer.free:SetPoint("TOPRIGHT", footer.top, "BOTTOMRIGHT", 0, -4)
    footer.free:SetJustifyH("RIGHT")

    f:SetScript("OnShow", function()
        if not self.active and self.OnShow then self:OnShow() end
        self.active = true
        self:Layout()
    end)
    f:SetScript("OnHide", function()
        if not f:IsShown() then self:Closed() end
    end)

    -- the corner grip: drag sideways to change the column count (the height follows the items)
    local grip = CreateFrame("Button", nil, f)
    self.grip = grip
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(base + 45)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:SetText("Drag to change the number of columns")
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function(b, button)
        if button ~= "LeftButton" or InCombatLockdown() then return end
        -- pin the top-left corner so the window grows and shrinks toward the grip
        local left, top = f:GetLeft(), f:GetTop()
        if not (left and top) then return end
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        SavePosition(f, self.cfg, "point")
        local startX = GetCursorPosition() / f:GetEffectiveScale()
        local startCols = self.cfg.columns
        b:SetScript("OnUpdate", function()
            if InCombatLockdown() then return end
            local dx = GetCursorPosition() / f:GetEffectiveScale() - startX
            local cols = max(MIN_COLS, min(MAX_COLS, startCols + floor(dx / M().step + 0.5)))
            if cols ~= self.cfg.columns then
                self.cfg.columns = cols
                self:ApplyGeometry()
                self:Layout()
            end
        end)
    end)
    grip:SetScript("OnMouseUp", function(b)
        b:SetScript("OnUpdate", nil)
        SavePosition(f, self.cfg, "point")
        if self.OnColumnsChanged then self:OnColumnsChanged() end
    end)

    self:ApplyGeometry()
    f:SetHeight(WindowHeight(M().rowH - M().G))
    themed[#themed + 1] = function() self:ApplyTheme() self:RequestLayout() end
    return self
end

--------------------------------------------------
-- 8. THE BAG WINDOW
--------------------------------------------------
local bags, bank
local watched = {}

local function CloseBlizzardBags()
    if CloseBackpack then CloseBackpack() end
    for frame in pairs(watched) do
        local bag = frame:GetID()
        if frame ~= _G.ContainerFrameCombinedBags and frame:IsShown() and OWN_BAGS[bag] and CloseBag then CloseBag(bag) end
    end
end

local function BuildBagWindow()
    bags = CreateView("BagkeeperFrame", "Bags", db)
    bags.maxTiles = NUM_BAGS + 1 + (REAGENT and 1 or 0)

    function bags:Prepare() self:EnsureLiveButtons(BagList()) end
    function bags:Collect()
        local data = CollectLive(BagList())
        data.ready = self.inWorld and data.ready and SlotCount(0) > 0
        return data
    end
    bags.ButtonFor = View.LiveButtonFor
    bags.TileFor = View.LiveTileFor
    function bags:FillButton(b, info, e) FillLive(b, info, e) end
    function bags:UpdateMoney() self.footer.top:SetText(GetMoneyString(GetMoney(), true)) end
    function bags:UpdateFooter() self:UpdateMoney() end
    function bags:OnShow()
        self.closePending = nil
        PlaySound(SOUNDKIT and SOUNDKIT.IG_BACKPACK_OPEN or 862)
    end
    function bags:OnHide()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_BACKPACK_CLOSE or 863)
        if not self.followingNative then
            if InCombatLockdown() then self.closePending = true else CloseBlizzardBags() end
        end
    end

    -- the Bank button, before the search box
    local bankButton = SmallButton(bags.top, "Bank", 46)
    bankButton.tip = "Open your bank. Away from a banker it shows what was in it last time."
    bankButton:SetScript("OnClick", function() bank:Toggle() end)
    bags.bankButton = bankButton
    bags:ApplyTheme()
end

--------------------------------------------------
-- 9. THE BANK WINDOW
-- At a banker: live buttons, items move between bank and bags with a right-click or a drag, and the
-- footer holds the bank's bag slots: drag a bag in or out, or buy the next slot.
-- Blizzard's bank window stays open (Blizzard sends right-clicked bag items to the bank only while it
-- is), but always out of sight.
-- Anywhere else: the copy saved at the last visit, read-only.
--------------------------------------------------
local bankOpen = false
local parking, parked

local function ParkBankFrame()
    local f = _G.BankFrame
    if not f or parking or (InCombatLockdown() and f:IsProtected()) then return end
    parking = true
    if bankOpen then
        if not parked then
            parked = { alpha = f:GetAlpha(), clamp = f:IsClampedToScreen(), points = {} }
            for i = 1, f:GetNumPoints() do parked.points[i] = { f:GetPoint(i) } end
        end
        f:SetAlpha(0)
        f:SetClampedToScreen(false)
        f:ClearAllPoints()
        f:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", -4000, 0)
    elseif parked then
        local point, parent, rel, x = f:GetPoint(1)
        if point == "TOPRIGHT" and parent == UIParent and rel == "TOPLEFT" and x == -4000 then
            f:ClearAllPoints()
            for _, p in ipairs(parked.points) do f:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
        end
        f:SetClampedToScreen(parked.clamp)
        f:SetAlpha(parked.alpha)
        parked = nil
    end
    parking = false
end

-- The bank's bag slots (Forever: bank bags are bank tabs). Tab 1 is the bank itself; tab N (2 and up)
-- is the bag in slot N of the Characterbanktab container, holding bank bag CharacterBankTab_N. The
-- same calls Syndicator's BagCache.lua and Baganator's BankContainerTabSlots.lua use.
local TABS_BAG = BAG_INDEX.Characterbanktab
local BANK_TYPE = Enum.BankType and Enum.BankType.Character

local function BankBagSlotsSupported()
    return TABS_BAG and BANK_TYPE and C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchMaxNumBankTabs
        and C_Bank.ShouldUsePlayerBagsInBank and C_Bank.ShouldUsePlayerBagsInBank() or false
end

local bankHooked = false
local function HookBankFrame()
    local f = _G.BankFrame
    if bankHooked or not f then return end
    bankHooked = true
    -- Let Blizzard finish all its anchors before moving the open frame.
    local queued = false
    local function AfterPlacement()
        if parking or queued or not bankOpen then return end
        queued = true
        C_Timer.After(0, function()
            queued = false
            if bankOpen then ParkBankFrame() end
        end)
    end
    hooksecurefunc(f, "SetPoint", AfterPlacement)
    f:HookScript("OnShow", AfterPlacement)
end

local function ReadBank()
    local data = CollectLive(BankList())
    if BAG_INDEX.CharacterBankTab_1 and SlotCount(BAG_INDEX.CharacterBankTab_1) == 0 then data.ready = false end
    if BankBagSlotsSupported() then
        local tabs = C_Bank.FetchPurchasedBankTabData(BANK_TYPE)
        if not tabs or not tabs[1] then data.ready = false end
        for i = 2, #(tabs or {}) do
            local id = BAG_INDEX["CharacterBankTab_" .. i]
            if id and SlotCount(id) == 0 and C_Container.GetContainerItemInfo(TABS_BAG, i) then data.ready = false end
        end
    end
    local key = CharacterKey()
    if not (key and data.ready) then return data end
    -- Compare against the last visit before replacing that snapshot, including on the first
    -- update after login. Bank data can already be inaccessible at BANKFRAME_CLOSED.
    if not bank.baseline then bank:Track(data) end
    local items = {}
    for _, list in pairs(data.groups) do
        for _, e in ipairs(list) do
            local info = e.info
            items[#items + 1] = {
                bag = e.bag, slot = e.slot, cat = e.category, itemID = info.itemID,
                link = info.hyperlink, icon = info.iconFileID, quality = info.quality,
                count = info.stackCount, bound = info.isBound,
            }
        end
    end
    db.banks[key] = { time = time(), free = data.free, total = data.total, items = items, tiles = data.tiles }
    return data
end

local function Ago(t)
    local s = max(0, time() - (t or 0))
    if s < 3600 then return ("%d min ago"):format(max(1, floor(s / 60))) end
    if s < 48 * 3600 then return ("%d h ago"):format(floor(s / 3600)) end
    return ("%d days ago"):format(floor(s / 86400))
end

local function BuildBankWindow()
    bank = CreateView("BagkeeperBankFrame", "Bank", db.bankWindow)
    bank.pool, bank.poolUsed = {}, 0
    bank.maxLead, bank.maxTiles = 8, 9
    function bank:ModeChanged() return (self.laidOutLive == true) ~= bankOpen end

    function bank:Prepare()
        if bankOpen then self:EnsureLiveButtons(BankList()) end
    end

    function bank:Collect()
        self.emptyMessage, self.minRows = nil, nil
        if bankOpen then
            local live = ReadBank()
            if live.ready then return live end
        end
        local data = { groups = NewGroups(), emptyList = {}, tiles = {}, free = 0, total = 0, cells = 0 }
        local saved = db.banks[CharacterKey()]
        if type(saved) ~= "table" or (not saved.items and not saved.total) then
            self.emptyMessage = bankOpen and "Waiting for bank data."
                or "Bagkeeper hasn't seen your bank yet. Visit a banker once and it will remember what's inside."
            self.minRows = 2
            return data
        end
        local occupied = 0
        for i, s in ipairs(saved.items or {}) do
            if s.itemID then
                local info = { itemID = s.itemID, hyperlink = s.link, iconFileID = s.icon, quality = s.quality,
                               stackCount = s.count, isBound = s.bound }
                if not info.hyperlink and C_Item.GetItemInfo then
                    local _, link, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(s.itemID)
                    info.hyperlink, info.quality, info.iconFileID = link, info.quality or quality, info.iconFileID or icon
                end
                local cat = s.cat
                -- Older copies stored the displayed category, which could depend on the toggles.
                if not saved.tiles and cat ~= "quest" then cat = CategoryOf(s.bag, info) end
                local e = MakeEntry(s.bag or 0, s.slot or i, info, Shown(cat))
                tinsert(data.groups[e.cat], e)
                occupied = occupied + 1
            end
        end
        data.free = saved.free or max(0, (saved.total or 0) - occupied)
        data.total = max(saved.total or 0, occupied + data.free)
        for i = 1, data.free do data.emptyList[i] = EmptyEntry(0, i) end
        data.cells = data.total
        data.ready = data.total > 0 and data.total == occupied + data.free
        -- Older copies have only the total free count; the next visit records the bag types.
        data.tiles = saved.tiles or (data.free > 0 and { { key = 0, count = data.free } } or {})
        return data
    end

    function bank:ReleaseAll() self.poolUsed = 0 end

    -- new in the bank = more than the saved copy from the last visit had
    function bank:InitialBaseline()
        local saved = db.banks[CharacterKey()]
        if type(saved) ~= "table" or not saved.items or (saved.total or 0) == 0 then return nil end
        local totals = {}
        for _, s in ipairs(saved.items) do
            if s.itemID then totals[s.itemID] = (totals[s.itemID] or 0) + (s.count or 1) end
        end
        return totals
    end

    function bank:ButtonFor(e)
        if e.live then return self:LiveButtonFor(e) end
        self.poolUsed = self.poolUsed + 1
        local b = self.pool[self.poolUsed]
        if not b then
            b = NewCachedButton(self.grid)
            self.pool[self.poolUsed] = b
        end
        return b
    end

    function bank:FillButton(b, info, e)
        if e.live then FillLive(b, info, e) else FillCached(b, info, e) end
    end

    function bank:TileFor(g)
        if self.laidOutLive then return self:LiveTileFor(g) end
        return self:ButtonFor(g)
    end

    function bank:UpdateFooter()
        local footer = self.footer
        self.title:SetText(self.laidOutLive and "Bank" or "Bank |cff8f8275(saved)|r")
        if self.laidOutLive then
            local c = Theme().accent
            footer.top:SetText("At the banker")
            footer.top:SetTextColor(c[1], c[2], c[3])
        else
            local saved = db.banks[CharacterKey()]
            footer.top:SetText(type(saved) == "table" and ("Saved " .. Ago(saved.time)) or "Not saved yet")
            footer.top:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3])
        end
    end

    -- the bag slots at the footer's left, before any free-slot tiles
    local slotHolder = CreateFrame("Frame", nil, bank.footer)
    slotHolder:SetSize(1, 1)
    slotHolder:SetPoint("LEFT")
    if TABS_BAG then slotHolder:SetID(TABS_BAG) end
    local slotButtons, buyButton = {}, nil

    local function BuyButton()
        if buyButton or InCombatLockdown() then return buyButton end
        -- Blizzard's own purchase script (a secure template): it asks to confirm and pays
        local ok, b = pcall(CreateFrame, "ItemButton", nil, slotHolder, "BankPanelPurchaseButtonScriptTemplate")
        if not ok or not b then return nil end
        SkinButton(b)
        b:SetAttribute("overrideBankType", BANK_TYPE)
        if SetItemButtonTexture then pcall(SetItemButtonTexture, b, "Interface\\Icons\\INV_Misc_Bag_10") end
        if b.bagkeeperIcon then
            b.bagkeeperIcon:SetDesaturated(true)
            b.bagkeeperIcon:SetAlpha(0.45)
        end
        b.bagkeeperFree:SetText("+")
        b.bagkeeperFree:SetTextColor(P.goldOn[1], P.goldOn[2], P.goldOn[3])
        b.bagkeeperFree:Show()
        b:HookScript("OnClick", function() PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 857) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(BankBagSlotsSupported() and "Buy a bank bag slot" or "Buy a bank tab")
            local next = C_Bank.FetchNextPurchasableBankTabData and C_Bank.FetchNextPurchasableBankTabData(BANK_TYPE)
            local cost = next and next.tabCost
            if type(cost) == "number" then
                local money = GetMoneyString(cost, true)
                if cost > GetMoney() then GameTooltip:AddLine("Cost: |cffff4040" .. money .. "|r", 1, 1, 1)
                else GameTooltip:AddLine("Cost: " .. money, 1, 1, 1) end
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:Hide()
        buyButton = b
        return b
    end

    local function FillBankSlot(b, index)
        local info = C_Container.GetContainerItemInfo(TABS_BAG, index)
        FillLive(b, info, nil)
        local tabBag = BAG_INDEX["CharacterBankTab_" .. index]
        if b.Count then
            local freeN = info and tabBag and C_Container.GetContainerNumFreeSlots(tabBag)
            b.Count:SetText(freeN or "")
            b.Count:SetShown(freeN ~= nil)
        end
    end

    function bank:RefreshBankSlots()
        for index, b in pairs(slotButtons) do if b:IsShown() then FillBankSlot(b, index) end end
    end

    function bank:RefreshCost()
        if buyButton and buyButton:IsVisible() and GameTooltip:IsOwned(buyButton) then
            buyButton:GetScript("OnEnter")(buyButton)
        end
    end

    function bank:FooterLead(place)
        for _, b in pairs(slotButtons) do b:Hide() end
        if buyButton then buyButton:Hide() end
        if not (self.laidOutLive and BANK_TYPE and C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchMaxNumBankTabs) then return end
        local tabs = C_Bank.FetchPurchasedBankTabData(BANK_TYPE)
        if not tabs then return end
        local purchased = #tabs
        local maxTabs = C_Bank.FetchMaxNumBankTabs(BANK_TYPE) or 0
        for index = 2, BankBagSlotsSupported() and purchased or 1 do
            local b = slotButtons[index]
            if not b and not InCombatLockdown() then
                b = NewLiveButton(slotHolder, index)
                b.bagkeeperBankSlot = index
                slotButtons[index] = b
            end
            if b then
                place(b)
                FillBankSlot(b, index)
            end
        end
        if purchased < maxTabs and (not C_Bank.FetchNextPurchasableBankTabData or C_Bank.FetchNextPurchasableBankTabData(BANK_TYPE)) then
            local b = BuyButton()
            if b then
                place(b)
                Dress(b, nil, nil)
                b.bagkeeperFree:SetText("+")
                b.bagkeeperFree:Show()
            end
        end
    end

    function bank:OnShow()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
    end

    function bank:OnHide()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
        -- closing the window ends the visit, as Blizzard's does
        if bankOpen then
            if C_Bank and C_Bank.CloseBankFrame then C_Bank.CloseBankFrame()
            elseif CloseBankFrame then CloseBankFrame() end
        end
    end

    bank:ApplyTheme()
end

--------------------------------------------------
-- 10. SETTINGS
-- A window in the chosen theme: the gear in either window, /bagkeeper config, the addon compartment, or
-- Options > AddOns > Bagkeeper. Every change applies at once.
--------------------------------------------------
local settings

local function BothViews(method, ...)
    bags[method](bags, ...)
    bank[method](bank, ...)
end

local function Relayout() BothViews("RequestLayout") end

local function ApplyAllThemes()
    for _, apply in ipairs(themed) do apply() end
    local c = Theme().accent
    for _, fs in ipairs(accentTexts) do fs:SetTextColor(c[1], c[2], c[3]) end
    for _, b in ipairs(smallButtons) do PaintSmall(b, false) end
    for _, g in ipairs(gears) do PaintGear(g, false) end
end

local function SectionTitle(parent, text, y)
    local fs = Accent(parent:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    line:SetColorTexture(1, 1, 1)
    line:SetGradient("HORIZONTAL", CreateColor(P.bronze2[1], P.bronze2[2], P.bronze2[3], 0.9),
                                   CreateColor(P.bronze2[1], P.bronze2[2], P.bronze2[3], 0))
    return fs
end

-- a bronze box that fills gold when on, its label clickable too
local function Checkbox(parent, label, tip, get, set)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(20)
    local box = CreateFrame("Frame", nil, b, "BackdropTemplate")
    box:SetSize(16, 16)
    box:SetPoint("LEFT")
    box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    box:SetBackdropColor(P.ground[1], P.ground[2], P.ground[3], 0.9)
    box:SetBackdropBorderColor(P.bronze3[1], P.bronze3[2], P.bronze3[3], 1)
    local fill = box:CreateTexture(nil, "OVERLAY")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(P.goldOn[1], P.goldOn[2], P.goldOn[3], 1)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
    fs:SetText(label)
    b:SetWidth(24 + fs:GetStringWidth() + 4)
    function b:Refresh() fill:SetShown(get() and true or false) end
    b:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
        PlaySound(SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON or 1115)
    end)
    b:SetScript("OnEnter", function(self)
        box:SetBackdropBorderColor(P.bronze5[1], P.bronze5[2], P.bronze5[3], 1)
        ShowTip(self, tip)
    end)
    b:SetScript("OnLeave", function()
        box:SetBackdropBorderColor(P.bronze3[1], P.bronze3[2], P.bronze3[3], 1)
        GameTooltip:Hide()
    end)
    b:Refresh()
    return b
end

-- a thin bronze track with a value; changes apply as you drag
local function Slider(parent, label, minV, maxV, stepV, fmt, get, set)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(220, 36)
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT")
    fs:SetText(label)
    local value = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    value:SetPoint("TOPRIGHT")
    value:SetTextColor(P.goldOn[1], P.goldOn[2], P.goldOn[3])
    local s = CreateFrame("Slider", nil, holder)
    s:SetOrientation("HORIZONTAL")
    s:SetHeight(14)
    s:SetPoint("BOTTOMLEFT")
    s:SetPoint("BOTTOMRIGHT")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(stepV)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetColorTexture(P.bronze1[1], P.bronze1[2], P.bronze1[3], 0.9)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 14)
    thumb:SetColorTexture(P.bronze4[1], P.bronze4[2], P.bronze4[3], 1)
    s:SetThumbTexture(thumb)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta) self:SetValue(self:GetValue() + delta * stepV) end)
    local ready = false
    s:SetScript("OnValueChanged", function(_, v)
        v = floor(v / stepV + 0.5) * stepV
        value:SetText(fmt:format(v))
        if ready and v ~= get() then set(v) end
    end)
    function holder:Refresh()
        ready = false
        s:SetValue(get())
        value:SetText(fmt:format(get()))
        ready = true
    end
    holder:Refresh()
    return holder
end

local function SetColumns(view, v)
    view.cfg.columns = v
    view:RequestLayout()
end

-- the corner grip changed the columns: the open settings window shows the new count
function View:OnColumnsChanged()
    if settings and settings:IsShown() then settings:GetScript("OnShow")(settings) end
end

local function BuildSettings()
    local f = CreateFrame("Frame", "BagkeeperSettings", UIParent, "BackdropTemplate")
    settings = f
    f:SetSize(500, 640)
    RestorePosition(f, db, "settingsPoint", DEFAULTS.settingsPoint)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false)
        SavePosition(self, db, "settingsPoint")
    end)
    f:Hide()
    tinsert(UISpecialFrames, "BagkeeperSettings")
    BuildSkin(f)
    local base = f:GetFrameLevel()

    -- everything sits on a layer above the skin
    local body = CreateFrame("Frame", nil, f)
    body:SetAllPoints()
    body:SetFrameLevel(base + 5)

    local title = Accent(body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    title:SetText("Bagkeeper Settings")
    local close = CreateFrame("Button", nil, body, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetFrameLevel(base + 40)
    close:SetScript("OnClick", function() f:Hide() end)
    local divider = Divider(f)

    local controls = {}
    local function Add(c) controls[#controls + 1] = c return c end

    -- Theme
    SectionTitle(body, "Theme", -60)
    local themeButtons = {}
    local function PaintThemeButtons()
        local _, current = Theme()
        for _, b in ipairs(themeButtons) do
            b.selected = b.key == current
            PaintSmall(b, false)
        end
    end
    for i, th in ipairs(THEMES) do
        local b = SmallButton(body, th.label, 106)
        b:SetPoint("TOPLEFT", 20 + (i - 1) * 116, -84)
        b.key = th.key
        b.tip = th.tip
        if (th.key == "forever" and not heavyOK) or (th.key == "blizzard" and not blizzOK) then
            b.tip = th.tip .. "\n\n|cffff6060Not available on this client.|r"
        end
        b:SetScript("OnClick", function(self)
            if (self.key == "forever" and not heavyOK) or (self.key == "blizzard" and not blizzOK) then return end
            db.theme = self.key
            ApplyAllThemes()
            PaintThemeButtons()
        end)
        themeButtons[i] = b
    end

    -- Windows
    SectionTitle(body, "Windows", -122)
    Add(Slider(body, "Bag columns", MIN_COLS, MAX_COLS, 1, "%d",
        function() return db.columns end, function(v) SetColumns(bags, v) end)):SetPoint("TOPLEFT", 20, -146)
    Add(Slider(body, "Bank columns", MIN_COLS, MAX_COLS, 1, "%d",
        function() return db.bankWindow.columns end, function(v) SetColumns(bank, v) end)):SetPoint("TOPLEFT", 260, -146)
    Add(Slider(body, "Scale", 0.6, 1.5, 0.05, "%.2f",
        function() return db.scale end,
        function(v)
            db.scale = v
            BothViews("ApplyGeometry")
        end)):SetPoint("TOPLEFT", 20, -192)
    Add(Checkbox(body, "Lock window positions", "The bag and bank windows can't be dragged.",
        function() return db.locked end, function(v) db.locked = v end)):SetPoint("TOPLEFT", 260, -206)

    -- Layout
    SectionTitle(body, "Layout", -242)
    Add(Slider(body, "Icon size", 24, 56, 1, "%d",
        function() return db.iconSize end, function(v) db.iconSize = v Relayout() end)):SetPoint("TOPLEFT", 20, -266)
    Add(Slider(body, "Space between slots", 0, 12, 1, "%d",
        function() return db.spacing end, function(v) db.spacing = v Relayout() end)):SetPoint("TOPLEFT", 260, -266)
    Add(Slider(body, "Space between categories", 0, 40, 1, "%d",
        function() return db.categoryGap end, function(v) db.categoryGap = v Relayout() end)):SetPoint("TOPLEFT", 20, -312)
    Add(Slider(body, "Category name size", 8, 16, 1, "%d",
        function() return db.labelSize end, function(v) db.labelSize = v Relayout() end)):SetPoint("TOPLEFT", 260, -312)
    Add(Checkbox(body, "Each category on a new row",
        "Every category starts at the left edge of its own row. Clearest, but the window needs more rows.",
        function() return db.newRow end, function(v) db.newRow = v Relayout() end)):SetPoint("TOPLEFT", 20, -358)

    -- Category look: three choices in a row
    local looks = CreateFrame("Frame", nil, body)
    looks:SetSize(222, 20)
    looks:SetPoint("TOPLEFT", 260, -366)   -- its small label above clears the sliders
    local LOOKS = {
        { key = "cards", label = "Cards", tip = "Each category in its own dark panel with a thin edge." },
        { key = "lines", label = "Lines", tip = "A thin line from each category's name to the end of the group." },
        { key = "plain", label = "Plain", tip = "Just the names, with a short line between categories that share a row." },
    }
    looks.buttons = {}
    function looks:Refresh()
        for _, b in ipairs(self.buttons) do
            b.selected = db.groupStyle == b.key
            PaintSmall(b, false)
        end
    end
    for i, l in ipairs(LOOKS) do
        local b = SmallButton(looks, l.label, 70)
        b:SetPoint("LEFT", (i - 1) * 76, 0)
        b.key, b.tip = l.key, l.tip
        b:SetScript("OnClick", function(self)
            db.groupStyle = self.key
            looks:Refresh()
            Relayout()
        end)
        looks.buttons[i] = b
    end
    local looksLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    looksLabel:SetPoint("BOTTOMLEFT", looks, "TOPLEFT", 0, 3)
    looksLabel:SetText("Category look")
    looksLabel:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3])
    Add(looks)

    -- Items
    SectionTitle(body, "Items", -394)
    Add(Checkbox(body, "Show every empty slot",
        "On: each empty slot has its own place in the grid, after the items.\nOff: one tile per bag type in the footer, with how many slots are free.",
        function() return db.emptyEach end, function(v) db.emptyEach = v Relayout() end)):SetPoint("TOPLEFT", 20, -416)
    Add(Checkbox(body, "Item level on gear", "The item level in the corner of weapons and armor.",
        function() return db.itemLevel end, function(v) db.itemLevel = v Relayout() end)):SetPoint("TOPLEFT", 260, -416)
    Add(Checkbox(body, "Rarity-colored rims",
        "Uncommon and better items get a rim in their quality color.",
        function() return db.rarity end, function(v) db.rarity = v Relayout() end)):SetPoint("TOPLEFT", 20, -440)

    -- Categories
    SectionTitle(body, "Categories", -476)
    local note = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", 20, -496)
    note:SetText("Turned off, a category's items go to Miscellaneous.")
    note:SetTextColor(P.warmGrey[1], P.warmGrey[2], P.warmGrey[3])
    local i = 0
    for _, c in ipairs(CATEGORIES) do
        if c.key ~= "misc" then
            local col, row = i % 3, floor(i / 3)
            Add(Checkbox(body, c.label, nil,
                function() return not db.catOff[c.key] end,
                function(v)
                    db.catOff[c.key] = (not v) or nil
                    Relayout()
                end)):SetPoint("TOPLEFT", 20 + col * 160, -516 - row * 24)
            i = i + 1
        end
    end

    -- foot
    local reset = SmallButton(body, "Reset window positions", 170)
    reset:SetPoint("BOTTOMLEFT", 16, 16)
    reset.tip = "Puts the bag, bank and settings windows back in their first places."
    reset:SetScript("OnClick", function()
        db.point = CopyTable(DEFAULTS.point)
        db.bankWindow.point = CopyTable(DEFAULTS.bankWindow.point)
        db.settingsPoint = CopyTable(DEFAULTS.settingsPoint)
        RestorePosition(f, db, "settingsPoint", DEFAULTS.settingsPoint)
        bags:ApplyGeometry()
        bank:ApplyGeometry()
    end)
    local done = SmallButton(body, "Done", 80)
    done:SetPoint("BOTTOMRIGHT", -16, 16)
    done:SetScript("OnClick", function() f:Hide() end)

    local function ApplySettingsTheme()
        local t = Theme()
        ApplySkin(f)
        PlaceClose(close, f, t)
        title:ClearAllPoints()
        if t.blizzard then title:SetPoint("TOP", f, "TOP", 0, -5)
        else title:SetPoint("LEFT", f, "TOPLEFT", 16, RowY(t)) end
        PlaceDivider(divider, f, "TOP", -38)
    end
    themed[#themed + 1] = ApplySettingsTheme
    ApplySettingsTheme()

    f:SetScript("OnShow", function()
        for _, c in ipairs(controls) do c:Refresh() end
        PaintThemeButtons()
    end)
end

OpenSettings = function()
    if not settings then return end
    settings:SetShown(not settings:IsShown())
end

-- the addon compartment (TOC) and Options > AddOns
function Bagkeeper_OpenSettings() OpenSettings() end

local function RegisterOptionsEntry()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local canvas = CreateFrame("Frame")
    local text = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 16, -16)
    text:SetText("Bagkeeper's settings have their own window.")
    local open = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    open:SetSize(180, 24)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
    open:SetText("Open Bagkeeper settings")
    -- opens above the game's Options (DIALOG strata); Blizzard's panel is left alone
    open:SetScript("OnClick", function()
        if not settings:IsShown() then OpenSettings() end
    end)
    pcall(function()
        local category = Settings.RegisterCanvasLayoutCategory(canvas, "Bagkeeper")
        Settings.RegisterAddOnCategory(category)
    end)
end

--------------------------------------------------
-- 11. BLIZZARD'S BAG WINDOWS
-- Blizzard still opens and closes its bags (the B key, the bag buttons, vendors, the mailbox): its
-- windows for Bagkeeper's bags live under a hidden parent and Bagkeeper's bag window follows their state.
--------------------------------------------------
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local originalParents = {}
local function ClaimFrame(frame)
    if InCombatLockdown() then return end
    if frame == _G.ContainerFrameCombinedBags or OWN_BAGS[frame:GetID()] then
        if frame:GetParent() ~= hiddenParent then
            originalParents[frame] = frame:GetParent()
            frame:SetParent(hiddenParent)
        end
    elseif frame:GetParent() == hiddenParent then
        frame:SetParent(originalParents[frame] or UIParent)
        originalParents[frame] = nil
    end
end

local function BlizzardBagsOpen()
    for frame in pairs(watched) do
        if frame:IsShown() and (frame == _G.ContainerFrameCombinedBags or OWN_BAGS[frame:GetID()]) then return true end
    end
    return false
end

local syncQueued = false
local function Sync()
    if syncQueued then return end
    syncQueued = true
    C_Timer.After(0, function()
        syncQueued = false
        for frame in pairs(watched) do ClaimFrame(frame) end
        local open = BlizzardBagsOpen()
        if not open then bags.closePending = nil end
        if not bags.closePending then
            bags.followingNative = true
            if bags.frame:IsShown() ~= open or bags.pendingOpen ~= nil then bags:SetOpen(open) end
            bags.followingNative = nil
        end
    end)
end

local function WatchFrame(frame)
    if type(frame) ~= "table" or not frame.GetID or watched[frame] then return end
    watched[frame] = true
    for _, method in ipairs({ "SetID", "Show", "Hide", "SetShown" }) do
        if frame[method] then hooksecurefunc(frame, method, Sync) end
    end
end

local function WatchContainers()
    WatchFrame(_G.ContainerFrameCombinedBags)
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
        WatchFrame(_G["ContainerFrame" .. i])
    end
    Sync()
end

local function TakeOverBlizzardBags()
    WatchContainers()
    if EventRegistry then
        EventRegistry:RegisterCallback("ContainerFrame.OpenBag", function(_, frame) WatchFrame(frame) Sync() end, bags)
    end
    for _, fn in ipairs({ "OpenAllBags", "CloseAllBags", "ToggleAllBags", "ToggleBackpack", "OpenBackpack",
                          "CloseBackpack", "ToggleBag", "OpenBag", "CloseBag" }) do
        if type(_G[fn]) == "function" then hooksecurefunc(fn, Sync) end
    end
end

--------------------------------------------------
-- 12. EVENTS AND SLASH COMMAND
--------------------------------------------------
local events = CreateFrame("Frame")

local function BankChanged()
    if not bankOpen then return end
    ReadBank()
    bank:RequestLayout()
end

local function OnEvent(_, event, ...)
    if event == "PLAYER_LOGIN" then
        LoadDB()
        if C_AddOns.IsAddOnLoaded("Baganator") then
            print("|cffcc9957Bagkeeper:|r Baganator is enabled, so Bagkeeper stays off. Disable one of the two.")
            return
        end
        heavyOK = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("heavybronze-frame-basic") ~= nil or false
        BuildBagWindow()
        BuildBankWindow()
        BuildSettings()
        RegisterOptionsEntry()
        ApplyAllThemes()
        TakeOverBlizzardBags()
        HookBankFrame()
        for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "BAG_UPDATE", "BAG_UPDATE_DELAYED", "USE_COMBINED_BAGS_CHANGED",
                             "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
                             "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "PLAYER_REGEN_ENABLED",
                             "GET_ITEM_INFO_RECEIVED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
                             "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED", "BANK_TABS_CHANGED",
                             "BANK_TAB_SETTINGS_UPDATED", "BAG_CONTAINER_UPDATE" }) do
            pcall(events.RegisterEvent, events, e)
        end
    elseif event == "ADDON_LOADED" then
        if bankOpen and not bankHooked then HookBankFrame() ParkBankFrame() end
    elseif event == "PLAYER_LOGOUT" then
        if bags.active then bags:MarkSeen(bags:Collect()) end
        if bank.active then bank:MarkSeen(bank:Collect()) end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        HookBankFrame()
        ParkBankFrame()
        ReadBank()
        if bank.frame:IsShown() then bank:RequestLayout() end
        bank:SetOpen(true)
    elseif event == "BANKFRAME_CLOSED" then
        if bankOpen then
            bankOpen = false
            bank:SetOpen(false)
            ParkBankFrame()
            if not InCombatLockdown() then bank:Layout(true) end
        end
    elseif event == "BAG_UPDATE" then
        local id = ...
        if OWN_BAGS[id] then
            if bags.inWorld and not bags.baseline then bags:Layout(true) else bags:RequestLayout() end
        else
            BankChanged()
        end
    elseif event == "USE_COMBINED_BAGS_CHANGED" then
        WatchContainers()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" or event == "BAG_CONTAINER_UPDATE" then
        if event == "PLAYER_ENTERING_WORLD" then
            bags.inWorld = true
            WatchContainers()
            if not bankOpen then bank:Layout(true) end
        end
        if event == "PLAYER_REGEN_ENABLED" then
            ParkBankFrame()
            if bags.closePending then bags.closePending = nil CloseBlizzardBags() end
            if bank.pendingOpen ~= nil then bank:SetOpen(bank.pendingOpen) end
            bank:Layout(true)
            Sync()
        end
        if bags.inWorld and (not bags.hasLayout or not bags.baseline or event == "BAG_CONTAINER_UPDATE" or event == "PLAYER_REGEN_ENABLED") then
            bags:Layout(true)
        else
            bags:EnsureLiveButtons(BagList())
            bags:RequestLayout()
        end
        BankChanged()
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED"
        or event == "BANK_TABS_CHANGED" or event == "BANK_TAB_SETTINGS_UPDATED" then
        bags:RequestLayout()
        BankChanged()
    elseif event == "ITEM_LOCK_CHANGED" then
        local bag, slot = ...
        if bag and slot then BothViews("RefreshSlot", bag, slot) end
        if bankOpen and bag == TABS_BAG then bank:RequestLayout() end
    elseif event == "BAG_UPDATE_COOLDOWN" then
        BothViews("RefreshCooldowns")
    elseif event == "PLAYER_MONEY" then
        if bags.frame:IsShown() then bags:UpdateMoney() end
        if bankOpen then bank:RefreshCost() end
    elseif event == "UNIT_QUEST_LOG_CHANGED" then
        if ... == "player" then Relayout() end
    else
        Relayout()
    end
end
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", OnEvent)

local function Say(msg) print("|cffcc9957Bagkeeper:|r " .. msg) end

SLASH_BAGKEEPER1 = "/bagkeeper"
SLASH_BAGKEEPER2 = "/bk"
SlashCmdList.BAGKEEPER = function(msg)
    if not bags then Say("not running (is Baganator enabled?)") return end
    local cmd = (msg or ""):lower():match("^(%S*)")
    if cmd == "" then
        ToggleAllBags()
    elseif cmd == "bank" then
        bank:Toggle()
    elseif cmd == "config" or cmd == "settings" or cmd == "options" then
        OpenSettings()
    else
        Say("/bagkeeper (or /bk) - open or close the bags")
        Say("/bagkeeper bank - open or close the bank (saved copy away from a banker)")
        Say("/bagkeeper config - settings")
    end
end
