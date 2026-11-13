--!strict
-- Parses staff chat command lines. Helper, not a service.

local CommandParser = {}

export type Args = { string }
export type Opts = { [string]: string }

local OPTION_KEYS = { char = true, hours = true, days = true }

-- Splits a command line into words, honouring "double quotes", and pulls
-- out key=value options.
function CommandParser.Parse(line: string): (string, Args, Opts)
	local words: { string } = {}
	local i, n = 1, #line
	while i <= n do
		local c = string.sub(line, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == '"' then
			local close = string.find(line, '"', i + 1, true)
			local stop = close or (n + 1)
			table.insert(words, string.sub(line, i + 1, stop - 1))
			i = stop + 1
		else
			local stop = string.find(line, "%s", i) or (n + 1)
			table.insert(words, string.sub(line, i, stop - 1))
			i = stop
		end
	end
	local alias = string.lower(table.remove(words, 1) or "")
	local args: Args, opts: Opts = {}, {}
	for _, word in words do
		local key, value = string.match(word, "^(%a+)=(.+)$")
		if key and OPTION_KEYS[key] then
			opts[key] = value
		else
			table.insert(args, word)
		end
	end
	return alias, args, opts
end

return CommandParser
