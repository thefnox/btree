-- Unit tests for lib/behaviorTree/serializeBlackboard.lua

local serializeBlackboard = require("../lib/behaviorTree/serializeBlackboard")

type tiniest_actual = typeof(require("../tiniest/tiniest_for_lune").configure({}))

return function(tiniest: tiniest_actual)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("serializeBlackboard", function()
		test("copies primitive values", function()
			local bb = { hp = 100, name = "Guard", alive = true }
			local result = serializeBlackboard(bb)
			expect(result.hp).is(100)
			expect(result.name).is("Guard")
			expect(result.alive).is(true)
		end)

		test("excludes _debugName", function()
			local bb = { _debugName = "TestAgent", hp = 50 }
			local result = serializeBlackboard(bb)
			expect(result._debugName).is(nil)
			expect(result.hp).is(50)
		end)

		test("skips function values", function()
			local bb = { fn = function() end, x = 1 }
			local result = serializeBlackboard(bb)
			expect(result.fn).is(nil)
			expect(result.x).is(1)
		end)

		test("serializes one nested level and stringifies deeper tables", function()
			local deeper = { x = 10 }
			local bb = { target = { id = 42, active = true, deeper = deeper } }
			local result = serializeBlackboard(bb)
			expect(type(result.target)).is("table")
			expect((result.target :: any).id).is(42)
			expect((result.target :: any).active).is(true)
			expect((result.target :: any).deeper).is(tostring(deeper))
		end)

		test("replaces direct self-reference with [Circular]", function()
			local bb: any = { hp = 10 }
			bb.self = bb -- blackboard refers to itself
			local result = serializeBlackboard(bb)
			expect(result.hp).is(10)
			expect(result.self).is("[Circular]")
		end)

		test("stringifies tables beyond the first nested level", function()
			-- Simulates a shared squad blackboard where each member's
			-- blackboard holds a reference back to the squad blackboard.
			local squadBB: any = { name = "Squad" }
			local member1: any = { role = "Scout" }
			local member2: any = { role = "Gunner" }
			member1.squad = squadBB
			member2.squad = squadBB
			squadBB.members = { member1, member2 }

			local result = serializeBlackboard(squadBB)
			expect(result.name).is("Squad")

			-- Integer keys become string keys after tostring() in serialization
			local members = result.members :: any
			expect(type(members)).is("table")
			expect(members["1"]).is(tostring(member1))
			expect(members["2"]).is(tostring(member2))
		end)

		test("replaces indirect cycle with [Circular]", function()
			-- A -> B -> A
			local a: any = { label = "a" }
			local b: any = { label = "b" }
			a.next = b
			b.prev = a

			local result = serializeBlackboard(a)
			expect(result.label).is("a")
			expect((result.next :: any).label).is("b")
			expect((result.next :: any).prev).is("[Circular]") -- back to a
		end)
	end)
end
