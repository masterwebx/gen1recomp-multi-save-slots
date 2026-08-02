-- Multiple Save Slots: CONTINUE loads / SAVE writes a chosen slot.
-- No empty slots: NEW SAVE creates a slot and immediately writes into it.
-- Delete removes the slot entirely and refreshes the list.
return function(mod)
  local SaveData = require("src.core.SaveData")
  local GameVersion = require("src.core.GameVersion")
  local Strings = require("src.core.Strings")
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local ListMenu = require("src.ui.ListMenu")
  local TitleState = require("src.ui.TitleState")
  local Game = require("src.core.Game")

  local function versionOf(game)
    return (game and game.version) or GameVersion.get()
  end

  local function sortSlotIds(list)
    table.sort(list, function(a, b)
      local na = tonumber(tostring(a):match("%d+")) or 0
      local nb = tonumber(tostring(b):match("%d+")) or 0
      return na < nb
    end)
  end

  -- Union merge for writeSave safety (stale memory must not wipe new slots).
  local function mergeSaveSlots(a, b)
    local out = {}
    local function absorb(src)
      if type(src) ~= "table" then return end
      for ver, reg in pairs(src) do
        if type(ver) == "string" and type(reg) == "table" then
          local dst = out[ver] or { list = {}, active = nil, names = {} }
          local seen = {}
          for _, id in ipairs(dst.list) do seen[id] = true end
          for _, id in ipairs(reg.list or {}) do
            if type(id) == "string" and not seen[id] then
              dst.list[#dst.list + 1] = id
              seen[id] = true
            end
          end
          if type(reg.names) == "table" then
            dst.names = dst.names or {}
            for k, v in pairs(reg.names) do dst.names[k] = v end
          end
          if reg.active and seen[reg.active] then
            dst.active = reg.active
          elseif not dst.active then
            dst.active = reg.active
          end
          out[ver] = dst
        end
      end
    end
    absorb(a)
    absorb(b)
    for _, reg in pairs(out) do
      sortSlotIds(reg.list)
      if reg.names and next(reg.names) == nil then reg.names = nil end
      if reg.active then
        local ok = false
        for _, id in ipairs(reg.list) do
          if id == reg.active then ok = true break end
        end
        if not ok then reg.active = reg.list[1] end
      elseif reg.list[1] then
        reg.active = reg.list[1]
      end
    end
    return out
  end

  local function syncSlotsIntoGame()
    local disk = SaveData.loadOptions()
    if not (disk and disk.saveSlots) then return end
    if Game and Game.save and Game.save.options then
      Game.save.options.saveSlots = disk.saveSlots
    end
  end

  local origSaveOptions = SaveData.saveOptions
  if not SaveData._multiSlotSaveOptsWrapped then
    function SaveData.saveOptions(opts, fs)
      if SaveData._slotWriteAuthoritative then
        local result = origSaveOptions(opts, fs)
        if result and Game and Game.save and Game.save.options and result.saveSlots then
          Game.save.options.saveSlots = result.saveSlots
        end
        return result
      end
      opts = opts or {}
      local disk = SaveData.loadOptions(fs)
      if disk and disk.saveSlots then
        opts.saveSlots = mergeSaveSlots(disk.saveSlots, opts.saveSlots)
      end
      local result = origSaveOptions(opts, fs)
      if result and Game and Game.save and Game.save.options and result.saveSlots then
        Game.save.options.saveSlots = result.saveSlots
      end
      return result
    end
    SaveData._multiSlotSaveOptsWrapped = true
  end

  -- deleteSlot must write opts authoritatively or merge re-adds the id
  -- from the still-unwritten disk snapshot.
  if not SaveData._multiSlotDeleteWrapped then
    local stockDelete = SaveData.deleteSlot
    function SaveData.deleteSlot(version, slotId)
      SaveData._slotWriteAuthoritative = true
      local ok, err = stockDelete(version, slotId)
      SaveData._slotWriteAuthoritative = false
      syncSlotsIntoGame()
      return ok, err
    end
    SaveData._multiSlotDeleteWrapped = true
  end

  if not SaveData._multiSlotCreateWrapped then
    local stockCreate = SaveData.createSlot
    function SaveData.createSlot(version)
      SaveData._slotWriteAuthoritative = true
      local id = stockCreate(version)
      SaveData._slotWriteAuthoritative = false
      syncSlotsIntoGame()
      return id
    end
    SaveData._multiSlotCreateWrapped = true
  end

  local function reconcileDiskSlots(ver)
    ver = ver or versionOf(Game)
    if not ver then return end
    local fs = love and love.filesystem
    if not (fs and fs.getDirectoryItems) then return end
    local dir = "saves/" .. ver
    local info = fs.getInfo(dir)
    if not (info and info.type == "directory") then return end
    local opts = SaveData.loadOptions()
    opts.saveSlots = opts.saveSlots or {}
    local reg = opts.saveSlots[ver] or { list = {}, active = nil }
    local seen = {}
    for _, id in ipairs(reg.list or {}) do seen[id] = true end
    local changed = false
    for _, name in ipairs(fs.getDirectoryItems(dir) or {}) do
      local id = tostring(name):match("^(slot%d+)%.lua$")
      if id and not seen[id] then
        reg.list[#reg.list + 1] = id
        seen[id] = true
        changed = true
      end
    end
    if changed then
      sortSlotIds(reg.list)
      if not reg.active then reg.active = reg.list[1] end
      opts.saveSlots[ver] = reg
      SaveData._slotWriteAuthoritative = true
      SaveData.saveOptions(opts)
      SaveData._slotWriteAuthoritative = false
      syncSlotsIntoGame()
    end
  end

  -- Drop registry entries with no save file (no empty slots).
  local function purgeEmptySlots(ver)
    ver = ver or versionOf(Game)
    if not ver then return end
    local active = SaveData.activeSlot(ver)
    local removed = false
    for _, s in ipairs(SaveData.listSlots(ver) or {}) do
      if s and s.id and not s.exists then
        -- Keep a brand-new active slot alive for a moment only if we are
        -- about to write into it; otherwise delete empties aggressively.
        if s.id ~= active then
          local ok = SaveData.deleteSlot(ver, s.id)
          if ok then removed = true end
        end
      end
    end
    if removed then syncSlotsIntoGame() end
  end

  pcall(reconcileDiskSlots)
  pcall(purgeEmptySlots)

  local function slotRows(ver, opts)
    opts = opts or {}
    pcall(reconcileDiskSlots, ver)
    pcall(purgeEmptySlots, ver)
    local slots = SaveData.listSlots(ver) or {}
    local active = SaveData.activeSlot(ver)
    local rows = {}
    for _, s in ipairs(slots) do
      if s.exists then
        local mark = (s.id == active) and "*" or " "
        local who = s.name or "SAVE"
        rows[#rows + 1] = {
          label = Strings("%s%s %s", mark, s.id, who),
          value = s.id,
          exists = true,
        }
      end
    end
    if opts.allowNew then
      rows[#rows + 1] = { label = Strings("NEW SAVE"), value = "__new__" }
    end
    if opts.allowManage then
      rows[#rows + 1] = { label = Strings("MANAGE"), value = "__manage__" }
    end
    return rows, active
  end

  local function tripleConfirmDelete(game, slotId, onYes)
    local prompts = {
      Strings("Delete %s?", slotId),
      Strings("Are you sure?"),
      Strings("Last chance!\nDelete forever?"),
    }
    local function ask(n)
      game.stack:push(TextBox.new(game, prompts[n], function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then return end
          if n >= 3 then onYes() else ask(n + 1) end
        end))
      end))
    end
    ask(1)
  end

  local function openManageSlots(game, onChanged)
    local ver = versionOf(game)
    pcall(reconcileDiskSlots, ver)
    pcall(purgeEmptySlots, ver)
    local active = SaveData.activeSlot(ver)

    local function buildRows()
      local rows = {}
      local active2 = SaveData.activeSlot(ver)
      for _, s in ipairs(SaveData.listSlots(ver) or {}) do
        if s.exists then
          if s.id == active2 then
            rows[#rows + 1] = {
              label = Strings("%s *ACTIVE", s.id),
              value = s.id, locked = true,
            }
          else
            rows[#rows + 1] = {
              label = Strings("DEL %s", s.id),
              value = s.id, locked = false,
            }
          end
        end
      end
      return rows
    end

    local rows = buildRows()
    if #rows == 0 then
      game.stack:push(TextBox.new(game, Strings("No slots.")))
      return
    end

    local function rebuild(menu)
      menu.items = buildRows()
      menu.index = math.max(1, math.min(menu.index or 1, #menu.items))
      menu.scroll = 0
      if onChanged then onChanged() end
    end

    game.stack:push(ListMenu.new(game, Strings("DELETE SLOT"), rows, {
      onChoose = function(item, menu)
        if item.locked then
          game.stack:push(TextBox.new(game,
            Strings("Can't delete\nthe active slot.\fSwitch first.")))
          return
        end
        tripleConfirmDelete(game, item.value, function()
          local ok, err = SaveData.deleteSlot(ver, item.value)
          pcall(purgeEmptySlots, ver)
          syncSlotsIntoGame()
          if ok then
            rebuild(menu)
            if #menu.items == 0 and menu.close then menu:close() end
            game.stack:push(TextBox.new(game, Strings("Deleted.")))
          else
            game.stack:push(TextBox.new(game,
              Strings("Couldn't delete.\n%s", tostring(err or ""))))
          end
        end)
      end,
    }))
  end

  local function openSlotPicker(game, opts)
    opts = opts or {}
    local ver = versionOf(game)
    local rows = slotRows(ver, opts)
    if #rows == 0 then
      game.stack:push(TextBox.new(game, Strings("No save slots.")))
      return
    end

    local function rebuild(menu)
      menu.items = slotRows(ver, opts)
      menu.index = math.max(1, math.min(menu.index or 1, #menu.items))
      menu.scroll = 0
    end

    game.stack:push(ListMenu.new(game, opts.title or Strings("SLOTS"), rows, {
      onChoose = function(item, menu)
        local ver2 = versionOf(game)
        if item.value == "__manage__" then
          openManageSlots(game, function()
            rebuild(menu)
          end)
          return
        end
        if item.value == "__new__" then
          -- Create + activate + immediately save into the new slot.
          local id = SaveData.createSlot(ver2)
          if not id then
            game.stack:push(TextBox.new(game, Strings("Can't create.")))
            return
          end
          SaveData.setActiveSlot(ver2, id)
          syncSlotsIntoGame()
          if menu and menu.close then menu:close() end
          if opts.onPick then opts.onPick(id, true) end
          return
        end
        if opts.requireExists and not item.exists then
          game.stack:push(TextBox.new(game, Strings("Empty.")))
          return
        end
        SaveData.setActiveSlot(ver2, item.value)
        syncSlotsIntoGame()
        if menu and menu.close then menu:close() end
        if opts.onPick then opts.onPick(item.value, false) end
      end,
    }))
  end

  if not TitleState._multiSlotWrapped then
    local origOpen = TitleState.openMenu
    function TitleState:openMenu()
      origOpen(self)
      pcall(reconcileDiskSlots, versionOf(self.game))
      pcall(purgeEmptySlots, versionOf(self.game))
      local top = self.game.stack and self.game.stack:top()
      if not (top and top.items) then return end
      for _, item in ipairs(top.items) do
        local lab = tostring(item.label or "")
        if lab:find("CONTINUE", 1, true) then
          local prev = item.onSelect
          item.onSelect = function()
            openSlotPicker(self.game, {
              title = Strings("LOAD SLOT"),
              requireExists = true,
              allowNew = false,
              allowManage = true,
              onPick = function()
                if prev then prev() end
              end,
            })
          end
          break
        end
      end
    end
    TitleState._multiSlotWrapped = true
  end

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    items = next(game, items) or items
    for _, item in ipairs(items) do
      local lab = tostring(item.label or "")
      if lab == "SAVE" or lab:find("SAVE", 1, true) and not lab:find("SLOT", 1, true) then
        local orig = item.onSelect
        item.onSelect = function()
          openSlotPicker(game, {
            title = Strings("SAVE TO"),
            allowNew = true,
            allowManage = true,
            requireExists = false,
            onPick = function()
              if orig then orig() end
            end,
          })
        end
        break
      end
    end
    return items
  end)

  mod.events:on("game.ready", function()
    pcall(reconcileDiskSlots)
    pcall(purgeEmptySlots)
    pcall(syncSlotsIntoGame)
  end)

  mod.exports.version = "1.0.0"
  mod.log:info("MULTI_SAVE_SLOTS 1.0.0")
end
