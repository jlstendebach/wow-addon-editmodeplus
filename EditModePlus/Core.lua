-- EditModePlus core: saved settings, applying them to frames/regions, and keeping
-- them applied when Blizzard's own code changes things back.
--
-- Every tracked object is identified by a "path": a global name followed by
-- parentKey steps, e.g. "MainActionBar.EndCaps.LeftEndCap". Paths survive
-- reloads because they never depend on table addresses.
--
-- Settings are kept per Edit Mode layout ("profile"). While Edit Mode is open,
-- edits are staged: they preview live, and Edit Mode's Save or Revert decides
-- whether they stick (see EditMode.lua).

local ADDON_NAME, ns = ...

local EditModePlus = {}
ns.EditModePlus = EditModePlus
_G.EditModePlus = EditModePlus

EditModePlus.STRATA = {
    "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG",
    "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP",
}
EditModePlus.LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY", "HIGHLIGHT" }
EditModePlus.MIN_LEVEL, EditModePlus.MAX_LEVEL = 0, 10000
EditModePlus.MIN_SUBLEVEL, EditModePlus.MAX_SUBLEVEL = -8, 7
-- How visible a "Hidden" object is while Edit Mode is open, so it can still
-- be found and selected.
EditModePlus.GHOST_ALPHA = 0.3
EditModePlus.FIELDS = { "visibility", "alpha", "strata", "level", "layer", "sublevel" }

local db                 -- EditModePlusDB once loaded
local loggedIn = false
local profileKey         -- key of the active layout's profile
local staged             -- edited copy of the active profile's entries, or nil
local editMode = false   -- Edit Mode is open
local pending = {}       -- path -> true while waiting for combat to end
local state = {}         -- object -> { orig = {}, touched = {} }
local pathOf = {}        -- object -> path
local hooked = {}        -- object -> true once hooks are installed
local busy = {}          -- object -> true while EditModePlus itself is changing it
local listeners = {}
local EMPTY = {}

-- Hidden objects are parented here. Blizzard can call Show() on them all it
-- likes; with a hidden parent they never become visible.
local Hider = CreateFrame("Frame", "EditModePlusHider", UIParent)
Hider:SetAllPoints(UIParent)
Hider:Hide()
EditModePlus.Hider = Hider

-- The version comes from the .toc so it only lives in one place.
do
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, version = pcall(getMetadata, ADDON_NAME, "Version")
    EditModePlus.VERSION = ok and type(version) == "string" and version or nil
end

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

function EditModePlus.Print(msg)
    print("|cff66ccffEdit Mode Plus|r: " .. tostring(msg))
end

function EditModePlus.Debug(msg)
    if db and db.debug then EditModePlus.Print("|cff999999" .. tostring(msg) .. "|r") end
end

-- Midnight-era clients can return "secret" values that addons may display but
-- not compare. Treat those as unknown.
local function Readable(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
EditModePlus.Readable = Readable

-- Calls obj:method(...) without ever raising; returns up to two readable values.
local function SafeCall(obj, method, ...)
    if type(obj) ~= "table" then return nil end
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, obj, ...)
    if not ok then return nil end
    return Readable(a), Readable(b)
end
EditModePlus.SafeCall = SafeCall

-- Calls a setter while marking the object busy so our own hooks ignore it.
local function Do(obj, method, ...)
    local fn = obj[method]
    if type(fn) ~= "function" then return false end
    busy[obj] = true
    local ok, err = pcall(fn, obj, ...)
    busy[obj] = nil
    if not ok then EditModePlus.Debug(method .. " failed: " .. tostring(err)) end
    return ok
end

local function CopyEntries(entries)
    local copy = {}
    for path, e in pairs(entries or EMPTY) do
        local c = {}
        for k, v in pairs(e) do c[k] = v end
        copy[path] = c
    end
    return copy
end
EditModePlus.CopyEntries = CopyEntries

