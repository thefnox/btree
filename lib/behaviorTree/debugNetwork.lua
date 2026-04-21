--!strict
--!native
--!optimize 2
-- Networked debugging for behavior trees.
--
-- On the server, when a tree is registered (by the wrapper whenever a tree is
-- created with debug enabled), three RemoteEvents are lazily created under the
-- library module:
--   DebugTreeList   — client fires an empty buffer to request the list of
--                     active debug trees; server replies on the same event
--                     with a buffer containing { id, debugName, executionCount,
--                     definitionPath } for each registered tree.
--   DebugSubscribe  — client → server. Buffer contains (treeId, subscribe)
--                     where subscribe is 1 to start receiving snapshots and
--                     0 to stop.
--   DebugSnapshot   — server → client. Buffer contains the current tick,
--                     paused flag, and either a full snapshot (first packet
--                     per subscription) or a delta (subsequent packets).
--
-- All payloads are buffers. Format documented in the `-- Buffer format` block
-- below. Client-side decoders are exposed via the `decode*` functions.
--
-- When no tree has been registered with debug enabled the RemoteEvents are
-- never created, so production builds with debugging disabled have zero
-- remote-event overhead.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local serializeBlackboard = require("@self/serializeBlackboard")

local IS_SERVER = RunService:IsServer()

------------------------------------------------------------------------
-- Buffer format constants
------------------------------------------------------------------------

-- Snapshot packet kinds.
local PACKET_FULL: number = 0
local PACKET_DELTA: number = 1

-- Per-key op codes used in delta packets.
local BB_OP_REMOVE: number = 0
local BB_OP_SET: number = 1

-- Value type tags for blackboard entries.
local VAL_FALSE: number = 1
local VAL_TRUE: number = 2
local VAL_NUMBER: number = 3
local VAL_STRING: number = 4
local VAL_VECTOR3: number = 5
local VAL_VECTOR2: number = 6
local VAL_COLOR3: number = 7
local VAL_CFRAME: number = 8
-- Fallback: tostring'd representation. Covers nested tables (serializeBlackboard
-- already converts them to strings), Instances (ditto), and anything else the
-- serializer left as a typeof we don't explicitly handle.
local VAL_FALLBACK: number = 9

------------------------------------------------------------------------
-- Growable buffer writer
------------------------------------------------------------------------
-- Roblox buffers are fixed-size. We grow a scratch buffer on demand and copy
-- out just the used prefix via `finish()`.

type Writer = {
	buf: buffer,
	offset: number,
}

local function newWriter(capacity: number): Writer
	return { buf = buffer.create(capacity), offset = 0 }
end

local function ensure(w: Writer, additional: number)
	local needed = w.offset + additional
	local cap = buffer.len(w.buf)
	if cap < needed then
		local newSize = if cap == 0 then 64 else cap * 2
		while newSize < needed do
			newSize *= 2
		end
		local newBuf = buffer.create(newSize)
		buffer.copy(newBuf, 0, w.buf, 0, w.offset)
		w.buf = newBuf
	end
end

local function writeU8(w: Writer, v: number)
	ensure(w, 1)
	buffer.writeu8(w.buf, w.offset, v)
	w.offset += 1
end

local function writeU16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writeu16(w.buf, w.offset, v)
	w.offset += 2
end

local function writeU32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writeu32(w.buf, w.offset, v)
	w.offset += 4
end

local function writeF32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writef32(w.buf, w.offset, v)
	w.offset += 4
end

local function writeF64(w: Writer, v: number)
	ensure(w, 8)
	buffer.writef64(w.buf, w.offset, v)
	w.offset += 8
end

local function writeString(w: Writer, s: string)
	local len = #s
	writeU16(w, len)
	ensure(w, len)
	buffer.writestring(w.buf, w.offset, s)
	w.offset += len
end

local function finish(w: Writer): buffer
	local out = buffer.create(w.offset)
	buffer.copy(out, 0, w.buf, 0, w.offset)
	return out
end

------------------------------------------------------------------------
-- Reader (used on the client-side decoders and for server-side subscribe parse)
------------------------------------------------------------------------

type Reader = {
	buf: buffer,
	offset: number,
}

local function newReader(buf: buffer): Reader
	return { buf = buf, offset = 0 }
