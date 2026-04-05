-- Produces a BindableEvent-safe copy of a blackboard table.
-- BindableEvent silently drops Instance values inside table arguments, so we
-- replace them with a human-readable "ClassName Name" string. Functions and
-- threads are skipped entirely. Everything else (primitives, Vector3, CFrame,
-- Color3, etc.) is kept as-is since BindableEvent supports those types.
-- The internal _debugName key is excluded from the output.
-- Nested tables are recursively serialized. Cyclical references (e.g. a shared
-- blackboard whose members each hold a back-reference to the same blackboard)
-- are replaced with the string "[Circular]" so BindableEvent never sees them.

local function serializeBlackboard(bb: any): { [string]: any }
	local visited: { [any]: boolean } = {}

	local function serialize(tbl: any): { [string]: any }
		if visited[tbl] then
			return "[Circular]" :: any
		end
		visited[tbl] = true

		local result: { [string]: any } = {}
		for k, v in tbl do
			local key = tostring(k)
			if key == "_debugName" then
				continue
			end
			local vKind = type(v)
			if vKind == "function" or vKind == "thread" then
				continue
			end
			if typeof(v) == "Instance" then
				local inst = v :: Instance
				result[key] = inst.ClassName .. " " .. inst.Name
			elseif vKind == "table" then
				result[key] = serialize(v)
			else
				result[key] = v
			end
		end

		return result
	end

	return serialize(bb)
end

return serializeBlackboard
