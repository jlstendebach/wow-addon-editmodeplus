"""Loads EditModePlus into a stubbed WoW client (real Lua 5.1) and checks behavior.

The stub follows Blizzard's Forever Edit Mode call order, but it is not the
real client: anything here still needs checking in game.

    pip install lupa
    python tests/test.py
"""
import pathlib
import re
import sys

from lupa import lua51

ADDON = pathlib.Path(__file__).resolve().parent.parent / "EditModePlus"
HERE = pathlib.Path(__file__).resolve().parent

FILES = re.findall(r"^(\w+\.lua)\s*$", (ADDON / "EditModePlus.toc").read_text(), re.M)

lua = lua51.LuaRuntime(unpack_returned_tuples=True)
lua.execute((HERE / "wowstub.lua").read_text())
ns = lua.eval("{}")
loader = lua.execute("return function(src, name) return assert(loadstring(src, name)) end")
for name in FILES:
    loader((ADDON / name).read_text(), "@" + name)("EditModePlus", ns)

results = []


def check(label, cond):
    results.append((label, bool(cond)))
    print(("PASS " if cond else "FAIL ") + label)


run = lua.execute
ev = lua.eval

run('''
__stub.Fire("ADDON_LOADED", "EditModePlus")
__stub.Fire("PLAYER_LOGIN")
__stub.RunTimers()
EditModeManagerFrame:UpdateLayoutInfo()
''')

# --- Profiles follow the active layout --------------------------------------
check("files loaded in toc order", FILES == ["Core.lua", "Picker.lua", "Controls.lua", "UI.lua", "EditMode.lua"])
check("profile is the active account layout", ev("EditModePlus.GetProfileKey()") == "account:Josten")

# --- Paths -------------------------------------------------------------------
check("path for named frame", ev("EditModePlus.GetPath(Minimap)") == "Minimap")
check("path for end cap system", ev("EditModePlus.GetPath(MainActionBar.EndCaps.LeftEndCap)") == "MainActionBar.EndCaps.LeftEndCap")
check("path for texture", ev("EditModePlus.GetPath(MainActionBar.EndCaps.LeftEndCap.Texture)") == "MainActionBar.EndCaps.LeftEndCap.Texture")
check("resolve bad path", ev('EditModePlus.Resolve("MainActionBar.Nope")') is None)

# --- Outside Edit Mode, changes save immediately ----------------------------
run('EditModePlus.Set("Minimap", "visibility", "hide")')
check("hidden minimap not visible", not ev("Minimap:IsVisible()"))
check("saved straight to the layout", ev('EditModePlusDB.profiles["account:Josten"].entries.Minimap.visibility') == "hide")
run('Minimap:Show()')
check("Blizzard Show() can't reveal it", not ev("Minimap:IsVisible()"))
run('Minimap:SetParent(WorldFrame)')
check("Blizzard reparent gets re-hidden", ev("Minimap:GetParent() == EditModePlusHider"))
run('EditModePlus.Set("Minimap", "visibility", nil)')
check("unhide restores latest parent", ev("Minimap:GetParent() == WorldFrame"))
check("empty entry removed", ev('EditModePlus.GetEntry("Minimap")') is None)
run('Minimap:SetParent(UIParent)')

# --- Opacity multiplies Blizzard's own --------------------------------------
run('EditModePlus.Set("Minimap", "alpha", 0.5)')
check("opacity applied", abs(ev("Minimap:GetAlpha()") - 0.5) < 1e-6)
run('Minimap:SetAlpha(0.8)')  # e.g. Blizzard's own opacity setting
check("Blizzard opacity combines with ours", abs(ev("Minimap:GetAlpha()") - 0.4) < 1e-6)
run('EditModePlus.Set("Minimap", "alpha", nil)')
check("opacity reset restores Blizzard's value", abs(ev("Minimap:GetAlpha()") - 0.8) < 1e-6)
run('Minimap:SetAlpha(1)')

