--!strict
--[[
	InventoryScreenController: the full-screen inventory.

	Layout (left to right):
	  * category tabs with icons and names, over a grid of square item tiles
	    with stack counts;
	  * a detail panel for the selected item: name, tags, description and
	    stats;
	  * a live 3D preview of the character, which can be turned.

	Controls (shown in the footer, and switched to gamepad names when a
	gamepad is used):
	  M / Back button     open and close
	  Q / E, LB / RB      previous / next category
	  WASD, arrows, D-pad move the selection
	  T, Y                change the sort order
	  Mouse               click a tile to select it, drag the character to
	                      turn it
	A small "Inventory [M]" button on the HUD opens it too (for touch).

	Weapons are class-locked (Shared.Combat.Config.Classes): the server equips
	the class weapon on spawn and nobody picks or swaps weapons. The Weapons
	tab therefore only shows the class weapon, marked as fixed, with no equip
	button. If the class default isn't an inventory item it is still shown.

	While it is open, movement and combat keys are ignored (UIState), so the
	player can't dodge or walk off by changing tabs.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local WorldConfig = require(Shared.Config.WorldConfig)
local Variations = require(Shared.Combat.Config.Variations)
local WeaponTypes = require(Shared.Combat.Config.WeaponTypes)
local Actions = require(Shared.Combat.Config.Actions)
local Classes = require(Shared.Combat.Config.Classes)

local UIState = require(script.Parent.Parent.Parent.UIState)
local CharacterController = require(script.Parent.Parent.CharacterController)
local CombatController = require(script.Parent.Parent.Combat.CombatController)
local InventoryController = require(script.Parent.InventoryController)
local Theme = require(script.Parent.InventoryUI.Theme)
local ItemIcons = require(script.Parent.InventoryUI.ItemIcons)
local CharacterPreview = require(script.Parent.InventoryUI.CharacterPreview)
local CustomisePage = require(script.Parent.InventoryUI.Pages.CustomisePage)
local SkillsPage = require(script.Parent.InventoryUI.Pages.SkillsPage)
local SettingsPage = require(script.Parent.InventoryUI.Pages.SettingsPage)

local C = Theme.Colors
local F = Theme.Fonts
local make = Theme.make
local label = Theme.label

local MENU_NAME = "Inventory"
local COLUMNS = 5
local TILE = 116
local GAP = 14
local MIN_SLOTS = 20 -- always show at least 4 rows of slots
local BLUR_SIZE = 18

type Tab = {
	key: string,
	label: string,
	shape: ItemIcons.Shape,
	categories: { [string]: boolean },
	empty: string,
}

local TABS: { Tab } = {
	{
		key = "Weapons",
		label = "Weapons",
		shape = "Sword",
		categories = { Weapon = true },
		empty = "No class weapon yet. Your weapon appears here once you spawn.",
	},
	{
		key = "Gear",
		label = "Gear",
		shape = "Shield",
		categories = { Equipment = true },
		empty = "No gear carried.",
	},
	{
		key = "Materials",
		label = "Materials",
		shape = "Crystal",
		categories = { Material = true, Resource = true },
		empty = "Materials you gather or craft show up here.",
	},
	{
		key = "Supplies",
		label = "Supplies",
		shape = "Vial",
		categories = { Consumable = true },
		empty = "Medical supplies and other consumables show up here.",
	},
	{
		key = "Keepsakes",
		label = "Keepsakes",
		shape = "Medal",
		categories = { Special = true, EventReward = true, Other = true },
		empty = "Awards and special items show up here.",
	},
}

local SORTS = { "Name", "Amount", "Newest" }

-- The screen's pages, shown as tabs across the top (keys 1-4, LT / RT).
local PAGES = { "Inventory", "Customise", "Skills", "Settings" }

local CATEGORY_NAMES: { [string]: string } = {
	Weapon = "Weapon",
	Material = "Material",
	Resource = "Resource",
	Consumable = "Supply",
	Equipment = "Gear",
	Special = "Special item",
	EventReward = "Award",
	Other = "Item",
}

-- `classWeapon` marks the fixed class weapon, which may be a synthetic entry
-- (the class default is not always an inventory item).
type Entry = { item: InventoryController.Item, def: any, order: number, classWeapon: boolean }

local InventoryScreenController = {}

local gui: ScreenGui
local launcher: ScreenGui
local backdrop: TextButton
local root: Frame
local uiScale: UIScale
local blur: BlurEffect
local preview: CharacterPreview.CharacterPreview
local characterLabel: TextLabel
local classLabel: TextLabel
local tabButtons: { [string]: { button: TextButton, icon: Frame, name: TextLabel, count: TextLabel, bar: Frame } } =
	{}
local tabTitle: TextLabel
local sortButton: TextButton
local grid: ScrollingFrame
local emptyLabel: TextLabel
local detail: {
	root: Frame,
	placeholder: TextLabel,
	content: Frame,
	icon: Frame,
	name: TextLabel,
	category: TextLabel,
	tags: Frame,
	description: TextLabel,
	stats: Frame,
	note: TextLabel,
}
local footer: Frame
local inventoryPage: Frame
local pageTabs: { [string]: { button: TextButton, bar: Frame } } = {}
local pages: { [string]: any } = {}
local currentPage = "Inventory"

local isOpen = false
local currentTab = TABS[3].key
local hasOpenedBefore = false
local sortIndex = 1
local entries: { Entry } = {}
local selectedUid: string? = nil

--------------------------------------------------------------------------------
-- Data helpers
--------------------------------------------------------------------------------

local function tabFor(category: string): string
	for _, tab in TABS do
		if tab.categories[category] then
			return tab.key
		end
	end
	return "Keepsakes"
end

local function equippedVariation(): string?
	return CombatController:GetState().variationId
end

-- The class is not sent to the client, but each class has its own weapon
-- type, so the wielded weapon tells us the class.
local function currentClass(): (string?, Classes.Class?)
	local variationId = equippedVariation()
	local variation = variationId and Variations[variationId]
	if not variation then
		return nil, nil
	end
	for classId, class in Classes do
		if class.weaponType == variation.weaponType then
			return classId, class
		end
	end
	return nil, nil
end

local CLASS_WEAPON_UID = "class-weapon"

local function entriesFor(tabKey: string): { Entry }
	local list: { Entry } = {}
	local wielded = equippedVariation()
	local wieldedListed = false
	for index, item in InventoryController:GetItems() do
		local def = InventoryController:GetDefinition(item.itemId)
		if def and tabFor(def.category) == tabKey then
			local isClassWeapon = wielded ~= nil and def.variationId == wielded and not wieldedListed
			wieldedListed = wieldedListed or isClassWeapon
			table.insert(list, { item = item, def = def, order = index, classWeapon = isClassWeapon })
		end
	end
	-- The class default weapon is handed out by the server and is not always
	-- an inventory item. Show it anyway so the Weapons tab is never empty
	-- for a character that is holding a weapon.
	local variation = wielded and Variations[wielded]
	if tabKey == "Weapons" and variation and not wieldedListed then
		table.insert(list, {
			item = { uid = CLASS_WEAPON_UID, itemId = "", quantity = 1 },
			def = {
				id = "",
				name = variation.displayName,
				description = "Your class weapon, issued to every member of your class.",
				category = "Weapon",
				variationId = wielded,
				untradeable = true,
				stackable = false,
				maxStack = 1,
				issued = true,
			},
			order = 0,
			classWeapon = true,
		})
	end
	local sort = SORTS[sortIndex]
	table.sort(list, function(a, b)
		-- The class weapon always comes first.
		if a.classWeapon ~= b.classWeapon then
			return a.classWeapon
		end
		if sort == "Amount" and a.item.quantity ~= b.item.quantity then
			return a.item.quantity > b.item.quantity
		elseif sort == "Newest" then
			return a.order > b.order
		end
		if a.def.name ~= b.def.name then
			return a.def.name < b.def.name
		end
		return a.item.uid < b.item.uid
	end)
	return list
end

local function selectedIndex(): number?
	for index, entry in entries do
		if entry.item.uid == selectedUid then
			return index
		end
	end
	return nil
end

local function selectedEntry(): Entry?
	local index = selectedIndex()
	return if index then entries[index] else nil
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

local function addTag(text: string, color: Color3, order: number)
	local chip = make("Frame", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.82,
		LayoutOrder = order,
	}, detail.tags)
	Theme.corner(chip, 13)
	Theme.stroke(chip, color, 1, 0.3)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, chip)
	label({
		Text = text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Font = F.Medium,
		TextSize = 14,
		TextColor3 = color,
	}, chip)
