--!strict
--!native
--!optimize 2
-- Networked debugging for behavior trees.
--
-- On the server, when a tree is registered (by the wrapper whenever a tree is
-- created with debug enabled), five RemoteEvents are lazily created under the
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
	pause: RemoteEvent,
	snapshot: RemoteEvent,
	openRequest: RemoteEvent,
}

local remotes: Remotes? = nil

-- RemoteEvents are parented under the library script. Because this module
-- is loaded via `require("@self/debugNetwork")` from the library's init.lua,
-- `script` here is the debugNetwork ModuleScript and `script.Parent` is the
-- library script itself.
local parentInstance: Instance = script.Parent :: Instance

type SubscriberState = {
	-- Per-player per-tree state. Nil until the player has received their
	-- first snapshot. After that, holds the last sent blackboard so the next
	-- packet can preserve trace semantics while still diffing blackboard state.
	lastBlackboard: { [string]: any }?,
}

type TreeEntry = {
	id: number,
	debugName: string,
	definitionPath: string,
	executionCount: number,
	definition: any,
	currentBlackboard: { [string]: any }?,
	currentTraceNodeStates: { [number]: number }?,
	currentTraceTaskParams: { [number]: { [string]: any } }?,
	currentTick: number,
	currentPaused: boolean,
	setPaused: (paused: boolean) -> (),
	subscribers: { [Player]: SubscriberState },
}

local nextTreeId = 0
local trees: { [number]: TreeEntry } = {}

local function cloneTaskParamTrace(taskParams: { [number]: { [string]: any } }?): { [number]: { [string]: any } }
	local out: { [number]: { [string]: any } } = {}
	if taskParams == nil then
		return out
	end
	for nodeIndex, params in taskParams do
		out[nodeIndex] = table.clone(params)
	end
	return out
end

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
		nodeStates = entry.currentTraceNodeStates or {},
		taskParams = entry.currentTraceTaskParams or {},
		blackboard = entry.currentBlackboard or {},
	}
end

local function broadcastSnapshot(entry: TreeEntry)
	if not remotes or entry.currentBlackboard == nil then
		return
	end
	local snapshotEvent = remotes.snapshot
	local frame = frameFromEntry(entry)
	for player, state in entry.subscribers do
		local buf: buffer
		if state.lastBlackboard == nil then
			buf = debugCodec.encodeFullSnapshot(frame)
		else
			buf = debugCodec.encodeDeltaSnapshot(frame, state.lastBlackboard :: any)
		end
		snapshotEvent:FireClient(player, buf)
		state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
	end
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

	local pause = parentInstance:FindFirstChild("DebugTreePause") :: RemoteEvent? or Instance.new("RemoteEvent")
	pause.Name = "DebugTreePause"
	pause.Parent = parentInstance

	local snapshot = parentInstance:FindFirstChild("DebugSnapshot") :: RemoteEvent? or Instance.new("RemoteEvent")
	snapshot.Name = "DebugSnapshot"
	snapshot.Parent = parentInstance

	-- Server→client request for the plugin to focus a specific tree's debug
	-- widget. Fired by debugNetwork.requestOpenViewer.
	local openRequest = parentInstance:FindFirstChild("DebugOpenRequest") :: RemoteEvent?
		or Instance.new("RemoteEvent")
	openRequest.Name = "DebugOpenRequest"
	openRequest.Parent = parentInstance

	remotes = {
		treeList = treeList,
		treeDefinition = treeDefinition,
		subscribe = subscribe,
		pause = pause,
		snapshot = snapshot,
		openRequest = openRequest,
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
				entry.subscribers[player] = { lastBlackboard = nil }
				-- Send initial full snapshot immediately if we have data.
				if entry.currentBlackboard ~= nil then
					local state = entry.subscribers[player]
					local buf = debugCodec.encodeFullSnapshot(frameFromEntry(entry))
					snapshot:FireClient(player, buf)
					state.lastBlackboard = table.clone(entry.currentBlackboard :: { [string]: any })
				end
			end
		else
			entry.subscribers[player] = nil
		end
	end)

	pause.OnServerEvent:Connect(function(_player, payload)
		if typeof(payload) ~= "buffer" then
			return
		end
		local request = debugCodec.decodePauseRequest(payload :: buffer)
		if request == nil then
			return
		end
		local entry = trees[request.treeId]
		if not entry then
			return
		end
		entry.setPaused(request.paused)
		entry.currentPaused = request.paused
		broadcastSnapshot(entry)
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
function DebugNetwork.registerTree(
	debugName: string,
	definitionPath: string,
	definition: any,
	setPaused: (paused: boolean) -> ()
): number
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
		currentTraceNodeStates = nil,
		currentTraceTaskParams = nil,
		currentTick = 0,
		currentPaused = false,
		setPaused = setPaused,
		subscribers = {},
	}
	return id
