-- EditModePlus picker: a full-screen overlay that outlines whatever is under the
-- cursor. Mouse wheel cycles through everything stacked at that spot (smallest
-- first), left-click chooses, right-click or Escape cancels.

local _, ns = ...
local EditModePlus = ns.EditModePlus
local SafeCall = EditModePlus.SafeCall

local Picker = {}
EditModePlus.Picker = Picker

local CACHE_SECONDS = 2
local UPDATE_SECONDS = 0.05

local cache, cacheTime = {}, 0
local stack, index = {}, 1
local lastX, lastY
local onPick, onDone
local flashToken = 0
local highlighted -- object outlined until ClearHighlight

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local overlay = CreateFrame("Frame", "EditModePlusPicker", UIParent)
overlay.__editModePlusUI = true
overlay:SetAllPoints(UIParent)
overlay:SetFrameStrata("TOOLTIP")
overlay:SetFrameLevel(9000)
overlay:EnableMouse(true)
overlay:EnableMouseWheel(true)
overlay:EnableKeyboard(true)
overlay:Hide()

local tint = overlay:CreateTexture(nil, "BACKGROUND")
tint:SetAllPoints()
tint:SetColorTexture(0, 0, 0, 0.12)

local box = CreateFrame("Frame", nil, UIParent)
box.__editModePlusUI = true
box:SetFrameStrata("TOOLTIP")
box:SetFrameLevel(9500)
box:Hide()

local fill = box:CreateTexture(nil, "BACKGROUND")
fill:SetAllPoints()
fill:SetColorTexture(0.25, 0.75, 1, 0.18)

local function Edge(point1, point2, horizontal)
    local t = box:CreateTexture(nil, "BORDER")
    t:SetColorTexture(0.35, 0.85, 1, 0.95)
    t:SetPoint(point1)
    t:SetPoint(point2)
    if horizontal then t:SetHeight(2) else t:SetWidth(2) end
end
Edge("TOPLEFT", "TOPRIGHT", true)
Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
Edge("TOPLEFT", "BOTTOMLEFT", false)
Edge("TOPRIGHT", "BOTTOMRIGHT", false)

local tip = CreateFrame("Frame", nil, overlay)
tip:SetFrameLevel(9800)
tip:SetSize(10, 10)
local tipBg = tip:CreateTexture(nil, "BACKGROUND")
tipBg:SetAllPoints()
tipBg:SetColorTexture(0.03, 0.03, 0.05, 0.92)
local tipText = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tipText:SetPoint("TOPLEFT", 8, -6)
tipText:SetJustifyH("LEFT")
tipText:SetSpacing(2)

---------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------

local function SafeRect(obj)
    local fn = obj.GetRect
    if type(fn) ~= "function" then return nil end
    local ok, l, b, w, h = pcall(fn, obj)
    if not ok then return nil end
    l, b, w, h = EditModePlus.Readable(l), EditModePlus.Readable(b), EditModePlus.Readable(w), EditModePlus.Readable(h)
    if type(l) ~= "number" or type(b) ~= "number" or type(w) ~= "number" or type(h) ~= "number" then
        return nil
    end
    return l, b, w, h
end

local function EffectiveScale(obj)
    local scale = SafeCall(obj, "GetEffectiveScale")
    if not scale then
        scale = SafeCall(SafeCall(obj, "GetParent"), "GetEffectiveScale")
    end
    return scale or 1
end

local function PlaceBox(obj)
    local l, b, w, h = SafeRect(obj)
    if not l then
        box:Hide()
        return false
    end
    local scale = EffectiveScale(obj) / UIParent:GetEffectiveScale()
    box:ClearAllPoints()
    box:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l * scale, b * scale)
    box:SetSize(math.max(w * scale, 2), math.max(h * scale, 2))
    box:Show()
    return true
end

---------------------------------------------------------------------------
-- Finding candidates
---------------------------------------------------------------------------