end

local function addStat(name: string, value: string, order: number)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = if order % 2 == 0 then 0.4 else 0.75,
		LayoutOrder = order,
	}, detail.stats)
	Theme.corner(row, 6)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, row)
	label({ Text = name, Size = UDim2.fromScale(0.55, 1), TextSize = 15, TextColor3 = C.TextDim }, row)
	label({
		Text = value,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.45, 1),
		Font = F.Heading,
		TextSize = 15,
		TextColor3 = C.Amber,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
end

local function clearChildren(parent: Instance, keepClass: string)
	for _, child in parent:GetChildren() do
		if not child:IsA(keepClass) then
			child:Destroy()
		end
	end
end

local function renderDetail()
	local entry = selectedEntry()
	detail.placeholder.Visible = entry == nil
	detail.content.Visible = entry ~= nil
	if not entry then
		return
	end
	local def, item = entry.def, entry.item

	clearChildren(detail.icon, "UICorner")
	local art = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		BackgroundTransparency = 1,
	}, detail.icon)
	ItemIcons.draw(art, def)

	detail.name.Text = def.name
	detail.category.Text = CATEGORY_NAMES[def.category] or def.category
	detail.description.Text = def.description

	clearChildren(detail.tags, "UIListLayout")
	if entry.classWeapon then
		addTag("Class weapon", C.Equipped, 1)
	end
	if def.issued then
		addTag("Issued, can't be traded", C.Bound, 2)
	elseif def.untradeable then
		addTag("Bound to this character", C.Bound, 2)
	else
		addTag("Tradeable", C.Glow, 2)
		addTag("Dropped on death", C.TextDim, 3)
	end

	clearChildren(detail.stats, "UIListLayout")
	local order = 0
	local function stat(name: string, value: string)
		order += 1
		addStat(name, value, order)
	end
	if def.stackable then
		stat("Carrying", string.format("%d / %d", item.quantity, def.maxStack))
	end
	local variation = def.variationId and Variations[def.variationId]
	if variation then
		if entry.classWeapon then
			local _, class = currentClass()
			if class then
				stat("Class", class.displayName)
			end
		end
		local weaponType = WeaponTypes[variation.weaponType]
		stat("Weapon type", if weaponType then weaponType.displayName else variation.weaponType)
		local critical = Actions[variation.critical]
		if critical then
			stat("Critical (R)", critical.displayName or variation.critical)
			if critical.damage then
				stat(
					"Critical damage",
					if critical.hits and critical.hits > 1
						then string.format("%d x %d hits", critical.damage, critical.hits)
						else tostring(critical.damage)
				)
			end
			if critical.cooldown then
				stat("Critical cooldown", string.format("%gs", critical.cooldown))
			end
		end
	end

	-- Weapons can't be picked or swapped: say so plainly instead of offering
	-- a button that would do nothing.
	if entry.classWeapon then
		detail.note.Text =
			"Fixed to your class. You always fight with this weapon; staff can change your class."
		detail.note.Visible = true
	elseif variation then
		detail.note.Text = "Not your class weapon, so you can't fight with it. You can still trade it."
		detail.note.Visible = true
	else
		detail.note.Visible = false
	end
