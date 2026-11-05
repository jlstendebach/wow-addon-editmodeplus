-- EditModePlus in Edit Mode: a panel docked to Blizzard's settings dialog for the
-- selected system, a toolbar under the Edit Mode window for picking anything
-- else, and settings that follow Edit Mode's layouts, Save and Revert.
--
-- Everything here only reads Edit Mode's state and hooks it after the fact
-- (hooksecurefunc / HookScript). Nothing writes into Blizzard's frames or
-- tables, which keeps Edit Mode and the action bars free of taint.

local _, ns = ...
local EditModePlus = ns.EditModePlus
local SafeCall = EditModePlus.SafeCall
local Controls = EditModePlus.Controls

local EM = {}
EditModePlus.EditMode = EM

local PAD = 20
local PANEL_WIDTH = Controls.WIDTH + PAD * 2
local HEADER_HEIGHT = 50
local FOOTER_HEIGHT = 46

local initialized = false
local mode            -- "docked" (follows Blizzard's dialog) or "free" (picked)
local copyFrom        -- entries to give a layout that's being created
local renameFromKey   -- profile key of a layout being renamed
local deleteKey       -- profile key of a layout being deleted

---------------------------------------------------------------------------
-- Layout identity
---------------------------------------------------------------------------

-- Profiles are keyed by layout type and name. Character layouts also carry
-- the character, since each character has its own set.
function EM.LayoutKey(layoutType, layoutName)
    layoutName = tostring(EditModePlus.Readable(layoutName) or "?")
    local types = Enum and Enum.EditModeLayoutType
    if types then
        if layoutType == types.Character then
            return ("char:%s-%s:%s"):format(UnitName("player") or "?", GetRealmName() or "?", layoutName)
        elseif layoutType == types.Account then
            return "account:" .. layoutName
        elseif layoutType == types.Preset then
            return "preset:" .. layoutName
        end
    end
    return ("layout:%s:%s"):format(tostring(layoutType), layoutName)
end

local function KeyForInfo(info)
    if type(info) ~= "table" then return nil end
    return EM.LayoutKey(info.layoutType, info.layoutName)
end

local function ActiveLayoutInfo()
    return EditModeManagerFrame and SafeCall(EditModeManagerFrame, "GetActiveLayoutInfo")
end

function EM.GetActiveLayoutName()
    local info = ActiveLayoutInfo()
    return info and EditModePlus.Readable(info.layoutName)
end

function EM.IsActiveLayoutPreset()
    local info = ActiveLayoutInfo()
    local types = Enum and Enum.EditModeLayoutType
    return info and types and info.layoutType == types.Preset or false
end

local function SyncProfile()
    local key = KeyForInfo(ActiveLayoutInfo())
    if key and key ~= EditModePlus.GetProfileKey() then
        EditModePlus.SetProfile(key)
    else
        EditModePlus.ApplyAll()
    end
end

---------------------------------------------------------------------------
-- Blizzard's Save / Revert buttons
---------------------------------------------------------------------------

-- Blizzard only enables Save and Revert for its own changes. Enable them for
-- ours too; clicking them runs Blizzard's normal handlers, which we hook.
local function SyncButtons()
    local mgr = EditModeManagerFrame
    if not mgr or not EditModePlus.IsEditMode() then return end
    local enable = EditModePlus.HasUnsavedChanges() or SafeCall(mgr, "HasActiveChanges") or false
    if mgr.SaveChangesButton then mgr.SaveChangesButton:SetEnabled(enable and true or false) end
    if mgr.RevertAllChangesButton then mgr.RevertAllChangesButton:SetEnabled(enable and true or false) end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "EditModePlusPanel", UIParent)
panel.__editModePlusUI = true
panel:SetSize(PANEL_WIDTH, 200)
panel:SetFrameStrata("DIALOG")
panel:SetFrameLevel(210)
panel:SetClampedToScreen(true)
panel:EnableMouse(true)
panel:Hide()
EM.panel = panel

-- Same border and background as Edit Mode's own dialogs.
local function AddBorder(frame)
    local ok, border = pcall(CreateFrame, "Frame", nil, frame, "DialogBorderTranslucentTemplate")
    if ok and border then
        border:SetAllPoints()
    else
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.07, 0.9)
    end
end
AddBorder(panel)

local title = Controls.Label(panel, "GameFontNormalLarge", "Edit Mode Plus")
title:SetPoint("TOP", 0, -15)

