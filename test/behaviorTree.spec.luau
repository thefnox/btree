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
			local params = { speed = 16, nested = { mode = "walk" } }
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
			expect(received.speed).is(16)
			expect(received.nested).is(params.nested)
			expect(received == params).is(false)
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
			expect(type(received)).is("table")
			expect(next(received)).is(nil)
			expect(received == def.params).is(false)
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

		test("snapshot contains runtime-only fields, including task params, but no structural info", function()
			local bb = {}
			local tree = BT.new(BT.task(SUCCEED), bb, true)
			local _, snap = tree:update()
			expect(snap.tick).exists()
			expect(snap.paused).exists()
			expect(snap.nodeStates).exists()
			expect(snap.taskParams).exists()
			-- Must NOT contain structural fields
			expect(snap.nodes).never_exists()
			expect(snap.definition).never_exists()
			expect(snap.paramTypes).never_exists()
			expect(snap.lastStatus).never_exists()
		end)

		test("snapshot includes resolved task params for the tasks visited in the last update", function()
			local bb = { speed = 8 }
			local taskDef = BT.task({
				params = { speed = "number", missing = "string" },
				run = function()
					return SUCCESS
				end,
			}, {
				speed = BT.bind("speed"),
			})
			local tree = BT.new(taskDef, bb, true)
			local _, snap = tree:update()
			expect(snap.taskParams[1].speed).is(8)
			expect(snap.taskParams[1].missing).is("nil")
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
	-- per-frame execution trace
	--
	-- These tests guarantee that the debug callback produces a complete trace
	-- every frame: every node visited during a tick shows up in the accumulator
	-- with its terminal status for that tick. This is the invariant the Roblox
	-- wrapper (init.lua) relies on when it assembles the BTDebugSnapshot
	-- payload with `nodeStates[nodeIndex] = status`.
	--
	-- Covers:
	--   - long-running tasks that return RUNNING across many frames
	--   - single frames where many nodes succeed/fail before the tree settles
	--   - selector/sequence fall-through (short-circuit) bookkeeping
	--   - yielding tasks whose run() spans a scheduler step
	------------------------------------------------------------------------

	describe("per-frame execution trace", function()
		-- Mirrors the wrapper's accumulator in init.lua so these tests prove
		-- the exact pipeline the debug event fires each frame. Returns the
		-- accumulated {nodeIndex = status} map and the ordered list of
		-- (node, status) pairs as emitted by the callback.
		local function tickWithTrace(tree: BT.Tree)
			local nodeStates: { [number]: BT.Status } = {}
			local events: { { node: number, status: BT.Status } } = {}
			local status, snap = tree:update(function(nodeIndex, s)
				nodeStates[nodeIndex] = s
				table.insert(events, { node = nodeIndex, status = s })
			end)
			return { nodeStates = nodeStates, events = events, status = status, snap = snap }
		end

		test("captures every visited node with its terminal status when all children succeed in one frame", function()
			-- Sequence(1) -> task(2), task(3), task(4) with all three succeeding
			-- within a single tick. All four DFS indices must appear in the
			-- accumulator with SUCCESS.
			local tree = BT.new(BT.sequence({ BT.task(SUCCEED), BT.task(SUCCEED), BT.task(SUCCEED) }), {}, true)
			local frame = tickWithTrace(tree)
			expect(frame.status).is(SUCCESS)
			expect(frame.nodeStates[1]).is(SUCCESS)
			expect(frame.nodeStates[2]).is(SUCCESS)
			expect(frame.nodeStates[3]).is(SUCCESS)
			expect(frame.nodeStates[4]).is(SUCCESS)
		end)

		test("captures each completion when a selector falls through multiple failing children before succeeding", function()
			-- Selector(1) -> task FAIL (2), task FAIL (3), task SUCCEED (4).
			-- All three children are visited in a single tick; their
			-- terminal statuses must all be present alongside the selector's
			-- SUCCESS.
			local tree = BT.new(BT.selector({ BT.task(FAIL), BT.task(FAIL), BT.task(SUCCEED) }), {}, true)
			local frame = tickWithTrace(tree)
			expect(frame.status).is(SUCCESS)
			expect(frame.nodeStates[1]).is(SUCCESS)
			expect(frame.nodeStates[2]).is(FAILURE)
			expect(frame.nodeStates[3]).is(FAILURE)
			expect(frame.nodeStates[4]).is(SUCCESS)
		end)

		test("does not include nodes that were short-circuited away in a sequence", function()
			-- Sequence(1) -> task FAIL (2), task SUCCEED (3). Node 3 must not
			-- appear in the trace because the sequence bailed on node 2.
			local tree = BT.new(BT.sequence({ BT.task(FAIL), BT.task(SUCCEED) }), {}, true)
			local frame = tickWithTrace(tree)
			expect(frame.status).is(FAILURE)
			expect(frame.nodeStates[1]).is(FAILURE)
			expect(frame.nodeStates[2]).is(FAILURE)
			expect(frame.nodeStates[3]).never_exists()
		end)

		test("does not include nodes that were short-circuited away in a selector", function()
			-- Selector(1) -> task SUCCEED (2), task SUCCEED (3). Node 3 must
			-- not appear in the trace because the selector bailed on node 2.
			local tree = BT.new(BT.selector({ BT.task(SUCCEED), BT.task(SUCCEED) }), {}, true)
			local frame = tickWithTrace(tree)
			expect(frame.status).is(SUCCESS)
			expect(frame.nodeStates[1]).is(SUCCESS)
			expect(frame.nodeStates[2]).is(SUCCESS)
			expect(frame.nodeStates[3]).never_exists()
		end)

		test("long-running task: records RUNNING for every active node on every frame", function()
			-- Sequence(1) -> task SUCCEED (2), long-running task (3). Once
			-- the sequence settles onto the long task, every subsequent
			-- frame must record sequence + running task (and never omit them).
			local tickCount = 0
			local longTask: BT.BTreeTask = {
				run = function()
					tickCount += 1
					return if tickCount < 5 then RUNNING else SUCCESS
				end,
			}
			local tree = BT.new(BT.sequence({ BT.task(SUCCEED), BT.task(longTask) }), {}, true)

			-- Frame 1: task(2) succeeds, task(3) first tick — must include all three.
			local f1 = tickWithTrace(tree)
			expect(f1.status).is(RUNNING)
			expect(f1.nodeStates[1]).is(RUNNING)
			expect(f1.nodeStates[2]).is(SUCCESS)
			expect(f1.nodeStates[3]).is(RUNNING)

			-- Frames 2..4: the sequence parks on task(3). Task(2) has already
			-- succeeded and is not re-ticked, so it must NOT appear — but
			-- sequence(1) and task(3) MUST appear each frame with RUNNING.
			for _ = 2, 4 do
				local f = tickWithTrace(tree)
				expect(f.status).is(RUNNING)
				expect(f.nodeStates[1]).is(RUNNING)
				expect(f.nodeStates[2]).never_exists()
				expect(f.nodeStates[3]).is(RUNNING)
			end

			-- Final frame: task(3) terminates with SUCCESS. Sequence settles.
			local fLast = tickWithTrace(tree)
			expect(fLast.status).is(SUCCESS)
			expect(fLast.nodeStates[1]).is(SUCCESS)
			expect(fLast.nodeStates[2]).never_exists()
			expect(fLast.nodeStates[3]).is(SUCCESS)
		end)

		test("selector fall-through: frame 1 visits everything, frame 2 only the running branch", function()
			-- Shape approximates the user's tree: selector of three sequences,
			-- the first two fail fast, the third parks on a long-running task.
			--
			-- Layout of DFS indices:
			--   1  selector
			--   2    sequence#1
			--   3      task FAIL     (guard fails)
			--   4    sequence#2
			--   5      task FAIL     (guard fails)
			--   6    sequence#3
			--   7      long-running task
			local longTickCount = 0
			local longTask: BT.BTreeTask = {
				run = function()
					longTickCount += 1
					return if longTickCount < 3 then RUNNING else SUCCESS
				end,
			}
			local tree = BT.new(
				BT.selector({
					BT.sequence({ BT.task(FAIL) }),
					BT.sequence({ BT.task(FAIL) }),
					BT.sequence({ BT.task(longTask) }),
				}),
				{},
				true
			)

			-- Frame 1: every node along the path must be present.
			local f1 = tickWithTrace(tree)
			expect(f1.status).is(RUNNING)
			expect(f1.nodeStates[1]).is(RUNNING)
			expect(f1.nodeStates[2]).is(FAILURE)
			expect(f1.nodeStates[3]).is(FAILURE)
			expect(f1.nodeStates[4]).is(FAILURE)
			expect(f1.nodeStates[5]).is(FAILURE)
			expect(f1.nodeStates[6]).is(RUNNING)
			expect(f1.nodeStates[7]).is(RUNNING)

			-- Frame 2: selector parks on sequence#3, so only nodes 1, 6, 7
			-- should appear. The previously-failed branches must not leak
			-- into this frame's trace.
			local f2 = tickWithTrace(tree)
			expect(f2.nodeStates[1]).is(RUNNING)
			expect(f2.nodeStates[2]).never_exists()
			expect(f2.nodeStates[3]).never_exists()
			expect(f2.nodeStates[4]).never_exists()
			expect(f2.nodeStates[5]).never_exists()
			expect(f2.nodeStates[6]).is(RUNNING)
			expect(f2.nodeStates[7]).is(RUNNING)

			-- Frame 3: the long task succeeds, so sequence#3 and the
			-- selector both settle. Still only the active branch appears.
			local f3 = tickWithTrace(tree)
			expect(f3.status).is(SUCCESS)
			expect(f3.nodeStates[1]).is(SUCCESS)
			expect(f3.nodeStates[2]).never_exists()
			expect(f3.nodeStates[3]).never_exists()
			expect(f3.nodeStates[4]).never_exists()
			expect(f3.nodeStates[5]).never_exists()
			expect(f3.nodeStates[6]).is(SUCCESS)
			expect(f3.nodeStates[7]).is(SUCCESS)
		end)

		test("each callback invocation is paired (RUNNING before, terminal after) for every visited node", function()
			-- Selector of a failing branch and a succeeding branch. For every
			-- visited node we expect exactly one RUNNING "enter" event and
			-- exactly one "exit" event carrying its terminal status.
			local tree = BT.new(
				BT.selector({
					BT.sequence({ BT.task(FAIL), BT.task(SUCCEED) }),
					BT.sequence({ BT.task(SUCCEED), BT.task(SUCCEED) }),
				}),
				{},
				true
			)
			local frame = tickWithTrace(tree)

			local enters: { [number]: number } = {}
			local exits: { [number]: BT.Status } = {}
			for _, ev in frame.events do
				if enters[ev.node] == nil then
					-- First event for this node must be RUNNING (the "before" call).
					expect(ev.status).is(RUNNING)
					enters[ev.node] = 1
				else
					-- Second event for this node is its terminal status.
					expect(exits[ev.node]).never_exists()
					exits[ev.node] = ev.status
				end
			end

			-- Every node that was entered must also have been exited.
			for node in enters do
				expect(exits[node]).exists()
				-- The terminal status recorded in the events log must match
				-- what the accumulator saved for the snapshot.
				expect(exits[node]).is(frame.nodeStates[node])
			end

			-- Node indices that must have been visited: selector(1),
			-- sequence#1(2), task-FAIL(3), sequence#2(5), task-SUCCEED(6),
			-- task-SUCCEED(7). Node 4 (the second task of the failing
			-- sequence) must NOT be visited.
			for _, idx in { 1, 2, 3, 5, 6, 7 } do
				expect(enters[idx]).exists()
				expect(exits[idx]).exists()
			end
			expect(enters[4]).never_exists()
			expect(exits[4]).never_exists()
		end)

		test("repeated node: each internal iteration only contributes one terminal status per frame", function()
			-- repeat(3) -> task SUCCEED. The child succeeds once per tick. The
			-- accumulator must still report the child's final status on every
			-- tick — never an intermediate or stale value.
			local tree = BT.new(BT.repeatNode(BT.task(SUCCEED), 3), {}, true)

			for _ = 1, 2 do
				local f = tickWithTrace(tree)
				expect(f.status).is(RUNNING)
				expect(f.nodeStates[1]).is(RUNNING) -- repeat still pending
				expect(f.nodeStates[2]).is(SUCCESS) -- child completed this tick
			end

			local fLast = tickWithTrace(tree)
			expect(fLast.status).is(SUCCESS)
			expect(fLast.nodeStates[1]).is(SUCCESS)
			expect(fLast.nodeStates[2]).is(SUCCESS)
		end)

		test("parallel: every child visited in a frame appears in the trace", function()
			-- Parallel(1) with three children, two succeed, one fails. With
			-- the default requireOne failure policy the parallel terminates
			-- this tick. All three children are ticked in this frame and must
			-- appear in the trace alongside the parallel itself.
			local tree = BT.new(BT.parallel({ BT.task(SUCCEED), BT.task(FAIL), BT.task(SUCCEED) }), {}, true)
			local frame = tickWithTrace(tree)
			expect(frame.nodeStates[1]).exists()
			expect(frame.nodeStates[2]).is(SUCCESS)
			expect(frame.nodeStates[3]).is(FAILURE)
			expect(frame.nodeStates[4]).is(SUCCESS)
		end)

		test("trace is complete across a task.wait() yield inside run()", function()
			-- A yielding run() suspends tree:update() between the "before" and
			-- "after" callback calls. After the scheduler resumes, the trace
			-- must still contain both halves — the sequence's enter, the
			-- task's enter and terminal status, and the sequence's exit.
			local captured: { nodeStates: { [number]: BT.Status }?, events: any } = { nodeStates = nil, events = nil }
			local resultStatus: BT.Status = BT.RUNNING

			task.spawn(function()
				local tree = BT.new(
					BT.sequence({
						BT.task({
							run = function()
								task.wait(YIELD_DUR)
								return BT.SUCCESS
							end,
						}),
					}),
					{},
					true
				)
				local frame = tickWithTrace(tree)
				captured.nodeStates = frame.nodeStates
				captured.events = frame.events
				resultStatus = frame.status
			end)

			-- Before the yield resolves the coroutine is parked inside run().
			-- The trace should have only the "enters" so far.
			expect(captured.nodeStates).never_exists()

			task.wait(SYNC_DUR)

			expect(resultStatus).is(BT.SUCCESS)
			expect(captured.nodeStates).exists()
			expect(captured.nodeStates[1]).is(SUCCESS) -- sequence
			expect(captured.nodeStates[2]).is(SUCCESS) -- task
		end)

		test("full trace of a repeated failure-then-rerun across frames preserves every node each frame", function()
			-- A sequence with a guard that fails the first tick and succeeds
			-- thereafter. Frame 1: guard(3) fails so sequence(2) fails; the
			-- selector(1) keeps searching. Frame 2: guard now succeeds, so
			-- the sequence goes all the way through. In both frames the trace
			-- must include every node that was actually visited that frame.
			local guardSucceeds = false
			local guardFiredOnce = false
			local guard: BT.BTreeTask = {
				run = function()
					if not guardFiredOnce then
						guardFiredOnce = true
						return FAILURE
					end
					return if guardSucceeds then SUCCESS else FAILURE
				end,
			}

			local tree = BT.new(
				BT.selector({
					BT.sequence({ BT.task(guard), BT.task(SUCCEED) }),
					BT.task(SUCCEED),
				}),
				{},
				true
			)

			local f1 = tickWithTrace(tree)
			expect(f1.status).is(SUCCESS)
			expect(f1.nodeStates[1]).is(SUCCESS) -- selector
			expect(f1.nodeStates[2]).is(FAILURE) -- sequence#1
			expect(f1.nodeStates[3]).is(FAILURE) -- guard
			expect(f1.nodeStates[4]).never_exists() -- sibling inside sequence#1 was short-circuited
			expect(f1.nodeStates[5]).is(SUCCESS) -- fallback task

			-- Flip the guard so the first branch wins on the next frame.
			guardSucceeds = true
			local f2 = tickWithTrace(tree)
			expect(f2.status).is(SUCCESS)
			expect(f2.nodeStates[1]).is(SUCCESS)
			expect(f2.nodeStates[2]).is(SUCCESS)
			expect(f2.nodeStates[3]).is(SUCCESS)
			expect(f2.nodeStates[4]).is(SUCCESS)
			expect(f2.nodeStates[5]).never_exists() -- selector short-circuited after sequence#1 succeeded
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

		test("BT.bind resolves simple, nested, numeric, and missing paths nil-safely", function()
			local received: any = nil
			local bb = {
				target = "orc",
				squad = {
					members = {
						{
							order = {
								params = "hold",
							},
						},
					},
				},
				blocker = 8,
			}
			BT.new(
				BT.task({
					run = function(_, p)
						received = p
						return SUCCESS
					end,
				}, {
					direct = BT.bind("target"),
					nested = BT.bind("squad.members.1.order.params"),
					missing = BT.bind("squad.members.2.order.params"),
					blocked = BT.bind("blocker.order"),
				}),
				bb
			):update()
			expect(received.direct).is("orc")
			expect(received.nested).is("hold")
			expect(received.missing).is(nil)
			expect(received.blocked).is(nil)
		end)

		test("BT.bind rejects empty and malformed paths", function()
			expect(function()
				BT.bind("")
			end).fails()
			expect(function()
				BT.bind("squad..order")
			end).fails()
		end)

		test("BT.bind re-resolves and creates new params after completed executions", function()
			local bb = { speed = 8 }
			local captures: { any } = {}
			local tree = BT.new(
				BT.task({
					run = function(_, p)
						table.insert(captures, p)
						return SUCCESS
					end,
				}, {
					speed = BT.bind("speed"),
				}),
				bb
			)
			tree:update()
			bb.speed = 20
			tree:update()
			expect(#captures).is(2)
			expect(captures[1] == captures[2]).is(false)
			expect(captures[1].speed).is(8)
			expect(captures[2].speed).is(20)
		end)

		test("BT.bind keeps params stable while the previous execution is RUNNING", function()
			local bb = { speed = 8 }
			local captures: { any } = {}
			local ticks = 0
			local tree = BT.new(
				BT.task({
					run = function(_, p)
						ticks += 1
						table.insert(captures, p)
						if ticks == 1 then
							bb.speed = 20
							return RUNNING
						end
						return SUCCESS
					end,
				}, {
					speed = BT.bind("speed"),
				}),
				bb
			)
			tree:update()
			tree:update()
			expect(#captures).is(2)
			expect(captures[1] == captures[2]).is(true)
			expect(captures[1].speed).is(8)
			expect(captures[2].speed).is(8)
		end)

		test("BT.calc resolves once per activation and stays stable across RUNNING ticks", function()
			local bb = { speed = 8 }
			local calcCount = 0
			local firstParams: any = nil
			local secondParams: any = nil
			local ticks = 0
			local tree = BT.new(
				BT.task({
					run = function(_, p)
						ticks += 1
						if ticks == 1 then
							firstParams = p
							bb.speed = 32
							return RUNNING
						end
						secondParams = p
						return SUCCESS
					end,
				}, {
					speed = BT.calc(function(currentBb)
						calcCount += 1
						return currentBb.speed
					end),
				}),
				bb
			)
			tree:update()
			tree:update()
			expect(calcCount).is(1)
			expect(firstParams == secondParams).is(true)
			expect(firstParams.speed).is(8)
			expect(secondParams.speed).is(8)
		end)

		test("task hooks receive the same resolved params table for the full activation", function()
			local enterBb: any = nil
			local enterParams: any = nil
			local startParams: any = nil
			local runParams: any = nil
			local endParams: any = nil
			local leaveBb: any = nil
			local leaveParams: any = nil
			local flag = true
			local bb = { marker = true, speed = 8 }
			local def = BT.sequence({
				BT.condition(function()
					return flag
				end),
				BT.task({
					onEnter = function(b, p)
						enterBb = b
						enterParams = p
					end,
					onStart = function(_, p)
						startParams = p
					end,
					onExit = function(b, p)
						leaveBb = b
						leaveParams = p
					end,
					run = function(_, p)
						runParams = p
						return SUCCESS
					end,
					onEnd = function(_, p)
						endParams = p
					end,
				}, {
					speed = BT.bind("speed"),
					label = BT.calc(function(currentBb)
						return `speed:{currentBb.speed}`
					end),
				}),
			})
			local tree = BT.new(def, bb)
			tree:update()
			bb.speed = 20
			flag = false
			tree:update()
			expect(enterBb).is(bb)
			expect(leaveBb).is(bb)
			expect(enterParams == startParams).is(true)
			expect(startParams == runParams).is(true)
			expect(runParams == endParams).is(true)
			expect(endParams == leaveParams).is(true)
			expect(leaveParams.speed).is(8)
			expect(leaveParams.label).is("speed:8")
		end)

		test("reset clears cached params so the next activation re-resolves", function()
			local bb = { speed = 8 }
			local captures: { any } = {}
			local tree = BT.new(
				BT.task({
					run = function(_, p)
						table.insert(captures, p)
						return SUCCESS
					end,
				}, {
					speed = BT.bind("speed"),
				}),
				bb
			)
			tree:update()
			bb.speed = 20
			tree:reset()
			tree:update()
			expect(#captures).is(2)
			expect(captures[1] == captures[2]).is(false)
			expect(captures[1].speed).is(8)
			expect(captures[2].speed).is(20)
		end)

		test("stop clears cached params so the next activation re-resolves", function()
			local bb = { speed = 8 }
			local captures: { any } = {}
			local tree = BT.new(
				BT.task({
					run = function(_, p)
						table.insert(captures, p)
						return RUNNING
					end,
				}, {
					speed = BT.bind("speed"),
				}),
				bb
			)
			tree:update()
			bb.speed = 20
			tree:stop()
			tree:update()
			expect(#captures).is(2)
			expect(captures[1] == captures[2]).is(false)
			expect(captures[1].speed).is(8)
			expect(captures[2].speed).is(20)
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
	-- task param bindings
	------------------------------------------------------------------------

	describe("task param bindings", function()
		test("legacy module params schemas are accepted as a no-op", function()
			local schema: BT.ParamTypes = { speed = "number" }
			local m: BT.BTreeTask = {
				params = schema,
				run = function(_, p)
					expect(p.speed).is("fast")
					return SUCCESS
				end,
			}
			expect(function()
				BT.new(BT.task(m, { speed = "fast" }), {}):update()
			end).never_fails()
			expect(m.params).is(schema)
		end)

		test("bare top-level function params must be wrapped in BT.calc", function()
			expect(function()
				BT.task(SUCCEED, {
					speed = function()
						return 8
					end,
				})
			end).fails_with("BT.calc")
		end)

		test("nested tables stay literal and are not recursively resolved", function()
			local received: any = nil
			local nested = {
				speed = BT.bind("speed"),
			}
			local bb = { speed = 8 }
			BT.new(
				BT.task({
					run = function(_, p)
						received = p
						return SUCCESS
					end,
				}, {
					nested = nested,
				}),
				bb
			):update()
			expect(received.nested).is(nested)
			expect(type(received.nested.speed)).is("table")
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