end

--------------------------------------------------------------------------------
-- Grid
--------------------------------------------------------------------------------

local tileFrames: { [string]: TextButton } = {}

local function styleTile(tile: TextButton, selected: boolean, hovered: boolean)
	local stroke = tile:FindFirstChildOfClass("UIStroke")
	local glow = tile:FindFirstChild("Glow") :: Frame?
	if stroke then
		stroke.Color = if selected then C.Select elseif hovered then C.Glow else C.GlowSoft
		stroke.Thickness = if selected then 3 else 1.5
		stroke.Transparency = if selected or hovered then 0 else 0.45
	end
	if glow then
		glow.Visible = selected
	end
	tile.BackgroundColor3 = if selected then C.SelectDeep elseif hovered then C.TileHover else C.Tile
end

local function refreshSelectionStyles()
	for uid, tile in tileFrames do
		styleTile(tile, uid == selectedUid, tile:GetAttribute("Hovered") == true)
	end
end

local function scrollIntoView(index: number)
	local row = (index - 1) // COLUMNS
	local top = row * (TILE + GAP)
	local bottom = top + TILE
	local view = grid.AbsoluteWindowSize.Y / math.max(uiScale.Scale, 0.01)
	local y = grid.CanvasPosition.Y
	if top < y then
		grid.CanvasPosition = Vector2.new(0, top)
	elseif bottom > y + view then
		grid.CanvasPosition = Vector2.new(0, bottom - view + GAP)
	end
end

local function select(uid: string?)
	selectedUid = uid
	refreshSelectionStyles()
	renderDetail()
	local index = selectedIndex()
	if index then
		scrollIntoView(index)
	end
end

local function buildTile(entry: Entry?, order: number): TextButton
	local tile = make("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = if entry then C.Tile else C.TileEmpty,
		BackgroundTransparency = if entry then 0.1 else 0.45,
		LayoutOrder = order,
		Selectable = entry ~= nil,
	}, grid)
	Theme.corner(tile, 10)
	Theme.stroke(tile, C.GlowSoft, 1.5, if entry then 0.45 else 0.8)
	if not entry then
		tile.Active = false
		return tile
	end

	local glow = make("Frame", {
		Name = "Glow",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Select,
		BackgroundTransparency = 0.6,
		Visible = false,
	}, tile)
	Theme.corner(glow, 10)
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.55, 0.85),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Rotation = 90,
	}, glow)

	local art = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromScale(0.74, 0.74),
		BackgroundTransparency = 1,
	}, tile)
	ItemIcons.draw(art, entry.def)

	if entry.def.stackable then
		local pill = make("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 6, 1, -6),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			BackgroundColor3 = C.Backdrop,
			BackgroundTransparency = 0.25,
			ZIndex = 3,
		}, tile)
		Theme.corner(pill, 6)
		make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, pill)
		label({
			Text = "x" .. tostring(entry.item.quantity),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			Font = F.Number,
			TextSize = 15,
			TextColor3 = C.Amber,
			ZIndex = 3,
		}, pill)
	end

	if entry.classWeapon then
		local badge = make("Frame", {
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.fromOffset(56, 20),
			BackgroundColor3 = C.Equipped,
			BackgroundTransparency = 0.15,
			ZIndex = 3,
		}, tile)
		Theme.corner(badge, 10)
		label({
			Text = "CLASS",
			Size = UDim2.fromScale(1, 1),
			Font = F.Heading,
			TextSize = 11,
			TextColor3 = C.Backdrop,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 3,
		}, badge)
	end

	if entry.def.untradeable then
		local seed = make("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 10),
			Size = UDim2.fromOffset(10, 10),
			Rotation = 45,
			BackgroundColor3 = C.Bound,
			ZIndex = 3,
		}, tile)
		Theme.corner(seed, 2)
	end

	local uid = entry.item.uid
	tile.MouseEnter:Connect(function()
		tile:SetAttribute("Hovered", true)
		styleTile(tile, uid == selectedUid, true)
	end)
	tile.MouseLeave:Connect(function()
		tile:SetAttribute("Hovered", false)
		styleTile(tile, uid == selectedUid, false)
	end)
	tile.Activated:Connect(function()
		select(uid)
	end)
	tile.SelectionGained:Connect(function()
		if selectedUid ~= uid then
			select(uid)
		end
	end)
	tileFrames[uid] = tile
	return tile
