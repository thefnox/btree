--!strict
--!native
--!optimize 2
-- Networked debugging for behavior trees.
--
-- On the server, when a tree is registered (by the wrapper whenever a tree is
-- created with debug enabled), four RemoteEvents are lazily created under the
-- library module:
--   DebugTreeList        — client fires an empty buffer to request the list
--                          of active debug trees; server replies on the same
--                          event with a buffer containing { id, debugName,
--                          executionCount, definitionPath } for each
--                          registered tree.
--   DebugTreeDefinition  — client fires `u32 treeId` to request the full
--                          static structure of a tree. Server replies on the
--                          same event with the encoded definition. Tree
--                          definitions don't replicate normally, so this is
--                          the only way for a client to learn the structure.
--   DebugSubscribe       — client → server. Buffer contains (treeId,
--                          subscribe) where subscribe is 1 to start
--                          receiving snapshots and 0 to stop.
--   DebugSnapshot        — server → client. Buffer contains the current
--                          tick, paused flag, and either a full snapshot
--                          (first packet per subscription) or a delta
--                          (subsequent packets).
--
-- All payloads are buffers. Formats live in `debugCodec.lua`, which is pure
-- Luau and has no Roblox dependencies so it can be unit-tested from Lune.
-- When no tree has been registered with debug enabled the RemoteEvents are
-- never created, so production builds with debugging disabled pay nothing.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local serializeBlackboard = require("./serializeBlackboard")
local debugCodec = require("./debugCodec")

local IS_SERVER = RunService:IsServer()

type Remotes = {
	treeList: RemoteEvent,
	treeDefinition: RemoteEvent,
	subscribe: RemoteEvent,
	snapshot: RemoteEvent,
}

local remotes: Remotes? = nil

-- RemoteEvents are parented under the library script. Because this module
-- is loaded via `require("@self/debugNetwork")` from the library's init.lua,
-- `script` here is the debugNetwork ModuleScript and `script.Parent` is the
-- library script itself.
local parentInstance: Instance = script.Parent :: Instance

type SubscriberState = {
	-- Per-player per-tree state. Nil until the player has received their
	-- first snapshot. After that, holds the last sent blackboard and node
	-- states so the next packet can be a delta against them.
	lastBlackboard: { [string]: any }?,
	lastNodeStates: { [number]: number }?,
}

type TreeEntry = {
	id: number,
	debugName: string,
	definitionPath: string,
	executionCount: number,
	definition: any,
	currentBlackboard: { [string]: any }?,
	currentNodeStates: { [number]: number }?,
	currentTick: number,
	currentPaused: boolean,
	subscribers: { [Player]: SubscriberState },
}

local nextTreeId = 0
local trees: { [number]: TreeEntry } = {}

local function collectTreeList(): { debugCodec.TreeListEntry }
	local out: { debugCodec.TreeListEntry } = {}
	for _, entry in trees do
		table.insert(out, {
			id = entry.id,
			executionCount = entry.executionCount,
			debugName = entry.debugName,
			definitionPath = entry.definitionPath,
		})
	end
	return out
end

local function frameFromEntry(entry: TreeEntry): debugCodec.SnapshotFrame
	return {
		treeId = entry.id,
		tick = entry.currentTick,
		paused = entry.currentPaused,
		nodeStates = entry.currentNodeStates or {},
		blackboard = entry.currentBlackboard or {},
	}
end

local DebugNetwork = {}