-- Skips EditModePlus's own windows and Edit Mode's chrome: its dialogs and the
-- blue selection boxes it draws over every system.
local function IsExcluded(obj)
    local cur = obj
    for _ = 1, 60 do
        if type(cur) ~= "table" then return false end
        if rawget(cur, "__editModePlusUI") then return true end
        local name = SafeCall(cur, "GetName")
        if type(name) == "string" and name:find("^EditMode") then return true end
        local parent = SafeCall(cur, "GetParent")
        if type(parent) == "table" and rawget(parent, "Selection") == cur and rawget(parent, "system") ~= nil then
            return true
        end
        cur = parent
    end
    return false
end

local function Consider(obj)
    if not SafeCall(obj, "IsVisible") then return end
    local alpha = SafeCall(obj, "GetEffectiveAlpha")
    if alpha and alpha <= 0.01 then return end
    local _, _, w, h = SafeRect(obj)
    if not w or w <= 0 or h <= 0 then return end
    local scale = EffectiveScale(obj)
    cache[#cache + 1] = { obj = obj, area = w * h * scale * scale }
end

local function PackRegions(frame)
    return { frame:GetRegions() }
end

local function BuildCache()
    wipe(cache)
    cacheTime = GetTime()
    local frame = EnumerateFrames()
    while frame do
        if frame ~= UIParent and frame ~= WorldFrame
            and not SafeCall(frame, "IsForbidden")
            and SafeCall(frame, "IsVisible")
            and not IsExcluded(frame) then
            Consider(frame)
            -- Textures can hang outside their frame (the action bar gryphons
            -- do), so regions are checked on their own, not via the frame's rect.
            local ok, regions = pcall(PackRegions, frame)
            if ok then
                for i = 1, #regions do
                    local objectType = SafeCall(regions[i], "GetObjectType")
                    if objectType == "Texture" or objectType == "FontString" then
                        Consider(regions[i])
                    end
                end
            end
        end
        frame = EnumerateFrames(frame)
    end
end

local function UpdateStack()
    local previous = stack[index] and stack[index].obj
    wipe(stack)
    for i = 1, #cache do
        local c = cache[i]
        if SafeCall(c.obj, "IsMouseOver") and SafeCall(c.obj, "IsVisible") then
            stack[#stack + 1] = c
        end
    end
    table.sort(stack, function(a, b) return a.area < b.area end)
    index = 1
    -- Keep a wheel-chosen candidate selected while the cursor stays on it.
    if previous then
        for i = 1, #stack do
            if stack[i].obj == previous then
                index = i
                break
            end
        end
    end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function DepthText(obj)
    local d = EditModePlus.Describe(obj)
    if d.kind == "frame" then
        return ("%s · strata %s · level %s"):format(d.objectType or "Frame", d.strata or "?", d.level or "?")
    end
    return ("%s · layer %s %s"):format(d.objectType or "Region", d.layer or "?", d.sublevel or "?")
end

local function PlaceTip()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    tip:ClearAllPoints()
    -- Flip to the other side of the cursor near screen edges.
    local right = x + 24 + tip:GetWidth() > UIParent:GetWidth()
    local top = y - 24 - tip:GetHeight() < 0
    local point = (top and "BOTTOM" or "TOP") .. (right and "RIGHT" or "LEFT")
    tip:SetPoint(point, UIParent, "BOTTOMLEFT", x + (right and -24 or 24), y + (top and 24 or -24))
end

local function Render()
    local c = stack[index]
    local lines = {}
    if c then
        PlaceBox(c.obj)
        local path = EditModePlus.GetPath(c.obj)
        if path then
            lines[1] = "|cff66ccff" .. path .. "|r"
        else
            local name = SafeCall(c.obj, "GetDebugName") or "unnamed"
            lines[1] = "|cffff6666" .. name .. " (no stable name, can't be saved)|r"
        end
        lines[2] = DepthText(c.obj)
        lines[3] = ("|cffaaaaaa%d of %d here · wheel to cycle · click to choose|r"):format(index, #stack)
    else
        box:Hide()
        lines[1] = "|cffaaaaaaNothing to pick here|r"
    end
    lines[#lines + 1] = "|cffaaaaaaRight-click or Esc to cancel|r"
    tipText:SetText(table.concat(lines, "\n"))
    tip:SetSize(tipText:GetStringWidth() + 16, tipText:GetStringHeight() + 12)
    tip:Show()
    PlaceTip()
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

overlay:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < UPDATE_SECONDS then return end
    self.elapsed = 0
    if GetTime() - cacheTime > CACHE_SECONDS then BuildCache() end
    local x, y = GetCursorPosition()
    if x ~= lastX or y ~= lastY then
        lastX, lastY = x, y
        UpdateStack()
        Render()
    end
end)

overlay:SetScript("OnMouseWheel", function(_, delta)
    if #stack == 0 then return end
    index = index - delta
    if index < 1 then index = #stack elseif index > #stack then index = 1 end
    Render()
end)

overlay:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then
        Picker:Stop()
        return
    end
    local c = stack[index]
    if not c then return end
    local path = EditModePlus.GetPath(c.obj)
    if not path then
        EditModePlus.Print("That object has no stable name, so its settings couldn't be found again after a reload. Try the wheel to pick its parent instead.")
        return
    end
    local callback = onPick
    Picker:Stop()
    if callback then callback(path) end
end)

overlay:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false)
        Picker:Stop()
    else
        self:SetPropagateKeyboardInput(true)
    end
end)

