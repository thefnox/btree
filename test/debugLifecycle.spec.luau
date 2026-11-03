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

local function loadDebugNetwork(serializeOverride: ((blackboard: any) -> any)?)
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
			return serializeOverride or require("../lib/behaviorTree/serializeBlackboard")
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

	return network, getRemote, playerRemoving
end

-- Loads the Roblox wrapper over the real native library with a stub debug registry,
-- a counting serializer and an optional legacy BTDebugSnapshot event.
local function loadWrapper(debugNetwork: any, serialize: (blackboard: any) -> any, legacyEvent: any?): any
	local nativeBT = require("../lib/behaviorTree/behaviorTree")
	local function injectedRequire(path: string)
		if path == "@self/behaviorTree" then
			return nativeBT
		end
		if path == "@self/serializeBlackboard" then
			return serialize
		end
		if path == "@self/debugNetwork" then
			return debugNetwork
		end
		error("Unexpected require: " .. path)
	end
	return loadWithEnvironment("lib/behaviorTree/init.lua", {
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
			FindFirstChild = function(_self, name)
				return if name == "BTDebugSnapshot" then legacyEvent else nil
			end,
		},
	})
end

local function newLegacyEvent()
	local attributeChanged = newSignal()
	local legacyEvent = { attributes = {}, fired = 0 }
	function legacyEvent:GetAttribute(name)
		return self.attributes[name]
	end
	function legacyEvent:SetAttribute(name, value)
		self.attributes[name] = value
		attributeChanged:Fire()
	end
	function legacyEvent:GetAttributeChangedSignal()
		return attributeChanged
	end
	function legacyEvent:Fire()
		self.fired += 1
	end
	return legacyEvent
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
					destroy = function() end,
				}
			end
			local debugNetwork = {
				registerTree = function(_debugName, _definitionPath, _definition, _setPaused, setObserved)
					setObserved(true)
					return 7
				end,
				unregisterTree = function(treeId)
					expect(treeId).is(7)
					unregisterCalls += 1
				end,
				onTreeUpdated = function()
					updatedCalls += 1
				end,
				countExecution = function() end,
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

	describe("debug observation gating", function()
		local function countingTask(): any
			local nativeBT = require("../lib/behaviorTree/behaviorTree")
			return nativeBT.task({
				run = function()
					return nativeBT.SUCCESS
				end,
			})
		end

		test("a native debug tree with snapshots disabled skips the snapshot and callback", function()
			local nativeBT = require("../lib/behaviorTree/behaviorTree")
			local tree: any = nativeBT.new(countingTask(), {}, true)
			local callbacks = 0
			local function onNode()
				callbacks += 1
			end

			tree._debugSetSnapshotsEnabled(false)
			local status, snapshot = tree:update(onNode)
			expect(status).is(nativeBT.SUCCESS)
			expect(snapshot).is(nil)
			expect(callbacks).is(0)

			tree:pause()
			local _, pausedSnapshot = tree:update(onNode)
			expect(pausedSnapshot).is(nil)
			tree:resume()

			tree._debugSetSnapshotsEnabled(true)
			local _, enabledSnapshot = tree:update(onNode)
			expect(enabledSnapshot ~= nil).is(true)
			expect(callbacks > 0).is(true)
		end)

		test("the wrapper only serializes and forwards while the registry reports an observer", function()
			local setObserved: ((boolean) -> ())? = nil
			local forwarded = 0
			local counted = 0
			local debugNetwork = {
				registerTree = function(_debugName, _definitionPath, _definition, _setPaused, observedSetter)
					setObserved = observedSetter
					return 3
				end,
				unregisterTree = function() end,
				onTreeUpdated = function(_treeId, _tick, _paused, _nodeStates, _taskParams, blackboard)
					expect(blackboard.hp).is(10)
					forwarded += 1
				end,
				countExecution = function(treeId)
					expect(treeId).is(3)
					counted += 1
				end,
				requestOpenViewer = function() end,
			}
			local serialized = 0
			local wrapper = loadWrapper(debugNetwork, function(blackboard)
				serialized += 1
				return blackboard
			end)
			local tree = wrapper.new(countingTask(), { hp = 10 }, true)

			local _, unobservedSnapshot = tree:update()
			tree:update()
			expect(unobservedSnapshot).is(nil)
			expect(forwarded).is(0)
			expect(counted).is(2)

			local observedSetter = setObserved :: (boolean) -> ()
			observedSetter(true)
			local _, observedSnapshot = tree:update()
			expect(observedSnapshot ~= nil).is(true)
			expect(forwarded).is(1)
			expect(counted).is(2)

			observedSetter(false)
			tree:update()
			expect(forwarded).is(1)
			expect(counted).is(3)
			expect(serialized).is(0)
		end)

		test("the legacy event fires only while its Enabled attribute is set", function()
			local debugNetwork = {
				registerTree = function()
					return 4
				end,
				unregisterTree = function() end,
				onTreeUpdated = function()
					error("an unsubscribed tree must not be forwarded")
				end,
				countExecution = function() end,
				requestOpenViewer = function() end,
			}
			local serialized = 0
			local legacyEvent = newLegacyEvent()
			local wrapper = loadWrapper(debugNetwork, function(blackboard)
				serialized += 1
				return blackboard
			end, legacyEvent)
			local tree = wrapper.new(countingTask(), {}, true)

			tree:update()
			expect(legacyEvent.fired).is(0)
			expect(serialized).is(0)

			legacyEvent:SetAttribute("Enabled", true)
			tree:update()
			expect(legacyEvent.fired).is(1)
			expect(serialized).is(1)

			legacyEvent:SetAttribute("Enabled", false)
			tree:update()
			expect(legacyEvent.fired).is(1)
			expect(serialized).is(1)
		end)

		test("the registry serializes only subscribed trees and drops the trace when the last one leaves", function()
			local serialized = 0
			local network, getRemote, playerRemoving = loadDebugNetwork(function(blackboard)
				serialized += 1
				return blackboard
			end)
			local observedValues = {}
			local treeId = network.registerTree("guard", "Server.GuardTree", {
				_type = "condition",
				check = function()
					return true
				end,
			}, function() end, function(observed)
				table.insert(observedValues, observed)
			end)
			local subscribe = getRemote("DebugSubscribe")
			local snapshot = getRemote("DebugSnapshot")
			local player = {}

			network.onTreeUpdated(treeId, 1, false, { [1] = 0 }, {}, { hp = 100 })
			expect(serialized).is(0)
			expect(#snapshot.fired).is(0)

			subscribe.OnServerEvent:Fire(player, debugCodec.encodeSubscribe(treeId, true))
			expect(observedValues[1]).is(true)
			network.onTreeUpdated(treeId, 2, false, { [1] = 0 }, {}, { hp = 90 })
			expect(serialized).is(1)
			expect(#snapshot.fired).is(1)
			expect(debugCodec.decodeSnapshot(snapshot.fired[1].payload).tick).is(2)

			subscribe.OnServerEvent:Fire(player, debugCodec.encodeSubscribe(treeId, false))
			expect(observedValues[2]).is(false)
			network.onTreeUpdated(treeId, 3, false, { [1] = 0 }, {}, { hp = 80 })
			expect(serialized).is(1)

			-- The cached trace was dropped, so a returning subscriber waits for the next update
			-- rather than receiving the stale one.
			subscribe.OnServerEvent:Fire(player, debugCodec.encodeSubscribe(treeId, true))
			expect(#snapshot.fired).is(1)
			network.onTreeUpdated(treeId, 4, false, { [1] = 0 }, {}, { hp = 70 })
			expect(#snapshot.fired).is(2)
			expect(debugCodec.decodeSnapshot(snapshot.fired[2].payload).tick).is(4)

			playerRemoving:Fire(player)
			expect(observedValues[#observedValues]).is(false)
			expect(#observedValues).is(4)
		end)
	end)
end
