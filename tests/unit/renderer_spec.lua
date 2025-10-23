local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local assert = require('luassert')

local function assert_output_matches(expected, actual, name)
  local normalized_extmarks = helpers.normalize_namespace_ids(actual.extmarks)

  assert.are.equal(
    #expected.lines,
    #actual.lines,
    string.format(
      'Line count mismatch: expected %d, got %d.\nFirst difference at index %d:\n  Expected: %s\n  Actual: %s',
      #expected.lines,
      #actual.lines,
      math.min(#expected.lines, #actual.lines) + 1,
      vim.inspect(expected.lines[math.min(#expected.lines, #actual.lines) + 1]),
      vim.inspect(actual.lines[math.min(#expected.lines, #actual.lines) + 1])
    )
  )

  for i = 1, #expected.lines do
    assert.are.equal(
      expected.lines[i],
      actual.lines[i],
      string.format(
        'Line %d mismatch:\n  Expected: %s\n  Actual: %s',
        i,
        vim.inspect(expected.lines[i]),
        vim.inspect(actual.lines[i])
      )
    )
  end

  assert.are.equal(
    #expected.extmarks,
    #normalized_extmarks,
    string.format(
      'Extmark count mismatch: expected %d, got %d.\nFirst difference at index %d:\n  Expected: %s\n  Actual: %s',
      #expected.extmarks,
      #normalized_extmarks,
      math.min(#expected.extmarks, #normalized_extmarks) + 1,
      vim.inspect(expected.extmarks[math.min(#expected.extmarks, #normalized_extmarks) + 1]),
      vim.inspect(normalized_extmarks[math.min(#expected.extmarks, #normalized_extmarks) + 1])
    )
  )

  for i = 1, #expected.extmarks do
    assert.are.same(
      expected.extmarks[i],
      normalized_extmarks[i],
      string.format(
        'Extmark %d mismatch:\n  Expected: %s\n  Actual: %s',
        i,
        vim.inspect(expected.extmarks[i]),
        vim.inspect(normalized_extmarks[i])
      )
    )
  end

  local expected_action_count = expected.actions and #expected.actions or 0
  local actual_action_count = actual.actions and #actual.actions or 0

  assert.are.equal(
    expected_action_count,
    actual_action_count,
    string.format('Action count mismatch: expected %d, got %d', expected_action_count, actual_action_count)
  )

  if expected.actions then
    local function sort_actions(actions)
      local sorted = vim.deepcopy(actions)
      table.sort(sorted, function(a, b)
        return vim.inspect(a) < vim.inspect(b)
      end)
      return sorted
    end

    assert.same(
      sort_actions(expected.actions),
      sort_actions(actual.actions),
      string.format(
        'Actions mismatch:\n  Expected: %s\n  Actual: %s',
        vim.inspect(expected.actions),
        vim.inspect(actual.actions)
      )
    )
  end

  local expected_unrendered = expected.unrendered_messages or {}
  local actual_unrendered = actual.unrendered_messages or {}

  if expected.unrendered_messages ~= nil then
    assert.are.equal(
      #expected_unrendered,
      #actual_unrendered,
      string.format('Unrendered message count mismatch: expected %d, got %d', #expected_unrendered, #actual_unrendered)
    )

    assert.same(
      expected_unrendered,
      actual_unrendered,
      string.format(
        'Unrendered messages mismatch:\n  Expected: %s\n  Actual: %s',
        vim.inspect(expected_unrendered),
        vim.inspect(actual_unrendered)
      )
    )
  end
end

describe('renderer', function()
  local restore_time_ago

  before_each(function()
    helpers.replay_setup()
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  local json_files = vim.fn.glob('tests/data/*.json', false, true)

  -- Don't do the full session test on these files, usually
  -- because they involve permission prompts
  local skip_full_session = {
    'permission-prompt',
    'shifting-and-multiple-perms',
    'message-removal',
  }

  for _, filepath in ipairs(json_files) do
    local name = vim.fn.fnamemodify(filepath, ':t:r')

    if not name:match('%.expected$') then
      local expected_path = 'tests/data/' .. name .. '.expected.json'

      if vim.fn.filereadable(expected_path) == 1 then
        it('replays ' .. name .. ' correctly (event-by-event)', function()
          local events = helpers.load_test_data(filepath)
          state.active_session = helpers.get_session_from_events(events)
          local expected = helpers.load_test_data(expected_path)

          helpers.replay_events(events)
          vim.wait(200)

          local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
          assert_output_matches(expected, actual, name)
        end)

        if not vim.tbl_contains(skip_full_session, name) then
          it('replays ' .. name .. ' correctly (session)', function()
            local renderer = require('opencode.ui.renderer')
            local events = helpers.load_test_data(filepath)
            state.active_session = helpers.get_session_from_events(events, true)
            local expected = helpers.load_test_data(expected_path)

            local session_data = helpers.load_session_from_events(events)
            renderer._render_full_session_data(session_data)
            vim.wait(200)

            local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
            assert_output_matches(expected, actual, name)
          end)
        end
      end
    end
  end

  describe('unrendered messages', function()
    local renderer

    before_each(function()
      renderer = require('opencode.ui.renderer')
    end)

    it('is_message_unrendered returns true for unrendered message', function()
      local rendered_message = { line_start = -1, line_end = -1 }
      local render_state = require('opencode.ui.render_state')
      local rs = render_state.new()
      assert.is_true(rs:is_message_unrendered(rendered_message))
    end)

    it('is_message_unrendered returns false for rendered message', function()
      local rendered_message = { line_start = 1, line_end = 5 }
      local render_state = require('opencode.ui.render_state')
      local rs = render_state.new()
      assert.is_false(rs:is_message_unrendered(rendered_message))
    end)

    it('is_message_unrendered returns false for nil', function()
      local render_state = require('opencode.ui.render_state')
      local rs = render_state.new()
      assert.is_false(rs:is_message_unrendered(nil))
    end)

    it('_remove_message_from_buffer removes unrendered message', function()
      local msg = { info = { id = 'msg1' } }
      renderer._render_state:set_message(msg, -1, -1)

      renderer._remove_message_from_buffer('msg1')

      assert.is_nil(renderer._render_state:get_message('msg1'))
    end)

    it('_replace_message_in_buffer returns false for unrendered message', function()
      local msg = { info = { id = 'msg1' } }
      renderer._render_state:set_message(msg, -1, -1)
      local Output = require('opencode.ui.output')
      local formatted = Output:new()
      formatted.lines = { 'test' }

      local success = renderer._replace_message_in_buffer('msg1', formatted)

      assert.is_false(success)
    end)
  end)
end)
