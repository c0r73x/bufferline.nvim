local colors = require "bufferline/colors"
local highlights = require "bufferline/highlights"
local utils = require "bufferline/utils"
local sorters = require "bufferline/sorters"
local constants = require "bufferline/constants"
local config = require "bufferline/config"
local tabs = require "bufferline/tabs"
local Buffer = require "bufferline/buffers".Buffer
local Buffers = require "bufferline/buffers".Buffers
local devicons_loaded = require "bufferline/buffers".devicons_loaded

local style_names = {
  slant = "slant",
  thick = "thick",
  thin = "thin"
}

local api = vim.api
-- string.len counts number of bytes and so the unicode icons are counted
-- larger than their display width. So we use nvim's strwidth
local strwidth = vim.fn.strwidth

local padding = constants.padding
local letters = constants.letters
local superscript_numbers = constants.superscript_numbers

-----------------------------------------------------------
-- State
-----------------------------------------------------------
local state = {
  is_picking = false,
  buffers = {},
  current_letters = {}
}

-------------------------------------------------------------------------//
-- EXPORT
---------------------------------------------------------------------------//

local M = {
  shade_color = colors.shade_color
}

---------------------------------------------------------------------------//
-- CORE
---------------------------------------------------------------------------//
local function refresh()
  vim.cmd("redrawtabline")
  vim.cmd("redraw")
end

function M.pick_buffer()
  state.is_picking = true
  refresh()

  local char = vim.fn.getchar()
  local letter = vim.fn.nr2char(char)
  for _, buf in pairs(state.buffers) do
    if letter == buf.letter then
      vim.cmd("buffer " .. buf.id)
    end
  end

  state.is_picking = false
  refresh()
end

---@param buf_id number
function M.handle_close_buffer(buf_id)
  vim.cmd("bdelete! " .. buf_id)
end

function M.handle_win_click(id)
  local win_id = vim.fn.bufwinid(id)
  vim.fn.win_gotoid(win_id)
end

-- if a button is right clicked close the buffer
---@param id number
---@param button string
function M.handle_click(id, button)
  if id then
    if button == "r" then
      M.handle_close_buffer(id)
    else
      vim.cmd("buffer " .. id)
    end
  end
end

local function get_buffer_highlight(buffer, user_highlights)
  local h = highlights
  local c = user_highlights
  local current_highlights = {
    background = nil,
    modified = nil,
    buffer = nil,
    pick = nil,
    duplicate = nil
  }
  if buffer:current() then
    current_highlights.background = h.selected
    current_highlights.modified = h.modified_selected
    current_highlights.buffer = c.bufferline_selected
    current_highlights.pick = h.pick
    current_highlights.duplicate = h.duplicate
  elseif buffer:visible() then
    current_highlights.background = h.inactive
    current_highlights.modified = h.modified_inactive
    current_highlights.buffer = c.bufferline_buffer_inactive
    current_highlights.pick = h.pick
    current_highlights.duplicate = h.duplicate
  else
    current_highlights.background = h.background
    current_highlights.modified = h.modified
    current_highlights.buffer = c.bufferline_background
    current_highlights.pick = h.pick_inactive
    current_highlights.duplicate = h.duplicate_inactive
  end
  return current_highlights
end

local function get_number_prefix(buffer, mode, style)
  local n = mode == "ordinal" and buffer.ordinal or buffer.id
  local num = style == "superscript" and superscript_numbers[n] or n .. "."
  return num
end

local function truncate_filename(filename, word_limit)
  local trunc_symbol = "…"
  local too_long = string.len(filename) > word_limit
  if not too_long then
    return filename
  end
  -- truncate nicely by seeing if we can drop the extension first
  -- to make things fit if not then truncate abruptly
  local without_prefix = vim.fn.fnamemodify(filename, ":t:r")
  if string.len(without_prefix) < word_limit then
    return without_prefix .. trunc_symbol
  else
    return string.sub(filename, 0, word_limit - 1) .. trunc_symbol
  end
end

