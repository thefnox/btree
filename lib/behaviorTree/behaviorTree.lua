--!native
--!optimize 2
--!strict
-- Behavior tree library.
-- Trees are constructed from a declarative `NodeDefinition` paired with a `Blackboard` table
-- that holds shared state accessible to all nodes. Task leaf nodes are module scripts passed via
-- string requires.
--
-- Runtime state is stored in two flat arrays held by the tree:
--   nodes: { FlatNode }    -- all nodes indexed by their position
--   childrenData: { number } -- all child indices packed contiguously; each composite node
--                              references its slice via firstChild + childCount
--
-- Usage:
--   local BT = require("@Common/shared/utils/behaviorTree")
--
--   local tree = BT.new(
--       BT.sequence({
--           BT.task(require("@Game/ai/tasks/MoveToTarget"), { speed = 16 }, { label = "Move" }),
--           BT.selector({
--               BT.condition(function(bb) return bb.target ~= nil end, { label = "HasTarget" }),
--               BT.task(require("@Game/ai/tasks/Idle")),
--           }),
--       }),
--       blackboard
--   )
--
--   -- Each frame:
--   local status = tree:update()
--   if status == BT.SUCCESS then ... end
--
--   -- Debug snapshots (opt-in via third parameter):
--   local tree = BT.new(definition, blackboard, true)
--   local status, snapshot = tree:update()
--   -- snapshot = {
--   --     tick,
--   --     paused,
--   --     nodeStates: {[dfsIndex]: Status},
--   --     taskParams: {[taskNodeIndex]: {[paramName]: resolvedValue}},
--   -- }
--
--   -- Per-node debug callback (called before and after each node is ticked):
--   local tree = BT.new(definition, blackboard, true)
--   local status, snapshot = tree:update(function(nodeIndex, nodeStatus)
--       -- nodeIndex: 1-based DFS index; nodeStatus: RUNNING before, result after
--   end)

-- Status constants
local SUCCESS: number = 0
local FAILURE: number = 1
local RUNNING: number = 2

export type Status = number
export type Blackboard = { [any]: any }
export type NodeMeta = { label: string?, size: Vector2?, position: Vector2? }

-- Legacy compatibility surface for task param schemas. The runtime no longer
-- validates these values, but existing task modules may still expose them.
export type ParamTypes = { [string]: string }
export type ParamPathSegment = string | number
export type ParamBinding = {
	__btParamKind: "bind",
	path: string,
	segments: { ParamPathSegment },
}
export type ParamCalculation = {
	__btParamKind: "calc",
	resolver: (blackboard: Blackboard) -> any,
}

-- A task is a module script that returns a value of this type.
export type BTreeTask = {
	-- Optional legacy schema kept for compatibility. It is no longer enforced.
	params: ParamTypes?,
	-- Fires the first time a task is reached in a tick after not being reached in the previous tick.
	-- Does not re-fire if the task continues to be reached every tick.
	onEnter: ((blackboard: Blackboard, params: any) -> ())?,
	-- Fires when a task that was reached last tick is not reached in the current tick.
	onExit: ((blackboard: Blackboard, params: any) -> ())?,
	-- Called once when the task starts a fresh execution. Not called when resuming after RUNNING.
	onStart: ((blackboard: Blackboard, params: any) -> ())?,
	-- Called once when the task exits with SUCCESS or FAILURE (not called when returning RUNNING).
	onEnd: ((blackboard: Blackboard, params: any) -> ())?,
	-- Main task body.
	-- Return BT.FAILURE to fail, or return nothing / BT.SUCCESS to succeed.
	run: ((blackboard: Blackboard, params: any) -> Status?)?,
	-- Optional name
	name: string?,
}

type TaskModule = {
	params: { [string]: string }?,
	onEnter: ((blackboard: Blackboard, params: any) -> ())?,
	onExit: ((blackboard: Blackboard, params: any) -> ())?,
	-- Called once when the task starts a fresh execution. Not called when resuming after RUNNING.
	onStart: ((blackboard: Blackboard, params: any) -> ())?,
	-- Called once when the task exits with SUCCESS or FAILURE (not called when returning RUNNING).
	onEnd: ((blackboard: Blackboard, params: any) -> ())?,
	-- Main task body.
	-- Return BT.FAILURE to fail, or return nothing / BT.SUCCESS to succeed.
	run: (blackboard: Blackboard, params: any) -> Status?,
}

-- Declarative node definition types. Build trees using the BT.sequence(), BT.task(), etc. helpers.

type BaseDefinition = { meta: NodeMeta? }

