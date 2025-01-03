local entry_display = require("telescope.pickers.entry_display")
local utils = require("telescope.utils")
local pretty_utils = require("pretty-telescope.utils")
local Path = require("plenary.path")
local origin_make_entry = require("telescope.make_entry")

for key, value in pairs(pretty_utils) do
  utils[key] = value
end

local lsp_type_highlight = {
  ["Class"] = "TelescopeResultsClass",
  ["Constant"] = "TelescopeResultsConstant",
  ["Field"] = "TelescopeResultsField",
  ["Function"] = "TelescopeResultsFunction",
  ["Method"] = "TelescopeResultsMethod",
  ["Property"] = "TelescopeResultsOperator",
  ["Struct"] = "TelescopeResultsStruct",
  ["Variable"] = "TelescopeResultsVariable",
}

local get_filename_fn = function()
  local bufnr_name_cache = {}
  return function(bufnr)
    bufnr = vim.F.if_nil(bufnr, 0)
    local c = bufnr_name_cache[bufnr]
    if c then
      return c
    end

    local n = vim.api.nvim_buf_get_name(bufnr)
    bufnr_name_cache[bufnr] = n
    return n
  end
end

local handle_entry_index = function(opts, t, k)
  local override = ((opts or {}).entry_index or {})[k]
  if not override then
    return
  end

  local val, save = override(t, opts)
  if save then
    rawset(t, k, val)
  end
  return val
end

local make_entry = {}

do
  local lookup_keys = {
    ordinal = 1,
    value = 1,
    filename = 1,
    cwd = 2,
  }

  function make_entry.gen_from_file(opts)
    opts = opts or {}

    local cwd = utils.path_expand(opts.cwd or vim.loop.cwd())

    local mt_file_entry = {}

    mt_file_entry.cwd = cwd
    mt_file_entry.display = function(entry)
      return utils.create_path_display(entry, opts)
    end

    mt_file_entry.__index = function(t, k)
      local override = handle_entry_index(opts, t, k)
      if override then
        return override
      end

      local raw = rawget(mt_file_entry, k)
      if raw then
        return raw
      end

      if k == "path" then
        local retpath = Path:new({ t.cwd, t.value }):absolute()
        if not vim.loop.fs_access(retpath, "R") then
          retpath = t.value
        end
        return retpath
      end

      return rawget(t, rawget(lookup_keys, k))
    end

    if opts.file_entry_encoding then
      return function(line)
        line = vim.iconv(line, opts.file_entry_encoding, "utf8")
        return setmetatable({ line }, mt_file_entry)
      end
    else
      return function(line)
        return setmetatable({ line }, mt_file_entry)
      end
    end
  end
end

do
  local lookup_keys = {
    value = 1,
    ordinal = 1,
  }

  -- Gets called only once to parse everything out for the vimgrep, after that looks up directly.
  local parse_with_col = function(t)
    local _, _, filename, lnum, col, text = string.find(t.value, [[(..-):(%d+):(%d+):(.*)]])

    local ok
    ok, lnum = pcall(tonumber, lnum)
    if not ok then
      lnum = nil
    end

    ok, col = pcall(tonumber, col)
    if not ok then
      col = nil
    end

    t.filename = filename
    t.lnum = lnum
    t.col = col
    t.text = text

    return { filename, lnum, col, text }
  end

  local parse_without_col = function(t)
    local _, _, filename, lnum, text = string.find(t.value, [[(..-):(%d+):(.*)]])

    local ok
    ok, lnum = pcall(tonumber, lnum)
    if not ok then
      lnum = nil
    end

    t.filename = filename
    t.lnum = lnum
    t.col = nil
    t.text = text

    return { filename, lnum, nil, text }
  end

  local parse_only_filename = function(t)
    t.filename = t.value
    t.lnum = nil
    t.col = nil
    t.text = ""

    return { t.filename, nil, nil, "" }
  end

  function make_entry.gen_from_vimgrep(opts)
    opts = opts or {}

    local mt_vimgrep_entry
    local parse = parse_with_col
    if opts.__matches == true then
      parse = parse_only_filename
    elseif opts.__inverted == true then
      parse = parse_without_col
    end

    local only_sort_text = opts.only_sort_text

    local execute_keys = {
      path = function(t)
        if Path:new(t.filename):is_absolute() then
          return t.filename, false
        else
          return Path:new({ t.cwd, t.filename }):absolute(), false
        end
      end,

      filename = function(t)
        return parse(t)[1], true
      end,

      lnum = function(t)
        return parse(t)[2], true
      end,

      col = function(t)
        return parse(t)[3], true
      end,

      text = function(t)
        return parse(t)[4], true
      end,
    }

    -- For text search only, the ordinal value is actually the text.
    if only_sort_text then
      execute_keys.ordinal = function(t)
        return t.text
      end
    end

    mt_vimgrep_entry = {
      cwd = utils.path_expand(opts.cwd or vim.loop.cwd()),

      display = function(entry)
        local display, path_style = utils.create_path_display(entry, opts)
        display = string.format("%s:%s", display, entry.text)
        return display, path_style
      end,

      __index = function(t, k)
        local override = handle_entry_index(opts, t, k)
        if override then
          return override
        end

        local raw = rawget(mt_vimgrep_entry, k)
        if raw then
          return raw
        end

        local executor = rawget(execute_keys, k)
        if executor then
          local val, save = executor(t)
          if save then
            rawset(t, k, val)
          end
          return val
        end

        return rawget(t, rawget(lookup_keys, k))
      end,
    }

    return function(line)
      return setmetatable({ line }, mt_vimgrep_entry)
    end
  end