end

local function renderTabs()
	for _, tab in TABS do
		local parts = tabButtons[tab.key]
		local active = tab.key == currentTab
		parts.bar.Visible = active
		parts.name.TextColor3 = if active then C.Text else C.TextFaint
		parts.button.BackgroundTransparency = if active then 0.55 else 1
		for _, child in parts.icon:GetDescendants() do
			if child:IsA("Frame") then
				child.BackgroundTransparency = if active then 0 else 0.45
			end
		end
		local count = #entriesFor(tab.key)
		parts.count.Text = tostring(count)
		local badge = parts.count.Parent :: GuiObject
		badge.Visible = count > 0
		if active then
			tabTitle.Text = tab.label
			emptyLabel.Text = tab.empty
		end
	end
	sortButton.Text = "Sort: " .. SORTS[sortIndex]
end

local function renderGrid()
	for _, child in grid:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	tileFrames = {}
	entries = entriesFor(currentTab)
	local slots = math.max(MIN_SLOTS, math.ceil(#entries / COLUMNS) * COLUMNS)
	for index = 1, slots do
		buildTile(entries[index], index)
	end
	emptyLabel.Visible = #entries == 0
	if not selectedEntry() then
		selectedUid = if entries[1] then entries[1].item.uid else nil
	end
	refreshSelectionStyles()
	renderDetail()
end

local function renderHeader()
	local character = CharacterController:GetActiveCharacter()
	if character then
		characterLabel.Text = string.format(
			"%s  ·  %s %s",
			character.name,
			WorldConfig.getFactionName(character.faction),
			WorldConfig.getRoleName(character.faction, character.role)
		)
	else
		characterLabel.Text = ""
	end
	local _, class = currentClass()
	classLabel.Text = if class then "Class: " .. class.displayName else "Class: none yet"
end

local function renderAll()
	if not gui then
		return
	end
	renderHeader()
	renderTabs()
	renderGrid()
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

local function switchTab(delta: number)
	local index = 1
	for i, tab in TABS do
		if tab.key == currentTab then
			index = i
		end
	end
	index = (index - 1 + delta) % #TABS + 1
	currentTab = TABS[index].key
	selectedUid = nil
	grid.CanvasPosition = Vector2.zero
	renderTabs()
	renderGrid()
end

local function moveSelection(dx: number, dy: number)
	if #entries == 0 then
		return
	end
	local index = selectedIndex() or 1
	local column = (index - 1) % COLUMNS
	local nextIndex = index
	if dx ~= 0 then
		local target = column + dx
		if target >= 0 and target < COLUMNS then
			nextIndex = index + dx
		else
			-- Off the edge of the grid: move to the next/previous category.
			switchTab(dx)
			return
		end
	else
		nextIndex = index + dy * COLUMNS
	end
	if nextIndex >= 1 and nextIndex <= #entries then
		select(entries[nextIndex].item.uid)
	end
end

local function cycleSort()
	sortIndex = sortIndex % #SORTS + 1
	renderTabs()
	renderGrid()
end

--------------------------------------------------------------------------------
-- Building the screen
--------------------------------------------------------------------------------

local function buildHeader()
	local header = make("Frame", {
		Size = UDim2.new(1, 0, 0, 96),
		BackgroundTransparency = 1,
	}, root)
	-- Page tabs: always labelled, with their number key.
	local row = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(4 * 150 + 3 * 8, 60),
		BackgroundTransparency = 1,
	}, header)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	for index, name in PAGES do
		local button = make("TextButton", {
			Size = UDim2.fromOffset(150, 52),
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			LayoutOrder = index,
		}, row)
		label({
			Name = "Title",
			Size = UDim2.new(1, 0, 0, 34),
			Text = string.upper(name),
			Font = F.Title,
			TextSize = 24,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, button)
		label({
			Name = "Key",
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 0, 14),
			Text = tostring(index),
			Font = F.Heading,
			TextSize = 11,
			TextColor3 = C.TextFaint,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, button)
		local bar = Theme.flourish(button, UDim2.new(0.5, 0, 1, 2), 120)
		button.Activated:Connect(function()
			InventoryScreenController:ShowPage(name)
		end)
		pageTabs[name] = { button = button, bar = bar }
	end

	characterLabel = label({
		Position = UDim2.fromOffset(56, 30),
		Size = UDim2.fromOffset(400, 30),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = F.Medium,
		TextSize = 18,
		TextColor3 = C.TextDim,
	}, header)

	local right = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -56, 0, 26),
		Size = UDim2.fromOffset(420, 38),
		BackgroundTransparency = 1,
	}, header)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, right)
	local slot = make("Frame", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 34),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = 0.2,
		LayoutOrder = 1,
	}, right)
	Theme.corner(slot, 17)
	Theme.stroke(slot, C.GlowSoft, 1, 0.3)
	make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, slot)
	classLabel = label({
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Font = F.Medium,
		TextSize = 15,
		TextColor3 = C.Amber,
	}, slot)

	local close = make("TextButton", {
		Text = "Close  [M]",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 34),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = 0.2,
		Font = F.Medium,
		TextSize = 15,
		TextColor3 = C.Text,
		AutoButtonColor = true,
		LayoutOrder = 2,
	}, right)
	Theme.corner(close, 17)
	Theme.stroke(close, C.Glow, 1, 0.4)
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, close)
	close.Activated:Connect(function()
		InventoryScreenController:Close()
	end)
