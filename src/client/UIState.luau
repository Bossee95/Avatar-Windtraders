--!strict
--[[
	UIState: which full-screen menu (if any) is open on this client.

	Gameplay input handlers (combat, defense, knock) check
	`UIState.IsMenuOpen()` and ignore keys while a menu such as the inventory
	is open, so pressing Q to change tabs never dodges.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local UIState = {}

UIState.MenuChanged = Signal.new() -- (menuName: string?)

local openMenu: string? = nil

function UIState.IsMenuOpen(): boolean
	return openMenu ~= nil
end

function UIState.GetOpenMenu(): string?
	return openMenu
end

-- Marks `name` open (or closed with open = false). Closing only clears the
-- flag if `name` is the menu that is currently open.
function UIState.SetMenuOpen(name: string, open: boolean)
	if open then
		openMenu = name
	elseif openMenu == name then
		openMenu = nil
	else
		return
	end
	UIState.MenuChanged:Fire(openMenu)
end

return UIState