end

function make_entry.gen_from_quickfix(opts)
  opts = opts or {}
  local show_line = vim.F.if_nil(opts.show_line, true)

  local hidden = utils.is_path_hidden(opts)

  local make_display = function(entry)
    local display_string, path_style = utils.create_path_display(entry, opts)
    if hidden then
      display_string = string.format("%4d:%2d", entry.lnum, entry.col)
    end

    if show_line then
      local text = entry.text
      if opts.trim_text then
        text = vim.trim(text)
      end
      text = text:gsub(".* | ", "")
      display_string = display_string .. ":" .. text
    end

    return display_string, path_style
  end

  local get_filename = get_filename_fn()
  return function(entry)
    local filename = vim.F.if_nil(entry.filename, get_filename(entry.bufnr))

    return origin_make_entry.set_default_entry_mt({
      value = entry,
      ordinal = (not hidden and filename or "") .. " " .. entry.text,
      display = make_display,

      bufnr = entry.bufnr,
      filename = filename,
      lnum = entry.lnum,
      col = entry.col,
      text = entry.text,
      start = entry.start,
      finish = entry.finish,
    }, opts)
  end
end

function make_entry.gen_from_lsp_symbols(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  -- Default we have two columns, symbol and type(unbound)
  -- If path is not hidden then its, filepath, symbol and type(still unbound)
  -- If show_line is also set, type is bound to len 8
  local display_items = {
    { remaining = true },
    { width = opts.symbol_width or 25 },
  }

  local hidden = utils.is_path_hidden(opts)
  if not hidden then
    table.insert(display_items, { width = vim.F.if_nil(opts.fname_width, 30) })
  end

  if opts.show_line then
    -- bound type to len 8 or custom
    table.insert(display_items, #display_items, { width = opts.symbol_type_width or 8 })
  end

  local displayer = entry_display.create({
    separator = " ",
    hl_chars = { ["["] = "TelescopeBorder", ["]"] = "TelescopeBorder" },
    items = display_items,
  })
  local type_highlight = vim.F.if_nil(opts.symbol_highlights or lsp_type_highlight)

  local make_display = function(entry)
    local msg

    if opts.show_line then
      msg = vim.trim(
        vim.F.if_nil(vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1], "")
      )
    end

    local highlight = type_highlight[entry.symbol_type]
    if _G.MiniIcons ~= nil then
      local _, hi = _G.MiniIcons.get("lsp", entry.symbol_type:lower())
      highlight = hi
    end

    local icon = utils.kind_icons[entry.symbol_type]
    if hidden then
      return displayer({
        {
          icon .. " " .. entry.symbol_type:lower(),
          highlight,
        },
        entry.symbol_name,
        msg,
      })
    else
      local display_path, path_style = utils.create_path_display(entry, opts)
      return displayer({
        {
          icon .. " " .. entry.symbol_type:lower(),
          highlight,
        },
        entry.symbol_name,
        {
          display_path,
          function()
            return path_style
          end,
        },
        msg,
      })
    end
  end

  local get_filename = get_filename_fn()
  return function(entry)
    local filename = vim.F.if_nil(entry.filename, get_filename(entry.bufnr))
    local symbol_msg = entry.text
    local symbol_type, symbol_name = symbol_msg:match("%[(.+)%]%s+(.*)")
    local ordinal = ""
    if not hidden and filename then
      ordinal = filename .. " "
    end
    ordinal = ordinal .. symbol_name .. " " .. (symbol_type or "unknown")
    return origin_make_entry.set_default_entry_mt({
      value = entry,
      ordinal = ordinal,
      display = make_display,

      filename = filename,
      lnum = entry.lnum,
      col = entry.col,
      symbol_name = symbol_name,
      symbol_type = symbol_type,
      start = entry.start,
      finish = entry.finish,
    }, opts)
  end
end

function make_entry.gen_from_buffer(opts)
  opts = opts or {}

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = opts.bufnr_width },
      { width = 4 },
      { remaining = true },
    },
  })

  local cwd = utils.path_expand(opts.cwd or vim.loop.cwd())

  local make_display = function(entry)
    local display, style = utils.create_path_display(entry, opts)

    return displayer({
      { entry.bufnr, "TelescopeResultsNumber" },
      { entry.indicator, "TelescopeResultsComment" },
      {
        display,
        function()
          return style
        end,
      },
    })
  end

  return function(entry)
    local filename = entry.info.name ~= "" and entry.info.name or nil
    local bufname = filename and Path:new(filename):normalize(cwd) or "[No Name]"

    local hidden = entry.info.hidden == 1 and "h" or "a"
    local readonly = vim.api.nvim_buf_get_option(entry.bufnr, "readonly") and "=" or " "
    local changed = entry.info.changed == 1 and "+" or " "
    local indicator = entry.flag .. hidden .. readonly .. changed
    local lnum = 1

    -- account for potentially stale lnum as getbufinfo might not be updated or from resuming buffers picker
    if entry.info.lnum ~= 0 then
      -- but make sure the buffer is loaded, otherwise line_count is 0
      if vim.api.nvim_buf_is_loaded(entry.bufnr) then
        local line_count = vim.api.nvim_buf_line_count(entry.bufnr)
        lnum = math.max(math.min(entry.info.lnum, line_count), 1)
      else
        lnum = entry.info.lnum
      end
    end

    return origin_make_entry.set_default_entry_mt({
      value = bufname,
      ordinal = entry.bufnr .. " : " .. bufname,
      display = make_display,
      bufnr = entry.bufnr,
      path = filename,
      filename = bufname,
      lnum = lnum,
      indicator = indicator,
    }, opts)
  end
