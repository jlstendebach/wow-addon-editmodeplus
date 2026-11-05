-- EditModePlus overview window: every change in the current layout, plus a way to
-- pick or type any frame and edit it outside Edit Mode. Opened with
-- /editmodeplus (or /emp), the addon compartment, Options > AddOns, or the
-- "All changes" button under the Edit Mode window.

local _, ns = ...
local EditModePlus = ns.EditModePlus
local Controls = EditModePlus.Controls

local UI = {}
EditModePlus.UI = UI

local PAD = 20
local WIDTH = Controls.WIDTH + PAD * 2 + 20
local ROW_HEIGHT, ROWS = 22, 8
local LIST_TOP = -100
local LIST_HEIGHT = ROW_HEIGHT * ROWS + 4

local selected      -- selected path (may have no changes yet)
local scroll = 0    -- first visible list index minus one

local function Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function IndexOf(list, value)
    for i = 1, #list do
        if list[i] == value then return i end
    end
    return nil
end

local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer)
    t:SetColorTexture(r, g, b, a)
    return t
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "EditModePlusFrame", UIParent)
frame.__editModePlusUI = true
frame:SetSize(WIDTH, 560)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetFrameLevel(230)
frame:SetToplevel(true)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()
tinsert(UISpecialFrames, "EditModePlusFrame")

local ok, border = pcall(CreateFrame, "Frame", nil, frame, "DialogBorderTranslucentTemplate")
if ok and border then
    border:SetAllPoints()
else
    Solid(frame, "BACKGROUND", 0.05, 0.05, 0.07, 0.95):SetAllPoints()
end

local title = Controls.Label(frame, "GameFontHighlightLarge", "Edit Mode Plus")
title:SetPoint("TOP", 0, -15)

local layoutText = Controls.Label(frame, "GameFontDisableSmall", "")
layoutText:SetPoint("TOP", title, "BOTTOM", 0, -4)
layoutText:SetJustifyH("CENTER")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

---------------------------------------------------------------------------
-- Picking or typing a frame
---------------------------------------------------------------------------

local pickButton = Controls.Button(frame, "Pick a frame", 110)
pickButton:SetPoint("TOPLEFT", PAD, -62)

local addButton = Controls.Button(frame, "Edit", 50)
addButton:SetPoint("TOPRIGHT", -PAD, -62)

local addBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
addBox:SetHeight(20)
addBox:SetAutoFocus(false)
addBox:SetPoint("LEFT", pickButton, "RIGHT", 14, 0)
addBox:SetPoint("RIGHT", addButton, "LEFT", -8, 0)

local addHint = Controls.Label(addBox, "GameFontDisableSmall", "or type a frame name, e.g. Minimap")
addHint:SetPoint("LEFT", 2, 0)

local function UpdateAddHint()
    addHint:SetShown(addBox:GetText() == "" and not addBox:HasFocus())
end
addBox:SetScript("OnEditFocusGained", UpdateAddHint)
addBox:SetScript("OnEditFocusLost", UpdateAddHint)
addBox:SetScript("OnTextChanged", UpdateAddHint)
addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local function EditTyped()
    local text = strtrim(addBox:GetText() or "")
    if text == "" then return end
    if not EditModePlus.Resolve(text) then
        EditModePlus.Print(("Couldn't find a frame or texture named '%s'. Names are case-sensitive."):format(text))
        return
    end
    addBox:SetText("")
    addBox:ClearFocus()
    UI:Select(text)
end
addButton:SetScript("OnClick", EditTyped)
addBox:SetScript("OnEnterPressed", EditTyped)

---------------------------------------------------------------------------
-- List of changes
---------------------------------------------------------------------------

local list = CreateFrame("Frame", nil, frame)
list:SetPoint("TOPLEFT", PAD, LIST_TOP)
list:SetPoint("TOPRIGHT", -PAD, LIST_TOP)
list:SetHeight(LIST_HEIGHT)
list:EnableMouseWheel(true)
Solid(list, "BACKGROUND", 1, 1, 1, 0.04):SetAllPoints()

local emptyText = Controls.Label(list, "GameFontDisable",
    "No changes in this layout yet.\nPick a frame, or select one in Edit Mode.")
emptyText:SetPoint("CENTER")
emptyText:SetJustifyH("CENTER")

local countText = Controls.Label(frame, "GameFontDisableSmall", "")
countText:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -3)
countText:SetJustifyH("RIGHT")