end

local function buildItemsPanel()
	local panel = Theme.panel({
		Position = UDim2.fromOffset(48, 104),
		Size = UDim2.fromOffset(COLUMNS * TILE + (COLUMNS - 1) * GAP + 56, 712),
	}, inventoryPage)

	-- Category tabs: icon + name, always labelled.
	local strip = make("Frame", {
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.new(1, -36, 0, 86),
		BackgroundTransparency = 1,
	}, panel)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, strip)
	for index, tab in TABS do
		local button = make("TextButton", {
			Text = "",
			Size = UDim2.new(1 / #TABS, -6, 1, 0),
			BackgroundColor3 = C.PanelDeep,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			LayoutOrder = index,
		}, strip)
		Theme.corner(button, 10)
		local icon = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Size = UDim2.fromOffset(44, 44),
			BackgroundTransparency = 1,
		}, button)
		ItemIcons.drawShape(icon, tab.shape, C.Glow)
		local name = label({
			Position = UDim2.new(0, 0, 0, 52),
			Size = UDim2.new(1, 0, 0, 22),
			Text = tab.label,
			Font = F.Medium,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, button)
		local bar = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(0.7, 0, 0, 3),
			BackgroundColor3 = C.Select,
			BorderSizePixel = 0,
		}, button)
		Theme.corner(bar, 2)
		local badge = make("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 4),
			Size = UDim2.fromOffset(24, 18),
			BackgroundColor3 = C.Backdrop,
			BackgroundTransparency = 0.2,
		}, button)
		Theme.corner(badge, 9)
		local count = label({
			Size = UDim2.fromScale(1, 1),
			Font = F.Heading,
			TextSize = 12,
			TextColor3 = C.Amber,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, badge)
		button.Activated:Connect(function()
			if currentTab ~= tab.key then
				currentTab = tab.key
				selectedUid = nil
				grid.CanvasPosition = Vector2.zero
				renderTabs()
				renderGrid()
			end
		end)
		tabButtons[tab.key] = { button = button, icon = icon, name = name, count = count, bar = bar }
	end

	-- Title row: category name on the left, sort on the right.
	tabTitle = label({
		Position = UDim2.fromOffset(28, 108),
		Size = UDim2.fromOffset(300, 30),
		Font = F.Title,
		TextSize = 24,
		TextColor3 = C.Text,
	}, panel)
	sortButton = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -28, 0, 108),
		Size = UDim2.fromOffset(150, 30),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = 0.3,
		Font = F.Medium,
		TextSize = 14,
		TextColor3 = C.TextDim,
		AutoButtonColor = true,
	}, panel)
	Theme.corner(sortButton, 15)
	Theme.stroke(sortButton, C.GlowSoft, 1, 0.4)
	sortButton.Activated:Connect(cycleSort)

	grid = make("ScrollingFrame", {
		Position = UDim2.fromOffset(28, 152),
		Size = UDim2.new(1, -40, 1, -170),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.Glow,
		ScrollBarImageTransparency = 0.4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		SelectionGroup = true,
	}, panel)
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(TILE, TILE),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		FillDirectionMaxCells = COLUMNS,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 2) }, grid)

	emptyLabel = label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 290),
		Size = UDim2.new(1, -120, 0, 60),
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.25,
		TextWrapped = true,
		TextSize = 17,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 5,
	}, panel)
	Theme.corner(emptyLabel, 10)
end

local function buildDetailPanel()
	local panelX = 48 + COLUMNS * TILE + (COLUMNS - 1) * GAP + 56 + 24
	local panel = Theme.panel({
		Position = UDim2.fromOffset(panelX, 104),
		Size = UDim2.fromOffset(440, 712),
	}, inventoryPage)
	-- Accent edge on the left, like a leaf vein.
	local edge = make("Frame", {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(0, 4, 1, -48),
		BackgroundColor3 = C.Glow,
		BorderSizePixel = 0,
	}, panel)
	Theme.corner(edge, 2)

	local placeholder = label({
		Size = UDim2.fromScale(1, 1),
		Text = "Select an item to see what it is and what you can do with it.",
		TextWrapped = true,
		TextSize = 18,
		TextColor3 = C.TextFaint,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, panel)
	make("UIPadding", { PaddingLeft = UDim.new(0, 40), PaddingRight = UDim.new(0, 40) }, placeholder)

	local content = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, panel)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 30),
		PaddingRight = UDim.new(0, 26),
		PaddingTop = UDim.new(0, 26),
		PaddingBottom = UDim.new(0, 24),
	}, content)

	local icon = make("Frame", {
		Size = UDim2.fromOffset(96, 96),
		BackgroundColor3 = C.Tile,
	}, content)
	Theme.corner(icon, 12)
	Theme.stroke(icon, C.Glow, 1.5, 0.3)

	local name = label({
		Position = UDim2.fromOffset(112, 6),
		Size = UDim2.new(1, -112, 0, 56),
		Font = F.Heading,
		TextSize = 28,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, content)
	local category = label({
		Position = UDim2.fromOffset(112, 66),
		Size = UDim2.new(1, -112, 0, 22),
		Font = F.Medium,
		TextSize = 16,
		TextColor3 = C.Glow,
	}, content)

	local tags = make("Frame", {
		Position = UDim2.fromOffset(0, 112),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
	}, content)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Wraps = true,
	}, tags)

	Theme.flourish(content, UDim2.new(0.5, 0, 0, 160), 300, C.GlowSoft)

	local description = label({
		Position = UDim2.fromOffset(0, 176),
		Size = UDim2.new(1, 0, 0, 120),
		TextWrapped = true,
		TextSize = 18,
		TextColor3 = C.Text,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.15,
	}, content)

	local stats = make("Frame", {
		Position = UDim2.fromOffset(0, 306),
		Size = UDim2.new(1, 0, 0, 200),
		BackgroundTransparency = 1,
	}, content)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, stats)

	-- A plain-language note at the bottom, e.g. why a weapon has no button.
	local note = label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = 0.3,
		TextWrapped = true,
		TextSize = 15,
		TextColor3 = C.TextDim,
		Visible = false,
	}, content)
	Theme.corner(note, 10)
	Theme.stroke(note, C.GlowSoft, 1, 0.5)
	make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, note)

	detail = {
		root = panel,
		placeholder = placeholder,
		content = content,
		icon = icon,
		name = name,
		category = category,
		tags = tags,
		description = description,
		stats = stats,
		note = note,
	}
