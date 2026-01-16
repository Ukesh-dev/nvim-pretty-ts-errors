-- Variable to hold the ID of the floating window
local diagnostic_win_id = nil
local diagnostic_buf_id = nil
local ns_id = vim.api.nvim_create_namespace("PrettyTsFormatDiagnostic")

local manage_diag_win = vim.api.nvim_create_augroup("ManageDiagnosticWindow", { clear = true })
local last_win = nil

-- Autocommand to close the diagnostic window when the cursor moves
vim.api.nvim_create_autocmd("WinEnter", {
  group = manage_diag_win,
  callback = function()
    local current_win_id = vim.api.nvim_get_current_win()
    if
      last_win
      and last_win == diagnostic_win_id
      and current_win_id
      and current_win_id ~= diagnostic_win_id
      and diagnostic_win_id
      and vim.api.nvim_win_is_valid(diagnostic_win_id)
    then
      vim.api.nvim_win_close(diagnostic_win_id, true)
      diagnostic_win_id = nil
      diagnostic_buf_id = nil
    end

    last_win = current_win_id
  end,
})

---@type table<vim.diagnostic.Severity,string>|nil
local default_icon_map

---get the default icon map from vim.diagnostic.severity
---@return table<vim.diagnostic.Severity,string>
local function get_default_icon_map()
  if default_icon_map then
    return default_icon_map
  end

  local icon_map = {}
  for k, v in pairs(vim.diagnostic.severity) do
    if string.len(k) == 1 and type(v) == "number" then
      icon_map[v] = k .. " "
    end
  end

  default_icon_map = icon_map
  return icon_map
end

--- Formats a single diagnostic into a Markdown string.
--- @param diagnostic table The diagnostic object.
--- @return table<string> The formatted diagnostic string.
local function format_diagnostic(diagnostic)
  local source = diagnostic.source or "nvim"
  local message = diagnostic.message
  -- typescript is for ts_ls
  -- ts is for vtsls
  if source == "typescript" or source == "ts" then
    local ok, formatted = pcall(vim.fn.PrettyTsFormat, message)
    if ok and formatted then
      message = formatted
    end
  end
  local message_lines = vim.split(message, "\n")
  local code = diagnostic.code

  local icon_map
  local diag_config = vim.diagnostic.config()
  if
    diag_config
    and type(diag_config.signs) == "table"
    and type(diag_config.signs.text) == "table"
  then
    icon_map = vim.diagnostic.config().signs.text
  else
    icon_map = get_default_icon_map()
  end

  local icon = icon_map[diagnostic.severity]

  local first = string.format("%s%s", icon, source)
  if code ~= nil then
    first = first .. string.format("(%s)", code)
  end

  local lines = { first }
  for i = 1, #message_lines do
    table.insert(lines, message_lines[i])
  end

  -- Simple Markdown formatting
  return lines
end

---@return string|nil
local function severity_to_hlgroup(severity)
  if severity == vim.diagnostic.severity.ERROR then
    return "DiagnosticSignError"
  elseif severity == vim.diagnostic.severity.HINT then
    return "DiagnosticSignHint"
  elseif severity == vim.diagnostic.severity.WARN then
    return "DiagnosticSignWarn"
  elseif severity == vim.diagnostic.severity.INFO then
    return "DiagnosticSignInfo"
  end
end

