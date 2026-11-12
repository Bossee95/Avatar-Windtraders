--!strict
-- Remotes used by the staff tools. Merged by Shared.Net.
return {
	Events = {
		StaffMessage = true, -- server -> staff client: (text, kind) command replies and alerts
	},
	Functions = {
		StaffCommand = true, -- staff client -> server: (commandLine) -> (ok, reply)
	},
}
