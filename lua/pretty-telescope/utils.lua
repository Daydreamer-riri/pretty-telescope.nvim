local utils = require("telescope.utils")
local pretty_utils = {}
local log = require("telescope.log")
local Path = require("plenary.path")
local truncate = require("plenary.strings").truncate
local get_status = require("telescope.state").get_status

pretty_utils.filter_symbols = function(results, opts, post_filter)
  local has_ignore = opts.ignore_symbols ~= nil
  local has_symbols = opts.symbols ~= nil
  local filtered_symbols

  if has_symbols and has_ignore then
    utils.notify("filter_symbols", {
      msg = "Either opts.symbols or opts.ignore_symbols, can't process opposing options at the same time!",
      level = "ERROR",
    })
    return
  elseif not (has_ignore or has_symbols) then
    return results
  elseif has_ignore then
    if type(opts.ignore_symbols) == "string" then
      opts.ignore_symbols = { opts.ignore_symbols }
    end
    if type(opts.ignore_symbols) ~= "table" then
      utils.notify("filter_symbols", {
        msg = "Please pass ignore_symbols as either a string or a list of strings",
        level = "ERROR",
      })
      return
    end

    opts.ignore_symbols = vim.tbl_map(string.lower, opts.ignore_symbols)
    filtered_symbols = vim.tbl_filter(function(item)
      return not vim.tbl_contains(opts.ignore_symbols, string.lower(item.kind))
    end, results)
  elseif has_symbols then
    if type(opts.symbols) == "string" then
      opts.symbols = { opts.symbols }
    end
    if type(opts.symbols) ~= "table" then
      utils.notify("filter_symbols", {
        msg = "Please pass filtering symbols as either a string or a list of strings",
        level = "ERROR",
      })
      return
    end

    opts.symbols = vim.tbl_map(string.lower, opts.symbols)
    filtered_symbols = vim.tbl_filter(function(item)
      return vim.tbl_contains(opts.symbols, string.lower(item.kind))
    end, results)
  end

  if type(post_filter) == "function" then
    filtered_symbols = post_filter(filtered_symbols)
  end

  if not vim.tbl_isempty(filtered_symbols) then
    return filtered_symbols
  end

  -- print message that filtered_symbols is now empty
  if has_symbols then
    local symbols = table.concat(opts.symbols, ", ")
    utils.notify("filter_symbols", {
      msg = string.format("%s symbol(s) were not part of the query results", symbols),
      level = "WARN",
    })
  elseif has_ignore then
    local symbols = table.concat(opts.ignore_symbols, ", ")
    utils.notify("filter_symbols", {
      msg = string.format(
        "%s ignore_symbol(s) have removed everything from the query result",
        symbols
      ),
      level = "WARN",
    })
  end
end

