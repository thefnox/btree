-- Thin Roblox-specific wrapper around the native Luau behaviorTree library.
-- Handles BindableEvent communication so the plugin can receive debug snapshots
-- without the native library depending on any Roblox APIs.
--
-- When a tree is created with debug enabled, each tree:update() call passes a
-- debugCallback to the native update function. The native library calls this
-- callback before and after each node is ticked with (nodeIndex, status).
-- The wrapper accumulates these per-node updates into the last completed
-- visited-node trace for that frame and fires the BTDebugSnapshot
-- BindableEvent. The payload also includes resolved task params for the task
-- nodes that executed in that last completed update.
--
-- The `debug` parameter to BT.new can be:
--   false / nil  — no debugging
--   true         — debug mode enabled, definition path defaults to ""
--   string       — debug mode enabled, string is used as the definition path
--
-- Usage:
--   local BT = require(game.ReplicatedStorage.BehaviorTree)
--   local definition = require(game.ServerStorage.AI.PatrolTree)
--   local tree = BT.new(definition, blackboard, script:GetFullName())
--   -- or simply:
--   local tree = BT.new(definition, blackboard, true)

local CollectionService = game:GetService("CollectionService")

local nativeBT = require("@self/behaviorTree")
local serializeBlackboard = require("@self/serializeBlackboard")
local debugNetwork = require("@self/debugNetwork")

-- Re-export all types from the native library (Luau does not automatically redirect them)
export type Status = nativeBT.Status
export type Blackboard = nativeBT.Blackboard
export type NodeMeta = nativeBT.NodeMeta
export type ParamTypes = nativeBT.ParamTypes
export type ParamPathSegment = nativeBT.ParamPathSegment
export type ParamBinding = nativeBT.ParamBinding
export type ParamCalculation = nativeBT.ParamCalculation
export type Task = nativeBT.BTreeTask
export type TaskDef = nativeBT.TaskDef
export type ConditionDef = nativeBT.ConditionDef
export type SequenceDef = nativeBT.SequenceDef
export type SelectorDef = nativeBT.SelectorDef
export type ParallelDef = nativeBT.ParallelDef
export type InvertDef = nativeBT.InvertDef
export type RepeatDef = nativeBT.RepeatDef
export type RetryDef = nativeBT.RetryDef
export type AlwaysSucceedDef = nativeBT.AlwaysSucceedDef
export type AlwaysFailDef = nativeBT.AlwaysFailDef
export type SubtreeDef = nativeBT.SubtreeDef
export type RandomSelectorDef = nativeBT.RandomSelectorDef
export type NodeDefinition = nativeBT.NodeDefinition
export type DebugSnapshot = nativeBT.DebugSnapshot
export type DebugCallback = nativeBT.DebugCallback
export type Tree = nativeBT.Tree
export type Library = nativeBT.Library & {
	new: (
		definition: NodeDefinition,
		blackboard: Blackboard,
		debug: (boolean | string)?,
		debugTarget: Instance?
	) -> Tree,
	openDebugViewer: (tree: Tree, player: Player) -> (),
}

local event = script:FindFirstChild("BTDebugSnapshot")

local DEBUG_TARGET_TAG = "BehaviorTreeDebugTarget"
local DEBUG_TREE_ID_ATTRIBUTE = "BehaviorTreeDebugTreeId"

local Wrapper = {}

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

-- Forward all constants and builder functions from the native library
for key, value in nativeBT do
	Wrapper[key] = value
end

