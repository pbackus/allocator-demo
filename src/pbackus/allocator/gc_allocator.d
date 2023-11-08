module pbackus.allocator.gc_allocator;

import pbackus.allocator.block;

import core.memory: GC;

version (D_BetterC) {} else:

struct GCAllocator
{
	static shared GCAllocator instance;

	@trusted pure nothrow
	Block!GCAllocator allocate(size_t size) const shared
	{
		if (size == 0)
			return Block!GCAllocator.init;

		void* p = GC.malloc(size);
		return p ? Block!GCAllocator(p[0 .. size]) : Block!GCAllocator.init;
	}

	@safe pure nothrow @nogc
	bool owns(ref const Block!GCAllocator block) const shared
	{
		return !block.isNull;
	}

	@safe pure nothrow @nogc
	void deallocate(ref Block!GCAllocator block) const shared
	{
		// Let the GC free it automatically
		block = Block!GCAllocator.init;
	}
}

// allocate
@safe unittest
{
	auto block = GCAllocator.instance.allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// owns
@safe unittest
{
	alias alloc = GCAllocator.instance;
	auto b1 = alloc.allocate(32);
	auto b2 = Block!GCAllocator.init;

	assert(alloc.owns(b1));
	assert(!alloc.owns(b2));
}

// deallocate
@safe unittest
{
	auto block = GCAllocator.instance.allocate(32);
	GCAllocator.instance.deallocate(block);
	assert(block.isNull);
}
