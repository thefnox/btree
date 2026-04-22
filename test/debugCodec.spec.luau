--!strict
-- Tests for lib/behaviorTree/debugCodec.lua.
-- Only primitive, Roblox-free value types are exercised here (boolean, number,
-- string, tostring-fallback). The encoder also supports Vector3/Vector2/
-- Color3/CFrame values, but those constructors don't exist in the Lune
-- environment; a Roblox-side smoke test would cover them.

local codec = require("../lib/behaviorTree/debugCodec")

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("tree definition roundtrip", function()
		test("single condition, full server response path", function()
			local def = { _type = "condition", check = function()
				return true
			end, meta = { label = "leaf" } }
			local defBuf = codec.encodeTreeDefinition(def)
			local response = codec.buildTreeDefinitionResponse(42, defBuf)
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.treeId).is(42)
			expect(#decoded.nodes).is(1)
			expect(decoded.nodes[1].type).is("condition")
			expect(decoded.nodes[1].label).is("leaf")
			expect(decoded.nodes[1].singleChild).is(0)
			expect(#decoded.nodes[1].children).is(0)
		end)

		test("empty response for unknown tree", function()
			local response = codec.buildEmptyTreeDefinitionResponse()
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.treeId).is(0)
			expect(#decoded.nodes).is(0)
		end)

		test("sequence with three children preserves DFS order", function()
			local childA = { _type = "condition", check = function()
				return true
			end, meta = { label = "A" } }
			local childB = { _type = "condition", check = function()
				return false
			end, meta = { label = "B" } }
			local childC = { _type = "condition", check = function()
				return true
			end, meta = { label = "C" } }
			local root = {
				_type = "sequence",
				children = { childA, childB, childC },
				meta = { label = "root" },
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(root))
			local decoded = codec.decodeTreeDefinition(response)
			expect(#decoded.nodes).is(4)
			expect(decoded.nodes[1].type).is("sequence")
			expect(decoded.nodes[1].children[1]).is(2)
			expect(decoded.nodes[1].children[2]).is(3)
			expect(decoded.nodes[1].children[3]).is(4)
			expect(decoded.nodes[2].label).is("A")
			expect(decoded.nodes[3].label).is("B")
			expect(decoded.nodes[4].label).is("C")
		end)

		test("decorator encodes singleChild", function()
			local inner = { _type = "condition", check = function()
				return true
			end }
			local root = {
				_type = "invert",
				child = inner,
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(root))
			local decoded = codec.decodeTreeDefinition(response)
			expect(#decoded.nodes).is(2)
			expect(decoded.nodes[1].type).is("invert")
			expect(decoded.nodes[1].singleChild).is(2)
			expect(#decoded.nodes[1].children).is(0)
			expect(decoded.nodes[2].type).is("condition")
		end)

		test("parallel stores success and failure policies", function()
			local def = {
				_type = "parallel",
				successPolicy = "requireOne",
				failurePolicy = "requireAll",
				children = { { _type = "condition", check = function()
					return true
				end } },
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(def))
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.nodes[1].successPolicy).is("requireOne")
			expect(decoded.nodes[1].failurePolicy).is("requireAll")
		end)

		test("repeat stores times including -1 sentinel", function()
			local def = {
				_type = "repeat",
				times = -1,
				child = { _type = "condition", check = function()
					return true
				end },
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(def))
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.nodes[1].type).is("repeat")
			expect(decoded.nodes[1].times).is(-1)
		end)

		test("task with params encodes name and values", function()
			local def = {
				_type = "task",
				module = {
					name = "PatrolMove",
					run = function()
						return 0
					end,
				},
				params = { speed = 14, message = "hello" },
			}
			local response = codec.buildTreeDefinitionResponse(7, codec.encodeTreeDefinition(def))
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.treeId).is(7)
			expect(decoded.nodes[1].type).is("task")
			expect(decoded.nodes[1].taskName).is("PatrolMove")
			expect(decoded.nodes[1].taskParams ~= nil).is(true)
			local params = decoded.nodes[1].taskParams :: { [string]: any }
			expect(params.speed).is(14)
			expect(params.message).is("hello")
		end)

		test("random selector encodes weights when present", function()
			local def = {
				_type = "randomSelector",
				children = {
					{ _type = "condition", check = function()
						return true
					end },
					{ _type = "condition", check = function()
						return true
					end },
				},
				weights = { 0.25, 0.75 },
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(def))
			local decoded = codec.decodeTreeDefinition(response)
			expect(decoded.nodes[1].weights ~= nil).is(true)
			local weights = decoded.nodes[1].weights :: { number }
			expect(#weights).is(2)
			-- f32 roundtrip introduces minor precision loss; compare with epsilon.
			expect(math.abs(weights[1] - 0.25) < 1e-6).is(true)
			expect(math.abs(weights[2] - 0.75) < 1e-6).is(true)
		end)

		test("subtree inlines the referenced definition as a singleChild", function()
			local sub = {
				_type = "sequence",
				children = {
					{ _type = "condition", check = function()
						return true
					end, meta = { label = "inner" } },
				},
			}
			local def = {
				_type = "subtree",
				module = sub,
			}
			local response = codec.buildTreeDefinitionResponse(1, codec.encodeTreeDefinition(def))
			local decoded = codec.decodeTreeDefinition(response)
			expect(#decoded.nodes).is(3) -- subtree + sequence + condition
			expect(decoded.nodes[1].type).is("subtree")
			expect(decoded.nodes[1].singleChild).is(2)
			expect(decoded.nodes[2].type).is("sequence")
			expect(decoded.nodes[3].label).is("inner")
		end)
	end)

	describe("tree list roundtrip", function()
		test("encodes and decodes a list of trees", function()
			local list = {
				{ id = 1, executionCount = 100, debugName = "alpha", definitionPath = "a/b" },
				{ id = 2, executionCount = 5, debugName = "beta", definitionPath = "" },
			}
			local buf = codec.encodeTreeList(list)
			local decoded = codec.decodeTreeList(buf)
			expect(#decoded).is(2)
			expect(decoded[1].id).is(1)
			expect(decoded[1].executionCount).is(100)
			expect(decoded[1].debugName).is("alpha")
			expect(decoded[1].definitionPath).is("a/b")
			expect(decoded[2].id).is(2)
			expect(decoded[2].debugName).is("beta")
			expect(decoded[2].definitionPath).is("")
		end)

		test("encodes an empty list", function()
			local buf = codec.encodeTreeList({})
			local decoded = codec.decodeTreeList(buf)
			expect(#decoded).is(0)
		end)
	end)

	describe("subscribe request codec", function()
		test("roundtrips subscribe=true", function()
			local buf = codec.encodeSubscribe(42, true)
			local parsed = codec.decodeSubscribe(buf)
			expect(parsed ~= nil).is(true)
			local p = parsed :: any
			expect(p.treeId).is(42)
			expect(p.subscribe).is(true)
		end)

		test("roundtrips subscribe=false", function()
			local buf = codec.encodeSubscribe(99, false)
			local parsed = codec.decodeSubscribe(buf) :: any
			expect(parsed.treeId).is(99)
			expect(parsed.subscribe).is(false)
		end)

		test("rejects short buffers", function()
			local tiny = buffer.create(2)
			expect(codec.decodeSubscribe(tiny) == nil).is(true)
		end)
	end)

	describe("pause request codec", function()
		test("roundtrips pause=true", function()
			local buf = codec.encodePauseRequest(42, true)
			local parsed = codec.decodePauseRequest(buf)
			expect(parsed ~= nil).is(true)
			local p = parsed :: any
			expect(p.treeId).is(42)
			expect(p.paused).is(true)
		end)

		test("roundtrips pause=false", function()
			local buf = codec.encodePauseRequest(99, false)
			local parsed = codec.decodePauseRequest(buf) :: any
			expect(parsed.treeId).is(99)
			expect(parsed.paused).is(false)
		end)

		test("rejects short buffers", function()
			local tiny = buffer.create(2)
			expect(codec.decodePauseRequest(tiny) == nil).is(true)
		end)
	end)

	describe("tree-definition request codec", function()
		test("roundtrips treeId", function()
			local buf = codec.encodeTreeDefinitionRequest(7)
			expect(codec.decodeTreeDefinitionRequest(buf)).is(7)
		end)

		test("rejects short buffers", function()
			local tiny = buffer.create(2)
			expect(codec.decodeTreeDefinitionRequest(tiny) == nil).is(true)
		end)
	end)

	describe("snapshot roundtrip", function()
		test("full snapshot roundtrips node states and primitive blackboard values", function()
			local frame = {
				treeId = 3,
				tick = 12,
				paused = false,
				nodeStates = { [1] = 0, [2] = 1, [3] = 2 },
				blackboard = {
					alerted = true,
					speed = 14.5,
					name = "sentry",
					disabled = false,
				},
			}
			local buf = codec.encodeFullSnapshot(frame)
			local decoded = codec.decodeSnapshot(buf)
			expect(decoded.kind).is("full")
			expect(decoded.treeId).is(3)
			expect(decoded.tick).is(12)
			expect(decoded.paused).is(false)
			expect(decoded.nodeStates[1]).is(0)
			expect(decoded.nodeStates[2]).is(1)
			expect(decoded.nodeStates[3]).is(2)
			expect(decoded.blackboardSet.alerted).is(true)
			expect(decoded.blackboardSet.speed).is(14.5)
			expect(decoded.blackboardSet.name).is("sentry")
			expect(decoded.blackboardSet.disabled).is(false)
			expect(#decoded.blackboardRemoved).is(0)
		end)

		test("paused flag is preserved", function()
			local frame = {
				treeId = 1,
				tick = 0,
				paused = true,
				nodeStates = {},
				blackboard = {},
			}
			local decoded = codec.decodeSnapshot(codec.encodeFullSnapshot(frame))
			expect(decoded.paused).is(true)
		end)

		test("delta preserves the full visited-node trace even when statuses repeat", function()
			local frame = {
				treeId = 1,
				tick = 2,
				paused = false,
				nodeStates = { [1] = 2, [2] = 0, [3] = 1 },
				blackboard = {},
			}
			local buf = codec.encodeDeltaSnapshot(frame, {})
			local decoded = codec.decodeSnapshot(buf)
			expect(decoded.kind).is("delta")
			-- All three nodes should still appear because nodeStates represents
			-- the full visited-node result of the last update, not a per-node diff.
			local traceCount = 0
			for _ in decoded.nodeStates do
				traceCount += 1
			end
			expect(traceCount).is(3)
			expect(decoded.nodeStates[1]).is(2)
			expect(decoded.nodeStates[2]).is(0)
			expect(decoded.nodeStates[3]).is(1)
		end)

		test("delta emits blackboard set and remove operations", function()
			local frame = {
				treeId = 1,
				tick = 2,
				paused = false,
				nodeStates = {},
				blackboard = {
					alerted = true, -- changed (was false)
					target = "A", -- unchanged
					newKey = 42, -- new key
				},
			}
			local previousBlackboard = {
				alerted = false,
				target = "A",
				staleKey = "gone", -- should be removed
			}
			local buf = codec.encodeDeltaSnapshot(frame, previousBlackboard)
			local decoded = codec.decodeSnapshot(buf)
			expect(decoded.kind).is("delta")
			expect(decoded.blackboardSet.alerted).is(true)
			expect(decoded.blackboardSet.newKey).is(42)
			expect(decoded.blackboardSet.target).is(nil) -- unchanged keys omitted
			expect(#decoded.blackboardRemoved).is(1)
			expect(decoded.blackboardRemoved[1]).is("staleKey")
		end)
	end)

	describe("growable writer", function()
		test("encoded string fields larger than the initial capacity still roundtrip", function()
			-- Force the writer past its default capacity with a big blackboard
			-- string value.
			local big = string.rep("x", 5000)
			local frame = {
				treeId = 1,
				tick = 0,
				paused = false,
				nodeStates = {},
				blackboard = { big = big },
			}
			local decoded = codec.decodeSnapshot(codec.encodeFullSnapshot(frame))
			expect(decoded.blackboardSet.big).is(big)
		end)
	end)
end
