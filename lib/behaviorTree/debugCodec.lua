--!strict
--!native
--!optimize 2
-- Pure buffer codec for the networked debugger. This module has no Roblox
-- dependencies (no `game:GetService`, no script instances), so it can be
-- required and tested from Lune as well as Roblox.
--
-- `debugNetwork.lua` owns the server-side state (tree registry, subscriber
-- tracking, RemoteEvent creation) and calls into this module for all buffer
-- encoding/decoding. Keeping the codec here means tests can exercise every
-- wire-format path without running a real Roblox data model.
--
-- Byte-level helpers (Writer, Reader, read/write/finish) live in
-- `bufferUtil.lua` so they can be reused without duplication.

local bufferUtil = require("./bufferUtil")

type Writer = bufferUtil.Writer
type Reader = bufferUtil.Reader

local newWriter = bufferUtil.newWriter
local finish = bufferUtil.finish
local writeU8 = bufferUtil.writeU8
local writeU16 = bufferUtil.writeU16
local writeU32 = bufferUtil.writeU32
local writeI32 = bufferUtil.writeI32
local writeF32 = bufferUtil.writeF32
local writeF64 = bufferUtil.writeF64
local writeString = bufferUtil.writeString

local newReader = bufferUtil.newReader
local readU8 = bufferUtil.readU8
local readU16 = bufferUtil.readU16
local readU32 = bufferUtil.readU32
local readI32 = bufferUtil.readI32
local readF32 = bufferUtil.readF32
local readF64 = bufferUtil.readF64
local readString = bufferUtil.readString

------------------------------------------------------------------------
-- Buffer format constants
------------------------------------------------------------------------

-- Snapshot packet kinds.
local PACKET_FULL: number = 0
local PACKET_DELTA: number = 1

-- Per-key op codes used in delta packets.
local BB_OP_REMOVE: number = 0
local BB_OP_SET: number = 1

-- Blackboard value type tags. Kept hardcoded because the set is fixed by the
-- typeof() values we can produce (booleans, numbers, strings, a few Roblox
-- value types, and a tostring fallback) — adding a new tag requires coupled
-- changes on both encoder and decoder anyway, so there's no maintenance
-- benefit to making the mapping dynamic here.
local VAL_FALSE: number = 1
local VAL_TRUE: number = 2
local VAL_NUMBER: number = 3
local VAL_STRING: number = 4
local VAL_VECTOR3: number = 5
local VAL_VECTOR2: number = 6
local VAL_COLOR3: number = 7
local VAL_CFRAME: number = 8
local VAL_FALLBACK: number = 9

-- Note: node types and parallel policies are NOT hardcoded on the wire.
-- Each tree-definition packet carries its own string enum header so adding
-- or renaming a node type on the server doesn't require a corresponding
-- client-side change. See encodeTreeDefinition / decodeTreeDefinition.

------------------------------------------------------------------------
-- Value encode / decode
------------------------------------------------------------------------
-- Vector3/Vector2/Color3/CFrame constructors are only available in the
-- Roblox runtime. In Lune tests these remain unused (tests only cover
-- primitive values). Wrapping the lookups with `any` keeps strict mode
-- happy on both environments.

local function writeValue(w: Writer, value: any)
	local t = typeof(value)
	if t == "boolean" then
		writeU8(w, if value then VAL_TRUE else VAL_FALSE)
	elseif t == "number" then
		writeU8(w, VAL_NUMBER)
		writeF64(w, value)
	elseif t == "string" then
		writeU8(w, VAL_STRING)
		writeString(w, value)
	elseif t == "Vector3" then
		writeU8(w, VAL_VECTOR3)
		writeF32(w, value.X)
		writeF32(w, value.Y)
		writeF32(w, value.Z)
	elseif t == "Vector2" then
		writeU8(w, VAL_VECTOR2)
		writeF32(w, value.X)
		writeF32(w, value.Y)
	elseif t == "Color3" then
		writeU8(w, VAL_COLOR3)
		writeF32(w, value.R)
		writeF32(w, value.G)
		writeF32(w, value.B)
	elseif t == "CFrame" then
		writeU8(w, VAL_CFRAME)
		local cf: any = value
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		writeF32(w, x)
		writeF32(w, y)
		writeF32(w, z)
		writeF32(w, r00)
		writeF32(w, r01)
		writeF32(w, r02)
		writeF32(w, r10)
		writeF32(w, r11)
		writeF32(w, r12)
		writeF32(w, r20)
		writeF32(w, r21)
		writeF32(w, r22)
	else
		writeU8(w, VAL_FALLBACK)
		writeString(w, tostring(value))
	end