local subtitle = Controls.Label(panel, "GameFontDisableSmall", "")
subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
subtitle:SetWidth(PANEL_WIDTH - PAD * 2)
subtitle:SetJustifyH("CENTER")
subtitle:SetWordWrap(false)

local closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 0, 0)
closeButton:SetScript("OnClick", function() EM.HidePanel() end)

local controls -- created below (needs EM.ShowFree)

local message = Controls.Label(panel, "GameFontHighlight", "")
message:SetPoint("TOP", 0, -HEADER_HEIGHT - 6)
message:SetWidth(PANEL_WIDTH - PAD * 2)
message:SetJustifyH("CENTER")

local resetButton = Controls.Button(panel, "Reset to Blizzard default", 200)
resetButton:SetPoint("BOTTOM", 0, 16)
resetButton:SetScript("OnClick", function()
    local path = controls and controls:GetTarget()
    if path then EditModePlus.Clear(path) end
end)

-- Space below and above `anchor`, in `frame`'s units, or nil if unknown.
local function SpaceAround(frame, anchor)
    local bottom, top = anchor:GetBottom(), anchor:GetTop()
    local screenTop = UIParent:GetTop()
    if not bottom or not top or not screenTop then return nil end
    local frameScale = frame:GetEffectiveScale() or 1
    local scale = (anchor:GetEffectiveScale() or 1) / frameScale
    local screenScale = (UIParent:GetEffectiveScale() or 1) / frameScale
    return bottom * scale, screenTop * screenScale - top * scale
end

-- Centers `frame` under `anchor` (or over it with preferAbove). Switches
-- sides only when the preferred side is too small and the other one fits.
local function Attach(frame, anchor, preferAbove, gap)
    local below, above = SpaceAround(frame, anchor)
    local height = frame:GetHeight() or 0
    local placeAbove = preferAbove
    if below and above then
        if preferAbove and above < height and below >= height then placeAbove = false end
        if not preferAbove and below < height and above >= height then placeAbove = true end
    end
    frame:ClearAllPoints()
    if placeAbove then
        frame:SetPoint("BOTTOM", anchor, "TOP", 0, gap)
    else
        frame:SetPoint("TOP", anchor, "BOTTOM", 0, -gap)
    end
end

local function Reposition()
    local dialog = EditModeSystemSettingsDialog
    if mode == "docked" and dialog then
        panel:SetWidth(math.max(PANEL_WIDTH, dialog:GetWidth() or 0))
        Attach(panel, dialog, false, 0)
    elseif EditModeManagerFrame and EditModeManagerFrame:IsShown() then
        panel:SetWidth(PANEL_WIDTH)
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", EditModeManagerFrame, "TOPRIGHT", 6, 0)
    else
        panel:SetWidth(PANEL_WIDTH)
        panel:ClearAllPoints()
        panel:SetPoint("CENTER")
    end
end

-- Blizzard moves its dialog into place in the same call that selects a
-- system, and a frame's position isn't measurable until the next frame.
-- Place the panel now, then again once positions have settled.
local function RepositionSoon()
    Reposition()
    C_Timer.After(0, function()
        if panel:IsShown() then Reposition() end
    end)
end

local function UpdateHeight()
    local body = controls:IsShown() and controls:GetHeight() or (message:GetStringHeight() + 12)
    panel:SetHeight(HEADER_HEIGHT + body + FOOTER_HEIGHT)
end

local function RefreshPanel()
    if not panel:IsShown() then return end
    local path = controls:GetTarget()
    resetButton:SetEnabled(path ~= nil and EditModePlus.GetEntry(path) ~= nil)
    if controls:IsShown() then controls:Refresh() end
    UpdateHeight()
    EditModePlus.Picker:RefreshHighlight()
end

-- Points the panel at an object. displayName is shown when it has no path.
local function SetPanelTarget(path, displayName)
    subtitle:SetText(path or displayName or "")
    if path then
        message:Hide()
        controls:Show()
        controls:SetTarget(path)
    else
        controls:SetTarget(nil)
        controls:Hide()
        message:SetText("This element has no stable name, so Edit Mode Plus can't save settings for it.")
        message:Show()
    end
    closeButton:SetShown(mode == "free")
    panel:Show()
    RefreshPanel()
    RepositionSoon()
end