---@param path string
---@param coordinates string
---@return string
---@return table
local color_coordinates = function(path, coordinates)
  local path_style = {}
  if coordinates:len() > 0 then
    local coordinatesStart = path:find(coordinates)
    local lineEnd = coordinates:find(":", 2, true)
    if lineEnd ~= nil then
      table.insert(path_style, { { coordinatesStart, coordinatesStart + lineEnd - 2 }, "Blue" })
      table.insert(
        path_style,
        { { coordinatesStart + lineEnd - 1, coordinatesStart + #coordinates }, "Purple" }
      )
    else
      table.insert(path_style, { { coordinatesStart, coordinatesStart + #coordinates }, "Blue" })
    end
  end

  return path, path_style
end

---@param path string
---@param reverse_directories boolean
---@param is_dir boolean
---@param dir_hl string?
---@param coordinates string
---@return string
---@return table
local path_filename_first = function(path, reverse_directories, is_dir, dir_hl, coordinates)
  local sep = utils.get_separator()
  local dirs = vim.split(path, sep)
  local filename
  local path_style = {}

  if reverse_directories then
    dirs = utils.reverse_table(dirs)
    filename = table.remove(dirs, 1)
  else
    filename = table.remove(dirs, #dirs)
  end

  if is_dir then
    filename = filename .. sep
    table.insert(path_style, { { 0, #filename }, dir_hl })
  end

  local tail = table.concat(dirs, sep)
  -- Trim prevents a top-level filename to have a trailing white space
  local transformed_path = vim.trim(filename .. coordinates .. " " .. tail)
  table.insert(
    path_style,
    { { #transformed_path - #tail, #transformed_path }, "TelescopeResultsComment" }
  )

  local _, color_coordinates_style = color_coordinates(transformed_path, coordinates)
  path_style = utils.merge_styles(path_style, color_coordinates_style, 0)

  return transformed_path, path_style
end

--- Normalize path_display table into a form
---     { [option] = { sub-option table } }
--- where `option` is one of "hidden"|"absolute"|"shorten"|"smart"|"truncate"|"filename_first
--- and `sub-option` is a table with the associated sub-options for a give
--- `option`. This can be an empty table.
---@param path_display table
---@return table
local function path_display_table_normalize(path_display)
  local res = {}
  for i, v in pairs(path_display) do
    if type(i) == "number" then
      res[v] = {}
    elseif type(i) == "string" then
      if i == "shorten" and type(v) == "number" then
        res[i] = { len = v }
      elseif type(v) == "boolean" and v then
        res[i] = {}
      else
        res[i] = v
      end
    end
  end
  return res
end

local calc_result_length = function(truncate_len)
  local status = get_status(vim.api.nvim_get_current_buf())
  local len = vim.api.nvim_win_get_width(status.layout.results.winid)
    - status.picker.selection_caret:len()
    - 2
  return type(truncate_len) == "number" and len - truncate_len or len
end

local path_truncate = function(path, truncate_len, opts)
  if opts.__length == nil then
    opts.__length = calc_result_length(truncate_len)
  end
  if opts.__prefix == nil then
    opts.__prefix = 0
  end
  return truncate(path, opts.__length - opts.__prefix, nil, -1)
end

local path_shorten = function(path, length, exclude)
  if exclude ~= nil then
    return Path:new(path):shorten(length, exclude)
  else
    return Path:new(path):shorten(length)
  end
end

local path_abs = function(path, opts)
  local cwd
  if opts.cwd then
    cwd = opts.cwd
    if not vim.in_fast_event() then
      cwd = utils.path_expand(opts.cwd)
    end
  else
    cwd = vim.loop.cwd()
  end
  return Path:new(path):make_relative(cwd)
end

--- Transform path is a util function that formats a path based on path_display
--- found in `opts` or the default value from config.
--- It is meant to be used in make_entry to have a uniform interface for
--- builtins as well as extensions utilizing the same user configuration
---
--- Optionally can concatenate line and column number coordinates to the path
--- string when they are provided.
--- For all path_display options besides `filename_first`, the coordinates are
--- appended to the end of the path.
--- For `filename_first`, the coordinates are appended to the end of the
--- filename, before the rest of the path.
--- eg. `utils.lua:387:24 lua/telescope`
---
--- Note: It is only supported inside `make_entry`/`make_display` the use of
--- this function outside of telescope might yield to undefined behavior and will
--- not be addressed by us
---@param opts table: The opts the users passed into the picker. Might contains a path_display key
---@param path string|nil: The path that should be formatted
---@param coordinates string|nil: Line and colunm numbers to be displayed (eg. ':395:86')
---@return string: path to be displayed
---@return table: The transformed path ready to be displayed with the styling
pretty_utils.transform_path = function(opts, path, coordinates)
  coordinates = vim.F.if_nil(coordinates, "")

  if path == nil then
    return coordinates, {}
  end
  if utils.is_uri(path) then
    return path .. coordinates, {}
  end

  ---@type fun(opts:table, path: string): string, table?
  local path_display =
    vim.F.if_nil(opts.path_display, require("telescope.config").values.path_display)
  local transformed_path = path
  local path_style = {}

  if type(path_display) == "function" then
    local custom_transformed_path, custom_path_style = path_display(opts, transformed_path)
    return custom_transformed_path .. coordinates, custom_path_style or path_style
  end

  if utils.is_path_hidden(opts, path_display) then
    return coordinates, path_style
  end

  if type(path_display) ~= "table" then
    log.warn(
      "`path_display` must be either a function or a table.",
      "See `:help telescope.defaults.path_display."
    )
    return transformed_path .. coordinates, path_style
  end

  local display_opts = path_display_table_normalize(path_display)
  local is_dir = opts.dir_hl and vim.fn.isdirectory(path) == 1 or false
  local sep = utils.get_separator()

  if display_opts.tail then
    transformed_path = utils.path_tail(transformed_path)
    if is_dir then
      transformed_path = transformed_path .. sep
      table.insert(path_style, { { 0, #transformed_path }, opts.dir_hl })
    end
    return transformed_path .. coordinates, path_style
  end

  if not display_opts.absolute then
    transformed_path = path_abs(transformed_path, opts)
  end
  if display_opts.smart then
    transformed_path = utils.path_smart(transformed_path)
  end
  if display_opts.shorten then
    transformed_path =
      path_shorten(transformed_path, display_opts.shorten.len, display_opts.shorten.exclude)
  end
  if display_opts.truncate then
    transformed_path = path_truncate(transformed_path, display_opts.truncate, opts)
  end

  if display_opts.filename_first then
    return path_filename_first(
      transformed_path,
      display_opts.filename_first.reverse_directories,
      is_dir,
      opts.dir_hl,
      coordinates
    )
  end

  if is_dir then
    transformed_path = transformed_path .. sep
    table.insert(path_style, { { 0, #transformed_path }, opts.dir_hl })
  end

  return transformed_path .. coordinates, path_style
end

-- this breaks tree-sitter-lua docgen
-- ---@class telescope.create_path_display.opts
-- ---@field path_display table|function(opts:table, path:string): string, table?
-- ---@field disable_devicons boolean?
-- ---@field disable_coordinates boolean?
-- ---@field dir_hl string? If set, the directory part of the path will be highlighted with this hl group

--- Combines devicon, path and lnum/col into a single string and calculates hl
--- group and positions for a given entry record.
---
--- Should be the preferred method to create a path display for an entry, semi-obsoleting
--- |telescope.utils.transform_path|.
---@param entry table: telescope.entry
---@param opts table: telescope.create_path_display.opts
---@return string diplay string with devicons, path and coordinates
---@return table style table with hl groups and positions
pretty_utils.create_path_display = function(entry, opts)
  local path = require("telescope.from_entry").path(entry, false, false)

  local coordinates = ""
  if not opts.disable_coordinates then
    if entry.lnum then
      if entry.col then
        coordinates = string.format(":%s:%s", entry.lnum, entry.col)
      else
        coordinates = string.format(":%s", entry.lnum)
      end
    end
  end

  local hl_group, icon
  local display, path_style = utils.transform_path(opts, path, coordinates)
  display, hl_group, icon = utils.transform_devicons(path, display, opts.disable_devicons)

  if hl_group then
    local style = { { { 0, #icon + 1 }, hl_group } }
    style = utils.merge_styles(style, path_style, #icon + 1)
    return display, style
  else
    return display, path_style
  end
end

pretty_utils.kind_icons = {
  Text = "󰉿",
  Class = "󱡠",
  Value = "󰦨",
  Keyword = "󰻾",
  Color = "󰏘",
  String = "",
  Array = "",
  Object = "󰅩",
  Namespace = "",
  Method = "m",
  Function = "󰊕",
  Constructor = "",
  Field = "",
  Variable = "󰫧",
  Interface = "",
  Module = "",
  Property = "",
  Unit = "",
  Enum = "",
  Snippet = "",
  File = "",
  Reference = "",
  Folder = "",
  EnumMember = "",
  Constant = "",
  Struct = "",
  Event = "",
  Operator = "",
  TypeParameter = "",
  Boolean = "",
}

return pretty_utils
