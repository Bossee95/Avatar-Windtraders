--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local CommandParser = require(ServerScriptService.Server.Services.Staff.CommandParser)

return function(t)
	t.test("splits words and lowercases the alias", function()
		local alias, args = CommandParser.Parse("/PD pause server lag")
		t.expect(alias).toBe("/pd")
		t.expect(args).toEqual({ "pause", "server", "lag" })
	end)

	t.test("keeps quoted text together", function()
		local _, args = CommandParser.Parse('/pd start "Battle of the Grove" conflict')
		t.expect(args).toEqual({ "start", "Battle of the Grove", "conflict" })
	end)

	t.test("pulls out known options only", function()
		local _, args, opts = CommandParser.Parse("/rank Bob 3 char=123-2 reason=promo")
		t.expect(args).toEqual({ "Bob", "3", "reason=promo" })
		t.expect(opts.char).toBe("123-2")
	end)

	t.test("handles an unterminated quote and empty input", function()
		local _, args = CommandParser.Parse('/pd start "Unclosed name')
		t.expect(args).toEqual({ "start", "Unclosed name" })
		local alias, empty = CommandParser.Parse("   ")
		t.expect(alias).toBe("")
		t.expect(#empty).toBe(0)
	end)
end
