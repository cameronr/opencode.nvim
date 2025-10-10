local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local M = {}

M._part_cache = {}
M._message_cache = {}
M._session_id = nil
M._namespace = vim.api.nvim_create_namespace('opencode_stream')

function M.reset()
  M._part_cache = {}
  M._message_cache = {}
  M._session_id = nil
end

function M._get_buffer_line_count()
  if not state.windows or not state.windows.output_buf then
    return 0
  end
  return vim.api.nvim_buf_line_count(state.windows.output_buf)
end

function M._is_streaming_update(part_id, new_text)
  local cached = M._part_cache[part_id]
  if not cached or not cached.text then
    return false
  end

  local old_text = cached.text
  if #new_text < #old_text then
    return false
  end

  return new_text:sub(1, #old_text) == old_text
end

function M._calculate_delta(part_id, new_text)
  local cached = M._part_cache[part_id]
  if not cached or not cached.text then
    return new_text
  end

  local old_text = cached.text
  return new_text:sub(#old_text + 1)
end

function M._shift_lines(from_line, delta)
  if delta == 0 then
    return
  end

  for part_id, part_data in pairs(M._part_cache) do
    if part_data.line_start and part_data.line_start >= from_line then
      part_data.line_start = part_data.line_start + delta
      if part_data.line_end then
        part_data.line_end = part_data.line_end + delta
      end
    end
  end

  for msg_id, msg_data in pairs(M._message_cache) do
    if msg_data.line_start and msg_data.line_start >= from_line then
      msg_data.line_start = msg_data.line_start + delta
      if msg_data.line_end then
        msg_data.line_end = msg_data.line_end + delta
      end
    end
  end
end

function M._apply_extmarks(buf, line_offset, extmarks)
  if not extmarks or type(extmarks) ~= 'table' then
    return
  end

  for line_idx, marks in pairs(extmarks) do
    if type(marks) == 'table' then
      for _, mark in ipairs(marks) do
        local actual_mark = mark
        if type(mark) == 'function' then
          actual_mark = mark()
        end
        
        if type(actual_mark) == 'table' then
          local target_line = line_offset + line_idx - 1
          pcall(vim.api.nvim_buf_set_extmark, buf, M._namespace, target_line, 0, actual_mark)
        end
      end
    end
  end
end

function M._text_to_lines(text)
  if not text or text == '' then
    return {}
  end
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line)
  end
  return lines
end

function M._append_delta_to_buffer(part_id, delta)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_end then
    return false
  end

  if not state.windows or not state.windows.output_buf then
    return false
  end

  local buf = state.windows.output_buf
  local delta_lines = M._text_to_lines(delta)

  if #delta_lines == 0 then
    return true
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })

  local last_line = vim.api.nvim_buf_get_lines(buf, cached.line_end, cached.line_end + 1, false)[1] or ''
  local first_delta_line = table.remove(delta_lines, 1)
  local new_last_line = last_line .. first_delta_line

  local ok = pcall(vim.api.nvim_buf_set_lines, buf, cached.line_end, cached.line_end + 1, false, { new_last_line })

  if ok and #delta_lines > 0 then
    ok = pcall(vim.api.nvim_buf_set_lines, buf, cached.line_end + 1, cached.line_end + 1, false, delta_lines)
    if ok then
      local old_line_end = cached.line_end
      cached.line_end = cached.line_end + #delta_lines
      M._shift_lines(old_line_end + 1, #delta_lines)
    end
  end

  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  return ok
end

function M._write_formatted_data(formatted_data, message_cache)
  if not state.windows or not state.windows.output_buf then
    return nil
  end

  local buf = state.windows.output_buf
  local buf_lines = M._get_buffer_line_count()
  local new_lines = formatted_data.lines

  if #new_lines == 0 then
    return nil
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, buf_lines, -1, false, new_lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if not ok then
    return nil
  end

  M._apply_extmarks(buf, buf_lines, formatted_data.extmarks)

  return {
    line_start = buf_lines,
    line_end = buf_lines + #new_lines - 1,
  }
end

function M._write_message_header(message, msg_idx)
  local formatter = require('opencode.ui.session_formatter')
  local header_data = formatter.format_message_header_isolated(message, msg_idx)
  local line_range = M._write_formatted_data(header_data, nil)
  return line_range
end

function M._replace_part_in_buffer(part_id, formatted_data)
  local cached = M._part_cache[part_id]
  if not cached then
    return false
  end

  if not state.windows or not state.windows.output_buf then
    return false
  end

  local buf = state.windows.output_buf
  local new_lines = formatted_data.lines

  local old_line_count = 0
  if cached.line_start and cached.line_end then
    old_line_count = cached.line_end - cached.line_start + 1
  end

  local new_line_count = #new_lines

  if cached.line_start and cached.line_end then
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, cached.line_start, cached.line_end + 1, false, new_lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

    if not ok then
      return false
    end

    cached.line_end = cached.line_start + new_line_count - 1

    M._apply_extmarks(buf, cached.line_start, formatted_data.extmarks)

    local line_delta = new_line_count - old_line_count
    if line_delta ~= 0 then
      M._shift_lines(cached.line_end + 1, line_delta)
    end
  else
    local buf_lines = M._get_buffer_line_count()
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, buf_lines, -1, false, new_lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

    if not ok then
      return false
    end

    if new_line_count > 0 then
      cached.line_start = buf_lines
      cached.line_end = buf_lines + new_line_count - 1
    end

    M._apply_extmarks(buf, cached.line_start, formatted_data.extmarks)
  end

  return true
end

function M._remove_part_from_buffer(part_id)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_start or not cached.line_end then
    M._part_cache[part_id] = nil
    return
  end

  if not state.windows or not state.windows.output_buf then
    M._part_cache[part_id] = nil
    return
  end

  local buf = state.windows.output_buf
  local line_count = cached.line_end - cached.line_start + 1

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  pcall(vim.api.nvim_buf_set_lines, buf, cached.line_start, cached.line_end + 1, false, {})
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  M._shift_lines(cached.line_end + 1, -line_count)
  M._part_cache[part_id] = nil
end

function M.handle_message_updated(event)
  if not event or not event.properties or not event.properties.info then
    return
  end

  local message = event.properties.info
  if not message.id or not message.sessionID then
    return
  end

  if M._session_id and M._session_id ~= message.sessionID then
    M.reset()
  end

  M._session_id = message.sessionID

  if not M._message_cache[message.id] then
    local msg_idx = 1
    for _, cached_msg in pairs(M._message_cache) do
      if cached_msg.msg_idx then
        msg_idx = math.max(msg_idx, cached_msg.msg_idx + 1)
      end
    end

    M._message_cache[message.id] = {
      info = message,
      parts = {},
      line_start = nil,
      line_end = nil,
      has_header = false,
      msg_idx = msg_idx,
    }
  else
    M._message_cache[message.id].info = message
  end
end

function M.handle_part_updated(event)
  if not event or not event.properties or not event.properties.part then
    return
  end

  local part = event.properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  if M._session_id and M._session_id ~= part.sessionID then
    M.reset()
  end

  M._session_id = part.sessionID

  local message_cache = M._message_cache[part.messageID]
  if not message_cache then
    local msg_idx = 1
    for _, cached_msg in pairs(M._message_cache) do
      if cached_msg.msg_idx then
        msg_idx = math.max(msg_idx, cached_msg.msg_idx + 1)
      end
    end

    M._message_cache[part.messageID] = {
      info = nil,
      parts = {},
      line_start = nil,
      line_end = nil,
      has_header = false,
      msg_idx = msg_idx,
    }
    message_cache = M._message_cache[part.messageID]
  end

  if message_cache.info and not message_cache.has_header then
    vim.notify('DEBUG: Writing header for msg ' .. part.messageID .. ', role=' .. (message_cache.info.role or 'nil'))
    local header_range = M._write_message_header(message_cache.info, message_cache.msg_idx)
    if header_range then
      message_cache.has_header = true
      message_cache.line_start = header_range.line_start
      message_cache.line_end = header_range.line_end
      vim.notify('DEBUG: Header written, lines ' .. header_range.line_start .. '-' .. header_range.line_end)
    else
      vim.notify('DEBUG: Header write FAILED')
    end
  end

  local is_new_part = not M._part_cache[part.id]
  if is_new_part then
    table.insert(message_cache.parts, part.id)
  end

  local part_text = part.text or ''

  if not is_new_part and M._is_streaming_update(part.id, part_text) then
    local delta = M._calculate_delta(part.id, part_text)
    local success = M._append_delta_to_buffer(part.id, delta)
  else
    if not M._part_cache[part.id] then
      M._part_cache[part.id] = {
        text = nil,
        line_start = nil,
        line_end = nil,
        message_id = part.messageID,
        type = part.type,
      }
    end

    if not message_cache.info then
      vim.notify('DEBUG: No msg info for part ' .. part.id .. ', using fallback')
      M._replace_part_in_buffer(part.id, { lines = M._text_to_lines(part_text), extmarks = {} })
      M._part_cache[part.id].text = part_text
    else
      vim.notify('DEBUG: Formatting part ' .. part.id .. ', type=' .. (part.type or 'nil') .. ', role=' .. (message_cache.info.role or 'nil') .. ', synthetic=' .. tostring(part.synthetic))
      local part_idx = 0
      for i, pid in ipairs(message_cache.parts) do
        if pid == part.id then
          part_idx = i
          break
        end
      end

      local message_with_parts = vim.tbl_extend('force', message_cache.info, {
        parts = {}
      })
      
      for _, pid in ipairs(message_cache.parts) do
        if pid == part.id then
          table.insert(message_with_parts.parts, part)
        else
          local cached_part = M._part_cache[pid]
          if cached_part then
            table.insert(message_with_parts.parts, {
              id = pid,
              messageID = cached_part.message_id,
              type = cached_part.type,
              text = cached_part.text,
            })
          end
        end
      end

      local formatter = require('opencode.ui.session_formatter')
      local ok, formatted = pcall(formatter.format_part_isolated, part, {
        msg_idx = message_cache.msg_idx,
        part_idx = part_idx,
        role = message_cache.info.role,
        message = message_with_parts,
      })

      if not ok then
        vim.notify('DEBUG: Formatter ERROR: ' .. tostring(formatted))
        return
      end

      vim.notify('DEBUG: Formatted result has ' .. #formatted.lines .. ' lines: ' .. vim.inspect(formatted.lines))
      local success = M._replace_part_in_buffer(part.id, formatted)
      vim.notify('DEBUG: _replace_part_in_buffer returned ' .. tostring(success))
      M._part_cache[part.id].text = part_text
    end
  end
end

function M.handle_part_removed(event)
  if not event or not event.properties then
    return
  end

  local part_id = event.properties.partID
  if not part_id then
    return
  end

  local cached = M._part_cache[part_id]
  if cached and cached.message_id then
    local message_cache = M._message_cache[cached.message_id]
    if message_cache and message_cache.parts then
      for i, pid in ipairs(message_cache.parts) do
        if pid == part_id then
          table.remove(message_cache.parts, i)
          break
        end
      end
    end
  end

  M._remove_part_from_buffer(part_id)
end

function M.handle_message_removed(event)
  if not event or not event.properties then
    return
  end

  local message_id = event.properties.messageID
  if not message_id then
    return
  end

  local message_cache = M._message_cache[message_id]
  if not message_cache or not message_cache.parts then
    M._message_cache[message_id] = nil
    return
  end

  for _, part_id in ipairs(message_cache.parts) do
    M._remove_part_from_buffer(part_id)
  end

  M._message_cache[message_id] = nil
end

function M.handle_session_compacted()
  M.reset()
  vim.notify('handle_session_compacted')
  require('opencode.ui.output_renderer').render(state.windows, true)
end

function M.reset_and_render()
  M.reset()
  vim.notify('reset and render')
  require('opencode.ui.output_renderer').render(state.windows, true)
end

return M