--- Gets all diagnostics for the current line.
--- @return table<string>, table A list of formatted diagnostic strings, or an empty list if none found.
local function get_diagnostics_for_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  -- vim.diagnostic.get with lnum gets all diagnostics on that line
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = cursor_row - 1 }) -- lnum is 0-indexed in API

  local line_count = 0

  local hl_positions = {}

  ---@type table<string>
  local formatted_diagnostics = {}
  for _, diag in ipairs(diagnostics) do
    for i, line in ipairs(format_diagnostic(diag)) do
      table.insert(formatted_diagnostics, line)
      if i == 1 then
        local hl_group = severity_to_hlgroup(diag.severity)
        if hl_group then
          table.insert(hl_positions, {
            hl_group,
            { line_count, 0 },
            { line_count, 1 },
          })
          table.insert(hl_positions, {
            "Bold",
            { line_count, 1 },
            { line_count, #line },
          })
        end
      end
      line_count = line_count + 1
    end
  end

  return formatted_diagnostics, hl_positions
end

local function get_window_size(lines, max_width)
  local height = #lines
  local width = 0

  for _, line in ipairs(lines) do
    -- Using vim.fn.strdisplaywidth accounts for tabs/multibyte chars
    local line_width = vim.fn.strdisplaywidth(line)
    if line_width > width then
      width = line_width
    end
  end

  -- Constrain width to a maximum
  width = math.min(width, max_width or 80)

  return width, height
end

--- Creates and displays a floating diagnostic window at the cursor with all diagnostics for the current line.
local function show_line_diagnostics()
  -- If window exists and is valid, toggle focus
  if diagnostic_win_id and vim.api.nvim_win_is_valid(diagnostic_win_id) then
    local current_win = vim.api.nvim_get_current_win()

    -- If we're currently in the diagnostic window, close it
    if current_win == diagnostic_win_id then
      vim.api.nvim_win_close(diagnostic_win_id, true)
      diagnostic_win_id = nil
      diagnostic_buf_id = nil
      return
    else
      -- Otherwise, focus the diagnostic window
      vim.api.nvim_set_current_win(diagnostic_win_id)
      return
    end
  end

  -- Create a new scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  diagnostic_buf_id = buf

  local diagnostic_messages, hl_positions = get_diagnostics_for_current_line()

  -- Do nothing if no diagnostics on the line
  if #diagnostic_messages == 0 then
    return
  end

  local lines = diagnostic_messages

  -- Set the content of the buffer
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, hl_pos in ipairs(hl_positions) do
    vim.hl.range(buf, ns_id, hl_pos[1], hl_pos[2], hl_pos[3])
  end

  local width, height = get_window_size(lines, 80) -- Max width of 80

  -- Set buffer options for the floating window
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  -- Open the floating window (focusable)
  diagnostic_win_id = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = true,
  })

  -- Set window options for wrapping
  vim.api.nvim_set_option_value("wrap", true, { win = diagnostic_win_id })
  vim.api.nvim_set_option_value("linebreak", true, { win = diagnostic_win_id })

  -- Now set buffer as readonly after window is created
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Set filetype and start treesitter
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.treesitter.start(buf, "markdown")

  -- Give render-markdown time to attach and render
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(diagnostic_win_id) then
      return
    end

    -- Trigger events that plugins like render-markdown listen to
    vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf })
    vim.cmd("redraw")
  end, 30)

  -- Add scroll keybindings that work from the original window
  local original_buf = vim.api.nvim_get_current_buf()
  local scroll_map_opts = { buffer = original_buf, nowait = true }

  -- Scroll down with <C-f>
  vim.keymap.set("n", "<C-f>", function()
    if diagnostic_win_id and vim.api.nvim_win_is_valid(diagnostic_win_id) then
      vim.api.nvim_win_call(diagnostic_win_id, function()
        vim.cmd("normal! \x06") -- <C-f> in the diagnostic window
      end)
    end
  end, scroll_map_opts)

  -- Scroll up with <C-b>
  vim.keymap.set("n", "<C-b>", function()
    if diagnostic_win_id and vim.api.nvim_win_is_valid(diagnostic_win_id) then
      vim.api.nvim_win_call(diagnostic_win_id, function()
        vim.cmd("normal! \x02") -- <C-b> in the diagnostic window
      end)
    end
  end, scroll_map_opts)

  -- Add keybinding to close with 'q' when inside the diagnostic window
  vim.keymap.set("n", "q", function()
    if diagnostic_win_id and vim.api.nvim_win_is_valid(diagnostic_win_id) then
      vim.api.nvim_win_close(diagnostic_win_id, true)
      diagnostic_win_id = nil
      diagnostic_buf_id = nil
    end
  end, { buffer = buf, nowait = true, desc = "Close diagnostic window" })

  -- Create the auto-close trigger (only when cursor moves in non-diagnostic window)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    once = true,
    callback = function()
      local current_win = vim.api.nvim_get_current_win()
      if
        current_win ~= diagnostic_win_id
        and diagnostic_win_id
        and vim.api.nvim_win_is_valid(diagnostic_win_id)
      then
        vim.api.nvim_win_close(diagnostic_win_id, true)
        diagnostic_win_id = nil
        diagnostic_buf_id = nil
      end
    end,
  })
end

-- Export the function
return {
  show_line_diagnostics = show_line_diagnostics,
}
