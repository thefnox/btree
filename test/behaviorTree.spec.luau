-- Unit tests for lib/behaviorTree.lua
-- Converted from zune testing to tiniest + lune

local task = require("@lune/task")

-- Lune's task.wait(0) doesn't reliably yield to other threads the way
-- Roblox/zune schedulers do. Use small positive durations instead.
local YIELD_DUR = 0.01 -- duration used inside spawned tasks to yield
local SYNC_DUR = 0.05 -- duration used in the test body to wait for spawned tasks

local Vector2 = {
	new = function(x: number, y: number): vector
		return vector.create(x, y, 0)
	end,
}

local BT = require("../lib/behaviorTree/behaviorTree")

local SUCCESS = BT.SUCCESS
local FAILURE = BT.FAILURE
local RUNNING = BT.RUNNING

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local SUCCEED: BT.BTreeTask = {
	run = function()
		return SUCCESS
	end,
}
local FAIL: BT.BTreeTask = {
	run = function()
		return FAILURE
	end,
}

local function counting(result: BT.Status, counter: { n: number }): BT.BTreeTask
	return {
		run = function()
			counter.n += 1
			return result
		end,
	}
end

------------------------------------------------------------------------
-- Test module
------------------------------------------------------------------------

type tiniest_actual = typeof(require("../tiniest/tiniest_for_lune").configure({}))