end

local function buildPreview()
	local x = 48 + COLUMNS * TILE + (COLUMNS - 1) * GAP + 56 + 24 + 440 + 16
	local area = make("Frame", {
		Position = UDim2.fromOffset(x, 96),
		Size = UDim2.new(0, Theme.DesignSize.X - x - 24, 0, 730),
		BackgroundTransparency = 1,
	}, root)

	-- A glowing plinth the character stands on.
	local ring = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -58),
		Size = UDim2.fromOffset(250, 56),
		BackgroundColor3 = C.Glow,
		BackgroundTransparency = 0.82,
	}, area)
	Theme.corner(ring, 999)
	Theme.stroke(ring, C.Glow, 2, 0.35)
	local inner = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.55),
		BackgroundColor3 = C.Select,
		BackgroundTransparency = 0.85,
	}, ring)
	Theme.corner(inner, 999)

	local holder = make("Frame", {
		Size = UDim2.new(1, 0, 1, -30),
		BackgroundTransparency = 1,
	}, area)
	preview = CharacterPreview.new(holder)

	label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "Drag to turn",
		TextSize = 14,
		TextColor3 = C.TextFaint,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, area)
end

type Hint = { keyboard: string, gamepad: string, text: string }

local INVENTORY_HINTS: { Hint } = {
	{ keyboard = "1-4", gamepad = "LT  RT", text = "Page" },
	{ keyboard = "Q  E", gamepad = "LB  RB", text = "Category" },
	{ keyboard = "Arrows", gamepad = "D-pad", text = "Move" },
	{ keyboard = "T", gamepad = "Y", text = "Sort" },
	{ keyboard = "Drag", gamepad = "RS", text = "Turn" },
	{ keyboard = "M", gamepad = "B", text = "Close" },
}

local PAGE_HINTS: { Hint } = {
	{ keyboard = "1-4", gamepad = "LT  RT", text = "Page" },
	{ keyboard = "Click", gamepad = "A", text = "Choose" },
	{ keyboard = "Drag", gamepad = "RS", text = "Turn" },
	{ keyboard = "M", gamepad = "B", text = "Close" },
}

local function renderFooter()
	for _, child in footer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local gamepad = UserInputService.GamepadEnabled
		and string.find(UserInputService:GetLastInputType().Name, "Gamepad") ~= nil
	local hints: { Hint } = if currentPage == "Inventory" then INVENTORY_HINTS else PAGE_HINTS
	for index, hint in hints do
		Theme.keyHint(footer, if gamepad then hint.gamepad else hint.keyboard, hint.text, index)
	end
end

local function buildFooter()
	local bar = make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundTransparency = 1,
	}, root)
	local line = make("Frame", {
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(1, -96, 0, 1),
		BackgroundColor3 = C.GlowSoft,
		BorderSizePixel = 0,
	}, bar)
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, line)
	footer = make("Frame", {
		Position = UDim2.fromOffset(48, 14),
		Size = UDim2.new(1, -96, 0, 34),
		BackgroundTransparency = 1,
	}, bar)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 26),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, footer)
	renderFooter()
end

local function buildLauncher(playerGui: Instance)
	launcher = make("ScreenGui", {
		Name = "InventoryLauncher",
		ResetOnSpawn = false,
		DisplayOrder = 4,
		Enabled = false,
	}, playerGui)
	local button = make("TextButton", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(150, 44),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.15,
		Text = "",
		AutoButtonColor = true,
	}, launcher)
	Theme.corner(button, 12)
	Theme.stroke(button, C.Glow, 1.5, 0.3)
	local icon = make("Frame", {
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.fromOffset(32, 32),
		BackgroundTransparency = 1,
	}, button)
	ItemIcons.drawShape(icon, "Pouch", C.Glow)
	label({
		Position = UDim2.fromOffset(46, 0),
		Size = UDim2.new(1, -52, 1, 0),
		Text = "Inventory  [M]",
		Font = F.Medium,
		TextSize = 15,
	}, button)
	button.Activated:Connect(function()
		InventoryScreenController:Open()
	end)
end

local function updateScale()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	uiScale.Scale = math.min(size.X / Theme.DesignSize.X, size.Y / Theme.DesignSize.Y)
end

