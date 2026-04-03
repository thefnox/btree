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

-- Produces a BindableEvent-safe copy of the blackboard.
-- BindableEvent silently drops Instance values inside table arguments, so we
-- replace them with a human-readable "ClassName Name" string. Functions and
-- threads are skipped entirely. Everything else (primitives, Vector3, CFrame,
-- Color3, etc.) is kept as-is since BindableEvent supports those types.
-- The internal _debugName key is excluded from the output.
local function serializeBlackboard(bb: any): { [string]: any }
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
        if typeof(v) == "Instance" then
            local inst = v :: Instance
            result[key] = inst.ClassName .. " " .. inst.Name
        else
            result[key] = v
        end
    end
    return result
end

-- Override new to intercept update() and fire the BindableEvent when debug is enabled.
function Wrapper.new(definition, blackboard, debug)
    local definitionPath = ""
    if type(debug) == "string" then
        definitionPath = debug
    end

    local tree = nativeBT.new(definition, blackboard, debug ~= nil and debug ~= false)

    if debug and event then
        local debugName = if type(blackboard) == "table" and blackboard._debugName
            then tostring(blackboard._debugName)
            else tostring(blackboard)

        local nativeUpdate = tree.update
        tree.update = function(self)
            local nodeStates = {}
            local function onNodeUpdate(nodeIndex, status)
                nodeStates[nodeIndex] = status
            end
            local status, nativeSnapshot = nativeUpdate(self, onNodeUpdate)
            local isPaused = nativeSnapshot ~= nil and nativeSnapshot.paused == true
            if next(nodeStates) or isPaused then
                event:Fire(definitionPath, debugName, {
                    tick = if nativeSnapshot then nativeSnapshot.tick else nil,
                    paused = isPaused,
                    nodeStates = nodeStates,
                    blackboard = serializeBlackboard(blackboard),
                })
            end
            return status, nativeSnapshot
        end
    end

    return tree
end

return Wrapper :: nativeBT.Library
