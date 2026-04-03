local fs = require("@lune/fs")
local process = require("@lune/process")

local RELEASE_DIR = "release"

local function log(text: string)
	print(`* {text}`)
end

if fs.isDir(RELEASE_DIR) then
	fs.removeDir(RELEASE_DIR)
end
fs.writeDir(RELEASE_DIR)

local start = os.clock()

local rojo_result = process.exec("rojo", {
	"build",
	"default.project.json",
	"--output",
	`{RELEASE_DIR}/BTree.rbxm`,
}, { stdio = "forward" })
assert(rojo_result.ok, rojo_result.stderr)
log("Built library rbxm")

print(string.format("Finished build in %.2f seconds", os.clock() - start))