local function SameEntry(a, b)
    a, b = a or EMPTY, b or EMPTY
    for _, k in ipairs(EditModePlus.FIELDS) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

local function SameEntries(a, b)
    a, b = a or EMPTY, b or EMPTY
    for path, e in pairs(a) do
        if not SameEntry(e, b[path]) then return false end
    end
    for path, e in pairs(b) do
        if not SameEntry(e, a[path]) then return false end
    end
    return true
end

local function IsEmptyEntry(e)
    for _, k in ipairs(EditModePlus.FIELDS) do
        if e[k] ~= nil then return false end
    end
    return true
end

local function Notify()
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i])
        if not ok then EditModePlus.Debug("listener failed: " .. tostring(err)) end
    end
end
EditModePlus.Notify = Notify

function EditModePlus.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

---------------------------------------------------------------------------
-- Identifying objects
---------------------------------------------------------------------------

-- "frame" for anything with a strata, "region" for textures and font strings.
function EditModePlus.GetKind(obj)
    if type(obj) ~= "table" then return nil end
    if type(obj.SetFrameStrata) == "function" then return "frame" end
    if type(obj.SetDrawLayer) == "function" then return "region" end
    return nil
end

function EditModePlus.Resolve(path)
    if type(path) ~= "string" or path == "" then return nil end
    local obj
    for part in path:gmatch("[^%.]+") do
        if obj == nil then
            obj = _G[part]
        else
            if type(obj) ~= "table" then return nil end
            local nextObj = rawget(obj, part)
            if nextObj == nil and tonumber(part) then
                nextObj = rawget(obj, tonumber(part))
            end
            obj = nextObj
        end
        if obj == nil then return nil end
    end
    if EditModePlus.GetKind(obj) then return obj end
    return nil
end

-- The real parent, even while EditModePlus has the object parked in the Hider.
function EditModePlus.GetParentOf(obj)
    local parent = SafeCall(obj, "GetParent")
    if parent == Hider then
        parent = state[obj] and state[obj].orig.parent
    end
    return parent
end

local function FindKey(parent, child)
    if type(parent) ~= "table" then return nil end
    local key = SafeCall(child, "GetParentKey")
    if type(key) == "string" and rawget(parent, key) == child then return key end
    for k, v in pairs(parent) do
        if v == child then
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
            if type(k) == "number" then return tostring(k) end
        end
    end
    return nil
end

-- Returns a stable path for obj, or nil if it has no name we can find again.
function EditModePlus.GetPath(obj)
    if type(obj) ~= "table" or SafeCall(obj, "IsForbidden") then return nil end
    if pathOf[obj] then return pathOf[obj] end

    local debugName = SafeCall(obj, "GetDebugName")
    if type(debugName) == "string" and EditModePlus.Resolve(debugName) == obj then
        return debugName
    end

    local parts, cur = {}, obj
    for _ = 1, 25 do
        local name = SafeCall(cur, "GetName")
        if type(name) == "string" and not name:find("%.") and _G[name] == cur then
            table.insert(parts, 1, name)
            local path = table.concat(parts, ".")
            if EditModePlus.Resolve(path) == obj then return path end
            return nil
        end
        local parent = EditModePlus.GetParentOf(cur)
        local key = parent and FindKey(parent, cur)
        if not key then return nil end
        table.insert(parts, 1, key)
        cur = parent
    end
    return nil
end

-- Live values for display. Uses the value Blizzard last set, not EditModePlus's
-- override, where EditModePlus has changed something.
function EditModePlus.Describe(obj)
    local s = state[obj]
    local orig = s and s.orig or EMPTY
    local touched = s and s.touched or EMPTY
    local d = {
        kind = EditModePlus.GetKind(obj),
        objectType = SafeCall(obj, "GetObjectType"),
        visible = SafeCall(obj, "IsVisible"),
    }
    if d.kind == "frame" then
        d.strata = touched.strata and orig.strata or SafeCall(obj, "GetFrameStrata")
        d.level = touched.level and orig.level or SafeCall(obj, "GetFrameLevel")
    elseif d.kind == "region" then
        if touched.layer then
            d.layer, d.sublevel = orig.layer, orig.sublevel
        else
            d.layer, d.sublevel = SafeCall(obj, "GetDrawLayer")
        end
    end
    d.alpha = touched.alpha and orig.alpha or SafeCall(obj, "GetAlpha")
    return d