--- @param buffer Buffer
--- @param background table
--- @return string
local function highlight_icon(buffer, background)
  local icon = buffer.icon
  local hl = buffer.icon_highlight

  if not icon or icon == "" then
    return ""
  end
  if not hl or hl == "" then
    return icon
  end

  local hl_override = "Bufferline" .. hl

  if background then
    local fg = colors.get_hex(hl, "fg")
    if buffer:current() or buffer:visible() then
      hl_override = hl_override .. "Selected"
    end
    colors.set_highlight(hl_override, {guibg = background.guibg, guifg = fg})
  end
  return "%#" .. hl_override .. "#" .. icon .. "%*"
end

local function get_indicator(style)
  local indicator = " "
  local indicator_symbol = indicator
  if style ~= style_names.slant then
    -- U+2590 ▐ Right half block, this character is right aligned so the
    -- background highlight doesn't appear in th middle
    -- alternatives:  right aligned => ▕ ▐ ,  left aligned => ▍
    indicator_symbol = "▎"
    indicator = highlights.indicator .. indicator_symbol .. "%*"
  end
  return indicator, strwidth(indicator_symbol)
end

--- "▍" "░"
--- Reference: https://en.wikipedia.org/wiki/Block_Elements
--- @param focused boolean
--- @param style table | string
local function get_separator(focused, style)
  if type(style) == "table" then
    return focused and style[1] or style[2]
  elseif style == style_names.thick then
    return focused and "▌" or "▐"
  elseif style == style_names.slant then
    return "", ""
  else
    return focused and "▏" or "▕"
  end
end

--- @param focused boolean
--- @param style table | string
local function get_separator_highlight(focused, style)
  if focused and style == style_names.slant then
    return highlights.selected_separator
  else
    return highlights.separator
  end
end

-- @param buf_id number
local function close_button(buf_id, options)
  local buffer_close_icon = options.buffer_close_icon
  local symbol = buffer_close_icon .. padding
  local size = strwidth(symbol)
  return "%" .. buf_id .. "@nvim_bufferline#handle_close_buffer@" .. symbol, size
end


