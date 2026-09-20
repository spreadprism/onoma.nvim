local M = {}

--- Directories which must never be indexed wholesale.
---
--- Indexing `$HOME` (or a filesystem root) pulls in caches, package managers,
--- VMs, mounts and so on. The watcher will either exhaust the platform file
--- watch limits or spend minutes walking the tree - which looks like Neovim
--- hanging on startup.
---
---@param directory string
---@return boolean indexable, string|nil reason
function M.is_indexable(directory)
	---@param path string|nil
	---@return string
	local function normalise(path)
		if path == nil or path == '' then
			return ''
		end

		local absolute = vim.fn.fnamemodify(path, ':p')

		-- Strip any trailing separator, but keep a bare root ("/", "C:\") intact
		return (absolute:gsub('(.)[/\\]+$', '%1'))
	end

	local path = normalise(directory)

	if path == '' then
		return false, 'the current directory could not be resolved'
	end

	-- Filesystem root, or a Windows drive root
	if path == '/' or path:match('^%a:[/\\]?$') then
		return false, 'the filesystem root (' .. path .. ') is too large to index'
	end

	local home = normalise(vim.uv.os_homedir() or vim.env.HOME)

	if home ~= '' and path == home then
		return false, 'the home directory (' .. path .. ') is too large to index'
	end

	return true, nil
end

---@param directories string[]
---@return onoma.Resolver
function M.new_resolver(directories)
	local utils = require('bridge.utils')
	local log = require('utils.log')

	local ok, onoma = pcall(utils.load_bridge)
	if not ok or onoma == nil then
		error('Onoma did not load correctly: ' .. tostring(onoma))
	end

	local ok, resolver = pcall(onoma.get_resolver, directories)
	if not ok then
		error(
			'Failed to initialise resolver for directories: '
				.. table.concat(directories, ', ')
				.. ': '
				.. tostring(resolver)
		)
	end

	log.debug('Resolver initialised for: ' .. table.concat(directories, ', '))

	return resolver
end

---@param directories string[]
---@return onoma.Watcher
function M.new_watcher(directories)
	local utils = require('bridge.utils')
	local log = require('utils.log')

	local ok, onoma = pcall(utils.load_bridge)
	if not ok or onoma == nil then
		error('Onoma did not load correctly: ' .. tostring(onoma))
	end

	local ok, watcher = pcall(onoma.get_watcher, directories)
	if not ok then
		error(
			'Failed to initialise watcher for directories: '
				.. table.concat(directories, ', ')
				.. ': '
				.. tostring(watcher)
		)
	end

	log.debug('Watcher initialised for: ' .. table.concat(directories, ', '))

	vim.api.nvim_create_autocmd('VimLeavePre', {
		group = vim.api.nvim_create_augroup('onoma_watcher', { clear = true }),
		callback = function()
			log.trace('Vim is exiting')

			if watcher then
				local ok, err = pcall(watcher.stop, watcher)

				if not ok then
					log.error('Failed to stop watcher: ' .. tostring(err))
					return
				end

				log.trace('Watcher has been cleaned up')

				-- Since Vim is closing, we want to flush any buffered logs
				log.flush()
			end
		end,
	})

	return watcher
end

return M
