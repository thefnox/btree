-- Regression tests for the Roblox debug wrapper and debugNetwork lifecycle.

local fs = require("@lune/fs")
local task = require("@lune/task")
local debugCodec = require("../lib/behaviorTree/debugCodec")

type tiniest_actual = typeof(require("../tiniest/tiniest_for_lune").configure({}))

local function loadWithEnvironment(path: string, environmentValues: { [string]: any }): any
	local source = fs.readFile(path)
	local chunk, loadError = loadstring(source, "@" .. path)
	assert(chunk ~= nil, loadError)
	local environment = setmetatable(environmentValues, { __index = getfenv() })
	setfenv(chunk :: any, environment)
	return (chunk :: any)()
end

local function newSignal()
	local handlers = {}
	local signal = {}

	function signal:Connect(handler)
		table.insert(handlers, handler)
		return {
			Disconnect = function() end,
		}
	end

	function signal:Fire(...)
		for _, handler in handlers do
			handler(...)
		end
	end

	return signal
end

local function loadDebugNetwork()
	local instances = {}
	local parentInstance = {}

	function parentInstance:FindFirstChild(name: string)
		for _, instance in instances do
			if instance.Name == name and instance.Parent == self then
				return instance
			end
		end
		return nil
	end

	local playerRemoving = newSignal()
	local gameMock = {}
	function gameMock:GetService(name: string)
		if name == "RunService" then
			return {
				IsServer = function()
					return true
				end,
			}
		end
		if name == "Players" then
			return { PlayerRemoving = playerRemoving }
		end
		error("Unexpected service: " .. name)
	end

	local instanceMock = {}
	function instanceMock.new(className: string)
		assert(className == "RemoteEvent")
		local remote = {
			OnServerEvent = newSignal(),
			fired = {},
		}
		function remote:FireClient(player, payload)
			table.insert(self.fired, { player = player, payload = payload })
		end
		table.insert(instances, remote)
		return remote
	end

	local function injectedRequire(path: string)
		if path == "./serializeBlackboard" then
			return require("../lib/behaviorTree/serializeBlackboard")
		end
		if path == "./debugCodec" then
			return debugCodec
		end
		error("Unexpected require: " .. path)
	end

	local network = loadWithEnvironment("lib/behaviorTree/debugNetwork.lua", {
		game = gameMock,
		Instance = instanceMock,
		require = injectedRequire,
		script = { Parent = parentInstance },
	})

	local function getRemote(name: string)
		return parentInstance:FindFirstChild(name)
	end

	return network, getRemote
end

local function forceAutomaticCollection()
	-- Luau only exposes collectgarbage("count"), so force the incremental
	-- collector to complete cycles through bounded allocation pressure.
	for batch = 1, 32 do
		local garbage = table.create(4096)
		for index = 1, 4096 do
			garbage[index] = { batch, index, { index } }
		end
		task.wait(0.001)
	end
end