-- Follows Blizzard's settings dialog for a selected Edit Mode system.
function EM.ShowDocked(systemFrame)
    mode = "docked"
    EditModePlus.Picker:ClearHighlight()
    local name = SafeCall(systemFrame, "GetSystemName") or SafeCall(systemFrame, "GetDebugName")
    SetPanelTarget(EditModePlus.GetPath(systemFrame), name)
end

-- Shows the panel on its own for something picked with "Pick any frame".
function EM.ShowFree(path)
    if EditModeManagerFrame and EditModeSystemSettingsDialog and EditModeSystemSettingsDialog:IsShown() then
        -- Deselect Blizzard's system; this is Edit Mode's own entry point for it.
        pcall(EditModeManagerFrame.ClearSelectedSystem, EditModeManagerFrame)
    end
    mode = "free"
    SetPanelTarget(path)
    EditModePlus.Picker:Highlight(EditModePlus.Resolve(path))
end

function EM.GetTarget()
    return panel:IsShown() and controls:GetTarget() or nil
end

function EM.HidePanel()
    panel:Hide()
    EditModePlus.Picker:ClearHighlight()
    mode = nil
end

controls = Controls.Create(panel, function(path) EM.ShowFree(path) end)
controls:SetPoint("TOP", 0, -HEADER_HEIGHT)

---------------------------------------------------------------------------
-- Toolbar under the Edit Mode window
---------------------------------------------------------------------------

local toolbar = CreateFrame("Frame", "EditModePlusToolbar", UIParent)
toolbar.__editModePlusUI = true
toolbar:SetSize(380, 46)
toolbar:SetFrameStrata("DIALOG")
toolbar:SetFrameLevel(210)
toolbar:EnableMouse(true)
toolbar:Hide()
EM.toolbar = toolbar

AddBorder(toolbar)

local toolbarLabel = Controls.Label(toolbar, "GameFontNormal", "Edit Mode Plus")
toolbarLabel:SetPoint("LEFT", 16, 0)

local overviewButton = Controls.Button(toolbar, "All changes", 100)
overviewButton:SetPoint("RIGHT", -14, 0)
overviewButton:SetScript("OnClick", function()
    if EditModePlus.UI then EditModePlus.UI:Toggle() end
end)

local pickButton = Controls.Button(toolbar, "Pick any frame", 120)
pickButton:SetPoint("RIGHT", overviewButton, "LEFT", -6, 0)
pickButton:SetScript("OnClick", function()
    local wasShown = panel:IsShown()
    panel:Hide()
    EditModePlus.Picker:Start(
        function(path) EM.ShowFree(path) end,
        function()
            -- Cancelled: bring back whatever was showing.
            if not panel:IsShown() and wasShown and mode then panel:Show() end
        end)
end)

---------------------------------------------------------------------------
-- Unsaved changes when Edit Mode closes
---------------------------------------------------------------------------