end

function make_entry.gen_from_registers(opts)
  local displayer = entry_display.create({
    separator = " ",
    hl_chars = { ["["] = "TelescopeBorder", ["]"] = "TelescopeBorder" },
    items = {
      { width = 3 },
      { remaining = true },
    },
  })

  local make_display = function(entry)
    local content = entry.content
    return displayer({
      { "[" .. entry.value .. "]", "TelescopeResultsNumber" },
      type(content) == "string" and content:gsub("\n", "\\n") or content,
    })
  end

  return function(entry)
    local contents = vim.fn.getreg(entry, 1)
    return origin_make_entry.set_default_entry_mt({
      value = entry,
      ordinal = string.format("%s %s", entry, contents),
      content = contents,
      display = make_display,
    }, opts)
  end
end

function make_entry.gen_from_vimoptions(opts)
  local displayer = entry_display.create({
    separator = "",
    hl_chars = { ["["] = "TelescopeBorder", ["]"] = "TelescopeBorder" },
    items = {
      { width = 25 },
      { width = 12 },
      { width = 11 },
      { remaining = true },
    },
  })

  local make_display = function(entry)
    return displayer({
      { entry.value.name, "Keyword" },
      { "[" .. entry.value.type .. "]", "Type" },
      { "[" .. entry.value.scope .. "]", "Identifier" },
      utils.display_termcodes(tostring(entry.value.value)),
    })
  end

  return function(o)
    local entry = {
      display = make_display,
      value = {
        name = o.name,
        value = o.default,
        type = o.type,
        scope = o.scope,
      },
      ordinal = string.format("%s %s %s", o.name, o.type, o.scope),
    }

    local ok, value = pcall(vim.api.nvim_get_option, o.name)
    if ok then
      entry.value.value = value
      entry.ordinal = entry.ordinal .. " " .. utils.display_termcodes(tostring(value))
    else
      entry.ordinal = entry.ordinal .. " " .. utils.display_termcodes(tostring(o.default))
    end

    return origin_make_entry.set_default_entry_mt(entry, opts)
  end