export type TaskDef = BaseDefinition & { _type: "task", module: TaskModule, params: any }
export type ConditionDef = BaseDefinition & { _type: "condition", check: (blackboard: Blackboard) -> boolean }
export type SequenceDef = BaseDefinition & { _type: "sequence", children: { NodeDefinition } }
export type SelectorDef = BaseDefinition & { _type: "selector", children: { NodeDefinition } }
export type ParallelDef = BaseDefinition & {
	_type: "parallel",
	successPolicy: "requireAll" | "requireOne",
	failurePolicy: "requireAll" | "requireOne",
	children: { NodeDefinition },
}
export type InvertDef = BaseDefinition & { _type: "invert", child: NodeDefinition }
export type RepeatDef = BaseDefinition & { _type: "repeat", times: number, child: NodeDefinition }
export type RetryDef = BaseDefinition & { _type: "retry", times: number, child: NodeDefinition }
export type AlwaysSucceedDef = BaseDefinition & { _type: "alwaysSucceed", child: NodeDefinition? }
export type AlwaysFailDef = BaseDefinition & { _type: "alwaysFail", child: NodeDefinition? }
-- The root of the subtree is retained as a pass-through marker so the visual editor can identify
-- the boundary, but all nodes are inlined into the parent tree's flat arrays at build time.
export type SubtreeDef = BaseDefinition & { _type: "subtree", module: NodeDefinition }
-- weights must be the same length as children if provided. Missing entries default to 0.
export type RandomSelectorDef = BaseDefinition & {
	_type: "randomSelector",
	children: { NodeDefinition },
	weights: { number }?,
}

export type NodeDefinition =
	TaskDef
	| ConditionDef
	| SequenceDef
	| SelectorDef
	| ParallelDef
	| InvertDef
	| RepeatDef
	| RetryDef
	| AlwaysSucceedDef
	| AlwaysFailDef
	| SubtreeDef
	| RandomSelectorDef

-- Flat runtime node. All instances live in a single `nodes` array; children are referenced
-- by index rather than by pointer, avoiding nested table allocations.
type FlatNode = {
	id: number,
	definition: NodeDefinition,
	status: Status,
	started: boolean, -- randomSelector: whether a child has been chosen for this activation
	activeChildIndex: number, -- sequence/selector: 1-based offset within this node's childrenData slice
	firstChild: number, -- 1-based start index into the shared childrenData array (0 if none)
	childCount: number, -- number of entries in childrenData starting at firstChild
	child: number, -- 1-based index into nodes for decorators (0 if none)
	iterationCount: number, -- repeat/retry: number of completed iterations
	activeLastTick: boolean, -- task: was this node reached in the previous tick?
	activeThisTick: boolean, -- task: has this node been reached in the current tick?
	wasRunning: boolean, -- task: did the previous execution of this node return RUNNING?
	resolvedParams: { [string]: any }?, -- task: params resolved once for the current activation
}

-- Lightweight debug snapshot returned as the second value from tree:update()
-- when the tree was created with debug=true. Contains only runtime state;
-- structural information comes from the definition tree.
-- nodeStates is keyed by 1-based DFS index (matching the FlatNode array position).
-- taskParams contains the resolved params for task nodes visited in the last
-- completed update; nil values are stringified as "nil" for debug transport.
export type DebugSnapshot = {
	tick: number,
	paused: boolean,
	nodeStates: { [number]: Status },
	taskParams: { [number]: { [string]: any } },
}

export type DebugCallback = (nodeIndex: number, status: Status) -> ()

export type Tree = {
	update: (self: Tree, debugCallback: DebugCallback?) -> (Status, DebugSnapshot?),
	reset: (self: Tree) -> (),
	stop: (self: Tree) -> (),
	pause: (self: Tree) -> (),
	resume: (self: Tree) -> (),
	isPaused: (self: Tree) -> boolean,
}

-- Per-tree runtime context used during a tick to fire onExit callbacks inline,
-- before the next task runs, rather than at the end of the whole tick.
type TreeContext = {
	nodes: { FlatNode },
	-- Sorted (ascending) node indices for task nodes that have an onExit callback.
	-- Pre-built once in BT.new(); avoids scanning all nodes every tick.
	leaveCandidates: { number },
	-- Tracks which leave candidates have already had onExit fired this tick.
	-- Keyed by node index. Cleared at the start of each update() call.
	leaveProcessed: { [number]: boolean },
	-- Optional callback invoked before and after each node is ticked during debug mode.
	-- Called with (nodeIndex, RUNNING) before entry and (nodeIndex, resultStatus) after.
	-- Set per-tick by update(); nil when debug is disabled or no callback is provided.
	debugCallback: DebugCallback?,
}

local treeRegistry: { [Blackboard]: TreeContext } = setmetatable({} :: { [Blackboard]: TreeContext }, { __mode = "k" })

-- Builds a nodeStates snapshot table keyed by 1-based DFS index from a flat node array.
local function buildNodeStates(nodes: { FlatNode }): { [number]: Status }
	local nodeStates: { [number]: Status } = {}
	for i = 1, #nodes do
		nodeStates[i] = nodes[i].status
	end
	return nodeStates
end

local function buildDebugTaskParams(nodes: { FlatNode }): { [number]: { [string]: any } }
	local taskParams: { [number]: { [string]: any } } = {}
	for i = 1, #nodes do
		local node = nodes[i]
		if node.definition._type == "task" and node.activeLastTick and node.resolvedParams ~= nil then
			local def = node.definition :: TaskDef
			local resolvedParams = node.resolvedParams :: { [any]: any }
			local encodedParams: { [string]: any } = {}
			local paramCount = 0
			local seenKeys: { [string]: boolean } = {}
			for rawKey in def.params do
				local key = tostring(rawKey)
				seenKeys[key] = true
				encodedParams[key] = if resolvedParams[rawKey] == nil then "nil" else resolvedParams[rawKey]
				paramCount += 1
			end
			local schema = def.module.params
			if schema ~= nil then
				for key in schema do
					if not seenKeys[key] then
						encodedParams[key] = if resolvedParams[key] == nil then "nil" else resolvedParams[key]
						paramCount += 1
					end
				end
			end
			if paramCount > 0 then
				taskParams[i] = encodedParams
			end
		end
	end
	return taskParams
