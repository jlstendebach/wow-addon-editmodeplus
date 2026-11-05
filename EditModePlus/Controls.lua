-- EditModePlus controls: the block of settings for one frame or texture
-- (visibility, opacity, strata/level or draw layer). Used by both the Edit Mode
-- panel and the overview window, styled after Edit Mode's own settings rows.

local _, ns = ...
local EditModePlus = ns.EditModePlus
local SafeCall = EditModePlus.SafeCall

local Controls = {}
EditModePlus.Controls = Controls

Controls.WIDTH = 343
local LABEL_WIDTH = 100
local CONTROL_WIDTH = 200
local ROW_HEIGHT = 32
local DEFAULT = "default"

local function Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function Label(parent, fontObject, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlightMedium")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end
Controls.Label = Label

local function Button(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height or 22)
    b:SetText(text)
    return b
end
Controls.Button = Button

local function Row(parent, labelText)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(Controls.WIDTH, ROW_HEIGHT)
    row.label = Label(row, "GameFontHighlightMedium", labelText)
    row.label:SetWidth(LABEL_WIDTH)
    row.label:SetPoint("LEFT")
    return row
end

-- Edit Mode style dropdown. options() returns { {value=, text=}, ... }.
local function Dropdown(row, options, getValue, setValue)
    local dd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    dd:SetWidth(CONTROL_WIDTH)
    dd:SetPoint("LEFT", row.label, "RIGHT", 5, 0)
    if dd.SetupMenu then
        dd:SetupMenu(function(_, root)
            for _, opt in ipairs(options()) do
                root:CreateRadio(opt.text,
                    function() return getValue() == opt.value end,
                    function() setValue(opt.value) end)
            end
        end)
    end
    function dd:Refresh()
        if self.GenerateMenu then self:GenerateMenu() end
    end
    return dd
end

-- Edit Mode style slider; falls back to - value + steppers if the template
-- isn't available.
local function Slider(row, minValue, maxValue, step, format, onChange)
    local quiet = false
    local ok, s = pcall(CreateFrame, "Frame", nil, row, "MinimalSliderWithSteppersTemplate")
    local Mixin = MinimalSliderWithSteppersMixin
    if ok and s and type(s.Init) == "function" and Mixin and Mixin.Event and Mixin.Label then
        s:SetSize(CONTROL_WIDTH, ROW_HEIGHT)
        s:SetPoint("LEFT", row.label, "RIGHT", 5, 0)
        local formatters = {}
        if CreateMinimalSliderFormatter then
            formatters[Mixin.Label.Right] = CreateMinimalSliderFormatter(Mixin.Label.Right, format)
        end
        s:Init(minValue, minValue, maxValue, (maxValue - minValue) / step, formatters)
        s:RegisterCallback(Mixin.Event.OnValueChanged, function(_, value)
            if not quiet then onChange(math.floor(value / step + 0.5) * step) end
        end, s)
        function s:SetValueQuiet(value)
            quiet = true
            self:SetValue(value)
            quiet = false
        end
        return s
    end

    local f = CreateFrame("Frame", nil, row)
    f:SetSize(CONTROL_WIDTH, ROW_HEIGHT)
    f:SetPoint("LEFT", row.label, "RIGHT", 5, 0)
    local value = minValue
    local text = Label(f, "GameFontHighlight")
    text:SetPoint("CENTER")
    local minus = Button(f, "-", 26)
    minus:SetPoint("LEFT")
    local plus = Button(f, "+", 26)
    plus:SetPoint("RIGHT")
    local function bump(sign)
        local amount = IsShiftKeyDown() and step * 5 or step
        onChange(Clamp(value + sign * amount, minValue, maxValue))
    end
    minus:SetScript("OnClick", function() bump(-1) end)
    plus:SetScript("OnClick", function() bump(1) end)
    function f:SetValueQuiet(v)
        value = v
        text:SetText(format(v))
    end
    return f
end

---------------------------------------------------------------------------
-- The control block
---------------------------------------------------------------------------

local VISIBILITY = {
    { value = DEFAULT, text = "Default" },
    { value = "hide", text = "Hidden" },
    { value = "show", text = "Always shown" },
}

local function PercentText(v) return ("%d%%"):format(v) end

-- onSelectPath(path) is called when the block asks to edit another object
-- (its parent frame).
function Controls.Create(parent, onSelectPath)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(Controls.WIDTH, 1)
    local path

    local function Entry() return path and EditModePlus.GetEntry(path) or {} end
    local function Obj() return path and EditModePlus.Resolve(path) end
    local function Live() local o = Obj(); return o and EditModePlus.Describe(o) or {} end
    local function Set(key, value)
        if path then EditModePlus.Set(path, key, value) end
    end

    -- Visibility
    local visRow = Row(c, "Visibility")
    local visDropdown = Dropdown(visRow,
        function() return VISIBILITY end,
        function() return Entry().visibility or DEFAULT end,
        function(v) Set("visibility", v ~= DEFAULT and v or nil) end)

    -- Opacity
    local alphaRow = Row(c, "Opacity")
    local alphaSlider = Slider(alphaRow, 0, 100, 5, PercentText, function(v)
        local alpha = v / 100
        Set("alpha", alpha < 1 and alpha or nil)
    end)

    -- Strata (frames)
    local strataRow = Row(c, "Strata")
    local strataDropdown = Dropdown(strataRow,
        function()
            local opts = { { value = DEFAULT, text = ("Default (%s)"):format(Live().strata or "?") } }
            for _, s in ipairs(EditModePlus.STRATA) do opts[#opts + 1] = { value = s, text = s } end
            return opts
        end,
        function() return Entry().strata or DEFAULT end,
        function(v) Set("strata", v ~= DEFAULT and v or nil) end)

    -- Frame level (frames)
    local levelRow = Row(c, "Frame level")
    local levelMinus = Button(levelRow, "-", 26)
    levelMinus:SetPoint("LEFT", levelRow.label, "RIGHT", 5, 0)
    local levelBox = CreateFrame("EditBox", nil, levelRow, "InputBoxTemplate")
    levelBox:SetSize(60, 20)
    levelBox:SetAutoFocus(false)
    levelBox:SetJustifyH("CENTER")
    levelBox:SetPoint("LEFT", levelMinus, "RIGHT", 10, 0)
    local levelPlus = Button(levelRow, "+", 26)
    levelPlus:SetPoint("LEFT", levelBox, "RIGHT", 6, 0)
    local levelReset = Button(levelRow, "Default", 70)
    levelReset:SetPoint("LEFT", levelPlus, "RIGHT", 8, 0)

    local function SetLevel(v)
        Set("level", Clamp(math.floor(v + 0.5), EditModePlus.MIN_LEVEL, EditModePlus.MAX_LEVEL))
    end
    local function StepLevel(sign)
        local current = Entry().level or Live().level or 0
        SetLevel(current + sign * (IsShiftKeyDown() and 10 or 1))
    end
    levelMinus:SetScript("OnClick", function() StepLevel(-1) end)
    levelPlus:SetScript("OnClick", function() StepLevel(1) end)
    levelReset:SetScript("OnClick", function() Set("level", nil) end)
    levelBox:SetScript("OnEnterPressed", function(self)
        local n = tonumber(self:GetText())
        self:ClearFocus()
        if n then SetLevel(n) else c:Refresh() end
    end)
    levelBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        c:Refresh()
    end)

    -- Draw layer (textures)
    local layerRow = Row(c, "Draw layer")
    local layerDropdown = Dropdown(layerRow,
        function()
            local opts = { { value = DEFAULT, text = ("Default (%s)"):format(Live().layer or "?") } }
            for _, l in ipairs(EditModePlus.LAYERS) do opts[#opts + 1] = { value = l, text = l } end
            return opts
        end,
        function() return Entry().layer or DEFAULT end,
        function(v) Set("layer", v ~= DEFAULT and v or nil) end)

    -- Sublevel (textures)
    local sublevelRow = Row(c, "Sublevel")
    local sublevelSlider = Slider(sublevelRow, EditModePlus.MIN_SUBLEVEL, EditModePlus.MAX_SUBLEVEL, 1, tostring, function(v)
        -- Back at Blizzard's own value means no override.
        Set("sublevel", v ~= Live().sublevel and v or nil)
    end)

    local hint = Label(c, "GameFontHighlightSmall")
    hint:SetWidth(Controls.WIDTH)
    hint:SetTextColor(0.65, 0.65, 0.65)

    local parentButton = Button(c, "Edit its parent frame", 170)
    parentButton:SetScript("OnClick", function()
        local obj = Obj()
        local parentObj = obj and EditModePlus.GetParentOf(obj)
        local parentPath = parentObj and EditModePlus.GetPath(parentObj)
        if parentPath and onSelectPath then
            onSelectPath(parentPath)
        else
            EditModePlus.Print("Its parent frame has no stable name, so it can't be saved.")
        end
    end)

    local allRows = { visRow, alphaRow, strataRow, levelRow, layerRow, sublevelRow }

    -- Shows the rows that apply and stacks them; sets the block's height.
    local function Layout(rows, showParentButton)
        for _, r in ipairs(allRows) do r:Hide() end
        local y = 0
        for _, r in ipairs(rows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -y)
            r:Show()
            y = y + ROW_HEIGHT + 2
        end
        hint:ClearAllPoints()
        hint:SetPoint("TOPLEFT", 0, -(y + 4))
        y = y + 8 + (hint:GetStringHeight() or 24)
        parentButton:ClearAllPoints()
        parentButton:SetShown(showParentButton)
        if showParentButton then
            parentButton:SetPoint("TOPLEFT", 0, -(y + 6))
            y = y + 32
        end
        c:SetHeight(y)
    end

    function c:SetTarget(newPath)
        path = newPath
        self:Refresh()
    end

    function c:GetTarget()
        return path
    end

    function c:Refresh()
        local e, obj, live = Entry(), Obj(), Live()
        local kind = live.kind or ((e.layer or e.sublevel) and "region" or "frame")

        visDropdown:Refresh()
        alphaSlider:SetValueQuiet(math.floor((e.alpha or 1) * 100 + 0.5))

        local notes = {}
        if kind == "frame" then
            strataDropdown:Refresh()
            if not levelBox:HasFocus() then
                levelBox:SetText(tostring(e.level or live.level or ""))
                if e.level then levelBox:SetTextColor(1, 1, 1) else levelBox:SetTextColor(0.6, 0.6, 0.6) end
            end
            levelReset:SetEnabled(e.level ~= nil)
            notes[#notes + 1] = "Strata decides what draws on top. Frame level only orders frames within the same strata."
        else
            layerDropdown:Refresh()
            sublevelSlider:SetValueQuiet(e.sublevel or live.sublevel or 0)
            notes[#notes + 1] = "Draw layer only orders this texture within its own frame. To move it behind other frames, edit its parent frame's strata."
        end
        if EditModePlus.IsEditMode() then
            local floor = math.floor(EditModePlus.GHOST_ALPHA * 100 + 0.5)
            if e.visibility == "hide" then
                notes[#notes + 1] = ("|cffffd100Hidden. Shown at %d%% while Edit Mode is open so you can find it.|r"):format(floor)
            elseif e.alpha and e.alpha < EditModePlus.GHOST_ALPHA then
                notes[#notes + 1] = ("|cffffd100Shown at %d%% while Edit Mode is open so you can find it.|r"):format(floor)
            end
        end
        if path and not obj then
            notes[#notes + 1] = "|cffff8040Not loaded right now. Settings apply as soon as it appears.|r"
        elseif path and EditModePlus.GetStatus(path) == "pending" then
            notes[#notes + 1] = "|cffffd100Locked during combat. Changes apply when combat ends.|r"
        end
        hint:SetText(table.concat(notes, "\n"))

        if kind == "frame" then
            Layout({ visRow, alphaRow, strataRow, levelRow }, false)
        else
            Layout({ visRow, alphaRow, layerRow, sublevelRow }, obj ~= nil)
        end
    end

    Layout({ visRow, alphaRow, strataRow, levelRow }, false)
    return c
end
