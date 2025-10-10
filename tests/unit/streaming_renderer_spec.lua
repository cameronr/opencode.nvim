local streaming_renderer = require('opencode.ui.streaming_renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

local function load_test_data(filename)
  local f = io.open(filename, 'r')
  if not f then
    error('Could not open ' .. filename)
  end
  local content = f:read('*all')
  f:close()
  return vim.json.decode(content)
end

local function replay_events(events)
  for _, event in ipairs(events) do
    if event.type == 'message.updated' then
      streaming_renderer.handle_message_updated(event)
    elseif event.type == 'message.part.updated' then
      streaming_renderer.handle_part_updated(event)
    elseif event.type == 'message.removed' then
      streaming_renderer.handle_message_removed(event)
    elseif event.type == 'message.part.removed' then
      streaming_renderer.handle_part_removed(event)
    elseif event.type == 'session.compacted' then
      streaming_renderer.handle_session_compacted()
    end
  end
end

local function capture_output()
  local buf = state.windows.output_buf
  return {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    extmarks = vim.api.nvim_buf_get_extmarks(buf, streaming_renderer._namespace, 0, -1, { details = true }),
  }
end

describe('streaming_renderer', function()
  before_each(function()
    streaming_renderer.reset()
    state.windows = ui.create_windows()
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  it('replays simple-session correctly', function()
    local events = load_test_data('tests/data/simple-session.json')
    local expected = load_test_data('tests/data/simple-session.expected.json')

    replay_events(events)

    vim.wait(100)

    local actual = capture_output()

    assert.are.same(expected.lines, actual.lines)
    assert.are.same(expected.extmarks, actual.extmarks)
  end)
end)