end

-- Structural (immutable) fields extracted from a FlatNode for use as a construction template.
type NodeTemplate = {
	id: number,
	definition: NodeDefinition,
	firstChild: number,
	childCount: number,
	child: number,
}

type CachedTreeStructure = {
	-- childrenData is read-only after construction and shared across all instances.
	childrenData: { number },
	nodeTemplates: { NodeTemplate },
	rootIndex: number,
}

-- Weak-keyed cache of compiled tree structures indexed by their root definition table.
-- Allows subsequent BT.new() calls with the same definition to skip buildFlatTree entirely.
local treeCache: { [NodeDefinition]: CachedTreeStructure } =
	setmetatable({} :: { [NodeDefinition]: CachedTreeStructure }, { __mode = "k" })

local nextId = 0
local function newId(): number
	nextId += 1
	return nextId
end

local PARAM_BIND_KIND = "bind"
local PARAM_CALC_KIND = "calc"

local function isParamBinding(value: any): boolean
	return type(value) == "table" and value.__btParamKind == PARAM_BIND_KIND
end

local function isParamCalculation(value: any): boolean
	return type(value) == "table" and value.__btParamKind == PARAM_CALC_KIND
end

local function parseBindingPath(path: string): { ParamPathSegment }
	if path == "" then
		error("BT.bind path must not be empty", 3)
	end

	local rawSegments = string.split(path, ".")
	local segments: { ParamPathSegment } = {}
	for i, rawSegment in rawSegments do
		if rawSegment == "" then
			error(`BT.bind path "{path}" contains an empty segment`, 3)
		end
		if string.match(rawSegment, "^%d+$") ~= nil then
			segments[i] = tonumber(rawSegment) :: number
		else
			segments[i] = rawSegment
		end
	end
	return segments
end

local function normalizeTaskParams(params: any?): { [string]: any }
	if params == nil then
		return {}
	end
	if type(params) ~= "table" then
		error("BT.task params must be a table or nil", 3)
	end
	for paramName, value in params do
		if type(value) == "function" then
			error(
				string.format(
					"task param '%s': function values must be wrapped in BT.calc(...)",
					tostring(paramName)
				),
				3
			)
		end
	end
	return params
end

local function resolveBinding(blackboard: Blackboard, binding: ParamBinding): any
	local current: any = blackboard
	for _, segment in binding.segments do
		if current == nil or type(current) ~= "table" then
			return nil
		end
		current = current[segment]
	end
	return current
end

local function resolveTaskParams(params: { [string]: any }, blackboard: Blackboard): { [string]: any }
	local resolved: { [string]: any } = {}
	for key, value in params do
		if isParamBinding(value) then
			resolved[key] = resolveBinding(blackboard, value :: ParamBinding)
		elseif isParamCalculation(value) then
			resolved[key] = (value :: ParamCalculation).resolver(blackboard)
		else
			resolved[key] = value
		end
	end
	return resolved
end

-- Recursively allocates FlatNodes into `nodes` and packs their child indices into `childrenData`.
-- Children for each composite are reserved as a contiguous slice before their subtrees are built,
-- ensuring the slice positions are stable even as deeper nodes append further entries.
local function buildFlatTree(definition: NodeDefinition, nodes: { FlatNode }, childrenData: { number }): number
	local nodeIndex = #nodes + 1
	local node: FlatNode = {
		id = newId(),
		definition = definition,
		status = RUNNING,
		started = false,
		activeChildIndex = 1,
		firstChild = 0,
		childCount = 0,
		child = 0,
		iterationCount = 0,
		activeLastTick = false,
		activeThisTick = false,
		wasRunning = false,
		resolvedParams = nil,
	}
	table.insert(nodes, node)

	local nodeType = definition._type

	if nodeType == "sequence" or nodeType == "selector" or nodeType == "parallel" or nodeType == "randomSelector" then
		local def = definition :: SequenceDef
		local count = #def.children
		local firstPos = #childrenData + 1
		node.firstChild = firstPos
		node.childCount = count
		-- Reserve the slice upfront so that recursive builds append after it.
		for i = 1, count do
			childrenData[firstPos + i - 1] = 0
		end
		for i, childDef in def.children do
			childrenData[firstPos + i - 1] = buildFlatTree(childDef, nodes, childrenData)
		end
	elseif nodeType == "invert" or nodeType == "repeat" or nodeType == "retry" then
		local def = definition :: InvertDef
		node.child = buildFlatTree(def.child, nodes, childrenData)
	elseif nodeType == "alwaysSucceed" or nodeType == "alwaysFail" then
		local def = definition :: AlwaysSucceedDef
		if def.child then
			node.child = buildFlatTree(def.child, nodes, childrenData)
		end
	elseif nodeType == "subtree" then
		local def = definition :: SubtreeDef
		node.child = buildFlatTree(def.module, nodes, childrenData)
	end

	return nodeIndex
