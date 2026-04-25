# BTree

A behavior tree library for Roblox, written in Luau. 

## Features

- Fully tested
- Flat array-based runtime — no nested table allocations during ticks
- Full Luau strict-mode types
- Binding-based task params via `BT.bind(...)` and `BT.calc(...)`
- Subtree inlining — subtrees are merged into the parent flat array at build time
- Pause/resume support
- Debug snapshots with per-node status, compatible with the BTree Studio plugin

## Installation

Install via [pesde](https://pesde.dev):

```
pesde add thefnox/btree
```

Then require it in your code:

```lua
local BT = require("@Packages/btree")
```


## Usage

### Defining a tree

Trees are built from a nested definition using builder functions. The definition is a plain Luau table — it can be stored in a `ModuleScript` and required like any other module.

```lua
-- ServerStorage/AI/PatrolTree.lua
local BT = require(game.ReplicatedStorage.BehaviorTree)
local MoveToPoint = require(script.Parent.Tasks.MoveToPoint)
local IsAlerted   = require(script.Parent.Tasks.IsAlerted)
local ChaseTarget = require(script.Parent.Tasks.ChaseTarget)

return BT.selector({
    BT.sequence({
        BT.condition(function(bb) return bb.alerted end),
        BT.task(ChaseTarget),
    }),
    BT.task(MoveToPoint, {
        speed = 8,
        targetPosition = BT.bind("targetPosition"),
    }),
})
```

### Creating and running a tree

```lua
local BT         = require(game.ReplicatedStorage.BehaviorTree)
local definition = require(game.ServerStorage.AI.PatrolTree)

local blackboard = { alerted = false, target = nil }
local tree = BT.new(definition, blackboard)

-- In a RunService loop or heartbeat:
RunService.Heartbeat:Connect(function()
    tree:update()
end)
```

`update()` ticks the tree once and returns the root status:

```lua
local status = tree:update()
if status == BT.SUCCESS then ... end
if status == BT.FAILURE then ... end
if status == BT.RUNNING  then ... end
```

### Writing a task module

A task is a `ModuleScript` that returns a `BTreeTask` table. All callbacks are optional.

```lua
-- Tasks/MoveToPoint.lua
local BT = require(game.ReplicatedStorage.BehaviorTree)

return {
    params = {
        speed = "number",
        targetPosition = "Vector3",
    },

    onStart = function(bb, params)
        bb.agent.WalkSpeed = params.speed
        bb.agent:MoveTo(params.targetPosition)
    end,

    run = function(bb, params): BT.Status?
        if bb.agent.MoveToFinished:Wait() then
            return BT.SUCCESS
        end
        return BT.FAILURE
    end,

    onExit = function(bb, params)
        bb.agent:MoveTo(bb.agent.HumanoidRootPart.Position) -- cancel
    end,
} :: BT.Task
```

| Callback | When it fires |
|---|---|
| `onEnter` | First tick this node is reached after not being reached last tick |
| `onExit` | When a previously reached task is no longer active, including `tree:stop()` |
| `onStart` | When a fresh execution of the task begins |
| `onEnd` | When the task exits with `SUCCESS` or `FAILURE` |
| `run` | Every tick while active — return `RUNNING` to stay active, `FAILURE` to fail, or nothing / `SUCCESS` to succeed |

### Subtrees

Use `BT.subtree` to compose a definition from another `ModuleScript`. Subtree nodes are inlined into the parent's flat array at build time — there is no runtime indirection.

```lua
local PatrolLoop = require(script.Parent.PatrolLoop)

return BT.sequence({
    BT.subtree(PatrolLoop),
    BT.task(ReturnToBase),
})
```

## Node reference

### Composites

| Function | Behaviour |
|---|---|
| `BT.sequence(children, meta?)` | Ticks children left to right. Fails on first `FAILURE`. Succeeds when all succeed. |
| `BT.selector(children, meta?)` | Ticks children left to right. Succeeds on first `SUCCESS`. Fails when all fail. |
| `BT.parallel(children, successPolicy?, failurePolicy?, meta?)` | Ticks all children every frame. Policies are `"requireAll"` (default) or `"requireOne"`. |
| `BT.randomSelector(children, weights?, meta?)` | Picks one child at random each activation. `weights` must be the same length as `children` if provided. |

### Decorators

| Function | Behaviour |
|---|---|
| `BT.invert(child, meta?)` | Flips `SUCCESS` ↔ `FAILURE`. `RUNNING` passes through. |
| `BT.alwaysSucceed(child?, meta?)` | Returns `SUCCESS` regardless of child result. |
| `BT.alwaysFail(child?, meta?)` | Returns `FAILURE` regardless of child result. |
| `BT.repeatNode(child, times, meta?)` | Repeats child on `SUCCESS`. Pass `-1` for infinite. |
| `BT.retryNode(child, times, meta?)` | Retries child on `FAILURE`. Pass `-1` for infinite. |

### Leaves

| Function | Behaviour |
|---|---|
| `BT.task(module, params?, meta?)` | Runs a task module. |
| `BT.condition(check, meta?)` | Calls `check(blackboard)` — returns `SUCCESS` if true, `FAILURE` if false. |
| `BT.subtree(module, meta?)` | Inlines another definition tree. |

### Param helpers

| Function | Behaviour |
|---|---|
| `BT.bind(path)` | Resolves a dot-separated blackboard path once when the task activation begins. Numeric segments index arrays/tables by number. |
| `BT.calc(resolver)` | Calls `resolver(blackboard)` once when the task activation begins and stores the returned value in the resolved params table. |

### Tree API

```lua
tree:update()           -- tick once, returns (Status, DebugSnapshot?)
tree:reset()            -- rewind runtime state to the root without firing interruption callbacks
tree:stop()             -- fire onExit for active tasks, rewind, and resume so the next update starts at the root
tree:pause()            -- suspend ticking
tree:resume()           -- resume ticking
tree:isPaused()         -- returns boolean
```

## Debug mode

Pass a third argument to `BT.new` to enable debug mode. This makes `update()` return a `DebugSnapshot` as a second value and fires a `BTDebugSnapshot` BindableEvent that the BTree Studio plugin listens to.

```lua
-- Pass true to enable (definition path defaults to "")
local tree = BT.new(definition, blackboard, true)

-- Pass the script path so the plugin can locate the definition source
local tree = BT.new(definition, blackboard, script:GetFullName())
```

The `DebugSnapshot` contains:

```lua
type DebugSnapshot = {
    tick: number,               -- monotonically increasing tick counter
    paused: boolean,
    nodeStates: { [number]: Status }, -- keyed by 1-based DFS index
    taskParams: { [number]: { [string]: any } }, -- resolved params for task nodes visited in the last completed update
}
```

Debug mode adds no overhead when disabled (`false` / `nil`).

## Task params

Task params are resolved into a fresh table when a task activation begins, before any of that task's hooks run. The same resolved table is then reused for `onEnter`, `onStart`, `run`, `onEnd`, and the eventual `onExit`.

Top-level param entries may be:

- literals, which are copied into the resolved params table unchanged
- `BT.bind("path.to.value")`, which nil-safely traverses the blackboard using dot-separated path segments
- `BT.calc(function(bb) ... end)`, which computes a value from the current blackboard

Nested tables are treated as literals and are not recursively resolved. Bare top-level function values are not allowed; wrap computed values with `BT.calc(...)` instead.

```lua
BT.task(MoveToPoint, {
    speed = 14,
    targetPosition = BT.bind("targetPosition"),
    currentOrderParams = BT.bind("squad.members.1.order.params"),
    timeout = BT.calc(function(bb)
        return if bb.alerted then 1 else 3
    end),
})
```

Legacy task-module `params` schemas are still accepted for compatibility, but they are no longer validated at runtime.

If a task module declares `params = { key = "type" }`, that schema is still sent through the tree-definition debug payload so remote tooling can know the expected param keys and types. When that task executes, the snapshot payload for that update also carries the resolved param values keyed by the task node's DFS index.

## NodeMeta

Every builder function accepts an optional `meta` table as its last argument. This is used by the visual editor and has no effect at runtime.

```lua
type NodeMeta = {
    label: string?,
    size: Vector2?,
    position: Vector2?,
}
```


### Remote debugging

In addition to the in-process `BTDebugSnapshot` BindableEvent, the server exposes five buffer-based RemoteEvents so clients can observe any tree created with debugging enabled. The RemoteEvents are lazily parented under the library script the first time a debug-enabled tree is registered, so non-debug builds carry no remote-event overhead.

| RemoteEvent | Direction | Payload |
|---|---|---|
| `DebugTreeList` | Client ↔ Server | Client fires an empty buffer; server replies with `u16 count` followed by `{u32 id, u32 executionCount, len-prefixed debugName, len-prefixed definitionPath}` per tree. |
| `DebugTreeDefinition` | Client ↔ Server | Client fires `u32 treeId`; server replies with `u32 treeId` (0 if unknown, and no further payload) followed by the encoded tree-definition packet (see below). Tree definitions don't replicate through normal Roblox replication, so this is the only way for a client to learn the tree's structure. |
| `DebugSubscribe` | Client → Server | Buffer: `u32 treeId, u8 subscribe` (1 to start, 0 to stop). |
| `DebugTreePause` | Client → Server | Buffer: `u32 treeId, u8 paused` (1 to pause the tree, 0 to resume it). |
| `DebugSnapshot` | Server → Client | Buffer: `u8 kind` (0=full, 1=delta), `u32 treeId`, `u32 tick`, `u8 paused`, node-state entries, task-param trace entries, then blackboard entries. |

The first snapshot a subscriber receives is a full packet containing the last completed update trace for the tree and the complete serialized blackboard. Each subsequent packet sends the full visited-node trace for that update again, plus the resolved task params for the task nodes that executed in that update, while only the blackboard portion is delta-compressed (`blackboardSet` / `blackboardRemoved`).

`nodeStates` contains the final status of every node that was visited during the last completed `tree:update()`. Nodes that were not visited in that update are omitted entirely.

`taskParams` is keyed by task-node DFS index and contains the resolved params observed by that task in the last completed update. Numbers are serialized as f64 values. `Vector3` and `Vector2` params are serialized as typed binary packets (3× or 2× f32 components) so clients reconstruct the native types directly. Native Luau `vector` values are serialized the same way. Every other param value is serialized as a string. Nil task params are sent as the string `"nil"`.

Remote pause control is available through a `DebugTreePause` RemoteEvent. Its payload is `u32 treeId, u8 paused`, where `1` pauses the tree and `0` resumes it. The server applies the new pause state immediately by calling `tree:pause()` / `tree:resume()`, then rebroadcasts a snapshot with the updated `paused` flag.

Tree-definition packets include task param schemas, not per-update task param values. For task nodes, the definition carries the optional task name plus any declared `module.params` entries as `{ key -> expected type }`.

**Tree-definition packet format.** To avoid hardcoding a shared type enum on both server and client, every tree-definition packet starts with a self-describing type enum. The layout is:

```
u32 treeId
u8  typeEnumCount
repeat typeEnumCount times: len-prefixed string   -- e.g. "task", "sequence", ...
u32 nodeCount
repeat nodeCount times:
    u8  typeEnumIndex                             -- 0-based into the header above
    u16 childCount                                -- composite children (DFS indices)
    repeat childCount times: u32 childIndex
    u32 singleChild                               -- decorator/subtree child, 0 if none
    u8  hasLabel; if 1: len-prefixed string
    u8  hasSize;  if 1: f32 x, f32 y
    u8  hasPosition; if 1: f32 x, f32 y
    -- type-specific payload:
    --   task            : hasName (u8), optional len-prefixed name,
    --                     u32 paramTypeCount, then repeated
    --                     { len-prefixed key, len-prefixed typeName }
    --   parallel        : len-prefixed successPolicy, len-prefixed failurePolicy
    --   repeat / retry  : i32 times (-1 = infinite)
    --   randomSelector  : hasWeights (u8), optional u32 count + f32 weights
    --   other types     : no extra payload
```

DFS node indices match the native library's `buildFlatTree` ordering, so they line up 1:1 with the `nodeIndex` keys used in `DebugSnapshot` packets.

Decoder helpers are available on the `debugNetwork` submodule:

```lua
local debugNetwork = require(path.to.BehaviorTree.debugNetwork)

-- Client-side
local remotes = debugNetwork.waitForRemotes()

-- List all active debug trees.
remotes.treeList.OnClientEvent:Connect(function(buf)
    for _, entry in debugNetwork.decodeTreeList(buf) do
        print(entry.id, entry.debugName, entry.executionCount)
    end
end)
remotes.treeList:FireServer()

-- Fetch the static structure of a tree so the client can render node graphs.
remotes.treeDefinition.OnClientEvent:Connect(function(buf)
    local packet = debugNetwork.decodeTreeDefinition(buf)
    for i, node in packet.nodes do
        -- node.type, node.children, node.singleChild, node.label,
        -- node.taskName, node.taskParamTypes, node.successPolicy, etc.
    end
end)
remotes.treeDefinition:FireServer(debugNetwork.encodeTreeDefinitionRequest(treeId))

-- Stream snapshot updates.
remotes.snapshot.OnClientEvent:Connect(function(buf)
    local packet = debugNetwork.decodeSnapshot(buf)
    -- packet.kind == "full" | "delta"
    -- packet.nodeStates is the full visited-node trace for that update
    -- packet.taskParams contains resolved params for task nodes visited in that update
    -- packet.blackboardSet / packet.blackboardRemoved are still deltas
end)
remotes.subscribe:FireServer(debugNetwork.encodeSubscribe(treeId, true))

-- Pause or resume the tree remotely.
remotes.pause:FireServer(debugNetwork.encodePauseRequest(treeId, true)) -- pause
remotes.pause:FireServer(debugNetwork.encodePauseRequest(treeId, false)) -- resume
```

## License

MIT