--[[
 In order to get the accurate character width of a buffer tab
 each buffer's length is manually calculated to avoid accidentally
 incorporating highlight strings into the buffer tab count
 e.g. %#HighlightName%filename.js should be 11 but strwidth will
 include the highlight in the count
 TODO
 Workout a function either using vim's regex or lua's to remove
 a highlight string. For example:
 -----------------------------------
  [WIP]
 -----------------------------------
 function get_actual_length(component)
  local formatted = string.gsub(component, '%%#.*#', '')
  return strwidth(formatted)
 end
--]]
--- @param preferences table
--- @param buffer Buffer
--- @return function,number
local function render_buffer(preferences, buffer)
  local options = preferences.options
  local current_highlights =
    get_buffer_highlight(buffer, preferences.highlights)
  local buf_highlight = current_highlights.background
  local modified_hl = current_highlights.modified
  local buffer_colors = current_highlights.buffer

  local length = 0
  local is_current = buffer:current()
  local is_visible = buffer:visible()
  local is_modified = buffer.modifiable and buffer.modified

  local modified_icon = preferences.options.modified_icon
  local modified_section = modified_icon .. padding
  local modified_size = strwidth(modified_section)
  local modified_padding = string.rep(padding, modified_size)

  local icon_size = strwidth(buffer.icon)
  local padding_size = strwidth(padding) * 2
  local max_length = options.max_name_length
  -- if we are enforcing regular tab size then all tabs will try and fit
  -- into the maximum tab size. If not we enforce a minimum tab size
  -- and allow tabs to be larger then the max otherwise
  if options.enforce_regular_tabs then
    -- estimate the maximum allowed size of a filename given that it will be
    -- padded an prefixed with a file icon
    max_length = options.tab_size - modified_size - icon_size - padding_size
  end

  local filename = truncate_filename(buffer.filename, max_length)
  local component = filename .. padding
  length = length + strwidth(component)

  -- there is no way to enforce a regular tab size as specified by the
  -- user if we are going to potentially increase the tab length by
  -- prefixing it with the parent dir(s)
  if buffer.duplicated and not options.enforce_regular_tabs then
    local dir = buffer:parent_dir()
    component =
      table.concat(
      {
        padding,
        current_highlights.duplicate,
        dir,
        buf_highlight,
        component
      }
    )
    length = length + strwidth(padding .. dir)
  else
    component = padding .. component
    length = length + strwidth(padding)
  end

  if state.is_picking and buffer.letter then
    component =
      table.concat(
      {current_highlights.pick, buffer.letter, buf_highlight, component}
    )
    length = length + strwidth(buffer.letter)
  elseif buffer.icon then
    local icon_highlight = highlight_icon(buffer, buffer_colors)
    component = icon_highlight .. buf_highlight .. component
    length = length + strwidth(buffer.icon)
  end

  if not options.show_buffer_close_icons then
    -- If the buffer is modified add an icon, if it isn't pad
    -- the buffer so it doesn't "jump" when it becomes modified i.e. due
    -- to the sudden addition of a new character
    local suffix =
      is_modified and modified_hl .. modified_section or modified_padding
    component = modified_padding .. component .. suffix
    length = length + (modified_size * 2)
  end
  -- pad each tab smaller than the max tab size to make it consistent
  local difference = options.tab_size - length
  if difference > 0 then
    local pad = string.rep(padding, math.floor((difference / 2)))
    component = pad .. component .. pad
    length = length + strwidth(pad) * 2
  end

  if options.numbers ~= "none" then
    local number_prefix =
      get_number_prefix(buffer, options.numbers, options.number_style)
    local number_component = number_prefix .. padding
    component = number_component .. component
    length = length + strwidth(number_component)
  end

  component = utils.make_clickable(options.mode, component, buffer.id)

  local style = options.separator_style

  if is_current then
    local indicator, indicator_size = get_indicator(style)
    length = length + strwidth(indicator_size)
    component = indicator .. buf_highlight .. component
  else
    -- since all non-current buffers do not have an indicator they need
    -- to be padded to make up the difference in size
    length = length + strwidth(padding)
    component = buf_highlight .. padding .. component
  end

  if options.show_buffer_close_icons then
    local close_btn, size = close_button(buffer.id, options)
    local suffix = is_modified and modified_hl .. modified_section or close_btn
    component = component .. buf_highlight .. suffix
    length = length + size
  end

  local focused = is_visible or is_current
  local right_sep, left_sep = get_separator(focused, style)
  local sep_hl = get_separator_highlight(focused, style)
  local right_separator = sep_hl .. right_sep
  local left_separator = left_sep and (sep_hl .. left_sep) or nil

  -- NOTE: the component is wrapped in an item -> %(content) so
  -- vim counts each item as one rather than all of its individual
  -- sub-components.
  local buffer_component = "%(" .. component .. "%)"

  -- We increment the buffer length by the separator although the final
  -- buffer will not have a separator so we are technically off by 1
  length = length + strwidth(right_sep)
  if left_sep then
    length = length + strwidth(left_sep)
  end

  --- We return a function from render buffer as we do not yet have access to
  --- information regarding which buffers will actually be rendered
  --- @param index number
  --- @param num_of_bufs number
  --- @returns string
  return function(index, num_of_bufs)
    if left_separator then
      buffer_component = left_separator .. buffer_component .. right_separator
    elseif index < num_of_bufs then
      buffer_component = buffer_component .. right_separator
    end
    return buffer_component
  end, length
end

local function render_close(icon)
  local component = padding .. icon .. padding
  return component, strwidth(component)
end

local function get_sections(buffers)
  local current = Buffers:new()
  local before = Buffers:new()
  local after = Buffers:new()

  for _, buf in ipairs(buffers) do
    if buf:current() then
      -- We haven't reached the current buffer yet
      current:add(buf)
    elseif current.length == 0 then
      before:add(buf)
    else
      after:add(buf)
    end
  end
  return before, current, after
end