end

---------------------------------------------------------------------------
-- Profiles (one per Edit Mode layout) and staging
---------------------------------------------------------------------------

local function Committed()
    local profile = profileKey and db and db.profiles[profileKey]
    return profile and profile.entries or EMPTY
end

-- The entries currently in effect: staged edits if any, else saved ones.
function EditModePlus.GetEntries()
    return staged or Committed()
end

function EditModePlus.GetEntry(path)
    return EditModePlus.GetEntries()[path]
end

function EditModePlus.GetProfileKey()
    return profileKey
end

function EditModePlus.HasUnsavedChanges()
    return staged ~= nil and not SameEntries(staged, Committed())
end

function EditModePlus.IsEditMode()
    return editMode
end

local function EnsureProfile(key, seed)
    local profile = db.profiles[key]
    if not profile then
        profile = { entries = CopyEntries(seed) }
        db.profiles[key] = profile
    end
    return profile
end
EditModePlus.EnsureProfile = EnsureProfile

-- Writes go to the staged copy while Edit Mode is open (or while unsaved
-- edits are waiting on a decision), otherwise straight to the profile.
local function WritableEntries()
    if editMode or staged then
        if not staged then staged = CopyEntries(Committed()) end
        return staged
    end
    if not profileKey then return nil end
    return EnsureProfile(profileKey).entries
end

local ApplyAll -- defined below

function EditModePlus.CommitStaged()
    if not staged then return end
    if profileKey then
        EnsureProfile(profileKey).entries = staged
    end
    staged = nil
    ApplyAll()
end

function EditModePlus.DiscardStaged()
    if not staged then return end
    staged = nil
    ApplyAll()
end

-- Switches to another layout's settings, creating them if needed.
function EditModePlus.SetProfile(key)
    if not db or key == nil or key == profileKey then return end
    if EditModePlus.HasUnsavedChanges() then
        EditModePlus.Print("Unsaved Edit Mode Plus changes were discarded because the layout changed.")
    end
    staged = nil
    EnsureProfile(key)
    profileKey = key
    ApplyAll()
end

function EditModePlus.CopyProfile(fromEntries, toKey)
    if not db or not toKey then return end
    db.profiles[toKey] = { entries = CopyEntries(fromEntries) }
    if toKey == profileKey then
        staged = nil
        ApplyAll()
    end
end

function EditModePlus.RenameProfile(fromKey, toKey)
    if not db or not fromKey or not toKey or fromKey == toKey then return end
    if db.profiles[fromKey] then
        db.profiles[toKey] = db.profiles[fromKey]
        db.profiles[fromKey] = nil
    end
    if profileKey == fromKey then profileKey = toKey end
    Notify()
end

function EditModePlus.DeleteProfile(key)
    if not db or not key then return end
    db.profiles[key] = nil
end

---------------------------------------------------------------------------
-- Applying settings
---------------------------------------------------------------------------

local function GetState(obj)
    local s = state[obj]
    if not s then
        s = { orig = {}, touched = {} }
        state[obj] = s
    end
    return s
end

-- Changing protected frames (action bars and friends) is blocked in combat.
local function IsLocked(obj)
    if not InCombatLockdown() then return false end
    if EditModePlus.GetKind(obj) == "frame" then
        return SafeCall(obj, "IsProtected") and true or false
    end
    local current = SafeCall(obj, "GetParent")
    local original = state[obj] and state[obj].orig.parent
    return (SafeCall(current, "IsProtected") or SafeCall(original, "IsProtected")) and true or false
