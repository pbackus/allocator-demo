module pbackus.allocator.region;

import pbackus.allocator.alignment;
import pbackus.allocator.block;

struct InSituRegion(size_t bufferSize)
{
	private @system {
		align(platformAlignment) void[bufferSize] storage;
		size_t inUse;
	}

	@trusted pure nothrow @nogc
	Block!InSituRegion allocate(size_t size)
	{
		import core.lifetime: move;

		if (size == 0 || size > maxAlignedSize)
			return Block!InSituRegion.init;

		size_t roundedSize = roundToAligned(size);
		if (roundedSize > bufferSize - inUse)
			return Block!InSituRegion.init;

		Block!InSituRegion result = storage[inUse .. inUse + roundedSize];
		inUse += roundedSize;
		return move(result);
	}

	@trusted pure nothrow @nogc
	bool owns(ref const Block!InSituRegion block) const
	{
		return !block.isNull
			&& &block.memory[0] >= &storage[0]
			&& &block.memory[$-1] <= &storage[$-1];
	}

	@trusted pure nothrow @nogc
	void deallocate(ref Block!InSituRegion block)
	{
		if (block.isNull)
			return;

		if (!this.owns(block))
			assert(0, "Invalid block");

		size_t blockOffset = &block.memory[0] - &storage[0];
		if (blockOffset + block.size == inUse)
		{
			inUse -= block.size;
			block = Block!InSituRegion.init;
		}
	}
}

// Allocates blocks of the correct size
@safe unittest
{
	InSituRegion!128 buf;
	auto block = buf.allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// Can't over-allocate
@safe unittest
{
	InSituRegion!128 buf;
	auto block = buf.allocate(256);
	assert(block.isNull);
}

// Can't allocate when full
@safe unittest
{
	InSituRegion!128 buf;
	auto b1 = buf.allocate(128);
	auto b2 = buf.allocate(1);
	assert(!b1.isNull);
	assert(b2.isNull);
}

// owns
@safe unittest
{
	InSituRegion!128 buf1, buf2;
	auto b1 = buf1.allocate(32);
	auto b2 = buf2.allocate(32);
	auto b3 = Block!(InSituRegion!128).init;

	assert(buf1.owns(b1));
	assert(!buf1.owns(b2));
	assert(!buf1.owns(b3));

	assert(!buf2.owns(b1));
	assert(buf2.owns(b2));
	assert(!buf2.owns(b3));
}

// Can deallocate an allocated block
@safe unittest
{
	InSituRegion!128 buf;
	auto block = buf.allocate(32);
	buf.deallocate(block);
	assert(block.isNull);
}

// Deallocated space can be allocated again
@safe unittest
{
	InSituRegion!128 buf;
	auto block = buf.allocate(128);
	buf.deallocate(block);
	block = buf.allocate(32);
	assert(!block.isNull);
}

// Can only deallocate the most recently allocated block
@safe unittest
{
	InSituRegion!128 buf;
	auto b1 = buf.allocate(32);
	auto b2 = buf.allocate(32);
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