overlay:SetScript("OnHide", function()
    if highlighted then PlaceBox(highlighted) else box:Hide() end
    tip:Hide()
    wipe(stack)
    wipe(cache)
    local callback = onDone
    onPick, onDone = nil, nil
    if callback then callback() end
end)

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

-- pickCallback(path) runs when something is chosen; doneCallback() runs
-- whenever picking ends, chosen or cancelled.
function Picker:Start(pickCallback, doneCallback)
    if InCombatLockdown() then
        EditModePlus.Print("Picking is disabled during combat.")
        if doneCallback then doneCallback() end
        return
    end
    onPick, onDone = pickCallback, doneCallback
    index, lastX, lastY = 1, nil, nil
    wipe(stack)
    BuildCache()
    overlay:Show()
end

function Picker:Stop()
    if overlay:IsShown() then overlay:Hide() end
end

-- Path of the candidate under the cursor (for tests and debugging).
function Picker:Current()
    local c = stack[index]
    return c and (EditModePlus.GetPath(c.obj) or SafeCall(c.obj, "GetDebugName"))
end

function Picker:IsActive()
    return overlay:IsShown()
end

-- Briefly outlines an object, e.g. from the settings window.
function Picker:Flash(obj)
    if not obj or not SafeCall(obj, "IsVisible") or not PlaceBox(obj) then
        EditModePlus.Print("That isn't visible on screen right now.")
        return
    end
    flashToken = flashToken + 1
    local token = flashToken
    C_Timer.After(1.5, function()
        if token == flashToken and not overlay:IsShown() then
            if highlighted then PlaceBox(highlighted) else box:Hide() end
        end
    end)
end

-- Keeps an object outlined, like Edit Mode's own selection box.
function Picker:Highlight(obj)
    highlighted = obj
    flashToken = flashToken + 1
    if not obj or not PlaceBox(obj) then box:Hide() end
end

function Picker:ClearHighlight()
    highlighted = nil
    flashToken = flashToken + 1
    if not overlay:IsShown() then box:Hide() end
end

function Picker:RefreshHighlight()
    if highlighted and not overlay:IsShown() then PlaceBox(highlighted) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function()
    if Picker:IsActive() then
        Picker:Stop()
        EditModePlus.Print("Picking stopped because you entered combat.")
    end
end)
