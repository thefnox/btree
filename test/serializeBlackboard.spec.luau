-- Unit tests for lib/behaviorTree/serializeBlackboard.lua

local serializeBlackboard = require("../lib/behaviorTree/serializeBlackboard")

type tiniest_actual = typeof(require("../tiniest/tiniest_for_lune").configure({}))

return function(tiniest: tiniest_actual)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("serializeBlackboard", function()
		test("keeps primitive values typed", function()
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

		test("skips function and thread values", function()
			local bb = { fn = function() end, co = coroutine.create(function() end), x = 1 }
			local result = serializeBlackboard(bb)
			expect(result.fn).is(nil)
			expect(result.co).is(nil)
			expect(result.x).is(1)
		end)

		test("flattens top-level tables to a single-line string", function()
			local bb = { target = { active = true, id = 42 } }
			local result = serializeBlackboard(bb)
			expect(result.target).is(`\{active = true, id = 42\}`)
		end)

		test("formats nested tables recursively with sorted keys", function()
			local bb = { target = { id = 42, active = true, meta = { tier = 3 } } }
			local result = serializeBlackboard(bb)
			-- Keys sorted alphabetically at each level so same contents → same string.
			expect(result.target).is(`\{active = true, id = 42, meta = \{tier = 3\}\}`)
		end)

		test("same table contents in different insertion orders produce equal strings", function()
			local a = serializeBlackboard({ data = { z = 1, a = 2 } })
			local b = serializeBlackboard({ data = { a = 2, z = 1 } })
			expect(a.data).is(b.data)
		end)

		test("replaces direct self-reference with [Circular]", function()
			local bb: any = { hp = 10 }
			bb.self = bb
			local result = serializeBlackboard(bb)
			expect(result.hp).is(10)
			expect(result.self).is("[Circular]")
		end)

		test("replaces indirect cycle with [Circular]", function()
			-- a -> next -> b -> prev -> a
			local a: any = { label = "a" }
			local b: any = { label = "b" }
			a.next = b
			b.prev = a
			local result = serializeBlackboard(a)
			-- a is visited at the top level, so when we reach b.prev we produce [Circular].
			expect(result.label).is("a")
			expect(result.next).is(`\{label = "b", prev = [Circular]\}`)
		end)

		test("serialized strings are quoted to distinguish from identifiers", function()
			local bb = { payload = { kind = "greeting" } }
			local result = serializeBlackboard(bb)
			expect(result.payload).is(`\{kind = "greeting"\}`)
		end)
	end)
end
