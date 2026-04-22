-- Thin Roblox-specific wrapper around the native Luau behaviorTree library.
-- Handles BindableEvent communication so the plugin can receive debug snapshots
-- without the native library depending on any Roblox APIs.
--
-- When a tree is created with debug enabled, each tree:update() call passes a
-- debugCallback to the native update function. The native library calls this
-- callback before and after each node is ticked with (nodeIndex, status).
-- The wrapper accumulates these per-node updates into a single snapshot
-- (keyed by node index) and fires the BTDebugSnapshot BindableEvent once per
-- frame if the snapshot contains at least 2 entries.
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

local nativeBT = require("@self/behaviorTree")
local serializeBlackboard = require("@self/serializeBlackboard")
local debugNetwork = require("@self/debugNetwork")

-- Re-export all types from the native library (Luau does not automatically redirect them)
export type Status = nativeBT.Status
export type Blackboard = nativeBT.Blackboard
export type NodeMeta = nativeBT.NodeMeta
export type ParamTypes = nativeBT.ParamTypes
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
export type Library = nativeBT.Library

local event = script:FindFirstChild("BTDebugSnapshot")

local Wrapper = {}

-- Forward all constants and builder functions from the native library
for key, value in nativeBT do
    Wrapper[key] = value
end


-- Override new to intercept update() and fire the BindableEvent when debug is enabled.
function Wrapper.new(definition, blackboard, debug)
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
        local treeId = debugNetwork.registerTree(debugName, definitionPath, definition, function(paused)
            if paused then
                tree:pause()
            else
                tree:resume()
            end
        end)

        local nativeUpdate = tree.update
        local lastRemoteNodeStates = {}
        tree.update = function(self)
            local nodeStates = {}
            local function onNodeUpdate(nodeIndex, status)
                nodeStates[nodeIndex] = status
            end
            local status, nativeSnapshot = nativeUpdate(self, onNodeUpdate)
            local isPaused = nativeSnapshot ~= nil and nativeSnapshot.paused == true
            if next(nodeStates) ~= nil then
                -- Preserve the terminal status of every node visited during the
                -- last completed update. While paused there is no new trace, so
                -- the remote debugger should continue seeing the prior update's
                -- visited-node map instead of being overwritten by an empty one.
                lastRemoteNodeStates = table.clone(nodeStates)
            end
            if event and (next(nodeStates) or isPaused) then
                event:Fire(definitionPath, debugName, {
                    tick = if nativeSnapshot then nativeSnapshot.tick else nil,
                    paused = isPaused,
                    nodeStates = nodeStates,
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
                    blackboard
                )
            end
            return status, nativeSnapshot
        end
    end

    return tree
end

return Wrapper :: nativeBT.Library