end

local function resetNode(nodeIndex: number, nodes: { FlatNode }, childrenData: { number })
	local node = nodes[nodeIndex]
	node.status = RUNNING
	node.started = false
	node.activeChildIndex = 1
	node.iterationCount = 0
	node.wasRunning = false
	node.resolvedParams = nil
	for i = 1, node.childCount do
		resetNode(childrenData[node.firstChild + i - 1], nodes, childrenData)
	end
	if node.child ~= 0 then
		resetNode(node.child, nodes, childrenData)
	end
end

local function getTaskResolvedParams(node: FlatNode, def: TaskDef, blackboard: Blackboard): { [string]: any }
	if node.resolvedParams == nil then
		node.resolvedParams = resolveTaskParams(def.params :: { [string]: any }, blackboard)
	end
	return node.resolvedParams
end

local function stopNode(nodeIndex: number, nodes: { FlatNode }, childrenData: { number }, blackboard: Blackboard)
	local node = nodes[nodeIndex]
	if node.definition._type == "task" and (node.activeThisTick or node.activeLastTick) then
		local def = node.definition :: TaskDef
		local params = getTaskResolvedParams(node, def, blackboard)
		if def.module.onExit then
			def.module.onExit(blackboard, params)
		end
		if def.module.onEnd and node.activeThisTick then
			def.module.onEnd(blackboard, params)
		end
		node.resolvedParams = nil
	end
	for i = 1, node.childCount do
		stopNode(childrenData[node.firstChild + i - 1], nodes, childrenData, blackboard)
	end
	if node.child ~= 0 then
		stopNode(node.child, nodes, childrenData, blackboard)
	end
end

-- tickNode is forward-declared so that composite ticker functions can reference it.
-- It is assigned at the bottom of the ticker block.
type Ticker = (nodeIndex: number, nodes: { FlatNode }, childrenData: { number }, blackboard: Blackboard) -> Status
local tickNode: Ticker
local tickers: { [string]: Ticker } = {}

tickers["task"] = function(nodeIndex: number, nodes: { FlatNode }, _: { number }, blackboard: Blackboard): Status
	local node = nodes[nodeIndex]
	local def = node.definition :: TaskDef
	local mod = def.module
	local taskParams: { [string]: any }

	-- Capture the per-tree tick context before mod.run() can yield.
	-- If another tree's update() runs during a yield it will overwrite treeRegistry[blackboard]
	-- for that tree's blackboard, but our local reference remains valid.
	local ctx = treeRegistry[blackboard]

	if not node.activeThisTick then
		if not node.wasRunning then
			node.resolvedParams = resolveTaskParams(def.params :: { [string]: any }, blackboard)
		end
		taskParams = getTaskResolvedParams(node, def, blackboard)

		-- Before entering this task, fire onExit for any earlier task nodes (lower DFS index)
		-- that were active last tick but have been skipped this tick. This guarantees the
		-- previous task's onExit fires before the incoming task's onEnter.
		if ctx then
			for _, candidateIdx in ctx.leaveCandidates do
				if candidateIdx >= nodeIndex then
					break
				end
				if not ctx.leaveProcessed[candidateIdx] then
					local candidate = ctx.nodes[candidateIdx]
					if candidate.activeLastTick and not candidate.activeThisTick then
						local candidateDef = candidate.definition :: TaskDef
						local candidateParams = getTaskResolvedParams(candidate, candidateDef, blackboard)
						if candidateDef.module.onExit then
							candidateDef.module.onExit(blackboard, candidateParams)
						end
						candidate.resolvedParams = nil
						ctx.leaveProcessed[candidateIdx] = true
					end
				end
			end
		end

		if not node.activeLastTick then
			if mod.onEnter then
				mod.onEnter(blackboard, taskParams)
			end
		end
		node.activeThisTick = true
	else
		taskParams = getTaskResolvedParams(node, def, blackboard)
	end

	-- onStart fires at the beginning of each fresh execution.
	-- It does not fire when the task is resuming after returning RUNNING.
	if not node.wasRunning then
		if mod.onStart then
			mod.onStart(blackboard, taskParams)
		end
	end

	-- run() may yield freely; tree:update() is assumed to be called inside a task.
	local result = mod.run(blackboard, taskParams)

	if mod.onEnd and result ~= RUNNING then
		mod.onEnd(blackboard, taskParams)
	end

	-- RUNNING passes through; explicit FAILURE fails; anything else (including nil) succeeds.
	local status: Status = if result == RUNNING then RUNNING elseif result == FAILURE then FAILURE else SUCCESS
	node.status = status
	node.wasRunning = (status == RUNNING)

	return status
end

tickers["condition"] = function(nodeIndex: number, nodes: { FlatNode }, _: { number }, blackboard: Blackboard): Status
	local node = nodes[nodeIndex]
	local def = node.definition :: ConditionDef
	local status: Status = if def.check(blackboard) then SUCCESS else FAILURE
	node.status = status
	return status