--------------------------------------------------------------------------------
-- Open / close and input
--------------------------------------------------------------------------------

local MENU_ACTION = "InventoryMenuInput"
local TOGGLE_ACTION = "InventoryToggle"

local MENU_KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.Q,
	Enum.KeyCode.E,
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
	Enum.KeyCode.Up,
	Enum.KeyCode.Down,
	Enum.KeyCode.Left,
	Enum.KeyCode.Right,
	Enum.KeyCode.F,
	Enum.KeyCode.T,
	Enum.KeyCode.Space,
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonA,
	Enum.KeyCode.ButtonB,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.DPadUp,
	Enum.KeyCode.DPadDown,
	Enum.KeyCode.DPadLeft,
	Enum.KeyCode.DPadRight,
	Enum.KeyCode.Thumbstick1,
	Enum.KeyCode.Thumbstick2,
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
}

local PAGE_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
}

-- On the other pages the gamepad moves between buttons with Roblox's own
-- selection, so these pass through instead of being handled here.
local GAMEPAD_NAV: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.DPadUp] = true,
	[Enum.KeyCode.DPadDown] = true,
	[Enum.KeyCode.DPadLeft] = true,
	[Enum.KeyCode.DPadRight] = true,
	[Enum.KeyCode.Thumbstick1] = true,
	[Enum.KeyCode.ButtonA] = true,
}

local function pageIndex(): number
	return table.find(PAGES, currentPage) or 1
end

local stickHeld = false