end

-- Called by the wrapper after each tree:update(). `nodeStates` is the final
-- visited-node trace for the last completed update, `taskParams` carries the
-- resolved params for the task nodes visited in that same update, and
-- `blackboard` is the raw table (will be serialized here).
function DebugNetwork.onTreeUpdated(
	treeId: number,
	tick: number,
	paused: boolean,
	nodeStates: { [number]: number },
	taskParams: { [number]: { [string]: any } },
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
	entry.currentTraceNodeStates = table.clone(nodeStates)
	entry.currentTraceTaskParams = cloneTaskParamTrace(taskParams)
	entry.currentBlackboard = serializeBlackboard(blackboard)
	broadcastSnapshot(entry)
end

-- Server-only. Fires DebugOpenRequest to the given player only. That player's
-- Studio plugin filters and acts on the request; other Team Test sessions are
-- unaffected. No-op when treeId is unknown, when remotes haven't been built
-- yet (no debug-enabled tree has registered, so no plugin can be listening
-- anyway), or when the player argument is invalid.
function DebugNetwork.requestOpenViewer(treeId: number, player: Player)
	if not IS_SERVER or treeId == 0 or not remotes then
		return
	end
	if trees[treeId] == nil then
		return
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	remotes.openRequest:FireClient(player, debugCodec.encodeOpenRequest(treeId))
end

-- Client helpers are re-exported from debugCodec so consumers don't need to
-- reach into the codec module directly.
DebugNetwork.encodeSubscribe = debugCodec.encodeSubscribe
DebugNetwork.encodePauseRequest = debugCodec.encodePauseRequest
DebugNetwork.encodeTreeDefinitionRequest = debugCodec.encodeTreeDefinitionRequest
DebugNetwork.encodeOpenRequest = debugCodec.encodeOpenRequest
DebugNetwork.decodeOpenRequest = debugCodec.decodeOpenRequest
DebugNetwork.decodeTreeList = debugCodec.decodeTreeList
DebugNetwork.decodeTreeDefinition = debugCodec.decodeTreeDefinition
DebugNetwork.decodeSnapshot = debugCodec.decodeSnapshot

export type TreeListEntry = debugCodec.TreeListEntry
export type DefinitionNode = debugCodec.DefinitionNode
export type TreeDefinitionPacket = debugCodec.TreeDefinitionPacket
export type SnapshotPacket = debugCodec.SnapshotPacket

-- Client helper: returns the six RemoteEvents once the server has created
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
	local pause = waitFor("DebugTreePause")
	local snapshot = waitFor("DebugSnapshot")
	local openRequest = waitFor("DebugOpenRequest")
	if treeList and treeDefinition and subscribe and pause and snapshot and openRequest then
		return {
			treeList = treeList,
			treeDefinition = treeDefinition,
			subscribe = subscribe,
			pause = pause,
			snapshot = snapshot,
			openRequest = openRequest,
		}
	end
	return nil
end

return DebugNetwork