local function get_marker_size(count, element_size)
  return count > 0 and strwidth(count) + element_size or 0
end

local function render_trunc_marker(count, icon)
  return table.concat(
    {
      highlights.fill,
      padding,
      count,
      padding,
      icon,
      padding
    }
  )
end

--[[
PREREQUISITE: active buffer always remains in view
1. Find amount of available space in the window
2. Find the amount of space the bufferline will take up
3. If the bufferline will be too long remove one tab from the before or after
section
4. Re-check the size, if still too long truncate recursively till it fits
5. Add the number of truncated buffers as an indicator
--]]
local function truncate(before, current, after, available_width, marker)
  local line = ""

  local left_trunc_marker =
    get_marker_size(marker.left_count, marker.left_element_size)
  local right_trunc_marker =
    get_marker_size(marker.right_count, marker.right_element_size)

  local markers_length = left_trunc_marker + right_trunc_marker

  local total_length =
    before.length + current.length + after.length + markers_length

  if available_width >= total_length then
    -- if we aren't even able to fit the current buffer into the
    -- available space that means the window is really narrow
    -- so don't show anything
    -- Merge all the buffers and render the components
    local buffers =
      utils.array_concat(before.buffers, current.buffers, after.buffers)
    for index, buf in ipairs(buffers) do
      line = line .. buf.component(index, table.getn(buffers))
    end
    return line, marker
  elseif available_width < current.length then
    return "", marker
  else
    if before.length >= after.length then
      before:drop(1)
      marker.left_count = marker.left_count + 1
    else
      after:drop(#after.buffers)
      marker.right_count = marker.right_count + 1
    end
    -- drop the markers if the window is too narrow
    -- this assumes we have dropped both before and after
    -- sections since if the space available is this small
    -- we have likely removed these
    if (current.length + markers_length) > available_width then
      marker.left_count = 0
      marker.right_count = 0
    end
    return truncate(before, current, after, available_width, marker), marker
  end
end

local function get_letter(buf)
  local first_letter = buf.filename:sub(1, 1)
  -- should only match alphanumeric characters
  local invalid_char = first_letter:match("[^%w]")

  if not state.current_letters[first_letter] and not invalid_char then
    state.current_letters[first_letter] = buf.id
    return first_letter
  end
  for letter in letters:gmatch(".") do
    if not state.current_letters[letter] then
      state.current_letters[letter] = buf.id
      return letter
    end
  end
end

local function render(buffers, tabs, options)
  local right_align = "%="
  local tab_components = ""
  local close_component, close_length = render_close(options.close_icon)
  local tabs_length = close_length

  -- Add the length of the tabs + close components to total length
  if table.getn(tabs) > 1 then
    for _, t in pairs(tabs) do
      if not vim.tbl_isempty(t) then
        tabs_length = tabs_length + t.length
        tab_components = tab_components .. t.component
      end
    end
  end

  -- Icons from https://fontawesome.com/cheatsheet
  local left_trunc_icon = options.left_trunc_marker
  local right_trunc_icon = options.right_trunc_marker
  -- measure the surrounding trunc items: padding + count + padding + icon + padding
  local left_element_size =
    strwidth(
    table.concat({padding, padding, left_trunc_icon, padding, padding})
  )
  local right_element_size =
    strwidth(table.concat({padding, padding, right_trunc_icon, padding}))

  local available_width = vim.o.columns - tabs_length - close_length
  local before, current, after = get_sections(buffers)
  local line, marker =
    truncate(
    before,
    current,
    after,
    available_width,
    {
      left_count = 0,
      right_count = 0,
      left_element_size = left_element_size,
      right_element_size = right_element_size
    }
  )

  if marker.left_count > 0 then
    local icon = render_trunc_marker(marker.left_count, left_trunc_icon)
    line = table.concat({highlights.background, icon, padding, line})
  end
  if marker.right_count > 0 then
    local icon = render_trunc_marker(marker.right_count, right_trunc_icon)
    line = table.concat({line, highlights.background, icon})
  end

  return table.concat(
    {
      line,
      highlights.fill,
      right_align,
      tab_components,
      highlights.close,
      close_component
    }
  )
end

--- @param mode string | nil
local function get_buffers_by_mode(mode)
  --[[
  show only relevant buffers depending on the layout of the current tabpage:
    - In tabs with only one window all buffers are listed.
    - In tabs with more than one window, only the buffers that are being displayed are listed.
--]]
  if mode == "multiwindow" then
    local is_single_tab = vim.fn.tabpagenr("$") == 1
    if is_single_tab then
      return utils.get_valid_buffers()
    end

    local tab_wins = api.nvim_tabpage_list_wins(0)

    local valid_wins = 0
    for _, win_id in ipairs(tab_wins) do
      -- Check that the window contains a listed buffer, if the buffer isn't
      -- listed we shouldn't be hiding the remaining buffers because of it
      -- note this is to stop temporary unlisted buffers like fzf from
      -- triggering this mode
      local buf_nr = vim.api.nvim_win_get_buf(win_id)
      if utils.is_valid(buf_nr) then
        valid_wins = valid_wins + 1
      end
    end

    if valid_wins > 1 then
      local unique = utils.filter_duplicates(vim.fn.tabpagebuflist())
      return utils.get_valid_buffers(unique)
    end
  end
  return utils.get_valid_buffers()
end

--- @param duplicates table
--- @param current Buffer
--- @buffers buffers table<Buffer>
--- @param prefs table
local function mark_duplicates(duplicates, current, buffers, prefs)
  local duplicate = duplicates[current.filename]
  if not duplicate then
    duplicates[current.filename] = {current}
  else
    for _, buf in ipairs(duplicate) do
      -- if the buffer is a duplicate we have to redraw it with the new name
      buf.duplicated = true
      buf.component, buf.length = render_buffer(prefs, buf)
      buffers[buf.ordinal] = buf
    end
    current.duplicated = true
    table.insert(duplicate, current)
  end
end

--- @param preferences table
--- @return string
local function bufferline(preferences)
  local options = preferences.options
  local buf_nums = get_buffers_by_mode(options.view)

  local all_tabs = tabs.get(options.separator_style)

  if not options.always_show_bufferline then
    if table.getn(buf_nums) == 1 then
      vim.o.showtabline = 0
      return
    end
  end

  state.buffers = {}
  state.current_letters = {}
  local duplicates = {}

  for i, buf_id in ipairs(buf_nums) do
    local name = vim.fn.bufname(buf_id)
    local buf =
      Buffer:new {
      path = name,
      id = buf_id,
      ordinal = i
    }

    mark_duplicates(duplicates, buf, state.buffers, preferences)
    buf.letter = get_letter(buf)

    buf.component, buf.length = render_buffer(preferences, buf)
    state.buffers[i] = buf
  end

  sorters.sort_buffers(preferences.options.sort_by, state.buffers)

  return render(state.buffers, all_tabs, options)
end

function M.go_to_buffer(num)
  local buf_nums = get_buffers_by_mode()
  if num <= table.getn(buf_nums) then
    vim.cmd("buffer " .. buf_nums[num])
  end
end

function M.cycle(direction)
  local current = api.nvim_get_current_buf()
  local index

  for i, buf in ipairs(state.buffers) do
    if buf.id == current then
      index = i
      break
    end
  end

  if not index then
    return
  end
  local length = table.getn(state.buffers)
  local next_index = index + direction

  if next_index <= length and next_index >= 1 then
    next_index = index + direction
  elseif index + direction <= 0 then
    next_index = length
  else
    next_index = 1
  end

  local next = state.buffers[next_index]

  if not next then
    vim.cmd('echoerr "This buffer does not exist"')
    return
  end

  vim.cmd("buffer " .. next.id)
end

function M.toggle_bufferline()
  local listed_bufs = vim.fn.getbufinfo({buflisted = 1})
  if table.getn(listed_bufs) > 1 then
    vim.o.showtabline = 2
  else
    vim.o.showtabline = 0
  end
end

-- TODO then validate user preferences and only set prefs that exists
function M.setup(prefs)
  local preferences = config.get_defaults()
  -- Combine user preferences with defaults preferring the user's own settings
  -- NOTE this should happen outside any of these inner functions to prevent the
  -- value being set within a closure
  if prefs and type(prefs) == "table" then
    utils.deep_merge(preferences, prefs)
  end

  function _G.__setup_bufferline_colors()
    local user_colors = preferences.highlights
    colors.set_highlight("BufferLineFill", user_colors.bufferline_fill)
    colors.set_highlight(
      "BufferLineInactive",
      user_colors.bufferline_buffer_inactive
    )
    colors.set_highlight(
      "BufferLineBackground",
      user_colors.bufferline_background
    )
    colors.set_highlight("BufferLineSelected", user_colors.bufferline_selected)
    colors.set_highlight(
      "BufferLineSelectedIndicator",
      user_colors.bufferline_selected_indicator
    )
    colors.set_highlight(
      "BufferLineDuplicate",
      user_colors.bufferline_duplicate
    )
    colors.set_highlight(
      "BufferLineDuplicateInactive",
      user_colors.bufferline_duplicate_inactive
    )
    colors.set_highlight("BufferLineModified", user_colors.bufferline_modified)
    colors.set_highlight(
      "BufferLineModifiedSelected",
      user_colors.bufferline_modified_selected
    )
    colors.set_highlight(
      "BufferLineModifiedInactive",
      user_colors.bufferline_modified_inactive
    )
    colors.set_highlight("BufferLineTab", user_colors.bufferline_tab)
    colors.set_highlight(
      "BufferLineSeparator",
      user_colors.bufferline_separator
    )
    colors.set_highlight(
      "BufferLineSelectedSeparator",
      user_colors.bufferline_selected_separator
    )
    colors.set_highlight(
      "BufferLineTabSelected",
      user_colors.bufferline_tab_selected
    )
    colors.set_highlight("BufferLineTabClose", user_colors.bufferline_tab_close)
    colors.set_highlight("BufferLinePick", user_colors.bufferline_pick)
    colors.set_highlight(
      "BufferLinePickInactive",
      user_colors.bufferline_pick_inactive
    )
  end

  local autocommands = {
    {"VimEnter", "*", [[lua __setup_bufferline_colors()]]},
    {"ColorScheme", "*", [[lua __setup_bufferline_colors()]]}
  }
  if not preferences.options.always_show_bufferline then
    -- toggle tabline
    table.insert(
      autocommands,
      {
        "VimEnter,BufAdd,TabEnter",
        "*",
        "lua require'bufferline'.toggle_bufferline()"
      }
    )
  end

  if devicons_loaded then
    table.insert(
      autocommands,
      {
        "ColorScheme",
        "*",
        [[lua require'nvim-web-devicons'.setup()]]
      }
    )
  end

  utils.nvim_create_augroups({BufferlineColors = autocommands})

  -----------------------------------------------------------
  -- Commands
  -----------------------------------------------------------
  vim.cmd('command BufferLinePick lua require"bufferline".pick_buffer()')
  vim.cmd('command BufferLineCycleNext lua require"bufferline".cycle(1)')
  vim.cmd('command BufferLineCyclePrev lua require"bufferline".cycle(-1)')

  -- TODO / idea: consider allowing these mappings to open buffers based on their
  -- visual position i.e. <leader>1 maps to the first visible buffer regardless
  -- of it actual ordinal number i.e. position in the full list or it's actual
  -- buffer id
  if preferences.options.mappings then
    for i = 1, 9 do
      api.nvim_set_keymap(
        "n",
        "<leader>" .. i,
        ':lua require"bufferline".go_to_buffer(' .. i .. ")<CR>",
        {
          silent = true,
          nowait = true,
          noremap = true
        }
      )
    end
  end

  function _G.nvim_bufferline()
    return bufferline(preferences)
  end

  vim.o.showtabline = 2
  vim.o.tabline = "%!v:lua.nvim_bufferline()"
end

return M