local function ensureRemotes()
	if remotes then
		return
	end
	assert(IS_SERVER, "Remote creation is server-only")

	-- Reuse any RemoteEvents that already exist (e.g. if the library was
	-- required a second time after an earlier session created them). Keeps
	-- us idempotent across script reloads.
	local treeList = parentInstance:FindFirstChild("DebugTreeList") :: RemoteEvent? or Instance.new("RemoteEvent")
	treeList.Name = "DebugTreeList"
	treeList.Parent = parentInstance

	local treeDefinition = parentInstance:FindFirstChild("DebugTreeDefinition") :: RemoteEvent?
		or Instance.new("RemoteEvent")
	treeDefinition.Name = "DebugTreeDefinition"
	treeDefinition.Parent = parentInstance

	local subscribe = parentInstance:FindFirstChild("DebugSubscribe") :: RemoteEvent? or Instance.new("RemoteEvent")
	subscribe.Name = "DebugSubscribe"
	subscribe.Parent = parentInstance

	local snapshot = parentInstance:FindFirstChild("DebugSnapshot") :: RemoteEvent? or Instance.new("RemoteEvent")
	snapshot.Name = "DebugSnapshot"
	snapshot.Parent = parentInstance

	remotes = {
		treeList = treeList,
		treeDefinition = treeDefinition,
		subscribe = subscribe,
		snapshot = snapshot,
	}

	treeList.OnServerEvent:Connect(function(player)
		treeList:FireClient(player, debugCodec.encodeTreeList(collectTreeList()))
	end)

	treeDefinition.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "buffer" then
			return
		end
		local treeId = debugCodec.decodeTreeDefinitionRequest(payload :: buffer)
		if treeId == nil then
			return
		end
		local entry = trees[treeId]
		if not entry then
			treeDefinition:FireClient(player, debugCodec.buildEmptyTreeDefinitionResponse())
			return
		end
		local defBuf = debugCodec.encodeTreeDefinition(entry.definition)
		treeDefinition:FireClient(player, debugCodec.buildTreeDefinitionResponse(treeId, defBuf))
	end)

	subscribe.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "buffer" then
			return
		end
		local request = debugCodec.decodeSubscribe(payload :: buffer)
		if request == nil then
			return
		end
		local entry = trees[request.treeId]
		if not entry then
			return
		end
		if request.subscribe then
			if entry.subscribers[player] == nil then
				entry.subscribers[player] = { lastBlackboard = nil, lastNodeStates = nil }
				-- Send initial full snapshot immediately if we have data.
				if entry.currentBlackboard ~= nil then
					local state = entry.subscribers[player]
					local buf = debugCodec.encodeFullSnapshot(frameFromEntry(entry))
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
function DebugNetwork.registerTree(debugName: string, definitionPath: string, definition: any): number
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
		definition = definition,
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

	if not remotes then
		return
	end
	local snapshotEvent = remotes.snapshot
	local frame = frameFromEntry(entry)
	for player, state in entry.subscribers do
		local buf: buffer
		if state.lastBlackboard == nil then
			buf = debugCodec.encodeFullSnapshot(frame)
		else
			buf = debugCodec.encodeDeltaSnapshot(frame, state.lastNodeStates :: any, state.lastBlackboard :: any)
		end
		snapshotEvent:FireClient(player, buf)
		state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
		state.lastNodeStates = table.clone(entry.currentNodeStates :: { [number]: number })
	end
end

-- Client helpers are re-exported from debugCodec so consumers don't need to
-- reach into the codec module directly.
DebugNetwork.encodeSubscribe = debugCodec.encodeSubscribe
DebugNetwork.encodeTreeDefinitionRequest = debugCodec.encodeTreeDefinitionRequest
DebugNetwork.decodeTreeList = debugCodec.decodeTreeList
DebugNetwork.decodeTreeDefinition = debugCodec.decodeTreeDefinition
DebugNetwork.decodeSnapshot = debugCodec.decodeSnapshot

export type TreeListEntry = debugCodec.TreeListEntry
export type DefinitionNode = debugCodec.DefinitionNode
export type TreeDefinitionPacket = debugCodec.TreeDefinitionPacket
export type SnapshotPacket = debugCodec.SnapshotPacket

-- Client helper: returns the four RemoteEvents once the server has created
-- them. Yields until all exist. Returns nil if any does not appear within
-- `timeout` seconds (when specified).
function DebugNetwork.waitForRemotes(timeout: number?): Remotes?
	local function waitFor(name: string): RemoteEvent?
		if timeout ~= nil then
			return parentInstance:WaitForChild(name, timeout) :: RemoteEvent?
		end
		return parentInstance:WaitForChild(name) :: RemoteEvent?
	end
	local treeList = waitFor("DebugTreeList")
	local treeDefinition = waitFor("DebugTreeDefinition")
	local subscribe = waitFor("DebugSubscribe")
	local snapshot = waitFor("DebugSnapshot")
	if treeList and treeDefinition and subscribe and snapshot then
		return {
			treeList = treeList,
			treeDefinition = treeDefinition,
			subscribe = subscribe,
			snapshot = snapshot,
		}
	end
	return nil
end

return DebugNetwork