return function(tiniest: tiniest_actual)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("debug tree lifecycle", function()
		test("registers the runtime-free pause setter without wrapping the tree", function()
			local registeredPauseSetter = nil
			local nativeBT = require("../lib/behaviorTree/behaviorTree")

			local debugNetwork = {
				registerTree = function(_debugName, _definitionPath, _definition, setPaused)
					registeredPauseSetter = setPaused
					return 1
				end,
				onTreeUpdated = function() end,
				requestOpenViewer = function() end,
			}
			local function injectedRequire(path: string)
				if path == "@self/behaviorTree" then
					return nativeBT
				end
				if path == "@self/serializeBlackboard" then
					return function(blackboard)
						return blackboard
					end
				end
				if path == "@self/debugNetwork" then
					return debugNetwork
				end
				error("Unexpected require: " .. path)
			end

			local wrapper = loadWithEnvironment("lib/behaviorTree/init.lua", {
				game = {
					GetService = function()
						return {
							AddTag = function() end,
							RemoveTag = function() end,
						}
					end,
				},
				require = injectedRequire,
				script = {
					FindFirstChild = function()
						return nil
					end,
				},
			})
			local definition = nativeBT.task({
				run = function()
					return nativeBT.RUNNING
				end,
			})
			local tree: any = wrapper.new(definition, { _debugName = "collectable" }, true)

			expect(registeredPauseSetter).is(tree._debugSetPaused)
			local pauseSetter = registeredPauseSetter :: any
			pauseSetter(true)
			expect(tree.isPaused()).is(true)

			local weakTree = setmetatable({ tree }, { __mode = "v" })
			local retainedTree = {}
			local weakRetainedTree = setmetatable({ retainedTree }, { __mode = "v" })
			local function retain(value)
				return function()
					return value
				end
			end
			local retainingSetter = retain(retainedTree)
			tree = nil
			retainedTree = nil

			forceAutomaticCollection()

			expect(weakTree[1]).is(nil)
			expect(weakRetainedTree[1] ~= nil).is(true)
			expect(pcall(pauseSetter, false)).is(true)
			expect(retainingSetter() ~= nil).is(true)
		end)

		test("unregister is idempotent and removes all remote visibility", function()
			local network, getRemote = loadDebugNetwork()
			expect(type(network.unregisterTree)).is("function")

			local pauseValues = {}
			local treeId = network.registerTree("guard", "Server.GuardTree", {
				_type = "condition",
				check = function()
					return true
				end,
			}, function(value)
				table.insert(pauseValues, value)
			end)
			local player = {}
			local treeList = getRemote("DebugTreeList")
			local treeDefinition = getRemote("DebugTreeDefinition")
			local subscribe = getRemote("DebugSubscribe")
			local pause = getRemote("DebugTreePause")
			local snapshot = getRemote("DebugSnapshot")

			treeList.OnServerEvent:Fire(player, buffer.create(0))
			local activeList = debugCodec.decodeTreeList(treeList.fired[#treeList.fired].payload)
			expect(#activeList).is(1)
			expect(activeList[1].id).is(treeId)

			treeDefinition.OnServerEvent:Fire(player, debugCodec.encodeTreeDefinitionRequest(treeId))
			local activeDefinition =
				debugCodec.decodeTreeDefinition(treeDefinition.fired[#treeDefinition.fired].payload)
			expect(activeDefinition.treeId).is(treeId)

			subscribe.OnServerEvent:Fire(player, debugCodec.encodeSubscribe(treeId, true))
			network.onTreeUpdated(treeId, 1, false, { [1] = 0 }, {}, { hp = 100 })
			expect(#snapshot.fired).is(1)
			local activeSnapshot = debugCodec.decodeSnapshot(snapshot.fired[1].payload)
			expect(activeSnapshot.treeId).is(treeId)

			pause.OnServerEvent:Fire(player, debugCodec.encodePauseRequest(treeId, true))
			pause.OnServerEvent:Fire(player, debugCodec.encodePauseRequest(treeId, false))
			expect(#pauseValues).is(2)
			expect(pauseValues[1]).is(true)
			expect(pauseValues[2]).is(false)

			network.unregisterTree(treeId)
			network.unregisterTree(treeId)

			treeList.OnServerEvent:Fire(player, buffer.create(0))
			local disposedList = debugCodec.decodeTreeList(treeList.fired[#treeList.fired].payload)
			expect(#disposedList).is(0)

			treeDefinition.OnServerEvent:Fire(player, debugCodec.encodeTreeDefinitionRequest(treeId))
			local disposedDefinition =
				debugCodec.decodeTreeDefinition(treeDefinition.fired[#treeDefinition.fired].payload)
			expect(disposedDefinition.treeId).is(0)

			local snapshotCount = #snapshot.fired
			network.onTreeUpdated(treeId, 2, false, { [1] = 0 }, {}, { hp = 50 })
			subscribe.OnServerEvent:Fire(player, debugCodec.encodeSubscribe(treeId, true))
			pause.OnServerEvent:Fire(player, debugCodec.encodePauseRequest(treeId, false))
			expect(#snapshot.fired).is(snapshotCount)
			expect(#pauseValues).is(2)
		end)

		test("destroy deregisters a debug tree once", function()
			local unregisterCalls = 0
			local updatedCalls = 0
			local nativeBT = {}
			function nativeBT.new()
				local paused = false
				return {
					update = function()
						return 0, {
							tick = 1,
							paused = paused,
							taskParams = {},
						}
					end,
					pause = function()
						paused = true
					end,
					resume = function()
						paused = false
					end,
					_debugSetPaused = function(value: boolean)
						paused = value
					end,
				}
			end
			local debugNetwork = {
				registerTree = function()
					return 7
				end,
				unregisterTree = function(treeId)
					expect(treeId).is(7)
					unregisterCalls += 1
				end,
				onTreeUpdated = function()
					updatedCalls += 1
				end,
				requestOpenViewer = function() end,
			}
			local function injectedRequire(path: string)
				if path == "@self/behaviorTree" then
					return nativeBT
				end
				if path == "@self/serializeBlackboard" then
					return function(blackboard)
						return blackboard
					end
				end
				if path == "@self/debugNetwork" then
					return debugNetwork
				end
				error("Unexpected require: " .. path)
			end
			local wrapper = loadWithEnvironment("lib/behaviorTree/init.lua", {
				game = {
					GetService = function()
						return {
							AddTag = function() end,
							RemoveTag = function() end,
						}
					end,
				},
				require = injectedRequire,
				script = {
					FindFirstChild = function()
						return nil
					end,
				},
			})
			local tree = wrapper.new({}, {}, true)

			tree:update()
			expect(updatedCalls).is(1)
			expect(type(tree.destroy)).is("function")
			tree:destroy()
			tree:destroy()
			tree:update()

			expect(unregisterCalls).is(1)
			expect(updatedCalls).is(1)
			expect(tree._debugId).is(0)
		end)

		test("tags the debug target with its tree id until destroy", function()
			local target = {
				tags = {},
				attributes = {},
			}
			function target:SetAttribute(name, value)
				self.attributes[name] = value
			end
			function target:GetAttribute(name)
				return self.attributes[name]
			end

			local removeCalls = 0
			local collectionService = {}
			function collectionService:AddTag(instance, tag)
				instance.tags[tag] = true
			end
			function collectionService:RemoveTag(instance, tag)
				removeCalls += 1
				instance.tags[tag] = nil
			end

			local nativeBT = require("../lib/behaviorTree/behaviorTree")
			local debugNetwork = {
				registerTree = function()
					return 19
				end,
				unregisterTree = function() end,
				onTreeUpdated = function() end,
				requestOpenViewer = function() end,
			}
			local function injectedRequire(path: string)
				if path == "@self/behaviorTree" then
					return nativeBT
				end
				if path == "@self/serializeBlackboard" then
					return function(blackboard)
						return blackboard
					end
				end
				if path == "@self/debugNetwork" then
					return debugNetwork
				end
				error("Unexpected require: " .. path)
			end

			local wrapper = loadWithEnvironment("lib/behaviorTree/init.lua", {
				game = {
					GetService = function(_self, serviceName)
						expect(serviceName).is("CollectionService")
						return collectionService
					end,
				},
				require = injectedRequire,
				script = {
					FindFirstChild = function()
						return nil
					end,
				},
			})
			local definition = nativeBT.task({
				run = function()
					return nativeBT.RUNNING
				end,
			})
			local tree = wrapper.new(definition, {}, true, target)

			expect(target.tags["BehaviorTreeDebugTarget"]).is(true)
			expect(target:GetAttribute("BehaviorTreeDebugTreeId")).is(19)

			tree:destroy()
			tree:destroy()

			expect(target.tags["BehaviorTreeDebugTarget"]).is(nil)
			expect(target:GetAttribute("BehaviorTreeDebugTreeId")).is(nil)
			expect(removeCalls).is(1)

			local claimedTarget = {
				tags = {},
				attributes = {},
			}
			function claimedTarget:SetAttribute(name, value)
				self.attributes[name] = value
			end
			function claimedTarget:GetAttribute(name)
				return self.attributes[name]
			end

			local claimedTree = wrapper.new(definition, {}, true, claimedTarget)
			claimedTarget:SetAttribute("BehaviorTreeDebugTreeId", 20)
			claimedTree:destroy()

			expect(claimedTarget.tags["BehaviorTreeDebugTarget"]).is(true)
			expect(claimedTarget:GetAttribute("BehaviorTreeDebugTreeId")).is(20)
			expect(removeCalls).is(1)
		end)

		test("releases an unregistered debug target on destroy", function()
			local nativeBT = require("../lib/behaviorTree/behaviorTree")
			local debugNetwork = {
				registerTree = function()
					return 0
				end,
				unregisterTree = function()
					error("unregistered trees must not be unregistered")
				end,
				onTreeUpdated = function() end,
				requestOpenViewer = function() end,
			}
			local function injectedRequire(path: string)
				if path == "@self/behaviorTree" then
					return nativeBT
				end
				if path == "@self/serializeBlackboard" then
					return function(blackboard)
						return blackboard
					end
				end
				if path == "@self/debugNetwork" then
					return debugNetwork
				end
				error("Unexpected require: " .. path)
			end
			local collectionService = {
				AddTag = function()
					error("unregistered trees must not tag targets")
				end,
				RemoveTag = function()
					error("unregistered trees must not remove target tags")
				end,
			}
			local wrapper = loadWithEnvironment("lib/behaviorTree/init.lua", {
				game = {
					GetService = function(_self, serviceName)
						expect(serviceName).is("CollectionService")
						return collectionService
					end,
				},
				require = injectedRequire,
				script = {
					FindFirstChild = function()
						return nil
					end,
				},
			})
			local definition = nativeBT.task({
				run = function()
					return nativeBT.RUNNING
				end,
			})
			local target = {
				SetAttribute = function()
					error("unregistered trees must not set target attributes")
				end,
			}
			local weakTargets = setmetatable({ target }, { __mode = "v" })
			local tree = wrapper.new(definition, {}, true, target)

			tree:destroy()
			target = nil
			forceAutomaticCollection()

			expect(weakTargets[1]).is(nil)
		end)
	end)
end
