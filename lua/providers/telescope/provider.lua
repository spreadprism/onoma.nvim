local finders = require('telescope.finders')
local pickers = require('telescope.pickers')

---@class onoma.TelescopeProviderSetup
---@field get_symbols fun(opts: onoma.Config)

---@class onoma.TelescopeProvider: onoma.Provider
---@field setup fun(): onoma.TelescopeProviderSetup

---@type onoma.TelescopeProvider
return {
	setup = function()
		local Async = require('utils.async')
		local Onoma = require('utils.onoma')
		local log = require('utils.log')

		local cwd = vim.fn.getcwd()
		local project_directory = { cwd }

		local indexable, reason = Onoma.is_indexable(cwd)
		if not indexable then
			log.warn('Skipping Onoma initialisation: ' .. tostring(reason))

			return {
				get_symbols = function()
					vim.notify('Onoma is disabled here: ' .. tostring(reason), vim.log.levels.WARN)
				end,
			}
		end

		log.info('Initialising Telescope integration for: ' .. table.concat(project_directory, ', '))

		---@type { resolver: onoma.Resolver|nil }
		local state = { resolver = nil }

		-- Initialisation runs in the background: blocking here would freeze the
		-- editor for as long as the initial index takes.
		Async(function()
			local ok, resolver = pcall(Onoma.new_resolver, project_directory)
			if not ok then
				log.error('Failed to create resolver: ' .. tostring(resolver))
				return
			end

			local ok, watcher = pcall(Onoma.new_watcher, project_directory)
			if not ok then
				log.error('Failed to create watcher: ' .. tostring(watcher))
				return
			end

			state.resolver = resolver

			local ok, err = pcall(watcher.start, watcher)
			if not ok then
				log.error('Failed to start watcher: ' .. tostring(err))
				return
			end

			local ok, err = pcall(watcher.run_full_index, watcher)
			if not ok then
				log.error('Failed to run full index: ' .. tostring(err))
			end
		end):run()

		return {
			get_symbols = function(opts)
				opts = vim.tbl_deep_extend('force', require('config'), opts == nil and {} or opts)

				if not state.resolver then
					vim.notify('Onoma is still initialising', vim.log.levels.WARN)
					return
				end

				pickers
					.new(opts, {
						results_title = opts.telescope.results_title,
						preview_title = opts.telescope.preview_title,
						prompt_title = opts.telescope.prompt_title,

						finder = finders.new_dynamic({
							entry_maker = require('providers.telescope.format').lsp_symbol(),
							fn = require('providers.telescope.finder').get_symbols(state.resolver, opts),
						}),
						sorter = require('telescope.sorters').Sorter:new({
							discard = false,
							scoring_function = function(_, _, ordinal)
								return 1 / ordinal
							end,
							highlighter = require('providers.telescope.format').substr_highlighter(),
						}),
						previewer = require('telescope.config').values.qflist_previewer({}),
						tiebreak = function()
							return false
						end,
					})
					:find()
			end,
		}
	end,
}