end

local function ApplyVisibility(obj, s, e, kind)
    -- While Edit Mode is open, "Hidden" objects stay findable as a ghost.
    local hide = e.visibility == "hide" and not editMode
    if hide then
        if SafeCall(obj, "GetParent") ~= Hider then
            s.orig.parent = obj:GetParent()
            if kind == "frame" then
                s.orig.parkedStrata = SafeCall(obj, "GetFrameStrata")
                s.orig.parkedLevel = SafeCall(obj, "GetFrameLevel")
            end
            s.touched.parent = true
            Do(obj, "SetParent", Hider)
        end
    elseif s.touched.parent then
        if SafeCall(obj, "GetParent") == Hider then
            Do(obj, "SetParent", s.orig.parent)
            if kind == "frame" then
                -- Reparenting can shift strata/level; put them back unless overridden.
                if not e.strata and s.orig.parkedStrata then Do(obj, "SetFrameStrata", s.orig.parkedStrata) end
                if not e.level and s.orig.parkedLevel then Do(obj, "SetFrameLevel", s.orig.parkedLevel) end
            end
        end
        s.touched.parent = nil
    end

    if e.visibility == "show" and not SafeCall(obj, "IsShown") then
        Do(obj, "Show")
    end
end

-- EditModePlus's opacity multiplies whatever Blizzard sets, so Blizzard's own
-- opacity settings (unit frames, cast bar, etc.) keep working alongside it.
local function ApplyAlpha(obj, s, e)
    local factor = e.alpha or 1
    if editMode then
        -- Keep everything findable while Edit Mode is open.
        if e.visibility == "hide" then
            factor = EditModePlus.GHOST_ALPHA
        else
            factor = math.max(factor, EditModePlus.GHOST_ALPHA)
        end
    end
    if factor ~= 1 then
        if not s.touched.alpha then
            s.orig.alpha = SafeCall(obj, "GetAlpha") or 1
            s.touched.alpha = true
        end
        local want = (s.orig.alpha or 1) * factor
        local cur = SafeCall(obj, "GetAlpha")
        if not cur or math.abs(cur - want) > 0.004 then
            Do(obj, "SetAlpha", want)
        end
    elseif s.touched.alpha then
        Do(obj, "SetAlpha", s.orig.alpha or 1)
        s.touched.alpha = nil
    end
end

local function ApplyStrata(obj, s, e)
    if e.strata then
        if not s.touched.strata then
            s.orig.strata = SafeCall(obj, "GetFrameStrata")
            s.orig.fixedStrata = SafeCall(obj, "HasFixedFrameStrata")
            s.touched.strata = true
        end
        if SafeCall(obj, "GetFrameStrata") ~= e.strata then
            Do(obj, "SetFixedFrameStrata", false)
            Do(obj, "SetFrameStrata", e.strata)
        end
        -- Fixed strata stops a parent's strata change from overwriting ours.
        Do(obj, "SetFixedFrameStrata", true)
    elseif s.touched.strata then
        Do(obj, "SetFixedFrameStrata", false)
        if s.orig.strata then Do(obj, "SetFrameStrata", s.orig.strata) end
        Do(obj, "SetFixedFrameStrata", s.orig.fixedStrata and true or false)
        s.touched.strata = nil
    end
end

local function ApplyLevel(obj, s, e)
    if e.level then
        if not s.touched.level then
            s.orig.level = SafeCall(obj, "GetFrameLevel")
            s.orig.fixedLevel = SafeCall(obj, "HasFixedFrameLevel")
            s.touched.level = true
        end
        if SafeCall(obj, "GetFrameLevel") ~= e.level then
            Do(obj, "SetFixedFrameLevel", false)
            Do(obj, "SetFrameLevel", e.level)
        end
        Do(obj, "SetFixedFrameLevel", true)
    elseif s.touched.level then
        Do(obj, "SetFixedFrameLevel", false)
        if s.orig.level then Do(obj, "SetFrameLevel", s.orig.level) end
        Do(obj, "SetFixedFrameLevel", s.orig.fixedLevel and true or false)
        s.touched.level = nil
    end