end

local function readValue(r: Reader): any
	local tag = readU8(r)
	if tag == VAL_FALSE then
		return false
	elseif tag == VAL_TRUE then
		return true
	elseif tag == VAL_NUMBER then
		return readF64(r)
	elseif tag == VAL_STRING then
		return readString(r)
	elseif tag == VAL_VECTOR3 then
		return (Vector3 :: any).new(readF32(r), readF32(r), readF32(r))
	elseif tag == VAL_VECTOR2 then
		return (Vector2 :: any).new(readF32(r), readF32(r))
	elseif tag == VAL_COLOR3 then
		return (Color3 :: any).new(readF32(r), readF32(r), readF32(r))
	elseif tag == VAL_CFRAME then
		return (CFrame :: any).new(
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r),
			readF32(r)
		)
	elseif tag == VAL_FALLBACK then
		return readString(r)
	end
	error(`Unknown value tag {tag}`)
end

------------------------------------------------------------------------
-- Tree definition encoding
------------------------------------------------------------------------
-- A tree definition is a static structure of plain Luau tables. The walker
-- mirrors the DFS order used by the native library's `buildFlatTree`, so
-- the `nodeIndex` values in the encoded output match the `nodeIndex` keys
-- used in `DebugSnapshot` packets.

type DefEntry = {
	def: any,
	children: { number },
	singleChild: number,
}

local function walkDefinition(def: any, entries: { DefEntry }): number
	local nodeIndex = #entries + 1
	local entry: DefEntry = { def = def, children = {}, singleChild = 0 }
	table.insert(entries, entry)

	local t = def._type
	if t == "sequence" or t == "selector" or t == "parallel" or t == "randomSelector" then
		for i, childDef in def.children do
			entry.children[i] = walkDefinition(childDef, entries)
		end
	elseif t == "invert" or t == "repeat" or t == "retry" then
		entry.singleChild = walkDefinition(def.child, entries)
	elseif t == "alwaysSucceed" or t == "alwaysFail" then
		if def.child then
			entry.singleChild = walkDefinition(def.child, entries)
		end
	elseif t == "subtree" then
		entry.singleChild = walkDefinition(def.module, entries)
	end

	return nodeIndex
end

local definitionCache: { [any]: buffer } = setmetatable({} :: any, { __mode = "k" }) :: any

