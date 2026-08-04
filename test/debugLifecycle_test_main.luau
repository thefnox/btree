-- Focused runner for debugLifecycle.spec.luau.

local tiniest = require("../tiniest/tiniest_for_lune").configure({
	snapshot_path = "./test/__snapshots__",
	save_snapshots = false,
})

local tests = tiniest.collect_tests(function()
	tiniest.describe("debugLifecycle", function()
		require("./debugLifecycle.spec")(tiniest)
	end)
end)

tiniest.run_tests(tests, {})
