-- From dphfox/tiniest, licensed under BSD3
--!strict

local SAVE_SNAPSHOTS = false

local tiniest = require("../tiniest/tiniest_for_lune").configure({
    snapshot_path = "./test/__snapshots__",
    save_snapshots = SAVE_SNAPSHOTS,
})

local require: any = require

local tests = tiniest.collect_tests(function()
    local describe = tiniest.describe

    local function describe_from_file(name: string)
        describe(name, function()
            require(`./{name}.spec`)(tiniest)
        end)
    end

    describe_from_file("tiniest")
    describe_from_file("behaviorTree")
    describe_from_file("serializeBlackboard")
    describe_from_file("debugCodec")
end)
tiniest.run_tests(tests, {})
