--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ConfigValidator = require(ReplicatedStorage.Shared.Combat.ConfigValidator)

return function(t)
	t.test("shipped combat config has no broken references", function()
		local problems = ConfigValidator.validate()
		if #problems > 0 then
			print(table.concat(problems, "\n"))
		end
		t.expect(#problems).toBe(0)
	end)
end
