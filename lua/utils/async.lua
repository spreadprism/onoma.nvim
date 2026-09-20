local uv = vim.uv

---@class AsyncTask<T>
---@field co thread
---@field poll_pending any
---@field on_yield fun(value: T)|nil
---@field on_done fun(value: T)|nil
---@field timer uv_timer_t|nil
---@field start fun(self: AsyncTask<T>)
local AsyncTask = {}
AsyncTask.__index = AsyncTask

---@class Async
---@field poll_pending any
---@field use_schedule boolean
---@field use_uv boolean
local Async = {
	poll_pending = (coroutine.wrap(function()
		local ok, result = pcall(require('bridge.utils').load_bridge)
		if not ok or result == nil then
			vim.notify_once('Onoma did not load correctly: ' .. tostring(result), vim.log.levels.ERROR)
			return
		end
		return result.pending
	end))(),
	use_schedule = true,
	use_uv = true,
}

---@param opts { schedule?: boolean, uv?: boolean }
function Async.setup(opts)
	if opts.schedule ~= nil then
		Async.use_schedule = opts.schedule
	end
	if opts.uv ~= nil then
		Async.use_uv = opts.uv
	end
end

---@generic T
---@param fn fun(): T
---@return AsyncTask<T>
local function new_task(fn)
	local task = setmetatable({
		co = coroutine.create(fn),
		poll_pending = Async.poll_pending,
		timer = nil,
	}, AsyncTask)

	local function schedule(step)
		if Async.use_uv then
			if not task.timer then
				task.timer = uv.new_timer()
			end

			task.timer:start(0, 0, function()
				task.timer:stop()
				vim.schedule(step)
			end)
		elseif Async.use_schedule then
			vim.schedule(step)
		else
			step()
		end
	end

	local function step()
		local ok, value = coroutine.resume(task.co)
		if not ok then
			if task.timer then
				task.timer:stop()
				task.timer:close()
				task.timer = nil
			end

			vim.notify('Onoma coroutine error: ' .. tostring(value), vim.log.levels.ERROR)

			-- Unblock any `await` waiting on this task
			if task.on_done then
				task.on_done(nil)
			end

			return
		end

		local dead = coroutine.status(task.co) == 'dead'

		if not dead and value ~= task.poll_pending and task.on_yield then
			task.on_yield(value)
		end

		if dead then
			if task.on_done then
				task.on_done(value)
			end
			if task.timer then
				task.timer:close()
			end
			return
		end

		schedule(step)
	end

	function task:start()
		schedule(step)
	end

	return task
end

--- The longest `await` will block the editor for before giving up.
---
--- `await` stops Neovim from processing input entirely, so it must never wait
--- indefinitely: a slow (or stuck) index on a huge directory would otherwise
--- look like a hard freeze.
Async.await_timeout = 10000

--- Await final value (logically blocking - avoid on startup paths)
---@generic T
---@param timeout? integer Milliseconds to wait before giving up (default: `Async.await_timeout`)
---@return T|nil, boolean timed_out
function AsyncTask:await(timeout)
	local result
	local done = false

	self.on_done = function(value)
		result = value
		done = true
	end

	self:start()

	local ok = vim.wait(timeout or Async.await_timeout, function()
		return done
	end)

	if not ok then
		return nil, true
	end

	return result, false
end

--- Run task without blocking
---@param opts? { on_yield?: fun(value:any), on_done?: fun(value:any) }
function AsyncTask:run(opts)
	opts = opts or {}
	self.on_yield = opts.on_yield
	self.on_done = opts.on_done or function() end
	self:start()
end

---@generic T
---@param fn fun(): T
---@return AsyncTask<T>
setmetatable(Async, {
	__call = function(_, fn)
		return new_task(fn)
	end,
})

return Async