end

function make_entry.gen_from_ctags(opts)
  opts = opts or {}

  local cwd = utils.path_expand(opts.cwd or vim.loop.cwd())
  local current_file = Path:new(vim.api.nvim_buf_get_name(opts.bufnr)):normalize(cwd)

  local display_items = {
    { remaining = true },
  }

  local idx = 1
  local hidden = utils.is_path_hidden(opts)
  if not hidden then
    table.insert(display_items, idx, { width = vim.F.if_nil(opts.fname_width, 30) })
    idx = idx + 1
  end

  if opts.show_line then
    table.insert(display_items, idx, { width = 30 })
  end

  local displayer = entry_display.create({
    separator = " │ ",
    items = display_items,
  })

  local make_display = function(entry)
    local display_path, path_style = utils.create_path_display(entry, opts)

    local scode
    if opts.show_line then
      scode = entry.scode
    end

    if hidden then
      return displayer({
        entry.tag,
        scode,
      })
    else
      return displayer({
        {
          display_path,
          function()
            return path_style
          end,
        },
        entry.tag,
        scode,
      })
    end
  end

  local mt = {}
  mt.__index = function(t, k)
    local override = handle_entry_index(opts, t, k)
    if override then
      return override
    end

    if k == "path" then
      local retpath = Path:new({ t.filename }):absolute()
      if not vim.loop.fs_access(retpath, "R") then
        retpath = t.filename
      end
      return retpath
    end
  end

  local current_file_cache = {}
  return function(line)
    if line == "" or line:sub(1, 1) == "!" then
      return nil
    end

    local tag, file, scode, lnum
    -- ctags gives us: 'tags\tfile\tsource'
    tag, file, scode = string.match(line, '([^\t]+)\t([^\t]+)\t/^?\t?(.*)/;"\t+.*')
    if not tag then
      -- hasktags gives us: 'tags\tfile\tlnum'
      tag, file, lnum = string.match(line, "([^\t]+)\t([^\t]+)\t(%d+).*")
    end

    if Path.path.sep == "\\" then
      file = string.gsub(file, "/", "\\")
    end

    if opts.only_current_file then
      if current_file_cache[file] == nil then
        current_file_cache[file] = Path:new(file):normalize(cwd) == current_file
      end

      if current_file_cache[file] == false then
        return nil
      end
    end

    local tag_entry = {}
    if opts.only_sort_tags then
      tag_entry.ordinal = tag
    else
      tag_entry.ordinal = file .. ": " .. tag
    end

    tag_entry.display = make_display
    tag_entry.scode = scode
    tag_entry.tag = tag
    tag_entry.filename = file
    tag_entry.col = 1
    tag_entry.lnum = lnum and tonumber(lnum) or 1

    return setmetatable(tag_entry, mt)
  end
end

