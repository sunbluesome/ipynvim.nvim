--- bridge.lua - Manages the bridge.py subprocess for Jupyter kernel communication.
---
--- Communicates with bridge.py via stdin/stdout JSON Lines.
--- Each request gets a unique ID; responses are routed to pending callbacks.

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

---@type integer|nil  jobstart() handle
local job_id = nil

--- Map from request_id (string) to callback table.
---@type table<string, { on_output: function|nil, on_done: function|nil }>
local pending_requests = {}

--- Incrementing counter for unique request IDs.
local req_counter = 0

--- Buffer for partial stdout lines (jobstart may split output arbitrarily).
local line_buf = ""

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Generate a unique request ID string.
---@return string
local function next_request_id()
  req_counter = req_counter + 1
  return string.format("req_%06d", req_counter)
end

--- Find the absolute path of bridge.py relative to this Lua file.
---@return string|nil path
local function find_bridge_py()
  -- This file is at <plugin_root>/lua/ipynvim/bridge.lua
  -- bridge.py is at   <plugin_root>/python/bridge.py
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if not src then
    return nil
  end
  -- Strip leading "@" added by Lua
  local lua_path = src:gsub("^@", "")
  -- lua_path = .../lua/ipynvim/bridge.lua  -> go up 3 levels
  local plugin_root = lua_path:gsub("/lua/ipynvim/bridge%.lua$", "")
  local bridge = plugin_root .. "/python/bridge.py"
  if vim.fn.filereadable(bridge) == 1 then
    return bridge
  end
  return nil
end

--- Write a JSON request line to the bridge process stdin.
---@param method string
---@param params table
---@param on_output function|nil  Called for each streaming output
---@param on_done function|nil    Called with final result
---@return string|nil request_id  nil if bridge not running
local function send_request(method, params, on_output, on_done)
  if not job_id then
    return nil
  end

  local request_id = next_request_id()
  pending_requests[request_id] = { on_output = on_output, on_done = on_done }

  local line = vim.fn.json_encode({
    id = request_id,
    method = method,
    params = params or {},
  })

  vim.fn.chansend(job_id, line .. "\n")
  return request_id
end

--- Parse a single JSON line and dispatch to the appropriate callback.
---@param line string  One complete JSON line from bridge stdout
local function dispatch_line(line)
  if line == "" then
    return
  end

  local ok, msg = pcall(vim.fn.json_decode, line)
  if not ok or type(msg) ~= "table" then
    vim.schedule(function()
      vim.notify("[ipynvim bridge] Bad JSON from bridge: " .. line, vim.log.levels.WARN)
    end)
    return
  end

  local request_id = msg.id
  if not request_id then
    return
  end

  local callbacks = pending_requests[request_id]
  if not callbacks then
    return
  end

  if msg.stream then
    -- Streaming output
    if callbacks.on_output then
      local output = msg.output
      vim.schedule(function()
        callbacks.on_output(output)
      end)
    end
  else
    -- Final response (ok or error)
    pending_requests[request_id] = nil
    if callbacks.on_done then
      local result = msg.ok and msg.result or { error = msg.error, ok = false }
      vim.schedule(function()
        callbacks.on_done(result)
      end)
    end
  end
end

--- Handle raw stdout data from jobstart (may contain partial lines).
---@param _job_id integer
---@param data string[]
---@param _event string
local function on_stdout(_job_id, data, _event)
  -- jobstart delivers data as a list of strings split on newlines.
  -- The last element may be an incomplete line (continuation in the next call).
  for i, chunk in ipairs(data) do
    if i < #data then
      -- Complete line: prepend any leftover buffer
      local full_line = line_buf .. chunk
      line_buf = ""
      dispatch_line(full_line)
    else
      -- Last chunk: might be incomplete; accumulate
      line_buf = line_buf .. chunk
    end
  end
end