end

local function readU8(r: Reader): number
	local v = buffer.readu8(r.buf, r.offset)
	r.offset += 1
	return v
end

local function readU16(r: Reader): number
	local v = buffer.readu16(r.buf, r.offset)
	r.offset += 2
	return v
end

local function readU32(r: Reader): number
	local v = buffer.readu32(r.buf, r.offset)
	r.offset += 4
	return v
end

local function readF32(r: Reader): number
	local v = buffer.readf32(r.buf, r.offset)
	r.offset += 4
	return v
end

local function readF64(r: Reader): number
	local v = buffer.readf64(r.buf, r.offset)
	r.offset += 8
	return v
end

local function readString(r: Reader): string
	local len = readU16(r)
	local s = buffer.readstring(r.buf, r.offset, len)
	r.offset += len
	return s
end

------------------------------------------------------------------------
-- Value encode / decode
------------------------------------------------------------------------

-- Returns (tag, writeFn). The writeFn writes just the payload; the tag must
-- be written separately by the caller.
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
		local cf = value :: CFrame
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
		-- Fallback: tostring. Covers any unusual type the serializer leaves
		-- through (which should be rare since serializeBlackboard already
		-- coerces Instances, functions, threads, and deep tables).
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
		return Vector3.new(readF32(r), readF32(r), readF32(r))
	elseif tag == VAL_VECTOR2 then
		return Vector2.new(readF32(r), readF32(r))
	elseif tag == VAL_COLOR3 then
		return Color3.new(readF32(r), readF32(r), readF32(r))
	elseif tag == VAL_CFRAME then
		return CFrame.new(
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

-- Cheap equality used for diff tracking. Serialized blackboards only contain
-- primitives, strings, and Roblox value types — all of which support == except
-- CFrame (which does but with tolerance; we use raw ==).
local function valuesEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	local ta = typeof(a)
	if ta ~= typeof(b) then
		return false
	end
	if ta == "Vector3" or ta == "Vector2" or ta == "Color3" then
		return a == b
	end
	return false
end

------------------------------------------------------------------------
-- Remote event management
------------------------------------------------------------------------

type Remotes = {
	treeList: RemoteEvent,
	subscribe: RemoteEvent,
	snapshot: RemoteEvent,
}

local remotes: Remotes? = nil

-- RemoteEvents are parented under the library script. Because this module
-- is loaded via `require("@self/debugNetwork")` from the library's init.lua,
-- `script` here is the debugNetwork ModuleScript and `script.Parent` is the
-- library script itself.
local parentInstance: Instance = script.Parent :: Instance

------------------------------------------------------------------------
-- Server-side tree registry
------------------------------------------------------------------------

type SubscriberState = {
	-- Per-player per-tree state. Nil until the player has received their first
	-- snapshot. After that, holds the last sent blackboard and node states so
	-- the next packet can be a delta against them.
	lastBlackboard: { [string]: any }?,
	lastNodeStates: { [number]: number }?,
}

type TreeEntry = {
	id: number,
	debugName: string,
	definitionPath: string,
	executionCount: number,
	-- Last authoritative blackboard/node state captured from the tree's update.
	-- Held so late subscribers can seed their initial full packet.
	currentBlackboard: { [string]: any }?,
	currentNodeStates: { [number]: number }?,
	currentTick: number,
	currentPaused: boolean,
	subscribers: { [Player]: SubscriberState },
}

local nextTreeId = 0
local trees: { [number]: TreeEntry } = {}

------------------------------------------------------------------------
-- Packet encoders
------------------------------------------------------------------------

local function encodeTreeList(): buffer
	local w = newWriter(256)
	local count = 0
	-- Two-pass: first count, then serialize. We need the count up front.
	for _ in trees do
		count += 1
	end
	writeU16(w, count)
	for _, entry in trees do
		writeU32(w, entry.id)
		writeU32(w, entry.executionCount)
		writeString(w, entry.debugName)
		writeString(w, entry.definitionPath)
	end
	return finish(w)
end

local function encodeFullSnapshot(entry: TreeEntry): buffer
	local w = newWriter(512)
	writeU8(w, PACKET_FULL)
	writeU32(w, entry.id)
	writeU32(w, entry.currentTick)
	writeU8(w, if entry.currentPaused then 1 else 0)

	-- Node states.
	local ns = entry.currentNodeStates or {}
	local nodeCount = 0
	for _ in ns do
		nodeCount += 1
	end
	writeU32(w, nodeCount)
	for nodeIdx, status in ns do
		writeU32(w, nodeIdx)
		writeU8(w, status)
	end

	-- Blackboard.
	local bb = entry.currentBlackboard or {}
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

local function encodeDeltaSnapshot(entry: TreeEntry, last: SubscriberState): buffer
	local w = newWriter(256)
	writeU8(w, PACKET_DELTA)
	writeU32(w, entry.id)
	writeU32(w, entry.currentTick)
	writeU8(w, if entry.currentPaused then 1 else 0)

	-- Node state diff. We only emit entries whose status changed since last
	-- sent or which are new.
	local currentNs = entry.currentNodeStates or {}
	local lastNs = last.lastNodeStates or {}
	local changedNodes: { { idx: number, status: number } } = {}
	for idx, status in currentNs do
		if lastNs[idx] ~= status then
			table.insert(changedNodes, { idx = idx, status = status })
		end
	end
	writeU32(w, #changedNodes)
	for _, change in changedNodes do
		writeU32(w, change.idx)
		writeU8(w, change.status)
	end

	-- Blackboard diff.
	local currentBb = entry.currentBlackboard or {}
	local lastBb = last.lastBlackboard or {}
	-- Count changes first so we can write a u32 count up front.
	local setEntries: { { key: string, value: any } } = {}
	local removedKeys: { string } = {}
	for key, value in currentBb do
		local previous = lastBb[key]
		if previous == nil or not valuesEqual(previous, value) then
			table.insert(setEntries, { key = key, value = value })
		end
	end
	for key in lastBb do
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

------------------------------------------------------------------------
-- Server-side public API
------------------------------------------------------------------------

local DebugNetwork = {}

local function ensureRemotes()
	if remotes then
		return
	end
	assert(IS_SERVER, "Remote creation is server-only")

	-- Reuse any RemoteEvents that already exist (e.g. if the library was
	-- required a second time after an earlier session created them). This
	-- keeps us idempotent across script reloads.
	local treeList = parentInstance:FindFirstChild("DebugTreeList") :: RemoteEvent? or Instance.new("RemoteEvent")
	treeList.Name = "DebugTreeList"
	treeList.Parent = parentInstance

	local subscribe = parentInstance:FindFirstChild("DebugSubscribe") :: RemoteEvent? or Instance.new("RemoteEvent")
	subscribe.Name = "DebugSubscribe"
	subscribe.Parent = parentInstance

	local snapshot = parentInstance:FindFirstChild("DebugSnapshot") :: RemoteEvent? or Instance.new("RemoteEvent")
	snapshot.Name = "DebugSnapshot"
	snapshot.Parent = parentInstance

	remotes = { treeList = treeList, subscribe = subscribe, snapshot = snapshot }

	-- List-request handler. The client fires an empty buffer; we respond
	-- with the encoded list back on the same event to just that player.
	treeList.OnServerEvent:Connect(function(player)
		treeList:FireClient(player, encodeTreeList())
	end)

	-- Subscribe handler. Client sends a buffer { u32 treeId, u8 subscribe }.
	subscribe.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "buffer" then
			return
		end
		local r = newReader(payload :: buffer)
		-- Defensive: any malformed payload just stops decoding.
		local ok, treeId, flag = pcall(function()
			return readU32(r), readU8(r)
		end)
		if not ok then
			return
		end
		local entry = trees[treeId]
		if not entry then
			return
		end
		if flag == 1 then
			if entry.subscribers[player] == nil then
				entry.subscribers[player] = { lastBlackboard = nil, lastNodeStates = nil }
				-- Send initial full snapshot immediately if we have data to send.
				if entry.currentBlackboard ~= nil then
					local state = entry.subscribers[player]
					local buf = encodeFullSnapshot(entry)
					snapshot:FireClient(player, buf)
					state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
					state.lastNodeStates = table.clone(entry.currentNodeStates :: { [number]: number })
				end
			end
		else
			entry.subscribers[player] = nil
		end
	end)

	-- Clean up subscriber state when a player leaves so we don't leak
	-- references or try to send to a gone player.
	Players.PlayerRemoving:Connect(function(player)
		for _, entry in trees do
			entry.subscribers[player] = nil
		end
	end)
end

-- Registers a new debug tree. Returns the assigned id. Server-only; on the
-- client this is a no-op returning 0.
function DebugNetwork.registerTree(debugName: string, definitionPath: string): number
	if not IS_SERVER then
		return 0
	end
	ensureRemotes()
	nextTreeId += 1
	local id = nextTreeId
	trees[id] = {
		id = id,
		debugName = debugName,
		definitionPath = definitionPath,
		executionCount = 0,
		currentBlackboard = nil,
		currentNodeStates = nil,
		currentTick = 0,
		currentPaused = false,
		subscribers = {},
	}
	return id
end

-- Called by the wrapper after each tree:update(). `nodeStates` is the
-- *authoritative* full node-state table (as returned by the native snapshot),
-- and `blackboard` is the raw table (will be serialized here).
function DebugNetwork.onTreeUpdated(
	treeId: number,
	tick: number,
	paused: boolean,
	nodeStates: { [number]: number },
	blackboard: any
)
	if not IS_SERVER then
		return
	end
	local entry = trees[treeId]
	if not entry then
		return
	end
	entry.executionCount += 1
	entry.currentTick = tick
	entry.currentPaused = paused
	entry.currentNodeStates = table.clone(nodeStates)
	entry.currentBlackboard = serializeBlackboard(blackboard)

	-- Fan out to subscribers. First-time subscribers get a full packet;
	-- everyone else gets a delta.
	if not remotes then
		return
	end
	local snapshotEvent = remotes.snapshot
	for player, state in entry.subscribers do
		if state.lastBlackboard == nil then
			local buf = encodeFullSnapshot(entry)
			snapshotEvent:FireClient(player, buf)
			state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
			state.lastNodeStates = table.clone(entry.currentNodeStates :: { [number]: number })
		else
			local buf = encodeDeltaSnapshot(entry, state)
			snapshotEvent:FireClient(player, buf)
			state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
			state.lastNodeStates = table.clone(entry.currentNodeStates :: { [number]: number })
		end
	end
end

------------------------------------------------------------------------
-- Client-side decoders
------------------------------------------------------------------------

export type TreeListEntry = {
	id: number,
	executionCount: number,
	debugName: string,
	definitionPath: string,
}

export type SnapshotPacket = {
	kind: "full" | "delta",
	treeId: number,
	tick: number,
	paused: boolean,
	-- Full: all node states and all blackboard entries.
	-- Delta: only changed node states; blackboard has `set` and `removed`
	-- arrays.
	nodeStates: { [number]: number },
	blackboardSet: { [string]: any },
	blackboardRemoved: { string },
}

function DebugNetwork.decodeTreeList(buf: buffer): { TreeListEntry }
	local r = newReader(buf)
	local count = readU16(r)
	local out: { TreeListEntry } = table.create(count)
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

function DebugNetwork.decodeSnapshot(buf: buffer): SnapshotPacket
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

-- Client helper: encode a subscribe/unsubscribe request buffer. The client
-- can fire the DebugSubscribe RemoteEvent with the returned buffer.
function DebugNetwork.encodeSubscribe(treeId: number, subscribe: boolean): buffer
	local w = newWriter(8)
	writeU32(w, treeId)
	writeU8(w, if subscribe then 1 else 0)
	return finish(w)
end

-- Client helper: returns the three RemoteEvents once the server has created
-- them. Yields until all three exist. Returns nil immediately when called on
-- the server (the server uses the internal `remotes` cache).
function DebugNetwork.waitForRemotes(timeout: number?): Remotes?
	local treeList = parentInstance:WaitForChild("DebugTreeList", timeout) :: RemoteEvent?
	local subscribe = parentInstance:WaitForChild("DebugSubscribe", timeout) :: RemoteEvent?
	local snapshot = parentInstance:WaitForChild("DebugSnapshot", timeout) :: RemoteEvent?
	if treeList and subscribe and snapshot then
		return { treeList = treeList, subscribe = subscribe, snapshot = snapshot }
	end
	return nil
end

return DebugNetwork