function make_entry.gen_from_diagnostics(opts)
  opts = opts or {}

  local type_diagnostic = vim.diagnostic.severity
  local signs = (function()
    if opts.no_sign then
      return
    end
    local signs = {}
    for _, severity in ipairs(type_diagnostic) do
      local status, sign = pcall(function()
        -- only the first char is upper all others are lowercalse
        return vim.trim(
          vim.fn.sign_getdefined("DiagnosticSign" .. severity:lower():gsub("^%l", string.upper))[1].text
        )
      end)
      if not status then
        sign = severity:sub(1, 1)
      end
      signs[severity] = sign
    end
    return signs
  end)()

  local sign_width
  if opts.disable_coordinates then
    sign_width = signs ~= nil and 2 or 0
  else
    sign_width = signs ~= nil and 10 or 8
  end

  local display_items = {
    { width = sign_width },
    { remaining = true },
  }
  local line_width = vim.F.if_nil(opts.line_width, 0.5)
  local line_width_opts = { width = line_width }
  if type(line_width) == "string" and line_width == "full" then
    line_width_opts = {}
  end
  local hidden = utils.is_path_hidden(opts)
  if not hidden then
    table.insert(display_items, 2, line_width_opts)
  end
  local displayer = entry_display.create({
    separator = "▏",
    items = display_items,
  })

  local make_display = function(entry)
    local display_path, path_style = utils.create_path_display(
      entry,
      vim.tbl_extend("force", opts, { disable_coordinates = true })
    )

    -- add styling of entries
    local pos = string.format("%4d:%2d", entry.lnum, entry.col)
    local line_info_text = signs and signs[entry.type] .. " " or ""
    local line_info = {
      opts.disable_coordinates and line_info_text or line_info_text .. pos,
      "DiagnosticSign" .. entry.type,
    }

    return displayer({
      line_info,
      entry.text,
      {
        display_path,
        function()
          return path_style
        end,
      },
    })
  end

  local errlist_type_map = {
    [type_diagnostic.ERROR] = "E",
    [type_diagnostic.WARN] = "W",
    [type_diagnostic.INFO] = "I",
    [type_diagnostic.HINT] = "N",
  }

  return function(entry)
    return origin_make_entry.set_default_entry_mt({
      value = entry,
      ordinal = ("%s %s"):format(not hidden and entry.filename or "", entry.text),
      display = make_display,
      filename = entry.filename,
      type = entry.type,
      lnum = entry.lnum,
      col = entry.col,
      text = entry.text,
      qf_type = errlist_type_map[type_diagnostic[entry.type]],
    }, opts)
  end
end

local git_icon_defaults = {
  added = "+",
  changed = "~",
  copied = ">",
  deleted = "-",
  renamed = "➡",
  unmerged = "‡",
  untracked = "?",
}

function make_entry.gen_from_git_status(opts)
  opts = opts or {}

  local col_width = ((opts.git_icons and opts.git_icons.added) and opts.git_icons.added:len() + 2)
    or 2
  local displayer = entry_display.create({
    separator = "",
    items = {
      { width = col_width },
      { width = col_width },
      { remaining = true },
    },
  })

  local icons = vim.tbl_extend("keep", opts.git_icons or {}, git_icon_defaults)

  local git_abbrev = {
    ["A"] = { icon = icons.added, hl = "TelescopeResultsDiffAdd" },
    ["U"] = { icon = icons.unmerged, hl = "TelescopeResultsDiffAdd" },
    ["M"] = { icon = icons.changed, hl = "TelescopeResultsDiffChange" },
    ["C"] = { icon = icons.copied, hl = "TelescopeResultsDiffChange" },
    ["R"] = { icon = icons.renamed, hl = "TelescopeResultsDiffChange" },
    ["D"] = { icon = icons.deleted, hl = "TelescopeResultsDiffDelete" },
    ["?"] = { icon = icons.untracked, hl = "TelescopeResultsDiffUntracked" },
  }

  local make_display = function(entry)
    local x = string.sub(entry.status, 1, 1)
    local y = string.sub(entry.status, -1)
    local status_x = git_abbrev[x] or {}
    local status_y = git_abbrev[y] or {}

    local display_path, path_style = utils.create_path_display(entry, opts)

    local empty_space = " "
    return displayer({
      { status_x.icon or empty_space, status_x.hl },
      { status_y.icon or empty_space, status_y.hl },
      {
        display_path,
        function()
          return path_style
        end,
      },
    })
  end

  return function(entry)
    if entry == "" then
      return nil
    end

    local mod, file = entry:match("^(..) (.+)$")
    -- Ignore entries that are the PATH in XY ORIG_PATH PATH
    -- (renamed or copied files)
    if not mod then
      return nil
    end

    return setmetatable({
      value = file,
      status = mod,
      ordinal = entry,
      display = make_display,
      path = Path:new({ opts.cwd, file }):absolute(),
    }, opts)
  end
end

return make_entry