--- Handle job exit.
---@param _job_id integer
---@param exit_code integer
---@param _event string
local function on_exit(_job_id, exit_code, _event)
  job_id = nil
  line_buf = ""
  -- Notify any waiting callbacks that the process died
  local leftover = pending_requests
  pending_requests = {}
  vim.schedule(function()
    if exit_code ~= 0 then
      vim.notify(
        string.format("[ipynvim bridge] bridge.py exited with code %d", exit_code),
        vim.log.levels.WARN
      )
    end
    for _, callbacks in pairs(leftover) do
      if callbacks.on_done then
        callbacks.on_done({ ok = false, error = "bridge process exited" })
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Start the bridge subprocess and send kernel_start.
---@param opts? { kernel_name: string|nil, cwd: string|nil, on_ready: function|nil }
function M.start(opts)
  opts = opts or {}

  if job_id then
    vim.notify("[ipynvim bridge] Bridge already running", vim.log.levels.WARN)
    return
  end

  local bridge_py = find_bridge_py()
  if not bridge_py then
    vim.notify("[ipynvim bridge] Cannot find bridge.py", vim.log.levels.ERROR)
    return
  end

  -- Resolve python executable.
  -- If python_venv is configured, look for python3 inside that venv.
  -- Otherwise fall back to system python3.
  local cfg = require("ipynvim").get_config()
  local python
  if cfg.python_venv then
    local venv_dir = cfg.python_venv
    -- Resolve relative paths against cwd (project root).
    if not venv_dir:match("^/") then
      venv_dir = vim.fn.getcwd() .. "/" .. venv_dir
    end
    local candidate = venv_dir .. "/bin/python3"
    if vim.fn.executable(candidate) == 1 then
      python = candidate
    end
  end
  if not python then
    python = vim.fn.exepath("python3")
    if python == "" then
      python = "python3"
    end
  end

  job_id = vim.fn.jobstart({ python, bridge_py }, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdout_buffered = false,
  })

  if job_id <= 0 then
    job_id = nil
    vim.notify("[ipynvim bridge] Failed to start bridge.py", vim.log.levels.ERROR)
    return
  end

  -- Send kernel_start immediately
  send_request(
    "kernel_start",
    {
      kernel_name = opts.kernel_name or "python3",
      cwd = opts.cwd or vim.fn.getcwd(),
    },
    nil,
    function(result)
      if result.ok == false then
        vim.notify("[ipynvim bridge] kernel_start failed: " .. (result.error or "unknown"), vim.log.levels.ERROR)
      else
        vim.notify("[ipynvim bridge] Kernel started", vim.log.levels.INFO)
        if opts.on_ready then
          opts.on_ready()
        end
      end
    end
  )
end

--- Stop the bridge: send kernel_shutdown, then kill the job.
function M.stop()
  if not job_id then
    return
  end

  send_request("kernel_shutdown", {}, nil, function(_result)
    if job_id then
      vim.fn.jobstop(job_id)
      job_id = nil
    end
  end)

  -- Safety: force-stop after 2 seconds if shutdown reply never arrives
  vim.defer_fn(function()
    if job_id then
      vim.fn.jobstop(job_id)
      job_id = nil
    end
  end, 2000)
end

--- Execute code in the kernel.
---@param code string
---@param _cell_id string  Cell UUID (currently unused; reserved for future routing)
---@param on_output function  Called for each streaming output object
---@param on_done function    Called with final result table
function M.execute(code, _cell_id, on_output, on_done)
  if not job_id then
    vim.notify("[ipynvim bridge] Bridge not running. Use :IpynvimKernelStart", vim.log.levels.ERROR)
    return
  end

  send_request(
    "execute",
    { code = code, cell_id = _cell_id },
    on_output,
    on_done
  )
end

--- Interrupt the currently running execution.
function M.interrupt()
  if not job_id then
    return
  end
  send_request("kernel_interrupt", {}, nil, nil)
end

--- Restart the kernel.
---@param callback function|nil  Called when restart completes
function M.restart(callback)
  if not job_id then
    vim.notify("[ipynvim bridge] Bridge not running", vim.log.levels.WARN)
    return
  end
  send_request("kernel_restart", {}, nil, function(result)
    if result.ok == false then
      vim.notify("[ipynvim bridge] Restart failed: " .. (result.error or "unknown"), vim.log.levels.ERROR)
    else
      vim.notify("[ipynvim bridge] Kernel restarted", vim.log.levels.INFO)
    end
    if callback then
      callback(result)
    end
  end)
end

--- Check whether the bridge process is alive.
---@return boolean
function M.is_alive()
  return job_id ~= nil and job_id > 0
end

return M
