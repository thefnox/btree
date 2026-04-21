--!strict
--!native
--!optimize 2
-- Byte-level buffer read/write helpers used by the debug codec. Kept in its
-- own module so higher-level codecs can share the same Writer/Reader without
-- duplicating primitives.
--
-- The Writer grows on demand: Roblox buffers are fixed-size, so we keep a
-- scratch buffer with a power-of-two capacity and double it when a write
-- wouldn't fit. `finish` copies just the used prefix into a correctly sized
-- output buffer.
--
-- The Reader is a thin cursor over a read-only buffer.

export type Writer = {
	buf: buffer,
	offset: number,
}

export type Reader = {
	buf: buffer,
	offset: number,
}

local function newWriter(capacity: number): Writer
	return { buf = buffer.create(capacity), offset = 0 }
end

local function ensure(w: Writer, additional: number)
	local needed = w.offset + additional
	local cap = buffer.len(w.buf)
	if cap < needed then
		local newSize = if cap == 0 then 64 else cap * 2
		while newSize < needed do
			newSize *= 2
		end
		local newBuf = buffer.create(newSize)
		buffer.copy(newBuf, 0, w.buf, 0, w.offset)
		w.buf = newBuf
	end
end

local function writeU8(w: Writer, v: number)
	ensure(w, 1)
	buffer.writeu8(w.buf, w.offset, v)
	w.offset += 1
end

local function writeU16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writeu16(w.buf, w.offset, v)
	w.offset += 2
end

local function writeU32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writeu32(w.buf, w.offset, v)
	w.offset += 4
end

local function writeI32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writei32(w.buf, w.offset, v)
	w.offset += 4
end

local function writeF32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writef32(w.buf, w.offset, v)
	w.offset += 4
end

local function writeF64(w: Writer, v: number)
	ensure(w, 8)
	buffer.writef64(w.buf, w.offset, v)
	w.offset += 8
end

local function writeString(w: Writer, s: string)
	local len = #s
	writeU16(w, len)
	ensure(w, len)
	buffer.writestring(w.buf, w.offset, s)
	w.offset += len
end

local function finish(w: Writer): buffer
	local out = buffer.create(w.offset)
	buffer.copy(out, 0, w.buf, 0, w.offset)
	return out
end

local function newReader(buf: buffer): Reader
	return { buf = buf, offset = 0 }
end

local function readU8(r: Reader): number
	local v = buffer.readu8(r.buf, r.offset)
	r.offset += 1
	return v
end

local function readU16(r: Reader): number
	local v = buffer.readu16(r.buf, r.offset)
	r.offset += 2
	return v
end

local function readU32(r: Reader): number
	local v = buffer.readu32(r.buf, r.offset)
	r.offset += 4
	return v
end

local function readI32(r: Reader): number
	local v = buffer.readi32(r.buf, r.offset)
	r.offset += 4
	return v
end

local function readF32(r: Reader): number
	local v = buffer.readf32(r.buf, r.offset)
	r.offset += 4
	return v
end

local function readF64(r: Reader): number
	local v = buffer.readf64(r.buf, r.offset)
	r.offset += 8
	return v
end

local function readString(r: Reader): string
	local len = readU16(r)
	local s = buffer.readstring(r.buf, r.offset, len)
	r.offset += len
	return s
end

return {
	newWriter = newWriter,
	ensure = ensure,
	writeU8 = writeU8,
	writeU16 = writeU16,
	writeU32 = writeU32,
	writeI32 = writeI32,
	writeF32 = writeF32,
	writeF64 = writeF64,
	writeString = writeString,
	finish = finish,

	newReader = newReader,
	readU8 = readU8,
	readU16 = readU16,
	readU32 = readU32,
	readI32 = readI32,
	readF32 = readF32,
	readF64 = readF64,
	readString = readString,
}