-- Override new to intercept update() and fire the BindableEvent when debug is enabled.
-- A debug target is tagged with the registered tree id for instance-based discovery.
function Wrapper.new(
	definition: NodeDefinition,
	blackboard: Blackboard,
	debug: (boolean | string)?,
	debugTarget: Instance?
): Tree
	local definitionPath = ""
	if type(debug) == "string" then
		definitionPath = debug
	end

	local tree = nativeBT.new(definition, blackboard, debug ~= nil and debug ~= false)

	if debug then
		local debugName = if type(blackboard) == "table" and blackboard._debugName
			then tostring(blackboard._debugName)
			else tostring(blackboard)

		-- Register with the network-debug registry so clients can discover and
		-- subscribe to this tree. Server-only; returns 0 on the client.
		-- The definition is stored so clients can request its static structure
		-- over the DebugTreeDefinition RemoteEvent.
		local treeId: number = debugNetwork.registerTree(debugName, definitionPath, definition, tree._debugSetPaused)
		-- Surface the registered id so BT.openDebugViewer can target this
		-- tree. 0 means debug disabled / called on client.
		tree._debugId = treeId
		local target: Instance? = if treeId ~= 0 then debugTarget else nil
		if target then
			CollectionService:AddTag(target, DEBUG_TARGET_TAG)
			target:SetAttribute(DEBUG_TREE_ID_ATTRIBUTE, treeId)
		end

		local nativeUpdate = tree.update
		local debugDisposed = false
		local lastRemoteNodeStates = {}
		local lastRemoteTaskParams = {}
		tree.update = function(self)
			if debugDisposed then
				return nativeUpdate(self)
			end
			local nodeStates = {}
			local function onNodeUpdate(nodeIndex, status)
				nodeStates[nodeIndex] = status
			end
			local status, nativeSnapshot = nativeUpdate(self, onNodeUpdate)
			local isPaused = nativeSnapshot ~= nil and nativeSnapshot.paused == true
			if nativeSnapshot ~= nil and not isPaused then
				-- Preserve the terminal status of every node visited during the
				-- last completed update. While paused there is no new trace, so
				-- the remote debugger should continue seeing the prior update's
				-- visited-node map instead of being overwritten by an empty one.
				lastRemoteNodeStates = table.clone(nodeStates)
			end
			if nativeSnapshot ~= nil then
				lastRemoteTaskParams = cloneTaskParamTrace(nativeSnapshot.taskParams)
			end
			local emittedNodeStates = if isPaused then lastRemoteNodeStates else nodeStates
			local emittedTaskParams = lastRemoteTaskParams
			if not isPaused then
				emittedTaskParams = if nativeSnapshot then nativeSnapshot.taskParams else {}
			end
			if event and (next(nodeStates) or isPaused) then
				event:Fire(definitionPath, debugName, {
					tick = if nativeSnapshot then nativeSnapshot.tick else nil,
					paused = isPaused,
					nodeStates = emittedNodeStates,
					taskParams = emittedTaskParams,
					blackboard = serializeBlackboard(blackboard),
				})
			end
			-- Forward the visited-node execution trace to the remote debugger.
			-- Unlike the native snapshot, this preserves the final status of
			-- every node actually visited during the last completed update.
			if treeId ~= 0 and nativeSnapshot ~= nil then
				debugNetwork.onTreeUpdated(
					treeId,
					nativeSnapshot.tick,
					isPaused,
					lastRemoteNodeStates,
					lastRemoteTaskParams,
					blackboard
				)
			end
			return status, nativeSnapshot
		end
		local nativeDestroy = tree.destroy
		tree.destroy = function(self)
			-- Fire pending onExit/onEnd for tasks still active in the current
			-- execution. Idempotent, so calling destroy twice is safe.
			nativeDestroy(self)
			if debugDisposed then
				return
			end
			debugDisposed = true
			if treeId ~= 0 then
				debugNetwork.unregisterTree(treeId)
				if target and target:GetAttribute(DEBUG_TREE_ID_ATTRIBUTE) == treeId then
					CollectionService:RemoveTag(target, DEBUG_TARGET_TAG)
					target:SetAttribute(DEBUG_TREE_ID_ATTRIBUTE, nil)
				end
				treeId = 0
				self._debugId = 0
			end
			target = nil
		end
	end

	return tree
end

-- Request the Studio plugin running with `player` to focus this tree's debug
-- widget. Server-only; targets exactly one Studio session. The tree must have
-- been created with debug enabled.
function Wrapper.openDebugViewer(tree: Tree, player: Player)
	local id: number = (tree :: any)._debugId or 0
	if id == 0 then
		warn(
			"[BTree] openDebugViewer: tree has no debug id "
				.. "(debug must be enabled when calling BT.new, and the call "
				.. "must run on the server)"
		)
		return
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warn(
			"[BTree] openDebugViewer: player parameter is required and "
				.. "must be a Player instance (got "
				.. typeof(player)
				.. ")"
		)
		return
	end
	debugNetwork.requestOpenViewer(id, player)
end

return Wrapper :: Library