-- Encodes the tree definition as:
--   u8  typeEnumCount
--   for i = 1..typeEnumCount: length-prefixed string (the BT._type name)
--   u32 nodeCount
--   for each node:
--     u8  typeEnumIndex (0-based into the header)
--     <structural + meta + type-specific payload>
-- Writing the enum at the head means the client never has to share a
-- hardcoded numeric mapping with the server — if a new node type is added
-- here, the client picks it up from the packet.
local function encodeTreeDefinition(definition: any): buffer
	local cached = definitionCache[definition]
	if cached then
		return cached
	end

	local entries: { DefEntry } = {}
	walkDefinition(definition, entries)

	-- First pass: build the local type enum in the order types are first
	-- encountered. This keeps the enum self-contained per packet.
	local typeEnum: { string } = {}
	local typeIndex: { [string]: number } = {}
	local function getTypeIndex(typeName: string): number
		local existing = typeIndex[typeName]
		if existing then
			return existing
		end
		local idx = #typeEnum
		typeEnum[idx + 1] = typeName
		typeIndex[typeName] = idx
		return idx
	end
	for _, entry in entries do
		getTypeIndex(entry.def._type)
	end

	local w = newWriter(1024)

	-- Type enum header.
	writeU8(w, #typeEnum)
	for _, typeName in typeEnum do
		writeString(w, typeName)
	end

	writeU32(w, #entries)

	for _, entry in entries do
		local def = entry.def
		writeU8(w, typeIndex[def._type])

		writeU16(w, #entry.children)
		for _, idx in entry.children do
			writeU32(w, idx)
		end
		writeU32(w, entry.singleChild)

		local meta = def.meta
		if meta and meta.label ~= nil then
			writeU8(w, 1)
			writeString(w, tostring(meta.label))
		else
			writeU8(w, 0)
		end
		if meta and typeof(meta.size) == "Vector2" then
			writeU8(w, 1)
			writeF32(w, meta.size.X)
			writeF32(w, meta.size.Y)
		else
			writeU8(w, 0)
		end
		if meta and typeof(meta.position) == "Vector2" then
			writeU8(w, 1)
			writeF32(w, meta.position.X)
			writeF32(w, meta.position.Y)
		else
			writeU8(w, 0)
		end

		-- Type-specific payload. Policies are written as length-prefixed
		-- strings rather than a hardcoded u8 so the wire format stays free
		-- of shared constants.
		local t = def._type
		if t == "task" then
			local mod = def.module
			if mod and mod.name ~= nil then
				writeU8(w, 1)
				writeString(w, tostring(mod.name))
			else
				writeU8(w, 0)
			end
			local params = def.params or {}
			local paramCount = 0
			for _ in params do
				paramCount += 1
			end
			writeU32(w, paramCount)
			for k, v in params do
				writeString(w, tostring(k))
				writeValue(w, v)
			end
		elseif t == "parallel" then
			writeString(w, tostring(def.successPolicy))
			writeString(w, tostring(def.failurePolicy))
		elseif t == "repeat" or t == "retry" then
			writeI32(w, def.times)
		elseif t == "randomSelector" then
			if def.weights then
				writeU8(w, 1)
				writeU32(w, #def.weights)
				for _, weight in def.weights do
					writeF32(w, weight)
				end
			else
				writeU8(w, 0)
			end
		end
	end

	local out = finish(w)
	definitionCache[definition] = out
	return out
end

export type DefinitionNode = {
	type: string,
	children: { number },
	singleChild: number,
	label: string?,
	size: Vector2?,
	position: Vector2?,
	taskName: string?,
	taskParams: { [string]: any }?,
	successPolicy: ("requireAll" | "requireOne")?,
	failurePolicy: ("requireAll" | "requireOne")?,
	times: number?,
	weights: { number }?,
}

export type TreeDefinitionPacket = {
	treeId: number,
	nodes: { DefinitionNode },
}

local function decodeTreeDefinitionFromReader(r: Reader, treeId: number, totalLen: number): TreeDefinitionPacket
	-- Server returns treeId=0 and no further payload when the id is unknown.
	if treeId == 0 and totalLen == 4 then
		return { treeId = 0, nodes = {} }
	end

	-- Read the self-describing type enum. Indices in the node stream below
	-- are 0-based into this table.
	local enumCount = readU8(r)
	local typeEnum: { string } = {}
	for i = 1, enumCount do
		typeEnum[i] = readString(r)
	end

	local nodeCount = readU32(r)
	local nodes: { DefinitionNode } = {}
	for i = 1, nodeCount do
		local typeIdx = readU8(r)
		local typeName = typeEnum[typeIdx + 1]
		if typeName == nil then
			error(`Unknown type enum index {typeIdx} in tree definition packet`)
		end

		local childCount = readU16(r)
		local children: { number } = {}
		for j = 1, childCount do
			children[j] = readU32(r)
		end
		local singleChild = readU32(r)

		local label: string? = nil
		local size: Vector2? = nil
		local position: Vector2? = nil
		if readU8(r) == 1 then
			label = readString(r)
		end
		if readU8(r) == 1 then
			size = (Vector2 :: any).new(readF32(r), readF32(r))
		end
		if readU8(r) == 1 then
			position = (Vector2 :: any).new(readF32(r), readF32(r))
		end

		local node: DefinitionNode = {
			type = typeName,
			children = children,
			singleChild = singleChild,
			label = label,
			size = size,
			position = position,
		}

		if typeName == "task" then
			if readU8(r) == 1 then
				node.taskName = readString(r)
			end
			local paramCount = readU32(r)
			local params: { [string]: any } = {}
			for _ = 1, paramCount do
				local key = readString(r)
				params[key] = readValue(r)
			end
			node.taskParams = params
		elseif typeName == "parallel" then
			node.successPolicy = readString(r) :: any
			node.failurePolicy = readString(r) :: any
		elseif typeName == "repeat" or typeName == "retry" then
			node.times = readI32(r)
		elseif typeName == "randomSelector" then
			if readU8(r) == 1 then
				local weightCount = readU32(r)
				local weights: { number } = {}
				for j = 1, weightCount do
					weights[j] = readF32(r)
				end
				node.weights = weights
			end
		end

		nodes[i] = node
	end
	return { treeId = treeId, nodes = nodes }
end

local function decodeTreeDefinition(buf: buffer): TreeDefinitionPacket
	local r = newReader(buf)
	local treeId = readU32(r)
	return decodeTreeDefinitionFromReader(r, treeId, buffer.len(buf))
end

------------------------------------------------------------------------
-- Tree list encoding
------------------------------------------------------------------------

export type TreeListEntry = {
	id: number,
	executionCount: number,
	debugName: string,
	definitionPath: string,
}

-- Iteration-count-free encoder: caller provides a sequential array.
local function encodeTreeList(entries: { TreeListEntry }): buffer
	local w = newWriter(256)
	writeU16(w, #entries)
	for _, entry in entries do
		writeU32(w, entry.id)
		writeU32(w, entry.executionCount)
		writeString(w, entry.debugName)
		writeString(w, entry.definitionPath)
	end
	return finish(w)
end

local function decodeTreeList(buf: buffer): { TreeListEntry }
	local r = newReader(buf)
	local count = readU16(r)
	local out: { TreeListEntry } = {}
	for i = 1, count do
		local id = readU32(r)
		local executionCount = readU32(r)
		local debugName = readString(r)
		local definitionPath = readString(r)
		out[i] = {
			id = id,
			executionCount = executionCount,
			debugName = debugName,
			definitionPath = definitionPath,
		}
	end
	return out
end

------------------------------------------------------------------------
-- Snapshot encoding
------------------------------------------------------------------------

export type SnapshotFrame = {
	treeId: number,
	tick: number,
	paused: boolean,
	nodeStates: { [number]: number },
	blackboard: { [string]: any },
}

local function encodeFullSnapshot(frame: SnapshotFrame): buffer
	local w = newWriter(512)
	writeU8(w, PACKET_FULL)
	writeU32(w, frame.treeId)
	writeU32(w, frame.tick)
	writeU8(w, if frame.paused then 1 else 0)

	local ns = frame.nodeStates
	local nodeCount = 0
	for _ in ns do
		nodeCount += 1
	end
	writeU32(w, nodeCount)
	for nodeIdx, status in ns do
		writeU32(w, nodeIdx)
		writeU8(w, status)
	end

	local bb = frame.blackboard
	local keyCount = 0
	for _ in bb do
		keyCount += 1
	end
	writeU32(w, keyCount)
	for key, value in bb do
		writeString(w, key)
		writeValue(w, value)
	end

	return finish(w)
end

local function encodeDeltaSnapshot(
	frame: SnapshotFrame,
	previousNodeStates: { [number]: number },
	previousBlackboard: { [string]: any }
): buffer
	local w = newWriter(256)
	writeU8(w, PACKET_DELTA)
	writeU32(w, frame.treeId)
	writeU32(w, frame.tick)
	writeU8(w, if frame.paused then 1 else 0)

	local currentNs = frame.nodeStates
	local changedNodes: { { idx: number, status: number } } = {}
	for idx, status in currentNs do
		if previousNodeStates[idx] ~= status then
			table.insert(changedNodes, { idx = idx, status = status })
		end
	end
	writeU32(w, #changedNodes)
	for _, change in changedNodes do
		writeU32(w, change.idx)
		writeU8(w, change.status)
	end

	-- Diff by direct `~=`. Callers are expected to have run the blackboard
	-- through `serializeBlackboard` first, which leaves only primitives,
	-- strings, and Roblox value types (Vector3/Vector2/Color3/CFrame) in the
	-- map — all of which support value-equality via `==`. Nested tables and
	-- Instances are reduced to strings by `serializeBlackboard`, so reference
	-- identity never leaks into the diff.
	local currentBb = frame.blackboard
	local setEntries: { { key: string, value: any } } = {}
	local removedKeys: { string } = {}
	for key, value in currentBb do
		if previousBlackboard[key] ~= value then
			table.insert(setEntries, { key = key, value = value })
		end
	end
	for key in previousBlackboard do
		if currentBb[key] == nil then
			table.insert(removedKeys, key)
		end
	end
	writeU32(w, #setEntries + #removedKeys)
	for _, entryData in setEntries do
		writeU8(w, BB_OP_SET)
		writeString(w, entryData.key)
		writeValue(w, entryData.value)
	end
	for _, key in removedKeys do
		writeU8(w, BB_OP_REMOVE)
		writeString(w, key)
	end

	return finish(w)
end

export type SnapshotPacket = {
	kind: "full" | "delta",
	treeId: number,
	tick: number,
	paused: boolean,
	nodeStates: { [number]: number },
	blackboardSet: { [string]: any },
	blackboardRemoved: { string },
}

local function decodeSnapshot(buf: buffer): SnapshotPacket
	local r = newReader(buf)
	local kindTag = readU8(r)
	local treeId = readU32(r)
	local tick = readU32(r)
	local paused = readU8(r) == 1

	local nodeStates: { [number]: number } = {}
	local bbSet: { [string]: any } = {}
	local bbRemoved: { string } = {}

	if kindTag == PACKET_FULL then
		local nodeCount = readU32(r)
		for _ = 1, nodeCount do
			local idx = readU32(r)
			local status = readU8(r)
			nodeStates[idx] = status
		end
		local keyCount = readU32(r)
		for _ = 1, keyCount do
			local key = readString(r)
			bbSet[key] = readValue(r)
		end
		return {
			kind = "full",
			treeId = treeId,
			tick = tick,
			paused = paused,
			nodeStates = nodeStates,
			blackboardSet = bbSet,
			blackboardRemoved = bbRemoved,
		}
	elseif kindTag == PACKET_DELTA then
		local changedCount = readU32(r)
		for _ = 1, changedCount do
			local idx = readU32(r)
			local status = readU8(r)
			nodeStates[idx] = status
		end
		local bbOpCount = readU32(r)
		for _ = 1, bbOpCount do
			local op = readU8(r)
			if op == BB_OP_SET then
				local key = readString(r)
				bbSet[key] = readValue(r)
			elseif op == BB_OP_REMOVE then
				table.insert(bbRemoved, readString(r))
			end
		end
		return {
			kind = "delta",
			treeId = treeId,
			tick = tick,
			paused = paused,
			nodeStates = nodeStates,
			blackboardSet = bbSet,
			blackboardRemoved = bbRemoved,
		}
	end
	error(`Unknown snapshot packet kind {kindTag}`)
end

------------------------------------------------------------------------
-- Client request encoders
------------------------------------------------------------------------

local function encodeSubscribe(treeId: number, subscribe: boolean): buffer
	local w = newWriter(8)
	writeU32(w, treeId)
	writeU8(w, if subscribe then 1 else 0)
	return finish(w)
end

local function encodeTreeDefinitionRequest(treeId: number): buffer
	local w = newWriter(4)
	writeU32(w, treeId)
	return finish(w)
end

-- Parse a subscribe payload on the server side. Returns nil on malformed
-- input. Kept here so the network layer doesn't need to know offsets.
local function decodeSubscribe(buf: buffer): ({ treeId: number, subscribe: boolean })?
	if buffer.len(buf) < 5 then
		return nil
	end
	local r = newReader(buf)
	local treeId = readU32(r)
	local flag = readU8(r)
	return { treeId = treeId, subscribe = flag == 1 }
end

local function decodeTreeDefinitionRequest(buf: buffer): number?
	if buffer.len(buf) < 4 then
		return nil
	end
	local r = newReader(buf)
	return readU32(r)
end

------------------------------------------------------------------------
-- Tree definition response helper
------------------------------------------------------------------------
-- The tree-definition response is `u32 treeId` followed by the cached
-- definition bytes. Builds a fresh buffer with both sections without
-- touching the cache.

local function buildTreeDefinitionResponse(treeId: number, definitionBuf: buffer): buffer
	local defLen = buffer.len(definitionBuf)
	local out = buffer.create(4 + defLen)
	buffer.writeu32(out, 0, treeId)
	buffer.copy(out, 4, definitionBuf, 0, defLen)
	return out
end

local function buildEmptyTreeDefinitionResponse(): buffer
	local out = buffer.create(4)
	buffer.writeu32(out, 0, 0)
	return out
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return {
	encodeTreeDefinition = encodeTreeDefinition,
	decodeTreeDefinition = decodeTreeDefinition,
	encodeTreeList = encodeTreeList,
	decodeTreeList = decodeTreeList,
	encodeFullSnapshot = encodeFullSnapshot,
	encodeDeltaSnapshot = encodeDeltaSnapshot,
	decodeSnapshot = decodeSnapshot,
	encodeSubscribe = encodeSubscribe,
	decodeSubscribe = decodeSubscribe,
	encodeTreeDefinitionRequest = encodeTreeDefinitionRequest,
	decodeTreeDefinitionRequest = decodeTreeDefinitionRequest,
	buildTreeDefinitionResponse = buildTreeDefinitionResponse,
	buildEmptyTreeDefinitionResponse = buildEmptyTreeDefinitionResponse,
}