# --- Gryphon fix: end cap strata pinned below the bars ----------------------
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap", "strata", "LOW")')
check("end cap strata LOW", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")
check("end cap strata pinned", ev("MainActionBar.EndCaps.LeftEndCap:HasFixedFrameStrata()"))
run('MainActionBar:SetFrameStrata("HIGH")')
check("parent strata change doesn't drag it along", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")
run('MainActionBar.EndCaps.LeftEndCap:SetFrameStrata("MEDIUM")')
check("Blizzard direct strata change is reverted", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")
check("Describe shows Blizzard's value", ev('EditModePlus.Describe(MainActionBar.EndCaps.LeftEndCap).strata') == "MEDIUM")
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap", "strata", nil)')
check("reset restores Blizzard's last strata", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "MEDIUM")
run('MainActionBar:SetFrameStrata("MEDIUM")')

# --- Texture layers ----------------------------------------------------------
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap.Texture", "layer", "BACKGROUND")')
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap.Texture", "sublevel", -8)')
lay = ev("{MainActionBar.EndCaps.LeftEndCap.Texture:GetDrawLayer()}")
check("texture layer set", lay[1] == "BACKGROUND" and lay[2] == -8)
run('EditModePlus.Clear("MainActionBar.EndCaps.LeftEndCap.Texture")')
lay = ev("{MainActionBar.EndCaps.LeftEndCap.Texture:GetDrawLayer()}")
check("clear restores texture layer", lay[1] == "OVERLAY" and lay[2] == 5)

# --- Combat ------------------------------------------------------------------
run('__stub.combat = true')
run('EditModePlus.Set("MultiBarBottomLeft", "visibility", "hide")')
check("no blocked actions in combat", len(list(ev("__stub.blocked").values())) == 0)
check("pending in combat", ev('EditModePlus.GetStatus("MultiBarBottomLeft")') == "pending")
run('__stub.combat = false; __stub.Fire("PLAYER_REGEN_ENABLED")')
check("applied after combat", not ev("MultiBarBottomLeft:IsVisible()"))
run('EditModePlus.Clear("MultiBarBottomLeft")')
check("bar back", ev("MultiBarBottomLeft:IsVisible()"))

# --- Edit Mode: docked panel -------------------------------------------------
run('EditModeManagerFrame:EnterEditMode()')
check("edit mode flag", ev("EditModePlus.IsEditMode()"))
check("toolbar shown", ev("EditModePlusToolbar:IsShown()"))
run('EditModeManagerFrame:SelectSystemFrame(MultiBarBottomLeft)')
check("panel docks to Blizzard's dialog", ev("EditModePlusPanel:IsShown()"))
check("panel targets the selected system", ev("EditModePlus.EditMode.GetTarget()") == "MultiBarBottomLeft")
run('EditModeSystemSettingsDialog:Hide()')
check("panel hides with the dialog", not ev("EditModePlusPanel:IsShown()"))

# --- Edit Mode: staged edits, Save --------------------------------------------
run('EditModeManagerFrame:SelectSystemFrame(MainActionBar.EndCaps.LeftEndCap)')
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap", "strata", "LOW")')
check("preview applies live", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")
check("not saved yet", ev('EditModePlusDB.profiles["account:Josten"].entries["MainActionBar.EndCaps.LeftEndCap"]') is None)
check("unsaved flag", ev("EditModePlus.HasUnsavedChanges()"))
check("Blizzard Save enabled for our change", ev("EditModeManagerFrame.SaveChangesButton:IsEnabled()"))
run('EditModeManagerFrame:SaveLayoutChanges()')
check("Save commits", ev('EditModePlusDB.profiles["account:Josten"].entries["MainActionBar.EndCaps.LeftEndCap"].strata') == "LOW")
check("Save button disabled again", not ev("EditModeManagerFrame.SaveChangesButton:IsEnabled()"))

# --- Edit Mode: Revert All ---------------------------------------------------
run('EditModePlus.Set("Minimap", "visibility", "hide")')
check("hidden is a ghost in Edit Mode", ev("Minimap:IsVisible()") and abs(ev("Minimap:GetAlpha()") - 0.3) < 1e-6)
run('EditModePlus.Set("Minimap", "alpha", 0.1)')
run('EditModePlus.Set("Minimap", "visibility", nil)')
check("opacity floor while editing", abs(ev("Minimap:GetAlpha()") - 0.3) < 1e-6)
run('EditModeManagerFrame:RevertAllChanges()')
check("Revert All discards", ev('EditModePlus.GetEntry("Minimap")') is None and abs(ev("Minimap:GetAlpha()") - 1) < 1e-6)
check("Revert keeps saved changes", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")

# --- Edit Mode: per-system revert --------------------------------------------
run('EditModePlus.Set("MainActionBar.EndCaps.LeftEndCap", "strata", "HIGH")')
run('EditModePlus.Set("Minimap", "alpha", 0.5)')
run('EditModeManagerFrame:RevertSystemChanges(MainActionBar.EndCaps.LeftEndCap)')
check("system revert restores that system", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")
check("system revert leaves others staged", ev('EditModePlus.GetEntry("Minimap").alpha') == 0.5)

# --- Edit Mode: exit with unsaved changes ------------------------------------
run('EditModeManagerFrame:ExitEditMode()')
check("toolbar hidden on exit", not ev("EditModePlusToolbar:IsShown()"))
check("asks about unsaved changes", list(ev("__stub.popups").values())[-1:] == ["EDITMODEPLUS_UNSAVED_CHANGES"])
check("change still previewed while asking", abs(ev("Minimap:GetAlpha()") - 0.5) < 1e-6)
run('StaticPopupDialogs.EDITMODEPLUS_UNSAVED_CHANGES.OnAccept()')
check("Save from the prompt commits", ev('EditModePlusDB.profiles["account:Josten"].entries.Minimap.alpha') == 0.5)

run('EditModeManagerFrame:EnterEditMode()')
run('EditModePlus.Set("Minimap", "alpha", 0.25)')
run('EditModeManagerFrame:ExitEditMode()')
run('StaticPopupDialogs.EDITMODEPLUS_UNSAVED_CHANGES.OnCancel()')
check("Discard from the prompt reverts", abs(ev("Minimap:GetAlpha()") - 0.5) < 1e-6)
n_popups = len(list(ev("__stub.popups").values()))
run('EditModeManagerFrame:EnterEditMode(); EditModeManagerFrame:ExitEditMode()')
check("no prompt without changes", len(list(ev("__stub.popups").values())) == n_popups)

# --- Layouts: switching, new from preset, rename, delete --------------------
run('EditModeManagerFrame:SelectLayout(1)')
check("switching layout switches profile", ev("EditModePlus.GetProfileKey()") == "preset:Modern")
check("other layout's changes undone", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "MEDIUM" and abs(ev("Minimap:GetAlpha()") - 1) < 1e-6)
run('EditModeManagerFrame:EnterEditMode()')
run('EditModePlus.Set("Minimap", "visibility", "hide")')
run('EditModeManagerFrame:SaveLayoutChanges()')  # preset: Blizzard asks for a new layout
run('EditModeManagerFrame:MakeNewLayout({ systems = {} }, Enum.EditModeLayoutType.Character, "Raid")')
check("new layout active", ev("EditModePlus.GetProfileKey()") == "char:Josten-Realm:Raid")
check("new layout got the unsaved changes", ev('EditModePlusDB.profiles["char:Josten-Realm:Raid"].entries.Minimap.visibility') == "hide")
check("preset left untouched", ev('next(EditModePlusDB.profiles["preset:Modern"].entries)') is None)
run('EditModeManagerFrame:ShowRenameLayoutDialog(4, EditModeManagerFrame.layoutInfo.layouts[4])')
run('EditModeManagerFrame:RenameLayout(4, "Raid2")')
check("rename moves the profile", ev('EditModePlusDB.profiles["char:Josten-Realm:Raid2"] ~= nil and EditModePlusDB.profiles["char:Josten-Realm:Raid"] == nil'))
check("rename keeps it active", ev("EditModePlus.GetProfileKey()") == "char:Josten-Realm:Raid2")
run('EditModeManagerFrame:ShowDeleteLayoutDialog(4, EditModeManagerFrame.layoutInfo.layouts[4])')
run('EditModeManagerFrame:DeleteLayout(4)')
check("delete removes the profile", ev('EditModePlusDB.profiles["char:Josten-Realm:Raid2"]') is None)
check("back on Josten after delete", ev("EditModePlus.GetProfileKey()") == "account:Josten")
check("Josten's changes back", ev("MainActionBar.EndCaps.LeftEndCap:GetFrameStrata()") == "LOW")

# --- Picker ------------------------------------------------------------------
run('''
__picked = nil
EditModePlus.Picker:Start(function(p) __picked = p end, function() __done = true end)
__stub.cursor = {530, 50}
EditModePlusPicker:GetScript("OnUpdate")(EditModePlusPicker, 1)
''')
offered = []
for _ in range(5):
    offered.append(ev("EditModePlus.Picker:Current()"))
    run('EditModePlusPicker:GetScript("OnMouseWheel")(EditModePlusPicker, -1)')
run('EditModePlus.Picker:Stop()')
check("picker never offers Edit Mode's selection box", offered and not any(p and "Selection" in p for p in offered))
run('''
__picked = nil
EditModePlus.Picker:Start(function(p) __picked = p end)
__stub.cursor = {530, 50}
EditModePlusPicker:GetScript("OnUpdate")(EditModePlusPicker, 1)
EditModePlusPicker:GetScript("OnMouseDown")(EditModePlusPicker, "LeftButton")
''')
check("picker finds the gryphon", ev("__picked") in ("MainActionBar.EndCaps.LeftEndCap", "MainActionBar.EndCaps.LeftEndCap.Texture"))
check("done callback", ev("__done") == True)

# --- Free panel in Edit Mode -------------------------------------------------
run('EditModeManagerFrame:EnterEditMode()')
run('EditModeManagerFrame:SelectSystemFrame(MultiBarBottomLeft)')
run('EditModePlus.EditMode.ShowFree("Minimap")')
check("free panel shown", ev("EditModePlusPanel:IsShown()") and ev("EditModePlus.EditMode.GetTarget()") == "Minimap")
check("Blizzard selection cleared", not ev("EditModeSystemSettingsDialog:IsShown()"))
run('EditModeManagerFrame:ExitEditMode()')
check("panel hidden on exit", not ev("EditModePlusPanel:IsShown()"))

# --- Controls: dropdowns drive settings --------------------------------------
run('EditModePlus.UI:Select("MultiBarBottomLeft")')
picked = lua.execute('''
-- Find the visibility dropdown of the overview's controls: first menu with "Hidden".
local result
local seen = {}
local function scan(t)
  if seen[t] or result then return end
  seen[t] = true
  for _, v in pairs(t) do
    if type(v) == "table" then
      if rawget(v, "__menu") and rawget(v, "__parent") then
        local ok = pcall(v.__Choose, v, "Hidden")
        if ok then result = v return end
      end
      scan(v)
    end
  end
end
-- Controls frames are children created via CreateFrame, reachable through __parent links only,
-- so walk every frame the stub created.
local f = EnumerateFrames()
while f and not result do
  if rawget(f, "__menu") then
    local p = f
    local inOverview = false
    for _ = 1, 10 do p = rawget(p, "__parent"); if not p then break end; if p == EditModePlusFrame then inOverview = true end end
    if inOverview then
      local ok = pcall(f.__Choose, f, "Hidden")
      if ok then result = f end
    end
  end
  f = EnumerateFrames(f)
end
return result ~= nil
''')
check("choosing Hidden in the dropdown hides the bar", picked and not ev("MultiBarBottomLeft:IsVisible()"))
strata = lua.execute('''
local f = EnumerateFrames()
while f do
  if rawget(f, "__menu") then
    local p, inOverview = f, false
    for _ = 1, 10 do p = rawget(p, "__parent"); if not p then break end; if p == EditModePlusFrame then inOverview = true end end
    if inOverview and pcall(f.__Choose, f, "HIGH") then return true end
  end
  f = EnumerateFrames(f)
end
return false
''')
check("choosing a strata applies it", strata and ev("MultiBarBottomLeft:GetFrameStrata()") == "HIGH")
run('EditModePlus.Clear("MultiBarBottomLeft")')

# --- No stray globals -----------------------------------------------------------
lua3 = lua51.LuaRuntime(unpack_returned_tuples=True)
lua3.execute((HERE / "wowstub.lua").read_text())
lua3.execute('''
__newglobals = {}
local allowed = { EditModePlus=1, EditModePlusDB=1, SLASH_EDITMODEPLUS1=1, SLASH_EDITMODEPLUS2=1,
  EditModePlus_OnAddonCompartmentClick=1, EditModePlusHider=1, EditModePlusPicker=1, EditModePlusFrame=1,
  EditModePlusPanel=1, EditModePlusToolbar=1 }
setmetatable(_G, { __newindex = function(t, k, v) if not allowed[k] then __newglobals[#__newglobals + 1] = k end rawset(t, k, v) end })
''')
ns3 = lua3.eval("{}")
loader3 = lua3.execute("return function(src, name) return assert(loadstring(src, name)) end")
for name in FILES:
    loader3((ADDON / name).read_text(), "@" + name)("EditModePlus", ns3)
lua3.execute('''
__stub.Fire("ADDON_LOADED", "EditModePlus"); __stub.Fire("PLAYER_LOGIN"); __stub.RunTimers()
EditModeManagerFrame:UpdateLayoutInfo()
EditModeManagerFrame:EnterEditMode()
EditModeManagerFrame:SelectSystemFrame(MultiBarBottomLeft)
EditModePlus.Set("Minimap", "alpha", 0.5)
EditModeManagerFrame:ExitEditMode()
SlashCmdList.EDITMODEPLUS("")
''')
stray = list(lua3.eval("__newglobals").values())
check("no stray globals " + (str(stray) if stray else ""), not stray)

print("\nprinted:", list(ev("__stub.printed").values()))
fails = [r for r in results if not r[1]]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
