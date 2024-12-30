local M = {}

function M.setup()
  local pretty_make_entry = require("pretty-telescope.make_entry")
  local origin_make_entry = require("telescope.make_entry")
  for key, value in pairs(pretty_make_entry) do
    origin_make_entry[key] = value
  end
end

return M
