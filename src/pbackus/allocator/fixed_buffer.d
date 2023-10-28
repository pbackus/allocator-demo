module pbackus.allocator.fixed_buffer;

import pbackus.allocator.alignment;
import pbackus.allocator.block;

import core.lifetime: move;

struct FixedBuffer(size_t bufferSize)
{
	private @system {
		align(platformAlignment) ubyte[bufferSize] storage;
		size_t used;
	}

	@trusted pure nothrow @nogc
	Block allocate(size_t size)
	{
		if (size == 0 || size > maxAllocSize)
			return Block.init;

		size_t roundedSize = roundToAligned(size);
		if (roundedSize > bufferSize - used)
			return Block.init;

		Block result = storage[used .. used + roundedSize];
		used += roundedSize;
		return move(result);
	}
}

// Allocates blocks of the correct size
@safe unittest
{
	FixedBuffer!128 buf;
	Block block = buf.allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// Can't over-allocate
@safe unittest
{
	FixedBuffer!128 buf;
	Block block = buf.allocate(256);
	assert(block.isNull);
}

// Can't allocate when full
@safe unittest
{
	FixedBuffer!128 buf;
	Block b1 = buf.allocate(128);
	Block b2 = buf.allocate(1);
	assert(!b1.isNull);
	assert(b2.isNull);
}