StaticPopupDialogs["EDITMODEPLUS_UNSAVED_CHANGES"] = {
    text = "You have unsaved Edit Mode Plus changes.",
    button1 = SAVE or "Save",
    button2 = "Discard",
    OnAccept = function() EditModePlus.CommitStaged() end,
    OnCancel = function() EditModePlus.DiscardStaged() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
    preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

-- Sized to its contents; above the Edit Mode window, where it covers less
-- than below it (the cast bar sits there by default).
local function PlaceToolbar()
    local width = 16 + (toolbarLabel:GetStringWidth() or 100) + 14
        + pickButton:GetWidth() + 6 + overviewButton:GetWidth() + 14
    toolbar:SetWidth(math.max(width, 300))
    if EditModeManagerFrame then Attach(toolbar, EditModeManagerFrame, true, 2) end
end

local function OnEnter()
    EditModePlus.SetEditMode(true)
    PlaceToolbar()
    toolbar:Show()
    C_Timer.After(0, function()
        if toolbar:IsShown() then PlaceToolbar() end
    end)
    SyncButtons()
end

local function OnExit()
    toolbar:Hide()
    EM.HidePanel()
    EditModePlus.Picker:Stop()
    EditModePlus.SetEditMode(false)
    if EditModePlus.HasUnsavedChanges() then
        -- Blizzard already reverted its own changes; ours wait for an answer.
        StaticPopup_Show("EDITMODEPLUS_UNSAVED_CHANGES")
    else
        EditModePlus.DiscardStaged()
    end
end

function EM.Init()
    if initialized then return true end
    local mgr, dialog = EditModeManagerFrame, EditModeSystemSettingsDialog
    if not mgr or not dialog then return false end
    initialized = true

    local function hook(target, method, fn)
        if type(target[method]) == "function" then hooksecurefunc(target, method, fn) end
    end

    -- Selection
    hook(dialog, "AttachToSystemFrame", function(_, systemFrame) EM.ShowDocked(systemFrame) end)
    dialog:HookScript("OnHide", function()
        if mode == "docked" then EM.HidePanel() end
    end)
    dialog:HookScript("OnSizeChanged", function()
        if mode == "docked" and panel:IsShown() then Reposition() end
    end)
    -- Both windows can be dragged; re-check which side has room afterwards.
    dialog:HookScript("OnDragStop", function()
        if mode == "docked" and panel:IsShown() then Reposition() end
    end)
    mgr:HookScript("OnDragStop", function()
        if toolbar:IsShown() then PlaceToolbar() end
        if mode == "free" and panel:IsShown() then Reposition() end
    end)

    -- Layouts
    hook(mgr, "UpdateLayoutInfo", SyncProfile)

    hook(mgr, "RevertAllChanges", function(self)
        -- Exiting Edit Mode reverts too; that case is handled in OnExit.
        if SafeCall(self, "IsEditModeActive") then EditModePlus.DiscardStaged() end
    end)

    -- The dialog's own Revert Changes button reverts our edits to that system too.
    hook(mgr, "RevertSystemChanges", function(_, systemFrame)
        local path = EditModePlus.GetPath(systemFrame)
        if path then EditModePlus.RevertPath(path) end
    end)

    hook(mgr, "ShowNewLayoutDialog", function(_, layoutInfo)
        -- A new layout starts as a copy of the one it's made from, including
        -- unsaved EditModePlus changes when that's the active layout.
        local source = KeyForInfo(layoutInfo or ActiveLayoutInfo())
        if source == EditModePlus.GetProfileKey() then
            copyFrom = EditModePlus.CopyEntries(EditModePlus.GetEntries())
        else
            local profile = source and EditModePlus.db.profiles[source]
            copyFrom = EditModePlus.CopyEntries(profile and profile.entries)
        end
    end)
    hook(mgr, "MakeNewLayout", function(self, _, layoutType, layoutName)
        -- Only if Blizzard actually created it (it rejects invalid names).
        local created = false
        for _, info in ipairs(self.layoutInfo and self.layoutInfo.layouts or {}) do
            if info.layoutType == layoutType and info.layoutName == layoutName then created = true end
        end
        if copyFrom and created then
            EditModePlus.CopyProfile(copyFrom, EM.LayoutKey(layoutType, layoutName))
        end
        copyFrom = nil
    end)

    hook(mgr, "ShowRenameLayoutDialog", function(_, _, layoutInfo)
        renameFromKey = KeyForInfo(layoutInfo)
    end)
    hook(mgr, "RenameLayout", function(self, layoutIndex, layoutName)
        local info = self.layoutInfo and self.layoutInfo.layouts and self.layoutInfo.layouts[layoutIndex]
        if renameFromKey and info then
            EditModePlus.RenameProfile(renameFromKey, EM.LayoutKey(info.layoutType, layoutName))
        end
        renameFromKey = nil
    end)

    hook(mgr, "ShowDeleteLayoutDialog", function(_, _, layoutInfo)
        deleteKey = KeyForInfo(layoutInfo)
    end)
    hook(mgr, "DeleteLayout", function()
        if deleteKey then EditModePlus.DeleteProfile(deleteKey) end
        deleteKey = nil
    end)

    hook(mgr, "SetHasActiveChanges", SyncButtons)

    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("EditMode.Enter", OnEnter, EM)
        EventRegistry:RegisterCallback("EditMode.Exit", OnExit, EM)
        EventRegistry:RegisterCallback("EditMode.SavedLayouts", function() EditModePlus.CommitStaged() end, EM)
        EventRegistry:RegisterCallback("EditMode.NewLayoutCancel", function() copyFrom = nil end, EM)
    end

    -- The layout may already be loaded.
    if ActiveLayoutInfo() then SyncProfile() end
    if SafeCall(mgr, "IsEditModeActive") then OnEnter() end
    return true
end

EditModePlus.RegisterListener(function()
    RefreshPanel()
    SyncButtons()
end)

-- Blizzard_EditMode normally loads before EditModePlus; keep trying until it has.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event)
    if EM.Init() and ActiveLayoutInfo() then SyncProfile() end
    if event == "PLAYER_LOGIN" and initialized then self:UnregisterAllEvents() end
end)
