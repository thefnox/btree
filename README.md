# BTree

A behavior tree library for Roblox, written in Luau. 

## Features

- Fully tested
- Flat array-based runtime — no nested table allocations during ticks
- Full Luau strict-mode types
- Built-in parameter validation for task modules
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
    BT.task(MoveToPoint, { speed = 8 }),
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
    },

    onStart = function(bb, params)
        bb.agent:MoveTo(bb.targetPosition)
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
}
```

Debug mode adds no overhead when disabled (`false` / `nil`).

## Parameter validation

When a task module declares a `params` schema, `BT.task()` validates the values passed at definition time. Supported type strings:

Omitted or `nil` task params are normalized to an empty table before being stored on the task definition and passed to task hooks.

- Lua primitives: `"number"`, `"string"`, `"boolean"`
- Roblox types: `"Vector2"`, `"Vector3"`, any Roblox Instance class name

```lua
BT.task(MyTask, { speed = 14, target = workspace.Boss })
```

## NodeMeta

Every builder function accepts an optional `meta` table as its last argument. This is used by the visual editor and has no effect at runtime.

```lua
type NodeMeta = {
    label: string?,
    size: Vector2?,
    position: Vector2?,
}
```
## License

MIT
