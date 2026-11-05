-- Minimal WoW client stub: enough of the frame/region model to exercise EditModePlus.
local stub = {}
_G.__stub = stub

local allFrames = {}
local eventFrames = {}
local timers = {}
stub.combat = false
stub.cursor = { 0, 0 }
stub.blocked = {}

local Object = {}
local FrameMethods = {}
local RegionMethods = {}
local FrameMT = { __index = function(t, k) local v = FrameMethods[k]; if v ~= nil then return v end return Object[k] end }
local RegionMT = { __index = function(t, k) local v = RegionMethods[k]; if v ~= nil then return v end return Object[k] end }

local function new(kind, objType, name, parent)
  local o = setmetatable({}, kind == "frame" and FrameMT or RegionMT)
  rawset(o, "__kind", kind)
  rawset(o, "__type", objType)
  rawset(o, "__name", name)
  rawset(o, "__shown", true)
  rawset(o, "__alpha", 1)
  rawset(o, "__rect", { 0, 0, 100, 20 })
  rawset(o, "__scripts", {})
  rawset(o, "__regions", {})
  rawset(o, "__protected", false)
  if kind == "frame" then
    rawset(o, "__strata", parent and parent.__strata or "MEDIUM")
    rawset(o, "__level", parent and (parent.__level + 1) or 0)
    allFrames[#allFrames + 1] = o
  else
    rawset(o, "__layer", "ARTWORK")
    rawset(o, "__sub", 0)
  end
  rawset(o, "__parent", parent)
  if name then _G[name] = o end
  return o
end
stub.new = new

local function protectedCheck(self, what)
  if stub.combat and self.__protected then
    stub.blocked[#stub.blocked + 1] = what
    error("ADDON_ACTION_BLOCKED " .. what)
  end
end

function Object:GetObjectType() return self.__type end
function Object:GetName() return self.__name end
function Object:GetDebugName()
  if self.__name then return self.__name end
  local p = self.__parent
  if p then
    for k, v in pairs(p) do if v == self and type(k) == "string" then return (p:GetDebugName()) .. "." .. k end end
    return (p:GetDebugName()) .. ".anon"
  end
  return "anon"
end
function Object:GetParentKey()
  local p = self.__parent
  if p then for k, v in pairs(p) do if v == self and type(k) == "string" then return k end end end
end
function Object:IsForbidden() return false end
function Object:IsProtected() return self.__protected, self.__protected end
function Object:GetParent() return self.__parent end
function Object:SetParent(p) protectedCheck(self, "SetParent"); self.__parent = p end
function Object:Show() protectedCheck(self, "Show"); local was = self.__shown; self.__shown = true
  if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end end
function Object:Hide() protectedCheck(self, "Hide"); local was = self.__shown; self.__shown = false
  if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
function Object:SetShown(v) if v then self:Show() else self:Hide() end end
function Object:IsShown() return self.__shown end
function Object:IsVisible()
  if not self.__shown then return false end
  if self.__parent then return self.__parent:IsVisible() end
  return true
end
function Object:GetAlpha() return self.__alpha end
function Object:GetEffectiveAlpha() return self.__alpha end
function Object:SetAlpha(a) self.__alpha = a end
function Object:GetRect() local r = self.__rect; return r[1], r[2], r[3], r[4] end
function Object:GetWidth() return self.__rect[3] end
function Object:GetHeight() return self.__rect[4] end
function Object:GetBottom() return self.__rect[2] end
function Object:GetTop() return self.__rect[2] + self.__rect[4] end
function Object:SetWidth(w) self.__rect = { self.__rect[1], self.__rect[2], w, self.__rect[4] } end
function Object:SetHeight(h) self.__rect = { self.__rect[1], self.__rect[2], self.__rect[3], h } end
function Object:SetSize(w, h) self:SetWidth(w); self:SetHeight(h or w) end
function Object:SetPoint(point, relativeTo, relativePoint, x, y)
  self.__points = self.__points or {}
  table.insert(self.__points, { point, relativeTo, relativePoint, x, y })
end
function Object:ClearAllPoints() self.__points = {} end
function Object:GetPoint(i) local p = (self.__points or {})[i or 1]; if p then return unpack(p) end end
function Object:GetEffectiveScale() return 1 end
function Object:IsMouseOver()
  local r = self.__rect; local x, y = stub.cursor[1], stub.cursor[2]
  return x >= r[1] and x <= r[1] + r[3] and y >= r[2] and y <= r[2] + r[4]
end
function FrameMethods:SetFrameStrata(s)
  protectedCheck(self, "SetFrameStrata"); self.__strata = s
  for _, f in ipairs(allFrames) do
    if f.__parent == self and not f.__fixedStrata then f:SetFrameStrata(s) end
  end
end
function FrameMethods:GetFrameStrata() return self.__strata end
function FrameMethods:SetFrameLevel(l) protectedCheck(self, "SetFrameLevel"); self.__level = l end
function FrameMethods:GetFrameLevel() return self.__level end
function FrameMethods:SetFixedFrameStrata(v) self.__fixedStrata = v end
function FrameMethods:HasFixedFrameStrata() return self.__fixedStrata or false end
function FrameMethods:SetFixedFrameLevel(v) self.__fixedLevel = v end
function FrameMethods:HasFixedFrameLevel() return self.__fixedLevel or false end
function RegionMethods:SetDrawLayer(l, s) self.__layer = l; self.__sub = s or 0 end
function RegionMethods:GetDrawLayer() return self.__layer, self.__sub end
function FrameMethods:CreateTexture(name, layer)
  local t = new("region", "Texture", name, self)
  t.__layer = layer or "ARTWORK"
  table.insert(self.__regions, t)
  return t
end
function FrameMethods:CreateFontString(name, layer)
  local t = new("region", "FontString", name, self)
  t.__layer = layer or "ARTWORK"
  table.insert(self.__regions, t)
  return t
end
function Object:GetRegions() return unpack(self.__regions) end
function Object:SetScript(name, fn) self.__scripts[name] = fn end
function Object:HookScript(name, fn)
  local prev = self.__scripts[name]
  self.__scripts[name] = function(...) if prev then prev(...) end fn(...) end
end
function Object:SetEnabled(v) self.__enabled = v and true or false end
function Object:IsEnabled() return self.__enabled ~= false end
function Object:Enable() self.__enabled = true end
function Object:Disable() self.__enabled = false end
function Object:SetupMenu(gen) self.__menu = gen end
-- Test helper: choose a dropdown option by its text.
function Object:__Choose(text)
  local radios = {}
  local root = { CreateRadio = function(_, t, isSel, setSel) radios[#radios + 1] = { t, isSel, setSel } end }
  self.__menu(self, root)
  for _, r in ipairs(radios) do if r[1] == text then r[3]() return true end end
  local names = {} for _, r in ipairs(radios) do names[#names + 1] = r[1] end
  error("no option " .. text .. " in: " .. table.concat(names, ", "))
end
function Object:__Selected()
  local sel
  local root = { CreateRadio = function(_, t, isSel) if isSel() then sel = t end end }
  self.__menu(self, root)
  return sel
end
function Object:GetScript(name) return self.__scripts[name] end
function Object:RegisterEvent(e) eventFrames[#eventFrames + 1] = { self, e } end
function Object:Click() local f = self.__scripts.OnClick; if f then f(self, "LeftButton") end end
function Object:GetText() return self.__text or "" end
function Object:SetText(t) self.__text = t end
function Object:HasFocus() return false end
function Object:GetStringWidth() return 100 end
function Object:GetStringHeight() return 40 end
-- everything else is a no-op
local KIND = { SetFrameStrata=1, GetFrameStrata=1, SetFrameLevel=1, GetFrameLevel=1, SetFixedFrameStrata=1,
  HasFixedFrameStrata=1, SetFixedFrameLevel=1, HasFixedFrameLevel=1, SetDrawLayer=1, GetDrawLayer=1, CreateTexture=1, CreateFontString=1 }
setmetatable(Object, { __index = function(_, k) if KIND[k] or not k:match("^%u") then return nil end return function() end end })

stub.Fire = function(event, ...)
  for _, pair in ipairs(eventFrames) do
    if pair[2] == event then
      local fn = pair[1].__scripts.OnEvent
      if fn then fn(pair[1], event, ...) end
    end
  end
end
stub.RunTimers = function()
  local t = timers; timers = {}
  for _, fn in ipairs(t) do fn() end
end

function CreateFrame(objType, name, parent, template)
  local f = new("frame", objType, name, parent)
  return f
end

UIParent = new("frame", "Frame", "UIParent", nil)
UIParent.__rect = { 0, 0, 1920, 1080 }
WorldFrame = new("frame", "Frame", "WorldFrame", nil)

function hooksecurefunc(t, name, fn)
  local orig = t[name]
  rawset(t, name, function(...) local r = { orig(...) }; fn(...); return unpack(r) end)
end
function InCombatLockdown() return stub.combat end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
function GetTime() return os.clock() + 1000 end
function GetCursorPosition() return stub.cursor[1], stub.cursor[2] end
function EnumerateFrames(f)
  if not f then return allFrames[1] end
  for i, x in ipairs(allFrames) do if x == f then return allFrames[i + 1] end end
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strlower = string.lower
tinsert = table.insert
UISpecialFrames = {}
StaticPopupDialogs = {}
stub.popups = {}
function StaticPopup_Show(which) stub.popups[#stub.popups + 1] = which end
function IsShiftKeyDown() return false end
SlashCmdList = {}
YES, NO = "Yes", "No"
stub.printed = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end stub.printed[#stub.printed + 1] = table.concat(t, " ") end

-- Fake Forever bottom bar: protected main bar, end caps that are Edit Mode systems.
MainActionBar = CreateFrame("Frame", "MainActionBar", UIParent)
MainActionBar.__protected = true
MainActionBar.__rect = { 600, 0, 700, 60 }
MainActionBar.__level = 50
MainActionBar.system = 0
function MainActionBar:GetSystemName() return "Action Bar 1" end
local endCaps = CreateFrame("Frame", nil, MainActionBar)
MainActionBar.EndCaps = endCaps
endCaps.__rect = { 600, 0, 700, 60 }
endCaps.__level = 100
local left = CreateFrame("Frame", nil, endCaps)
endCaps.LeftEndCap = left
left.system = 30
left.__level = 100
left.__rect = { 520, 0, 100, 100 }  -- hangs outside the bar
function left:GetSystemName() return "Left End Cap" end
local leftTex = left:CreateTexture(nil, "OVERLAY")
left.Texture = leftTex
leftTex.__rect = { 520, 0, 100, 100 }
leftTex.__sub = 5
local sel = CreateFrame("Frame", nil, left)   -- Edit Mode selection box
left.Selection = sel
sel.__rect = { 518, -2, 104, 104 }
ActionButton1 = CreateFrame("CheckButton", "ActionButton1", MainActionBar)
ActionButton1.__protected = true
ActionButton1.__rect = { 640, 10, 40, 40 }
ActionButton1.__level = 51
MultiBarBottomLeft = CreateFrame("Frame", "MultiBarBottomLeft", UIParent)
MultiBarBottomLeft.__protected = true
MultiBarBottomLeft.__level = 50
MultiBarBottomLeft.system = 0
function MultiBarBottomLeft:GetSystemName() return "Action Bar 2" end
Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap.__rect = { 1700, 860, 200, 200 }

-- EventRegistry
EventRegistry = { callbacks = {} }
function EventRegistry:RegisterCallback(event, fn, owner)
  self.callbacks[event] = self.callbacks[event] or {}
  table.insert(self.callbacks[event], { fn, owner })
end
function EventRegistry:TriggerEvent(event, ...)
  for _, c in ipairs(self.callbacks[event] or {}) do c[1](c[2], ...) end
end

Enum = { EditModeLayoutType = { Preset = 0, Account = 1, Character = 2, Override = 3 } }
function UnitName() return "Josten" end
stub.metadata = {}
C_AddOns = { GetAddOnMetadata = function(name, field) return (stub.metadata[name] or {})[field] end }
function GetRealmName() return "Realm" end

-- Edit Mode, following Blizzard's call order in EditModeManager.lua.
EditModeManagerFrame = CreateFrame("Frame", "EditModeManagerFrame", UIParent)
EditModeManagerFrame:Hide()
local mgr = EditModeManagerFrame
mgr.SaveChangesButton = CreateFrame("Button", nil, mgr)
mgr.RevertAllChangesButton = CreateFrame("Button", nil, mgr)
mgr.layoutInfo = { activeLayout = 3, layouts = {
  { layoutType = 0, layoutName = "Modern", systems = {} },
  { layoutType = 0, layoutName = "Classic", systems = {} },
  { layoutType = 1, layoutName = "Josten", systems = {} },
} }
stub.blizzChanges = false
function mgr:GetActiveLayoutInfo() return self.layoutInfo.layouts[self.layoutInfo.activeLayout] end
function mgr:UpdateLayoutInfo(info) if info then self.layoutInfo = info end end
function mgr:IsEditModeActive() return self.editModeActive end
function mgr:HasActiveChanges() return self.hasActiveChanges end
function mgr:SetHasActiveChanges(v)
  self.hasActiveChanges = v and true or false
  self.SaveChangesButton:SetEnabled(v)
  self.RevertAllChangesButton:SetEnabled(v)
end
function mgr:ClearSelectedSystem() EditModeSystemSettingsDialog:Hide() end
function mgr:RevertAllChanges() self:ClearSelectedSystem(); self:UpdateLayoutInfo(self.layoutInfo); self:SetHasActiveChanges(false) end
function mgr:RevertSystemChanges(systemFrame) end
function mgr:SaveLayouts() self:SetHasActiveChanges(false); EventRegistry:TriggerEvent("EditMode.SavedLayouts") end
function mgr:IsActiveLayoutPreset() return self:GetActiveLayoutInfo().layoutType == 0 end
function mgr:SaveLayoutChanges() if self:IsActiveLayoutPreset() then self:ShowNewLayoutDialog() else self:SaveLayouts() end end
function mgr:ShowNewLayoutDialog(layoutInfo) self:ClearSelectedSystem() end
function mgr:MakeNewLayout(newLayoutInfo, layoutType, layoutName)
  self:RevertAllChanges()
  newLayoutInfo.layoutType = layoutType; newLayoutInfo.layoutName = layoutName
  table.insert(self.layoutInfo.layouts, newLayoutInfo)
  self:SaveLayouts()
  self.layoutInfo.activeLayout = #self.layoutInfo.layouts
  self:UpdateLayoutInfo(self.layoutInfo)
end
function mgr:SelectLayout(i) self.layoutInfo.activeLayout = i; self:UpdateLayoutInfo(self.layoutInfo) end
function mgr:ShowRenameLayoutDialog(i, info) end
function mgr:RenameLayout(i, name) self.layoutInfo.layouts[i].layoutName = name end
function mgr:ShowDeleteLayoutDialog(i, info) end
function mgr:DeleteLayout(i) table.remove(self.layoutInfo.layouts, i); self.layoutInfo.activeLayout = 3; self:UpdateLayoutInfo(self.layoutInfo) end
function mgr:EnterEditMode() self.editModeActive = true; self:Show(); self:SetHasActiveChanges(false); EventRegistry:TriggerEvent("EditMode.Enter") end
function mgr:ExitEditMode() self.editModeActive = false; self:RevertAllChanges(); self:Hide(); EventRegistry:TriggerEvent("EditMode.Exit") end
function mgr:SelectSystemFrame(f) f.isSelected = true; EditModeSystemSettingsDialog:AttachToSystemFrame(f) end

EditModeSystemSettingsDialog = CreateFrame("Frame", "EditModeSystemSettingsDialog", UIParent)
EditModeSystemSettingsDialog:Hide()
EditModeSystemSettingsDialog.__rect = { 300, 400, 383, 350 }
mgr.__rect = { 728, 330, 465, 690 }
function EditModeSystemSettingsDialog:AttachToSystemFrame(f) self.attachedToSystem = f; self:Show() end
EditModeSystemSettingsDialog:SetScript("OnHide", function(self) self.attachedToSystem = nil end)