end

-- Ticks children left-to-right. Resumes from the last running child on subsequent ticks.
-- Fails immediately on the first child failure; succeeds once all children succeed.
tickers["sequence"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	while node.activeChildIndex <= node.childCount do
		local childIndex = childrenData[node.firstChild + node.activeChildIndex - 1]
		local status = tickNode(childIndex, nodes, childrenData, blackboard)

		if status == RUNNING then
			node.status = RUNNING
			return RUNNING
		elseif status == FAILURE then
			node.activeChildIndex = 1
			node.status = FAILURE
			return FAILURE
		end

		node.activeChildIndex += 1
	end

	node.activeChildIndex = 1
	node.status = SUCCESS
	return SUCCESS
end

-- Ticks children left-to-right. Succeeds immediately on the first child success;
-- fails once all children fail.
tickers["selector"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	while node.activeChildIndex <= node.childCount do
		local childIndex = childrenData[node.firstChild + node.activeChildIndex - 1]
		local status = tickNode(childIndex, nodes, childrenData, blackboard)

		if status == RUNNING then
			node.status = RUNNING
			return RUNNING
		elseif status == SUCCESS then
			node.activeChildIndex = 1
			node.status = SUCCESS
			return SUCCESS
		end

		node.activeChildIndex += 1
	end

	node.activeChildIndex = 1
	node.status = FAILURE
	return FAILURE
end

-- Ticks all children every frame. Terminates based on the success/failure policies,
-- interrupting and resetting any children that are still running when it terminates.
tickers["parallel"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	local def = node.definition :: ParallelDef
	local successCount = 0
	local failureCount = 0

	for i = 1, node.childCount do
		local childIndex = childrenData[node.firstChild + i - 1]
		local child = nodes[childIndex]
		if child.status == RUNNING then
			tickNode(childIndex, nodes, childrenData, blackboard)
		end
		if child.status == SUCCESS then
			successCount += 1
		elseif child.status == FAILURE then
			failureCount += 1
		end
	end

	local succeeded = if def.successPolicy == "requireAll" then successCount == node.childCount else successCount > 0
	local failed = if def.failurePolicy == "requireAll" then failureCount == node.childCount else failureCount > 0

	if succeeded or failed then
		for i = 1, node.childCount do
			local childIndex = childrenData[node.firstChild + i - 1]
			if nodes[childIndex].status == RUNNING then
				stopNode(childIndex, nodes, childrenData, blackboard)
			end
			resetNode(childIndex, nodes, childrenData)
		end
		-- Success takes priority when both policies trigger simultaneously.
		local result: Status = if succeeded then SUCCESS else FAILURE
		node.status = result
		return result
	end

	node.status = RUNNING
	return RUNNING
end

tickers["invert"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	local status = tickNode(node.child, nodes, childrenData, blackboard)
	local result: Status = if status == SUCCESS then FAILURE elseif status == FAILURE then SUCCESS else RUNNING
	node.status = result
	return result
end

-- Always reports SUCCESS regardless of the child's result.
tickers["alwaysSucceed"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	if node.child == 0 then
		node.status = SUCCESS
		return SUCCESS
	end
	local status = tickNode(node.child, nodes, childrenData, blackboard)
	if status == RUNNING then
		node.status = RUNNING
		return RUNNING
	end
	node.status = SUCCESS
	return SUCCESS
end

-- Always reports FAILURE regardless of the child's result.
tickers["alwaysFail"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	if node.child == 0 then
		node.status = FAILURE
		return FAILURE
	end
	local status = tickNode(node.child, nodes, childrenData, blackboard)
	if status == RUNNING then
		node.status = RUNNING
		return RUNNING
	end
	node.status = FAILURE
	return FAILURE
end

-- Repeats the child on success up to `times` times; fails immediately if the child fails.
tickers["repeat"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	local def = node.definition :: RepeatDef
	local status = tickNode(node.child, nodes, childrenData, blackboard)

	if status == FAILURE then
		node.iterationCount = 0
		resetNode(node.child, nodes, childrenData)
		node.status = FAILURE
		return FAILURE
	elseif status == SUCCESS then
		node.iterationCount += 1
		if def.times ~= -1 and node.iterationCount >= def.times then
			node.iterationCount = 0
			resetNode(node.child, nodes, childrenData)
			node.status = SUCCESS
			return SUCCESS
		end
		resetNode(node.child, nodes, childrenData)
	end

	node.status = RUNNING
	return RUNNING
end

-- Retries the child on failure up to `times` times; succeeds immediately if the child succeeds.
tickers["retry"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	local def = node.definition :: RetryDef
	local status = tickNode(node.child, nodes, childrenData, blackboard)

	if status == SUCCESS then
		node.iterationCount = 0
		resetNode(node.child, nodes, childrenData)
		node.status = SUCCESS
		return SUCCESS
	elseif status == FAILURE then
		node.iterationCount += 1
		if def.times ~= -1 and node.iterationCount >= def.times then
			node.iterationCount = 0
			resetNode(node.child, nodes, childrenData)
			node.status = FAILURE
			return FAILURE
		end
		resetNode(node.child, nodes, childrenData)
	end

	node.status = RUNNING
	return RUNNING
end

-- Picks one child per activation based on optional weights, then runs it to completion.
-- Re-picks on the next activation once the chosen child terminates.
tickers["randomSelector"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]

	if not node.started then
		local def = node.definition :: RandomSelectorDef
		local chosen: number
		if def.weights then
			local totalWeight = 0
			for _, w in def.weights do
				totalWeight += w
			end
			local r = math.random() * totalWeight
			local cumulative = 0
			chosen = node.childCount -- fallback in case of floating point edge cases
			for i = 1, node.childCount do
				cumulative += def.weights[i] or 0
				if r <= cumulative then
					chosen = i
					break
				end
			end
		else
			chosen = math.random(1, node.childCount)
		end
		node.activeChildIndex = chosen
		node.started = true
	end

	local childIndex = childrenData[node.firstChild + node.activeChildIndex - 1]
	local status = tickNode(childIndex, nodes, childrenData, blackboard)

	if status ~= RUNNING then
		node.started = false
		node.activeChildIndex = 1
	end

	node.status = status
	return status
end

-- Pass-through: the subtree node exists only as a visual boundary marker.
tickers["subtree"] = function(
	nodeIndex: number,
	nodes: { FlatNode },
	childrenData: { number },
	blackboard: Blackboard
): Status
	local node = nodes[nodeIndex]
	local status = tickNode(node.child, nodes, childrenData, blackboard)
	node.status = status
	return status
end

tickNode = function(nodeIndex: number, nodes: { FlatNode }, childrenData: { number }, blackboard: Blackboard): Status
	local node = nodes[nodeIndex]
	local ticker = tickers[node.definition._type]
	assert(ticker ~= nil, "Unknown behavior tree node type: " .. node.definition._type)

	local ctx = treeRegistry[blackboard]
	local cb = if ctx then ctx.debugCallback else nil

	if cb then
		cb(nodeIndex, RUNNING)
	end

	local result = ticker(nodeIndex, nodes, childrenData, blackboard)

	if cb then
		cb(nodeIndex, result)
	end

	return result
end

-- Public API

local BehaviorTree = {}

-- Creates a runtime behavior tree from a declarative definition and a blackboard.
-- The tree must be updated each frame by calling `tree:update()`.
-- When `debug` is true, each `tree:update()` call returns `(status, snapshot)` as
-- a second return value, where snapshot is a lightweight `DebugSnapshot` table.
function BehaviorTree.new(definition: NodeDefinition, blackboard: Blackboard, debug: boolean?): Tree
	local cached = treeCache[definition]
	if not cached then
		local templateNodes: { FlatNode } = {}
		local childrenData: { number } = {}
		local rootIndex = buildFlatTree(definition, templateNodes, childrenData)
		local nodeTemplates: { NodeTemplate } = {}
		for i, node in templateNodes do
			nodeTemplates[i] = {
				id = node.id,
				definition = node.definition,
				firstChild = node.firstChild,
				childCount = node.childCount,
				child = node.child,
			}
		end
		cached = { childrenData = childrenData, nodeTemplates = nodeTemplates, rootIndex = rootIndex }
		treeCache[definition] = cached
	end

	local childrenData = cached.childrenData
	local rootIndex = cached.rootIndex
	local nodes: { FlatNode } = {}
	for i, template in cached.nodeTemplates do
		nodes[i] = {
			id = template.id,
			definition = template.definition,
			firstChild = template.firstChild,
			childCount = template.childCount,
			child = template.child,
			status = RUNNING,
			started = false,
			activeChildIndex = 1,
			iterationCount = 0,
			activeLastTick = false,
			activeThisTick = false,
			wasRunning = false,
			resolvedParams = nil,
		}
	end

	-- Pre-build the sorted list of task node indices that have an onExit callback.
	-- Kept outside of the tick loop to avoid allocating on every frame.
	local leaveCandidates: { number } = {}
	for i = 1, #nodes do
		local n = nodes[i]
		if n.definition._type == "task" and (n.definition :: TaskDef).module.onExit then
			table.insert(leaveCandidates, i)
		end
	end

	treeRegistry[blackboard] = {
		nodes = nodes,
		leaveCandidates = leaveCandidates,
		leaveProcessed = {},
		debugCallback = nil,
	}

	local tickCount = 0
	local paused = false
	local lastStatus: Status = RUNNING
	local isDebug = debug and true or false

	local function resetTreeRuntime(resumeAfterReset: boolean)
		resetNode(rootIndex, nodes, childrenData)
		for i = 1, #nodes do
			local node = nodes[i]
			if node.definition._type == "task" then
				node.activeLastTick = false
				node.activeThisTick = false
			end
		end
		lastStatus = RUNNING
		if resumeAfterReset then
			paused = false
		end

		local ctx = treeRegistry[blackboard]
		if ctx then
			table.clear(ctx.leaveProcessed)
			ctx.debugCallback = nil
		end
	end

	local tree: Tree = {
		-- Advances the tree by one tick. Should be called once per frame.
		-- When the tree is paused (via tree:pause()), returns the last status without ticking.
		-- When debug mode is enabled, returns `(status, snapshot)` where snapshot is a
		-- lightweight DebugSnapshot table containing tick count, paused state,
		-- per-node status keyed by 1-based DFS index, and resolved params for
		-- any task nodes visited in the last completed update.
		-- An optional `debugCallback` parameter can be provided; it will be called before
		-- and after each node is ticked with `(nodeIndex, status)`. Before entry the status
		-- is RUNNING; after the ticker completes it is the result status.
		update = function(_self: Tree, debugCallback: DebugCallback?): (Status, DebugSnapshot?)
			if paused then
				if isDebug then
					local snapshot = {
						tick = tickCount,
						paused = true,
						nodeStates = buildNodeStates(nodes),
						taskParams = buildDebugTaskParams(nodes),
					}
					return lastStatus, snapshot
				end
				return lastStatus
			end

			tickCount += 1

			local ctx = treeRegistry[blackboard]
			if ctx then
				table.clear(ctx.leaveProcessed)
				-- Store the callback so tickNode can invoke it around each node.
				-- Only set when debug is enabled; otherwise the callback is ignored.
				if isDebug then
					ctx.debugCallback = debugCallback
				end
			end

			local status = tickNode(rootIndex, nodes, childrenData, blackboard)

			-- Post-tick fallback: fire onExit for any leave candidates that were active last
			-- tick but were never visited at all this tick (e.g. in an entirely skipped branch).
			-- The inline path in tickers["task"] already handles candidates with lower DFS indices
			-- than the task that ran; this handles the rest.
			if ctx then
				for _, candidateIdx in ctx.leaveCandidates do
					if not ctx.leaveProcessed[candidateIdx] then
						local n = nodes[candidateIdx]
						if n.activeLastTick and not n.activeThisTick then
							local def = n.definition :: TaskDef
							local params = getTaskResolvedParams(n, def, blackboard)
							if def.module.onExit then
								def.module.onExit(blackboard, params)
							end
							n.resolvedParams = nil
							ctx.leaveProcessed[candidateIdx] = true
						end
					end
				end
			end

			-- Advance the per-tick tracking flags for all task nodes.
			for i = 1, #nodes do
				local n = nodes[i]
				if n.definition._type == "task" then
					if not n.activeThisTick then
						n.resolvedParams = nil
					end
					n.activeLastTick = n.activeThisTick
					n.activeThisTick = false
				end
			end

			lastStatus = status

			-- Clear the per-tick debug callback so it doesn't leak into future ticks.
			if ctx then
				ctx.debugCallback = nil
			end

			if isDebug then
				return status, {
					tick = tickCount,
					paused = false,
					nodeStates = buildNodeStates(nodes),
					taskParams = buildDebugTaskParams(nodes),
				}
			end

			return status
		end,

		-- Resets the tree to its initial state without firing interruption callbacks.
		-- The next update starts from the root. Pause state is preserved.
		reset = function(_self: Tree)
			resetTreeRuntime(false)
		end,

		-- Fires onExit for any tasks that were active in the current execution,
		-- then resets the tree to its initial state and resumes ticking.
		stop = function(_self: Tree)
			stopNode(rootIndex, nodes, childrenData, blackboard)
			resetTreeRuntime(true)
		end,

		-- Pauses the tree so that subsequent update() calls are no-ops.
		pause = function(_self: Tree)
			paused = true
		end,

		-- Resumes a paused tree so that update() ticks normally again.
		resume = function(_self: Tree)
			paused = false
		end,

		-- Returns whether the tree is currently paused.
		isPaused = function(_self: Tree): boolean
			return paused
		end,
	}

	return tree
end

-- Node definition builders

function BehaviorTree.bind(path: string): ParamBinding
	if type(path) ~= "string" then
		error("BT.bind path must be a string", 2)
	end
	return {
		__btParamKind = PARAM_BIND_KIND,
		path = path,
		segments = parseBindingPath(path),
	}
end

function BehaviorTree.calc(resolver: (blackboard: Blackboard) -> any): ParamCalculation
	if type(resolver) ~= "function" then
		error("BT.calc resolver must be a function", 2)
	end
	return {
		__btParamKind = PARAM_CALC_KIND,
		resolver = resolver,
	}
end

function BehaviorTree.task(module: BTreeTask, params: any?, meta: NodeMeta?): TaskDef
	module.run = module.run or function()
		return SUCCESS
	end
	local resolvedParams = normalizeTaskParams(params)
	local resolvedMeta: NodeMeta? = meta
	if module.name ~= nil and (meta == nil or meta.label == nil) then
		local withName: NodeMeta = if meta ~= nil then table.clone(meta) else {} :: NodeMeta
		withName.label = tostring(module.name)
		resolvedMeta = withName
	end
	return { _type = "task", module = module :: TaskModule, params = resolvedParams, meta = resolvedMeta }
end

function BehaviorTree.condition(check: (blackboard: Blackboard) -> boolean, meta: NodeMeta?): ConditionDef
	return { _type = "condition", check = check, meta = meta }
end

function BehaviorTree.sequence(children: { NodeDefinition }, meta: NodeMeta?): SequenceDef
	return { _type = "sequence", children = children, meta = meta }
end

function BehaviorTree.selector(children: { NodeDefinition }, meta: NodeMeta?): SelectorDef
	return { _type = "selector", children = children, meta = meta }
end

-- successPolicy defaults to "requireAll": all children must succeed for the parallel to succeed.
-- failurePolicy defaults to "requireOne": any child failure causes the parallel to fail.
function BehaviorTree.parallel(
	children: { NodeDefinition },
	successPolicy: ("requireAll" | "requireOne")?,
	failurePolicy: ("requireAll" | "requireOne")?,
	meta: NodeMeta?
): ParallelDef
	return {
		_type = "parallel",
		children = children,
		successPolicy = if successPolicy then successPolicy else "requireAll",
		failurePolicy = if failurePolicy then failurePolicy else "requireOne",
		meta = meta,
	}
end

function BehaviorTree.invert(child: NodeDefinition, meta: NodeMeta?): InvertDef
	return { _type = "invert", child = child, meta = meta }
end

-- Wraps a child node, always reporting SUCCESS regardless of the child's outcome.
-- If no child is provided, acts as a success leaf.
function BehaviorTree.alwaysSucceed(child: NodeDefinition?, meta: NodeMeta?): AlwaysSucceedDef
	return { _type = "alwaysSucceed", child = child, meta = meta }
end

-- Wraps a child node, always reporting FAILURE regardless of the child's outcome.
-- If no child is provided, acts as a failure leaf.
function BehaviorTree.alwaysFail(child: NodeDefinition?, meta: NodeMeta?): AlwaysFailDef
	return { _type = "alwaysFail", child = child, meta = meta }
end

-- Repeats the child `times` times on success. Fails immediately on child failure.
-- Pass -1 for `times` to repeat indefinitely.
function BehaviorTree.repeatNode(child: NodeDefinition, times: number, meta: NodeMeta?): RepeatDef
	return { _type = "repeat", child = child, times = times, meta = meta }
end

-- Retries the child up to `times` times on failure. Succeeds immediately on child success.
-- Pass -1 for `times` to retry indefinitely.
function BehaviorTree.retryNode(child: NodeDefinition, times: number, meta: NodeMeta?): RetryDef
	return { _type = "retry", child = child, times = times, meta = meta }
end

-- Inlines a subtree from a required module into this tree at build time.
-- The subtree node is a pass-through at runtime but is preserved in debug snapshots so
-- a visual editor can identify the subtree boundary.
function BehaviorTree.subtree(module: NodeDefinition, meta: NodeMeta?): SubtreeDef
	return { _type = "subtree", module = module, meta = meta }
end

-- Randomly picks one child to execute per activation. weights must be the same length as children
-- if provided; if omitted, all children are equally likely.
function BehaviorTree.randomSelector(
	children: { NodeDefinition },
	weights: { number }?,
	meta: NodeMeta?
): RandomSelectorDef
	return { _type = "randomSelector", children = children, weights = weights, meta = meta }
end

BehaviorTree.SUCCESS = SUCCESS
BehaviorTree.FAILURE = FAILURE
BehaviorTree.RUNNING = RUNNING

-- Full type signature of this library's public interface.
-- The `debug` parameter on `new` accepts a string (used as the definition path by the
-- Roblox wrapper) in addition to a boolean, so the type reflects the combined API.
export type Library = {
	SUCCESS: Status,
	FAILURE: Status,
	RUNNING: Status,
	new: (definition: NodeDefinition, blackboard: Blackboard, debug: (boolean | string)?) -> Tree,
	bind: (path: string) -> ParamBinding,
	calc: (resolver: (blackboard: Blackboard) -> any) -> ParamCalculation,
	task: (module: BTreeTask, params: any?, meta: NodeMeta?) -> TaskDef,
	condition: (check: (blackboard: Blackboard) -> boolean, meta: NodeMeta?) -> ConditionDef,
	sequence: (children: { NodeDefinition }, meta: NodeMeta?) -> SequenceDef,
	selector: (children: { NodeDefinition }, meta: NodeMeta?) -> SelectorDef,
	parallel: (
		children: { NodeDefinition },
		successPolicy: ("requireAll" | "requireOne")?,
		failurePolicy: ("requireAll" | "requireOne")?,
		meta: NodeMeta?
	) -> ParallelDef,
	invert: (child: NodeDefinition, meta: NodeMeta?) -> InvertDef,
	alwaysSucceed: (child: NodeDefinition?, meta: NodeMeta?) -> AlwaysSucceedDef,
	alwaysFail: (child: NodeDefinition?, meta: NodeMeta?) -> AlwaysFailDef,
	repeatNode: (child: NodeDefinition, times: number, meta: NodeMeta?) -> RepeatDef,
	retryNode: (child: NodeDefinition, times: number, meta: NodeMeta?) -> RetryDef,
	subtree: (module: NodeDefinition, meta: NodeMeta?) -> SubtreeDef,
	randomSelector: (children: { NodeDefinition }, weights: { number }?, meta: NodeMeta?) -> RandomSelectorDef,
}

return BehaviorTree :: Library
