-- Flattens a blackboard for the debug paths (BindableEvent and the remote
-- debug codec). Top-level primitives and supported Roblox value types
-- (Vector3/Vector2/Color3/CFrame) are kept typed so the codec can encode them
-- with type fidelity on the wire. Everything else — Instances, tables,
-- functions, threads — is reduced to a display string. Nested tables are
-- formatted inline with sorted keys so the same contents always produce the
-- same string, which is what keeps the delta encoder's `==` diff stable.
-- The internal _debugName key is excluded from the output.
-- Cyclical references (direct or indirect) are replaced with "[Circular]".

type Entry = { key: any, keyStr: string }

local function format(value: any, visited: { [any]: boolean }): string
	local t = typeof(value)
	if t == "string" then
		return `"{value}"`
	end
	if t == "Instance" then
		local inst = value :: Instance
		return `({inst.ClassName}) {inst:GetFullName()}`
	end
	if t == "table" then
		if visited[value] then
			return "[Circular]"
		end
		visited[value] = true
		local entries: { Entry } = {}
		for k in value do
			local keyStr = tostring(k)
			if keyStr ~= "_debugName" then
				table.insert(entries, { key = k, keyStr = keyStr })
			end
		end
		table.sort(entries, function(a, b): boolean
			return a.keyStr < b.keyStr
		end)
		local parts: { string } = {}
		for _, entry in entries do
			local inner = value[entry.key]
			local innerKind = type(inner)
			if innerKind ~= "function" and innerKind ~= "thread" then
				table.insert(parts, `{entry.keyStr} = {format(inner, visited)}`)
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function serializeBlackboard(bb: any): { [string]: any }
	local visited: { [any]: boolean } = {}
	visited[bb] = true

	local result: { [string]: any } = {}
	for k, v in bb do
		local key = tostring(k)
		if key == "_debugName" then
			continue
		end
		local vKind = type(v)
		if vKind == "function" or vKind == "thread" then
			continue
		end
		if typeof(v) == "Instance" or vKind == "table" then
			result[key] = format(v, visited)
		else
			result[key] = v
		end
	end

	return result
end

return serializeBlackboard
