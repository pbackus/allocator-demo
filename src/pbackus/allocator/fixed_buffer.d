module pbackus.allocator.fixed_buffer;

import pbackus.allocator.alignment;
import pbackus.allocator.block;

struct FixedBuffer(size_t bufferSize)
{
	private @system {
		align(platformAlignment) void[bufferSize] storage;
		size_t inUse;
	}

	@trusted pure nothrow @nogc
	Block allocate(size_t size)
	{
		import core.lifetime: move;

		if (size == 0 || size > maxAllocSize)
			return Block.init;

		size_t roundedSize = roundToAligned(size);
		if (roundedSize > bufferSize - inUse)
			return Block.init;

		Block result = storage[inUse .. inUse + roundedSize];
		inUse += roundedSize;
		return move(result);
	}

	@trusted pure nothrow @nogc
	bool owns(ref const Block block) const
	{
		return !block.isNull
			&& &block.memory[0] >= &storage[0]
			&& &block.memory[$-1] <= &storage[$-1];
	}

	@trusted pure nothrow @nogc
	void deallocate(ref Block block)
	{
		if (block.isNull)
			return;

		if (!this.owns(block))
			assert(0, "Invalid block");

		size_t blockOffset = &block.memory[0] - &storage[0];
		if (blockOffset + block.size == inUse)
		{
			inUse -= block.size;
			block = Block.init;
		}
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

// owns
@system unittest
{
	FixedBuffer!128 buf;
	Block b1 = buf.allocate(32);
	Block b2;
	Block b3 = new void[](1);

	assert(buf.owns(b1));
	assert(!buf.owns(b2));
	assert(!buf.owns(b3));
}

// Can deallocate an allocated block
@safe unittest
{
	FixedBuffer!128 buf;
	Block block = buf.allocate(32);
	buf.deallocate(block);
	assert(block.isNull);
}

// Deallocated space can be allocated again
@safe unittest
{
	FixedBuffer!128 buf;
	Block block = buf.allocate(128);
	buf.deallocate(block);
	block = buf.allocate(32);
	assert(!block.isNull);
}

// Can only deallocate the most recently allocated block
@safe unittest
{
	FixedBuffer!128 buf;
	Block b1 = buf.allocate(32);
	Block b2 = buf.allocate(32);
	// should fail
	buf.deallocate(b1);
	assert(!b1.isNull);
	// should succeed
	buf.deallocate(b2);
	assert(b2.isNull);
	// should succeed
	buf.deallocate(b1);
	assert(b1.isNull);
}