local function onMenuInput(_: string, inputState: Enum.UserInputState, input: InputObject)
	local key = input.KeyCode
	if inputState == Enum.UserInputState.Begin then
		local page = PAGE_KEYS[key]
		if page then
			InventoryScreenController:ShowPage(PAGES[page])
			return Enum.ContextActionResult.Sink
		elseif key == Enum.KeyCode.ButtonL2 or key == Enum.KeyCode.ButtonR2 then
			local delta = if key == Enum.KeyCode.ButtonL2 then -1 else 1
			InventoryScreenController:ShowPage(PAGES[(pageIndex() - 1 + delta) % #PAGES + 1])
			return Enum.ContextActionResult.Sink
		elseif key == Enum.KeyCode.ButtonB then
			InventoryScreenController:Close()
			return Enum.ContextActionResult.Sink
		end
	end
	if currentPage ~= "Inventory" and key ~= Enum.KeyCode.Thumbstick2 then
		-- Grid keys only act on the Inventory page. Movement keys stay sunk.
		return if GAMEPAD_NAV[key] then Enum.ContextActionResult.Pass else Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.Thumbstick2 then
		if math.abs(input.Position.X) > 0.2 then
			preview:Rotate(input.Position.X * 0.08)
		end
		return Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.Thumbstick1 then
		-- Left stick moves the selection one step per push.
		local p = input.Position
		if math.max(math.abs(p.X), math.abs(p.Y)) < 0.6 then
			stickHeld = false
		elseif not stickHeld then
			stickHeld = true
			if math.abs(p.X) > math.abs(p.Y) then
				moveSelection(if p.X > 0 then 1 else -1, 0)
			else
				moveSelection(0, if p.Y > 0 then -1 else 1)
			end
		end
		return Enum.ContextActionResult.Sink
	end
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.Q or key == Enum.KeyCode.ButtonL1 then
		switchTab(-1)
	elseif key == Enum.KeyCode.E or key == Enum.KeyCode.ButtonR1 then
		switchTab(1)
	elseif key == Enum.KeyCode.W or key == Enum.KeyCode.Up or key == Enum.KeyCode.DPadUp then
		moveSelection(0, -1)
	elseif key == Enum.KeyCode.S or key == Enum.KeyCode.Down or key == Enum.KeyCode.DPadDown then
		moveSelection(0, 1)
	elseif key == Enum.KeyCode.A or key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft then
		moveSelection(-1, 0)
	elseif key == Enum.KeyCode.D or key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight then
		moveSelection(1, 0)
	elseif key == Enum.KeyCode.T or key == Enum.KeyCode.ButtonY then
		cycleSort()
	end
	return Enum.ContextActionResult.Sink
end

local function canOpen(): boolean
	return CharacterController:GetActiveCharacter() ~= nil
		and (UIState.GetOpenMenu() == nil or UIState.GetOpenMenu() == MENU_NAME)
end

-- Switches the page shown on the left (Inventory, Customise, Skills,
-- Settings). The 3D preview stays on the right for all of them.
function InventoryScreenController:ShowPage(name: string)
	if not table.find(PAGES, name) then
		return
	end
	currentPage = name
	for pageName, tab in pageTabs do
		local active = pageName == name
		local title = tab.button:FindFirstChild("Title") :: TextLabel
		title.TextColor3 = if active then C.Text else C.TextFaint
		title.TextSize = if active then 26 else 20
		tab.bar.Visible = active
	end
	inventoryPage.Visible = name == "Inventory"
	for pageName, page in pages do
		if pageName == name then
			page:Show()
		else
			page:Hide()
		end
	end
	if name == "Inventory" and isOpen then
		renderAll()
	end
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	renderFooter()
end

function InventoryScreenController:IsOpen(): boolean
	return isOpen
end

function InventoryScreenController:Open()
	if isOpen or not gui or not canOpen() then
		return
	end
	isOpen = true
	UIState.SetMenuOpen(MENU_NAME, true)

	if not hasOpenedBefore then
		hasOpenedBefore = true
		-- First open: start on the first category that has something in it.
		for _, tab in TABS do
			if #entriesFor(tab.key) > 0 then
				currentTab = tab.key
				break
			end
		end
	end

	updateScale()
	renderAll()
	InventoryScreenController:ShowPage(currentPage)

	gui.Enabled = true
	-- After enabling, so the viewport has its real size for framing.
	preview:Refresh()
	preview:ResetRotation()
	launcher.Enabled = false
	backdrop.BackgroundTransparency = 1
	root.Position = UDim2.new(0.5, 0, 0.5, 24)
	TweenService:Create(backdrop, TweenInfo.new(0.2), { BackgroundTransparency = 0.35 }):Play()
	TweenService
		:Create(root, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { Position = UDim2.fromScale(0.5, 0.5) })
		:Play()
	blur.Parent = Lighting
	TweenService:Create(blur, TweenInfo.new(0.25), { Size = BLUR_SIZE }):Play()

	ContextActionService:BindActionAtPriority(
		MENU_ACTION,
		onMenuInput,
		false,
		Enum.ContextActionPriority.High.Value,
		table.unpack(MENU_KEYS)
	)
	local first = selectedUid and tileFrames[selectedUid]
	if first and UserInputService.GamepadEnabled then
		GuiService.SelectedObject = first
	end
end

function InventoryScreenController:Close()
	if not isOpen then
		return
	end
	isOpen = false
	ContextActionService:UnbindAction(MENU_ACTION)
	UIState.SetMenuOpen(MENU_NAME, false)
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	gui.Enabled = false
	preview:Clear()
	launcher.Enabled = CharacterController:GetActiveCharacter() ~= nil
	local tween = TweenService:Create(blur, TweenInfo.new(0.15), { Size = 0 })
	tween.Completed:Connect(function()
		if not isOpen then
			blur.Parent = nil
		end
	end)
	tween:Play()
end

function InventoryScreenController:Toggle()
	if isOpen then
		self:Close()
	else
		self:Open()
	end
end

function InventoryScreenController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	gui = make("ScreenGui", {
		Name = "Inventory",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 20,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	}, playerGui)

	-- Full-screen backdrop: dims the world, frees the mouse (Modal) and stops
	-- clicks from reaching combat.
	backdrop = make("TextButton", {
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Modal = true,
		Selectable = false,
	}, gui)
	Theme.gradient(backdrop, Color3.fromRGB(255, 255, 255), Color3.fromRGB(120, 120, 150))

	root = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(Theme.DesignSize.X, Theme.DesignSize.Y),
		BackgroundTransparency = 1,
	}, gui)
	uiScale = make("UIScale", {}, root)

	blur = make("BlurEffect", { Name = "InventoryBlur", Size = 0 })

	inventoryPage = make("Frame", {
		Name = "InventoryPage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, root)
	-- The other pages fill the space the item grid and detail panel use.
	local pageHost = make("Frame", {
		Name = "Pages",
		Position = UDim2.fromOffset(48, 104),
		Size = UDim2.fromOffset(COLUMNS * TILE + (COLUMNS - 1) * GAP + 56 + 24 + 440, 712),
		BackgroundTransparency = 1,
	}, root)
	local ctx = {
		refreshPreview = function()
			if isOpen then
				preview:Refresh()
			end
		end,
	}

	buildHeader()
	buildItemsPanel()
	buildDetailPanel()
	buildPreview()
	pages.Customise = CustomisePage.new(pageHost, ctx)
	pages.Skills = SkillsPage.new(pageHost, ctx)
	pages.Settings = SettingsPage.new(pageHost, ctx)
	buildFooter()
	InventoryScreenController:ShowPage("Inventory")

	Net.OnEvent("CosmeticsState", function(state)
		pages.Customise:SetState(state)
	end)
	buildLauncher(playerGui)
	updateScale()

	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	UserInputService.LastInputTypeChanged:Connect(function()
		if isOpen then
			renderFooter()
		end
	end)

	-- M (or the gamepad Back button) toggles. Bound once; CAS doesn't fire
	-- while the player is typing in chat.
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			InventoryScreenController:Toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.M, Enum.KeyCode.ButtonSelect)

	InventoryController.Changed:Connect(function()
		if isOpen then
			renderAll()
		end
	end)
	local lastVariation: string? = nil
	CombatController.StateChanged:Connect(function(state)
		local weaponChanged = state.variationId ~= lastVariation
		lastVariation = state.variationId
		if isOpen and currentPage == "Inventory" then
			renderAll()
		end
		if isOpen and weaponChanged then
			-- The weapon model is welded on by the server; give it a moment
			-- to replicate before copying the character again.
			task.delay(0.3, function()
				if isOpen then
					preview:Refresh()
				end
			end)
		end
	end)
	CharacterController.StateChanged:Connect(function()
		local active = CharacterController:GetActiveCharacter() ~= nil
		if not active then
			InventoryScreenController:Close()
		end
		launcher.Enabled = active and not isOpen
	end)
	launcher.Enabled = CharacterController:GetActiveCharacter() ~= nil
	Players.LocalPlayer.CharacterAdded:Connect(function()
		if isOpen then
			task.wait(0.5)
			preview:Refresh()
		end
	end)
end

return InventoryScreenController