local function Summary(path)
    local e = EditModePlus.GetEntry(path) or {}
    local parts = {}
    if e.visibility == "hide" then parts[#parts + 1] = "hidden" end
    if e.visibility == "show" then parts[#parts + 1] = "always shown" end
    if e.alpha then parts[#parts + 1] = ("%d%%"):format(math.floor(e.alpha * 100 + 0.5)) end
    if e.strata then parts[#parts + 1] = e.strata end
    if e.level then parts[#parts + 1] = "level " .. e.level end
    if e.layer then parts[#parts + 1] = e.layer end
    if e.sublevel then parts[#parts + 1] = "sub " .. e.sublevel end
    local status = EditModePlus.GetStatus(path)
    if status == "missing" then parts[#parts + 1] = "|cffff8040not loaded|r" end
    if status == "pending" then parts[#parts + 1] = "|cffffd000after combat|r" end
    return table.concat(parts, ", ")
end

local rows = {}
for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * ROW_HEIGHT)

    row.selectedBg = Solid(row, "BACKGROUND", 0.2, 0.45, 0.75, 0.4)
    row.selectedBg:SetAllPoints()
    Solid(row, "HIGHLIGHT", 1, 1, 1, 0.07):SetAllPoints()

    row.name = Controls.Label(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetWidth(200)
    row.name:SetWordWrap(false)

    row.summary = Controls.Label(row, "GameFontHighlightSmall")
    row.summary:SetPoint("RIGHT", -6, 0)
    row.summary:SetWidth(170)
    row.summary:SetJustifyH("RIGHT")
    row.summary:SetWordWrap(false)
    row.summary:SetTextColor(0.75, 0.75, 0.75)

    row:SetScript("OnClick", function(self) UI:Select(self.path) end)
    rows[i] = row
end

list:SetScript("OnMouseWheel", function(_, delta)
    scroll = scroll - delta * 2
    UI:RefreshList()
end)

---------------------------------------------------------------------------
-- Selected object
---------------------------------------------------------------------------

local detailTop = LIST_TOP - LIST_HEIGHT - 24

local noSelection = Controls.Label(frame, "GameFontDisable", "Select a change to edit it.")
noSelection:SetPoint("TOP", 0, detailTop - 20)

local nameText = Controls.Label(frame, "GameFontNormal")
nameText:SetPoint("TOPLEFT", PAD, detailTop)
nameText:SetPoint("RIGHT", -PAD, 0)
nameText:SetWordWrap(false)

local controls = Controls.Create(frame, function(path) UI:Select(path) end)
controls:SetPoint("TOPLEFT", PAD, detailTop - 24)

local showButton = Controls.Button(frame, "Show me", 90)
local resetButton = Controls.Button(frame, "Reset", 80)
resetButton:SetPoint("LEFT", showButton, "RIGHT", 6, 0)

showButton:SetScript("OnClick", function()
    EditModePlus.Picker:Flash(selected and EditModePlus.Resolve(selected))
end)
resetButton:SetScript("OnClick", function()
    if selected then EditModePlus.Clear(selected) end
end)

---------------------------------------------------------------------------
-- Footer
---------------------------------------------------------------------------

local resetAllButton = Controls.Button(frame, "Reset all", 90)
resetAllButton:SetPoint("BOTTOMRIGHT", -PAD, 16)

local footer = Controls.Label(frame, "GameFontDisableSmall", "")
footer:SetPoint("BOTTOMLEFT", PAD, 22)
footer:SetPoint("RIGHT", resetAllButton, "LEFT", -10, 0)

StaticPopupDialogs["EDITMODEPLUS_RESET_ALL"] = {
    text = "Remove every Edit Mode Plus change in this layout?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        selected = nil
        EditModePlus.ClearAll()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
resetAllButton:SetScript("OnClick", function()
    StaticPopup_Show("EDITMODEPLUS_RESET_ALL")
end)

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function UI:RefreshList()
    local paths = EditModePlus.GetSortedPaths()
    scroll = Clamp(scroll, 0, math.max(0, #paths - ROWS))
    for i = 1, ROWS do
        local row = rows[i]
        local path = paths[i + scroll]
        if path then
            row.path = path
            row.name:SetText(path)
            row.summary:SetText(Summary(path))
            row.selectedBg:SetShown(path == selected)
            row:Show()
        else
            row.path = nil
            row:Hide()
        end
    end
    emptyText:SetShown(#paths == 0)
    if #paths > ROWS then
        countText:SetText(("%d-%d of %d (scroll for more)"):format(scroll + 1, scroll + ROWS, #paths))
    elseif #paths > 0 then
        countText:SetText(("%d changed"):format(#paths))
    else
        countText:SetText("")
    end
    resetAllButton:SetEnabled(#paths > 0)
end

function UI:RefreshDetail()
    local shown = selected ~= nil
    noSelection:SetShown(not shown)
    nameText:SetShown(shown)
    controls:SetShown(shown)
    showButton:SetShown(shown)
    resetButton:SetShown(shown)
    if not shown then
        frame:SetHeight(-detailTop + 80 + 50)
        return
    end
    nameText:SetText(selected)
    if controls:GetTarget() ~= selected then controls:SetTarget(selected) else controls:Refresh() end
    showButton:ClearAllPoints()
    showButton:SetPoint("TOPLEFT", controls, "BOTTOMLEFT", 0, -8)
    showButton:SetEnabled(EditModePlus.Resolve(selected) ~= nil)
    resetButton:SetEnabled(EditModePlus.GetEntry(selected) ~= nil)
    frame:SetHeight(-detailTop + 24 + controls:GetHeight() + 8 + 22 + 60)
end

function UI:Refresh()
    if not frame:IsShown() then return end
    local layoutName = EditModePlus.EditMode and EditModePlus.EditMode.GetActiveLayoutName()
    local parts = {}
    if layoutName then parts[1] = "Layout: " .. layoutName end
    if EditModePlus.HasUnsavedChanges() then
        parts[#parts + 1] = "|cffffd100unsaved, use Save in Edit Mode|r"
    end
    layoutText:SetText(table.concat(parts, "  ·  "))
    if EditModePlus.IsEditMode() then
        footer:SetText("Changes here are saved with Edit Mode's Save button.")
    else
        footer:SetText("Action bars and other protected frames only change out of combat.")
    end
    self:RefreshList()
    self:RefreshDetail()
end

-- Selects a path (it doesn't need to have changes yet) and scrolls to it.
function UI:Select(path)
    selected = path
    local paths = EditModePlus.GetSortedPaths()
    local i = IndexOf(paths, path)
    if i then
        if i <= scroll then scroll = i - 1 end
        if i > scroll + ROWS then scroll = i - ROWS end
    end
    frame:Show()
    self:Refresh()
end

function UI:Toggle()
    frame:SetShown(not frame:IsShown())
end

frame:SetScript("OnShow", function()
    UpdateAddHint()
    UI:Refresh()
end)

EditModePlus.RegisterListener(function() UI:Refresh() end)

pickButton:SetScript("OnClick", function()
    frame:Hide()
    EditModePlus.Picker:Start(
        function(path) UI:Select(path) end,
        function() frame:Show() end)
end)

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

SLASH_EDITMODEPLUS1 = "/editmodeplus"
SLASH_EDITMODEPLUS2 = "/emp"
SlashCmdList.EDITMODEPLUS = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "pick" then
        pickButton:Click()
    elseif msg == "debug" then
        if EditModePlus.db then
            EditModePlus.db.debug = not EditModePlus.db.debug
            EditModePlus.Print("Debug messages " .. (EditModePlus.db.debug and "on" or "off") .. ".")
        end
    else
        UI:Toggle()
    end
end

function EditModePlus_OnAddonCompartmentClick()
    UI:Toggle()
end

-- Options > AddOns entry that opens the window.
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local panel = CreateFrame("Frame")
    local heading = Controls.Label(panel, "GameFontNormalLarge", "Edit Mode Plus")
    heading:SetPoint("TOPLEFT", 16, -16)
    local blurb = Controls.Label(panel, "GameFontHighlight",
        "Open Edit Mode and select anything to change its visibility, opacity and draw order.\n" ..
        "/emp lists every change in the current layout.")
    blurb:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    local open = Controls.Button(panel, "Open Edit Mode Plus", 160)
    open:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -12)
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() and HideUIPanel then HideUIPanel(SettingsPanel) end
        frame:Show()
    end)
    local okCategory, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, "Edit Mode Plus")
    if okCategory and category then pcall(Settings.RegisterAddOnCategory, category) end
end