return function(tiniest: tiniest_actual)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	------------------------------------------------------------------------
	-- task
	------------------------------------------------------------------------

	describe("task", function()
		test("returns SUCCESS when run returns nil", function()
			local tree = BT.new(
				BT.task({
					run = function()
						return nil
					end,
				}),
				{}
			)
			expect(tree:update()).is(SUCCESS)
		end)

		test("returns SUCCESS when run returns SUCCESS", function()
			local tree = BT.new(BT.task(SUCCEED), {})
			expect(tree:update()).is(SUCCESS)
		end)

		test("returns FAILURE when run returns FAILURE", function()
			local tree = BT.new(BT.task(FAIL), {})
			expect(tree:update()).is(FAILURE)
		end)

		test("calls onStart before run and onEnd after run", function()
			local log: { string } = {}
			local m: BT.BTreeTask = {
				onStart = function()
					table.insert(log, "start")
				end,
				run = function()
					table.insert(log, "run")
					return SUCCESS
				end,
				onEnd = function()
					table.insert(log, "end")
				end,
			}
			BT.new(BT.task(m), {}):update()
			expect(log[1]).is("start")
			expect(log[2]).is("run")
			expect(log[3]).is("end")
		end)

		test("passes blackboard to run", function()
			local bb = { value = 99 }
			local received: any = nil
			BT.new(
				BT.task({
					run = function(b)
						received = b
						return SUCCESS
					end,
				}),
				bb
			):update()
			expect(received).is(bb)
		end)

		test("passes params to run", function()
			local params = { speed = 16 }
			local received: any = nil
			BT.new(
				BT.task({
					run = function(_, p)
						received = p
						return SUCCESS
					end,
				}, params),
				{}
			):update()
			expect(received).is(params)
		end)

		test("defaults nil params to an empty table", function()
			local received: any = nil
			local def = BT.task({
				run = function(_, p)
					received = p
					return SUCCESS
				end,
			}, nil)
			BT.new(def, {}):update()
			expect(type(def.params)).is("table")
			expect(next(def.params)).is(nil)
			expect(received).is(def.params)
		end)

		test("passes blackboard to onStart and onEnd", function()
			local bb = { marker = true }
			local startBb: any = nil
			local endBb: any = nil
			BT.new(
				BT.task({
					onStart = function(b)
						startBb = b
					end,
					run = function()
						return SUCCESS
					end,
					onEnd = function(b)
						endBb = b
					end,
				}),
				bb
			):update()
			expect(startBb).is(bb)
			expect(endBb).is(bb)
		end)

		test("onStart fires on first tick of a fresh execution", function()
			local startCount = 0
			local def = BT.task({
				onStart = function()
					startCount += 1
				end,
				run = function()
					return SUCCESS
				end,
			})
			BT.new(def, {}):update()
			expect(startCount).is(1)
		end)

		test("onStart does not fire again when task resumes from RUNNING", function()
			local startCount = 0
			local ticks = 0
			local def = BT.task({
				onStart = function()
					startCount += 1
				end,
				run = function()
					ticks += 1
					return if ticks < 3 then RUNNING else SUCCESS
				end,
			})
			local tree = BT.new(def, {})
			tree:update() -- tick 1: fresh start, onStart fires
			tree:update() -- tick 2: resuming RUNNING, onStart does NOT fire
			tree:update() -- tick 3: resuming RUNNING, SUCCESS, onStart does NOT fire
			expect(startCount).is(1)
		end)

		test("onStart fires again on each fresh execution in a repeat loop", function()
			local startCount = 0
			local def = BT.repeatNode(
				BT.task({
					onStart = function()
						startCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
				-1
			)
			local tree = BT.new(def, {})
			tree:update()
			tree:update()
			tree:update()
			expect(startCount).is(3)
		end)

		test("onEnd fires after SUCCESS", function()
			local endCount = 0
			BT.new(
				BT.task({
					onEnd = function()
						endCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
				{}
			):update()
			expect(endCount).is(1)
		end)

		test("onEnd fires after FAILURE", function()
			local endCount = 0
			BT.new(
				BT.task({
					onEnd = function()
						endCount += 1
					end,
					run = function()
						return FAILURE
					end,
				}),
				{}
			):update()
			expect(endCount).is(1)
		end)

		test("onEnd does not fire when task returns RUNNING", function()
			local endCount = 0
			local ticks = 0
			local def = BT.task({
				onEnd = function()
					endCount += 1
				end,
				run = function()
					ticks += 1
					return if ticks < 3 then RUNNING else SUCCESS
				end,
			})
			local tree = BT.new(def, {})
			tree:update() -- RUNNING
			tree:update() -- RUNNING
			expect(endCount).is(0)
			tree:update() -- SUCCESS -> onEnd fires
			expect(endCount).is(1)
		end)

		test("onEnd fires on each completion in a repeat loop", function()
			local endCount = 0
			local def = BT.repeatNode(
				BT.task({
					onEnd = function()
						endCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
				-1
			)
			local tree = BT.new(def, {})
			tree:update()
			tree:update()
			tree:update()
			expect(endCount).is(3)
		end)
	end)

	------------------------------------------------------------------------
	-- condition
	------------------------------------------------------------------------

	describe("condition", function()
		test("returns SUCCESS when check returns true", function()
			local tree = BT.new(
				BT.condition(function()
					return true
				end),
				{}
			)
			expect(tree:update()).is(SUCCESS)
		end)

		test("returns FAILURE when check returns false", function()
			local tree = BT.new(
				BT.condition(function()
					return false
				end),
				{}
			)
			expect(tree:update()).is(FAILURE)
		end)

		test("passes blackboard to check", function()
			local bb = { ready = true }
			local tree = BT.new(
				BT.condition(function(b)
					return b.ready
				end),
				bb
			)
			expect(tree:update()).is(SUCCESS)
		end)

		test("re-evaluates check on every tick", function()
			local flag = true
			local tree = BT.new(
				BT.condition(function()
					return flag
				end),
				{}
			)
			expect(tree:update()).is(SUCCESS)
			flag = false
			expect(tree:update()).is(FAILURE)
		end)
	end)

	------------------------------------------------------------------------
	-- sequence
	------------------------------------------------------------------------

	describe("sequence", function()
		test("returns SUCCESS when all children succeed", function()
			local def = BT.sequence({ BT.task(SUCCEED), BT.task(SUCCEED), BT.task(SUCCEED) })
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("returns FAILURE when the first child fails", function()
			local def = BT.sequence({ BT.task(FAIL), BT.task(SUCCEED) })
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("returns FAILURE when a middle child fails", function()
			local def = BT.sequence({ BT.task(SUCCEED), BT.task(FAIL), BT.task(SUCCEED) })
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("short-circuits: does not run children after a failure", function()
			local counter = { n = 0 }
			local def = BT.sequence({ BT.task(FAIL), BT.task(counting(SUCCESS, counter)) })
			BT.new(def, {}):update()
			expect(counter.n).is(0)
		end)

		test("does not run children after the failing child in the middle", function()
			local counter = { n = 0 }
			local def = BT.sequence({
				BT.task(SUCCEED),
				BT.task(FAIL),
				BT.task(counting(SUCCESS, counter)),
			})
			BT.new(def, {}):update()
			expect(counter.n).is(0)
		end)
	end)

	------------------------------------------------------------------------
	-- selector
	------------------------------------------------------------------------

	describe("selector", function()
		test("returns FAILURE when all children fail", function()
			local def = BT.selector({ BT.task(FAIL), BT.task(FAIL), BT.task(FAIL) })
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("returns SUCCESS when the first child succeeds", function()
			local def = BT.selector({ BT.task(SUCCEED), BT.task(FAIL) })
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("returns SUCCESS when a later child succeeds after failures", function()
			local def = BT.selector({ BT.task(FAIL), BT.task(FAIL), BT.task(SUCCEED) })
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("short-circuits: does not run children after a success", function()
			local counter = { n = 0 }
			local def = BT.selector({ BT.task(SUCCEED), BT.task(counting(FAIL, counter)) })
			BT.new(def, {}):update()
			expect(counter.n).is(0)
		end)
	end)

	------------------------------------------------------------------------
	-- parallel
	------------------------------------------------------------------------

	describe("parallel", function()
		test("succeeds when all children succeed (requireAll success policy)", function()
			local def = BT.parallel({ BT.task(SUCCEED), BT.task(SUCCEED) })
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("fails when any child fails (requireOne failure policy)", function()
			local def = BT.parallel({ BT.task(SUCCEED), BT.task(FAIL) })
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("fails when all children fail (requireAll failure policy)", function()
			local def = BT.parallel({ BT.task(FAIL), BT.task(FAIL) }, "requireAll", "requireAll")
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("succeeds when any child succeeds (requireOne success policy)", function()
			local def = BT.parallel({ BT.task(SUCCEED), BT.task(FAIL) }, "requireOne", "requireAll")
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("returns RUNNING when mixed results satisfy neither requireAll policy", function()
			local def = BT.parallel({ BT.task(SUCCEED), BT.task(FAIL) }, "requireAll", "requireAll")
			expect(BT.new(def, {}):update()).is(RUNNING)
		end)

		test("success takes priority when both requireOne policies trigger simultaneously", function()
			local def = BT.parallel({ BT.task(SUCCEED), BT.task(FAIL) }, "requireOne", "requireOne")
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("ticks every child each frame", function()
			local counter = { n = 0 }
			local def = BT.parallel({
				BT.task(counting(SUCCEED, counter)),
				BT.task(counting(SUCCEED, counter)),
			})
			BT.new(def, {}):update()
			expect(counter.n).is(2)
		end)
	end)

	------------------------------------------------------------------------
	-- invert
	------------------------------------------------------------------------

	describe("invert", function()
		test("inverts SUCCESS to FAILURE", function()
			local def = BT.invert(BT.task(SUCCEED))
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("inverts FAILURE to SUCCESS", function()
			local def = BT.invert(BT.task(FAIL))
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("passes RUNNING through unchanged", function()
			local def = BT.invert(BT.repeatNode(BT.task(SUCCEED), 2))
			expect(BT.new(def, {}):update()).is(RUNNING)
		end)
	end)

	------------------------------------------------------------------------
	-- alwaysSucceed
	------------------------------------------------------------------------

	describe("alwaysSucceed", function()
		test("converts child SUCCESS to SUCCESS", function()
			local def = BT.alwaysSucceed(BT.task(SUCCEED))
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("converts child FAILURE to SUCCESS", function()
			local def = BT.alwaysSucceed(BT.task(FAIL))
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("passes RUNNING through unchanged", function()
			local def = BT.alwaysSucceed(BT.repeatNode(BT.task(SUCCEED), 2))
			expect(BT.new(def, {}):update()).is(RUNNING)
		end)

		test("behaves like a success leaf when no child is provided", function()
			local def = BT.alwaysSucceed()
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)
	end)

	------------------------------------------------------------------------
	-- alwaysFail
	------------------------------------------------------------------------

	describe("alwaysFail", function()
		test("converts child SUCCESS to FAILURE", function()
			local def = BT.alwaysFail(BT.task(SUCCEED))
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("converts child FAILURE to FAILURE", function()
			local def = BT.alwaysFail(BT.task(FAIL))
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("passes RUNNING through unchanged", function()
			local def = BT.alwaysFail(BT.repeatNode(BT.task(SUCCEED), 2))
			expect(BT.new(def, {}):update()).is(RUNNING)
		end)

		test("behaves like a failure leaf when no child is provided", function()
			local def = BT.alwaysFail()
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)
	end)

	------------------------------------------------------------------------
	-- repeat
	------------------------------------------------------------------------

	describe("repeat", function()
		test("returns RUNNING while iterating", function()
			local def = BT.repeatNode(BT.task(SUCCEED), 3)
			local tree = BT.new(def, {})
			expect(tree:update()).is(RUNNING) -- iteration 1 of 3
			expect(tree:update()).is(RUNNING) -- iteration 2 of 3
		end)

		test("returns SUCCESS after completing all iterations", function()
			local def = BT.repeatNode(BT.task(SUCCEED), 3)
			local tree = BT.new(def, {})
			tree:update()
			tree:update()
			expect(tree:update()).is(SUCCESS) -- iteration 3 of 3
		end)

		test("runs the child exactly N times", function()
			local counter = { n = 0 }
			local def = BT.repeatNode(BT.task(counting(SUCCESS, counter)), 4)
			local tree = BT.new(def, {})
			for _ = 1, 4 do
				tree:update()
			end
			expect(counter.n).is(4)
		end)

		test("returns FAILURE immediately when child fails", function()
			local def = BT.repeatNode(BT.task(FAIL), 5)
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("never terminates with times = -1", function()
			local counter = { n = 0 }
			local def = BT.repeatNode(BT.task(counting(SUCCESS, counter)), -1)
			local tree = BT.new(def, {})
			for _ = 1, 10 do
				expect(tree:update()).is(RUNNING)
			end
			expect(counter.n).is(10)
		end)
	end)

	------------------------------------------------------------------------
	-- retry
	------------------------------------------------------------------------

	describe("retry", function()
		test("returns RUNNING while retrying", function()
			local def = BT.retryNode(BT.task(FAIL), 3)
			local tree = BT.new(def, {})
			expect(tree:update()).is(RUNNING) -- attempt 1 of 3
			expect(tree:update()).is(RUNNING) -- attempt 2 of 3
		end)

		test("returns FAILURE after exhausting all attempts", function()
			local def = BT.retryNode(BT.task(FAIL), 3)
			local tree = BT.new(def, {})
			tree:update()
			tree:update()
			expect(tree:update()).is(FAILURE) -- attempt 3 of 3
		end)

		test("returns SUCCESS immediately when child succeeds", function()
			local def = BT.retryNode(BT.task(SUCCEED), 5)
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("never terminates with times = -1", function()
			local def = BT.retryNode(BT.task(FAIL), -1)
			local tree = BT.new(def, {})
			for _ = 1, 10 do
				expect(tree:update()).is(RUNNING)
			end
		end)
	end)

	------------------------------------------------------------------------
	-- subtree
	------------------------------------------------------------------------

	describe("subtree", function()
		test("passes through child SUCCESS", function()
			local def = BT.subtree(BT.task(SUCCEED))
			expect(BT.new(def, {}):update()).is(SUCCESS)
		end)

		test("passes through child FAILURE", function()
			local def = BT.subtree(BT.task(FAIL))
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("inlines a composite subtree correctly", function()
			local childDef = BT.sequence({ BT.task(SUCCEED), BT.task(FAIL) })
			local def = BT.subtree(childDef)
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)

		test("subtree root appears as subtree nodeType in debug snapshot", function()
			local def = BT.subtree(BT.task(SUCCEED))
			local bb = {}
			local tree = BT.new(def, bb, true)
			local _, snap = tree:update()
			expect(snap).exists()
			-- DFS index 1 is the subtree root; its status should be present
			expect(snap.nodeStates[1]).exists()
		end)

		test("inlined child appears under subtree node in debug snapshot", function()
			local def = BT.subtree(BT.task(SUCCEED))
			local bb = {}
			local tree = BT.new(def, bb, true)
			local _, snap = tree:update()
			-- DFS index 1 = subtree, DFS index 2 = task child
			expect(snap.nodeStates[2]).exists()
			expect(snap.nodeStates[2]).is(SUCCESS)
		end)
	end)

	------------------------------------------------------------------------
	-- randomSelector
	------------------------------------------------------------------------

	describe("randomSelector", function()
		test("runs exactly one child per activation", function()
			local counter = { n = 0 }
			local def = BT.randomSelector({
				BT.task(counting(SUCCESS, counter)),
				BT.task(counting(SUCCESS, counter)),
			})
			BT.new(def, {}):update()
			expect(counter.n).is(1)
		end)

		test("with weight 0, that child is never chosen", function()
			local counter = { n = 0 }
			local def = BT.randomSelector({
				BT.task(SUCCEED),
				BT.task(counting(SUCCESS, counter)),
			}, { 1, 0 })
			local tree = BT.new(def, {})
			for _ = 1, 50 do
				tree:update()
			end
			expect(counter.n).is(0)
		end)

		test("re-picks a child on each new activation after the previous one terminates", function()
			local activations = 0
			local def = BT.randomSelector({
				BT.task({
					run = function()
						activations += 1
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			for _ = 1, 5 do
				tree:update()
			end
			expect(activations).is(5)
		end)

		test("uniform selection eventually picks all children", function()
			local chosen: { [number]: number } = { [1] = 0, [2] = 0 }
			local def = BT.randomSelector({
				BT.task({
					run = function()
						chosen[1] += 1
						return SUCCESS
					end,
				}),
				BT.task({
					run = function()
						chosen[2] += 1
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			for _ = 1, 100 do
				tree:update()
			end
			expect(chosen[1] > 0).is_true()
			expect(chosen[2] > 0).is_true()
		end)

		test("returns the chosen child's status", function()
			local def = BT.randomSelector({ BT.task(FAIL), BT.task(SUCCEED) }, { 1, 0 })
			expect(BT.new(def, {}):update()).is(FAILURE)
		end)
	end)

	------------------------------------------------------------------------
	-- debug snapshot
	------------------------------------------------------------------------

	describe("debug snapshot", function()
		test("update returns snapshot when debug=true", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local status, snap = tree:update()
			expect(status).is(SUCCESS)
			expect(snap).exists()
			expect(snap.tick).is(1)
			expect(snap.paused).is(false)
		end)

		test("update returns nil snapshot when debug=false", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb)
			local status, snap = tree:update()
			expect(status).is(SUCCESS)
			expect(snap).never_exists()
		end)

		test("nodeStates contains status for each node keyed by DFS index", function()
			local bb = {}
			local tree = BT.new(
				BT.condition(function()
					return false
				end),
				bb,
				true
			)
			local _, snap = tree:update()
			-- Single node: DFS index 1 = condition, status FAILURE
			expect(snap.nodeStates[1]).is(FAILURE)
		end)

		test("composite snapshot includes nodeStates for all children", function()
			local bb = {}
			local tree = BT.new(BT.sequence({ BT.task(SUCCEED), BT.task(SUCCEED), BT.task(SUCCEED) }), bb, true)
			local _, snap = tree:update()
			-- 4 nodes total: sequence(1) + 3 tasks(2,3,4)
			expect(snap.nodeStates[1]).exists()
			expect(snap.nodeStates[2]).exists()
			expect(snap.nodeStates[3]).exists()
			expect(snap.nodeStates[4]).exists()
		end)

		test("decorator snapshot includes nodeStates for child", function()
			local bb = {}
			local tree = BT.new(BT.invert(BT.task(SUCCEED)), bb, true)
			local _, snap = tree:update()
			-- 2 nodes: invert(1) + task(2)
			expect(snap.nodeStates[1]).exists()
			expect(snap.nodeStates[2]).exists()
		end)

		test("tick count increments on each update", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local _, snap1 = tree:update()
			expect(snap1.tick).is(1)
			local _, snap2 = tree:update()
			expect(snap2.tick).is(2)
		end)

		test("snapshot contains only tick, paused, and nodeStates (no structural info)", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local _, snap = tree:update()
			expect(snap.tick).exists()
			expect(snap.paused).exists()
			expect(snap.nodeStates).exists()
			-- Must NOT contain structural fields
			expect(snap.nodes).never_exists()
			expect(snap.definition).never_exists()
			expect(snap.paramTypes).never_exists()
			expect(snap.lastStatus).never_exists()
		end)

		test("debugCallback is called before and after each node tick", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local updates = {}
			tree:update(function(nodeIndex, status)
				table.insert(updates, { nodeIndex = nodeIndex, status = status })
			end)
			-- Single task node (index 1): RUNNING before + SUCCESS after = 2 calls
			expect(#updates).is(2)
			expect(updates[1].nodeIndex).is(1)
			expect(updates[1].status).is(RUNNING)
			expect(updates[2].nodeIndex).is(1)
			expect(updates[2].status).is(SUCCESS)
		end)

		test("debugCallback fires for each node in a sequence", function()
			local bb = {}
			local tree = BT.new(BT.sequence({ BT.task(SUCCEED), BT.task(SUCCEED) }), bb, true)
			local updates = {}
			tree:update(function(nodeIndex, status)
				table.insert(updates, { nodeIndex = nodeIndex, status = status })
			end)
			-- Nodes: sequence(1), task(2), task(3)
			-- sequence entered (RUNNING) -> task1 entered (RUNNING) -> task1 done (SUCCESS)
			-- -> task2 entered (RUNNING) -> task2 done (SUCCESS) -> sequence done (SUCCESS)
			-- = 6 total calls (2 per node)
			expect(#updates).is(6)
		end)

		test("debugCallback is not called when debug is false", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb)
			local called = false
			tree:update(function(_nodeIndex, _status)
				called = true
			end)
			expect(called).is(false)
		end)

		test("debugCallback receives correct node indices", function()
			local bb = {}
			-- sequence(1) -> task(2)
			local tree = BT.new(BT.sequence({ BT.task(SUCCEED) }), bb, true)
			local indices = {}
			tree:update(function(nodeIndex, _status)
				table.insert(indices, nodeIndex)
			end)
			-- sequence(1) RUNNING, task(2) RUNNING, task(2) SUCCESS, sequence(1) SUCCESS
			expect(indices[1]).is(1) -- sequence enters
			expect(indices[2]).is(2) -- task enters
			expect(indices[3]).is(2) -- task done
			expect(indices[4]).is(1) -- sequence done
		end)

		test("debugCallback not called for paused tree", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			tree:pause()
			local called = false
			tree:update(function(_nodeIndex, _status)
				called = true
			end)
			-- Paused: no per-node callbacks are fired
			expect(called).is(false)
		end)
	end)

	------------------------------------------------------------------------
	-- definition cache
	------------------------------------------------------------------------

	describe("definition cache", function()
		test("two trees from the same definition share node ids", function()
			local def = BT.sequence({ BT.task(SUCCEED), BT.task(FAIL) })
			local bb1, bb2 = {}, {}
			local tree1 = BT.new(def, bb1, true)
			local tree2 = BT.new(def, bb2, true)
			local _, snap1 = tree1:update()
			local _, snap2 = tree2:update()
			-- Both snapshots should have the same number of nodes (same DFS structure)
			local count1, count2 = 0, 0
			for _ in snap1.nodeStates do
				count1 += 1
			end
			for _ in snap2.nodeStates do
				count2 += 1
			end
			expect(count1).is(count2)
		end)

		test("two trees from the same definition run independently", function()
			local def = BT.selector({ BT.task(SUCCEED), BT.task(FAIL) })
			local tree1 = BT.new(def, {})
			local tree2 = BT.new(def, {})
			expect(tree1:update()).is(SUCCESS)
			expect(tree2:update()).is(SUCCESS)
		end)

		test("state from one tree instance does not affect another", function()
			local def = BT.repeatNode(BT.task(SUCCEED), 3)
			local tree1 = BT.new(def, {})
			local tree2 = BT.new(def, {})
			tree1:update() -- iter 1
			tree1:update() -- iter 2
			expect(tree2:update()).is(RUNNING)
		end)
	end)

	------------------------------------------------------------------------
	-- reset / stop
	------------------------------------------------------------------------

	describe("reset", function()
		test("rewinds execution to the root without firing interruption exits", function()
			local log: { string } = {}
			local exitCount = 0
			local def = BT.sequence({
				BT.task({
					run = function()
						table.insert(log, "A")
						return SUCCESS
					end,
				}),
				BT.task({
					onExit = function()
						exitCount += 1
					end,
					run = function()
						table.insert(log, "B")
						return RUNNING
					end,
				}),
			})

			local tree = BT.new(def, {})
			tree:update()
			tree:reset()
			tree:update()

			expect(exitCount).is(0)
			expect(#log).is(4)
			expect(log[1]).is("A")
			expect(log[2]).is("B")
			expect(log[3]).is("A")
			expect(log[4]).is("B")
		end)
	end)

	describe("stop", function()
		test("fires onExit for tasks that were active when the tree was stopped", function()
			local exitCount = 0
			local tree = BT.new(
				BT.task({
					onExit = function()
						exitCount += 1
					end,
					run = function()
						return RUNNING
					end,
				}),
				{}
			)

			tree:update()
			tree:stop()

			expect(exitCount).is(1)
		end)

		test("resets iteration count so the next update cannot reach the terminal iteration", function()
			local def = BT.repeatNode(BT.task(SUCCEED), 2)
			local tree = BT.new(def, {})
			tree:update() -- iteration 1 -> RUNNING
			tree:stop() -- reset to iteration 0
			expect(tree:update()).is(RUNNING) -- iteration 1 again, not the final SUCCESS
		end)

		test("resets retry count so exhausted retries are not carried over", function()
			local def = BT.retryNode(BT.task(FAIL), 2)
			local tree = BT.new(def, {})
			tree:update() -- attempt 1 -> RUNNING
			tree:stop() -- reset to attempt 0
			expect(tree:update()).is(RUNNING) -- attempt 1 again, not the terminal FAILURE
		end)

		test("resumes a paused tree and restarts execution from the root", function()
			local log: { string } = {}
			local def = BT.sequence({
				BT.task({
					run = function()
						table.insert(log, "A")
						return SUCCESS
					end,
				}),
				BT.task({
					run = function()
						table.insert(log, "B")
						return RUNNING
					end,
				}),
			})

			local tree = BT.new(def, {})
			tree:update()
			tree:pause()
			tree:stop()

			expect(tree:isPaused()).is(false)
			tree:update()

			expect(#log).is(4)
			expect(log[1]).is("A")
			expect(log[2]).is("B")
			expect(log[3]).is("A")
			expect(log[4]).is("B")
		end)
	end)

	------------------------------------------------------------------------
	-- onEnter and onExit
	------------------------------------------------------------------------

	describe("onEnter and onExit", function()
		test("onEnter fires the first time a task is reached", function()
			local enterCount = 0
			local def = BT.task({
				onEnter = function()
					enterCount += 1
				end,
				run = function()
					return SUCCESS
				end,
			})
			BT.new(def, {}):update()
			expect(enterCount).is(1)
		end)

		test("onEnter does not fire again while the task is reached every tick", function()
			local enterCount = 0
			local def = BT.repeatNode(
				BT.task({
					onEnter = function()
						enterCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
				-1
			)
			local tree = BT.new(def, {})
			for _ = 1, 5 do
				tree:update()
			end
			expect(enterCount).is(1)
		end)

		test("onExit fires when a previously active task is not reached this tick", function()
			local leaveCount = 0
			local flag = true
			local def = BT.sequence({
				BT.condition(function()
					return flag
				end),
				BT.task({
					onExit = function()
						leaveCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			tree:update() -- task reached (flag=true)
			flag = false
			tree:update() -- condition fails, task not reached -> onExit fires
			expect(leaveCount).is(1)
		end)

		test("onEnter fires again after the task re-activates following a leave", function()
			local enterCount = 0
			local flag = true
			local def = BT.sequence({
				BT.condition(function()
					return flag
				end),
				BT.task({
					onEnter = function()
						enterCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			tree:update() -- tick 1: onEnter fires -> enterCount=1
			flag = false
			tree:update() -- tick 2: task not reached -> onExit fires, activeLastTick resets
			flag = true
			tree:update() -- tick 3: task reached again -> onEnter fires -> enterCount=2
			expect(enterCount).is(2)
		end)

		test("onExit does not fire for a task that was never reached", function()
			local leaveCount = 0
			local def = BT.selector({
				BT.task(SUCCEED),
				BT.task({
					onExit = function()
						leaveCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			for _ = 1, 3 do
				tree:update()
			end
			expect(leaveCount).is(0)
		end)

		test("onExit fires before the incoming task's onEnter", function()
			local log: { string } = {}
			local flag = true
			local def = BT.selector({
				BT.sequence({
					BT.condition(function()
						return flag
					end),
					BT.task({
						onExit = function()
							table.insert(log, "A_leave")
						end,
						run = function()
							return SUCCESS
						end,
					}),
				}),
				BT.task({
					onEnter = function()
						table.insert(log, "B_enter")
					end,
					run = function()
						return SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			tree:update() -- tick 1: A active, B not reached
			flag = false
			tree:update() -- tick 2: A skipped, B runs -> A.onExit fires before B.onEnter
			expect(#log).is(2)
			expect(log[1]).is("A_leave")
			expect(log[2]).is("B_enter")
		end)

		test("onEnter and onExit receive the blackboard and params", function()
			local enterBb: any = nil
			local enterParams: any = nil
			local leaveBb: any = nil
			local leaveParams: any = nil
			local flag = true
			local bb = { marker = true }
			local params = { speed = 8 }
			local def = BT.sequence({
				BT.condition(function()
					return flag
				end),
				BT.task({
					onEnter = function(b, p)
						enterBb = b
						enterParams = p
					end,
					onExit = function(b, p)
						leaveBb = b
						leaveParams = p
					end,
					run = function()
						return SUCCESS
					end,
				}, params),
			})
			local tree = BT.new(def, bb)
			tree:update()
			flag = false
			tree:update()
			expect(enterBb).is(bb)
			expect(enterParams).is(params)
			expect(leaveBb).is(bb)
			expect(leaveParams).is(params)
		end)

		test("onExit fires when tree finishes and a previously ticked task is not reached", function()
			-- Scenario: sequence resumes from a later child on tick 2, skipping a task
			-- that was ticked on tick 1. The tree finishes (SUCCESS) but the skipped
			-- task's onExit must still fire.
			local exitCount = 0
			local taskBTicks = 0
			local def = BT.sequence({
				BT.task({
					onExit = function()
						exitCount += 1
					end,
					run = function()
						return SUCCESS
					end,
				}),
				BT.task({
					run = function()
						taskBTicks += 1
						return if taskBTicks < 2 then RUNNING else SUCCESS
					end,
				}),
			})
			local tree = BT.new(def, {})
			-- Tick 1: TaskA succeeds, TaskB returns RUNNING -> both active this tick.
			-- sequence.activeChildIndex stays at TaskB (2).
			tree:update()
			-- Tick 2: sequence resumes at TaskB (skips TaskA) -> TaskB succeeds -> tree SUCCESS.
			-- TaskA was active last tick but not reached this tick -> onExit should fire.
			tree:update()
			expect(exitCount).is(1)
		end)
	end)

	------------------------------------------------------------------------
	-- yielding tasks
	-- These tests exercise the design intent that run() may call task.wait()
	-- to span multiple scheduler steps.
	------------------------------------------------------------------------

	describe("yielding tasks", function()
		test("task.wait() in run() suspends update() until the next scheduler step", function()
			local timeline: { string } = {}
			local result: BT.Status = BT.RUNNING

			task.spawn(function()
				result = BT.new(
					BT.task({
						run = function()
							table.insert(timeline, "started")
							task.wait(YIELD_DUR)
							table.insert(timeline, "resumed")
							return BT.SUCCESS
						end,
					}),
					{}
				):update()
				table.insert(timeline, "done")
			end)

			-- task.spawn runs until the first yield: only "started" logged so far
			expect(#timeline).is(1)
			expect(timeline[1]).is("started")

			-- Yield the test thread so the scheduler can resume the spawned task
			task.wait(SYNC_DUR)

			expect(#timeline).is(3)
			expect(timeline[2]).is("resumed")
			expect(timeline[3]).is("done")
			expect(result).is(BT.SUCCESS)
		end)

		test("run() can yield multiple times, resuming through each successive step", function()
			local step = 0
			local result: BT.Status = BT.RUNNING

			task.spawn(function()
				result = BT.new(
					BT.task({
						run = function()
							step = 1
							task.wait(YIELD_DUR)
							step = 2
							task.wait(YIELD_DUR)
							step = 3
							return BT.SUCCESS
						end,
					}),
					{}
				):update()
			end)

			expect(step).is(1)
			-- Wait long enough for both yields to complete
			task.wait(SYNC_DUR * 3)
			expect(step).is(3)
			expect(result).is(BT.SUCCESS)
		end)

		test("a yielding run() that returns FAILURE propagates FAILURE through update()", function()
			local result: BT.Status = BT.RUNNING

			task.spawn(function()
				result = BT.new(
					BT.task({
						run = function()
							task.wait(YIELD_DUR)
							return BT.FAILURE
						end,
					}),
					{}
				):update()
			end)

			task.wait(SYNC_DUR)
			expect(result).is(BT.FAILURE)
		end)

		test("a sequence pauses while a child task is yielded then completes normally", function()
			local log: { string } = {}
			local result: BT.Status = BT.RUNNING

			task.spawn(function()
				result = BT.new(
					BT.sequence({
						BT.task({
							run = function()
								table.insert(log, "task1_start")
								task.wait(YIELD_DUR)
								table.insert(log, "task1_end")
								return BT.SUCCESS
							end,
						}),
						BT.task({
							run = function()
								table.insert(log, "task2")
								return BT.SUCCESS
							end,
						}),
					}),
					{}
				):update()
			end)

			-- task1 has started and yielded; task2 has not yet run
			expect(#log).is(1)
			expect(log[1]).is("task1_start")

			task.wait(SYNC_DUR) -- advance the scheduler

			-- task1 finished, task2 ran, sequence succeeded
			expect(#log).is(3)
			expect(log[2]).is("task1_end")
			expect(log[3]).is("task2")
			expect(result).is(BT.SUCCESS)
		end)
	end)

	------------------------------------------------------------------------
	-- task param types
	------------------------------------------------------------------------

	describe("task param types", function()
		test("no error when module has no params schema", function()
			local m: BT.BTreeTask = {
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = 16 })
			end).never_fails()
		end)

		test("no error when schema is satisfied with correct types", function()
			local m: BT.BTreeTask = {
				params = { speed = "number", name = "string", active = "boolean" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = 10, name = "run", active = true })
			end).never_fails()
		end)

		test("errors when a number param is the wrong type", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = "fast" })
			end).fails()
		end)

		test("errors when a string param is the wrong type", function()
			local m: BT.BTreeTask = {
				params = { label = "string" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { label = 42 })
			end).fails()
		end)

		test("errors when a boolean param is the wrong type", function()
			local m: BT.BTreeTask = {
				params = { active = "boolean" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { active = 1 })
			end).fails()
		end)

		test("nil is accepted when params table is absent (all params implicitly nullable)", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, nil)
			end).never_fails()
		end)

		test("nil is accepted when a key is missing from the params table", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, {})
			end).never_fails()
		end)

		test("a wrong non-nil value still errors", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = "fast" })
			end).fails()
		end)

		test("extra params not declared in schema are accepted silently", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = 10, undeclared = true })
			end).never_fails()
		end)

		test("error message names the offending param", function()
			local m: BT.BTreeTask = {
				params = { speed = "number" },
				run = function()
					return SUCCESS
				end,
			}
			expect(function()
				BT.task(m, { speed = "fast" })
			end).fails_with("speed")
		end)

		test("paramTypes is available on the task module", function()
			local schema: BT.ParamTypes = { speed = "number" }
			local m: BT.BTreeTask = {
				params = schema,
				run = function()
					return SUCCESS
				end,
			}
			expect(m.params).is(schema)
		end)

		test("paramTypes is nil on task module when no schema", function()
			expect(SUCCEED.params).never_exists()
		end)
	end)

	------------------------------------------------------------------------
	-- pause / resume
	------------------------------------------------------------------------

	describe("pause / resume", function()
		test("tree:isPaused() returns false by default", function()
			local tree = BT.new(BT.task(SUCCEED), {})
			expect(tree:isPaused()).is(false)
		end)

		test("tree:isPaused() returns true after tree:pause()", function()
			local tree = BT.new(BT.task(SUCCEED), {})
			tree:pause()
			expect(tree:isPaused()).is(true)
		end)

		test("tree:isPaused() returns false after tree:pause() then tree:resume()", function()
			local tree = BT.new(BT.task(SUCCEED), {})
			tree:pause()
			tree:resume()
			expect(tree:isPaused()).is(false)
		end)

		test("paused tree:update() does not tick the task", function()
			local counter = { n = 0 }
			local tree = BT.new(BT.task(counting(SUCCESS, counter)), {})
			tree:update()
			expect(counter.n).is(1)
			tree:pause()
			tree:update()
			tree:update()
			expect(counter.n).is(1)
		end)

		test("paused tree:update() returns last status", function()
			local tree = BT.new(BT.task(SUCCEED), {})
			local status = tree:update()
			expect(status).is(SUCCESS)
			tree:pause()
			local pausedStatus = tree:update()
			expect(pausedStatus).is(SUCCESS)
		end)

		test("resumed tree ticks normally again", function()
			local counter = { n = 0 }
			local tree = BT.new(BT.task(counting(SUCCESS, counter)), {})
			tree:update()
			expect(counter.n).is(1)
			tree:pause()
			tree:update()
			expect(counter.n).is(1)
			tree:resume()
			tree:update()
			expect(counter.n).is(2)
		end)

		test("debug snapshot paused flag reflects tree state", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local _, snap1 = tree:update()
			expect(snap1.paused).is(false)
			tree:pause()
			local _, snap2 = tree:update()
			expect(snap2.paused).is(true)
			tree:resume()
			local _, snap3 = tree:update()
			expect(snap3.paused).is(false)
		end)

		test("paused tree preserves tick count in debug snapshot", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local _, snap1 = tree:update()
			local tickBefore = snap1.tick
			tree:pause()
			local _, snap2 = tree:update()
			local _, snap3 = tree:update()
			expect(snap2.tick).is(tickBefore)
			expect(snap3.tick).is(tickBefore)
		end)
	end)
end