end

local function ApplyLayer(obj, s, e)
    if e.layer or e.sublevel then
        if not s.touched.layer then
            s.orig.layer, s.orig.sublevel = SafeCall(obj, "GetDrawLayer")
            s.touched.layer = true
        end
        local layer = e.layer or s.orig.layer or "ARTWORK"
        local sublevel = e.sublevel or s.orig.sublevel or 0
        local curLayer, curSublevel = SafeCall(obj, "GetDrawLayer")
        if curLayer ~= layer or curSublevel ~= sublevel then
            Do(obj, "SetDrawLayer", layer, sublevel)
        end
    elseif s.touched.layer then
        if s.orig.layer then Do(obj, "SetDrawLayer", s.orig.layer, s.orig.sublevel or 0) end
        s.touched.layer = nil
    end
end

local Hook -- defined below

-- Applies (or, for an untracked path, undoes) settings. Returns a status:
-- "ok", "missing" (not created yet), "pending" (waiting on combat), "forbidden".
function EditModePlus.Apply(path)
    if not db then return "missing" end
    local obj = EditModePlus.Resolve(path)
    if not obj then return "missing" end
    if SafeCall(obj, "IsForbidden") then return "forbidden" end

    local e = EditModePlus.GetEntries()[path]
    if not e and not state[obj] then return "ok" end

    pathOf[obj] = path
    if e then Hook(obj) end

    if IsLocked(obj) then
        pending[path] = true
        return "pending"
    end
    pending[path] = nil

    local kind = EditModePlus.GetKind(obj)
    local s = GetState(obj)
    e = e or EMPTY
    ApplyVisibility(obj, s, e, kind)
    ApplyAlpha(obj, s, e)
    if kind == "frame" then
        ApplyStrata(obj, s, e)
        ApplyLevel(obj, s, e)
    else
        ApplyLayer(obj, s, e)
    end
    return "ok"
end

-- Re-applies everything in effect and undoes anything no longer in effect.
function ApplyAll()
    if not db then return end
    local paths = {}
    for path in pairs(EditModePlus.GetEntries()) do paths[path] = true end
    for _, path in pairs(pathOf) do paths[path] = true end
    for path in pairs(paths) do EditModePlus.Apply(path) end
    Notify()
end
EditModePlus.ApplyAll = ApplyAll

local function ApplyPending()
    local paths = {}
    for path in pairs(pending) do paths[#paths + 1] = path end
    for _, path in ipairs(paths) do EditModePlus.Apply(path) end
    if #paths > 0 then Notify() end
end

function EditModePlus.SetEditMode(active)
    active = active and true or false
    if editMode == active then return end
    editMode = active
    ApplyAll()
end

---------------------------------------------------------------------------
-- Re-applying after outside changes
---------------------------------------------------------------------------

local function Reapply(obj)
    local path = pathOf[obj]
    if path and EditModePlus.GetEntries()[path] then EditModePlus.Apply(path) end
end

function Hook(obj)
    if hooked[obj] then return end
    hooked[obj] = true

    local function hook(method, fn)
        if type(obj[method]) == "function" then hooksecurefunc(obj, method, fn) end
    end

    hook("SetParent", function(self, parent)
        if busy[self] then return end
        local s = state[self]
        -- Blizzard moved it somewhere new; that's the parent to restore later.
        if s and s.touched.parent and parent ~= Hider then s.orig.parent = parent end
        Reapply(self)
    end)

    local function onVisibility(self)
        if busy[self] then return end
        local e = EditModePlus.GetEntries()[pathOf[self] or ""]
        if e and e.visibility == "show" then Reapply(self) end
    end
    hook("Hide", onVisibility)
    hook("SetShown", onVisibility)

    hook("SetAlpha", function(self, alpha)
        if busy[self] then return end
        local s = state[self]
        if s and s.touched.alpha and Readable(alpha) then s.orig.alpha = alpha end
        Reapply(self)
    end)

    if EditModePlus.GetKind(obj) == "frame" then
        hook("SetFrameStrata", function(self, strata)
            if busy[self] then return end
            local s = state[self]
            if s and s.touched.strata and Readable(strata) then s.orig.strata = strata end
            Reapply(self)
        end)
        hook("SetFrameLevel", function(self, level)
            if busy[self] then return end
            local s = state[self]
            if s and s.touched.level and Readable(level) then s.orig.level = level end
            Reapply(self)
        end)
    else
        hook("SetDrawLayer", function(self, layer, sublevel)
            if busy[self] then return end
            local s = state[self]
            if s and s.touched.layer and Readable(layer) then
                s.orig.layer, s.orig.sublevel = layer, Readable(sublevel) or 0
            end
            Reapply(self)
        end)
    end
end

---------------------------------------------------------------------------
-- Public editing API (used by the UI)
---------------------------------------------------------------------------

function EditModePlus.GetStatus(path)
    if pending[path] then return "pending" end
    if not EditModePlus.Resolve(path) then return "missing" end
    return "ok"
end

function EditModePlus.GetSortedPaths()
    local paths = {}
    for path in pairs(EditModePlus.GetEntries()) do paths[#paths + 1] = path end
    table.sort(paths, function(a, b) return a:lower() < b:lower() end)
    return paths
end

-- Sets one field (nil clears it). An entry with nothing set is removed.
function EditModePlus.Set(path, key, value)
    local entries = WritableEntries()
    if not entries then
        EditModePlus.Print("Settings aren't ready yet. Try again in a moment.")
        return
    end
    local e = entries[path]
    if not e then
        if value == nil then return end
        e = {}
        entries[path] = e
    end
    e[key] = value
    if IsEmptyEntry(e) then entries[path] = nil end
    if EditModePlus.Apply(path) == "pending" then
        EditModePlus.Print("That frame is locked during combat. The change will apply when combat ends.")
    end
    Notify()
end

function EditModePlus.Clear(path)
    local entries = WritableEntries()
    if not entries or not entries[path] then return end
    entries[path] = nil
    EditModePlus.Apply(path)
    Notify()
end

-- Puts one object's staged settings back to what's saved.
function EditModePlus.RevertPath(path)
    if not staged then return end
    local saved = Committed()[path]
    if saved then
        local copy = {}
        for k, v in pairs(saved) do copy[k] = v end
        staged[path] = copy
    else
        staged[path] = nil
    end
    EditModePlus.Apply(path)
    Notify()
end

function EditModePlus.ClearAll()
    local entries = WritableEntries()
    if not entries then return end
    for path in pairs(entries) do entries[path] = nil end
    ApplyAll()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")

local function Register(event)
    pcall(events.RegisterEvent, events, event)
end

Register("ADDON_LOADED")
Register("PLAYER_LOGIN")
Register("PLAYER_ENTERING_WORLD")
Register("PLAYER_REGEN_ENABLED")

local function LoadDB()
    EditModePlusDB = EditModePlusDB or {}
    db = EditModePlusDB
    db.profiles = db.profiles or {}
    db.version = 1
    EditModePlus.db = db
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            LoadDB()
        elseif loggedIn then
            -- Load-on-demand addons create frames late; catch them as they appear.
            ApplyAll()
        end
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        ApplyAll()
        -- Some Blizzard frames finish setting themselves up a moment after login.
        C_Timer.After(1, ApplyAll)
        C_Timer.After(5, function()
            -- No Edit Mode layout after 5 seconds: fall back to one set of settings.
            if not profileKey then EditModePlus.SetProfile("default") end
            ApplyAll()
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0, ApplyAll)
    elseif event == "PLAYER_REGEN_ENABLED" then
        ApplyPending()
    end
end)
