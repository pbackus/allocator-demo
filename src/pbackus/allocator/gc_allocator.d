module pbackus.allocator.gc_allocator;

import pbackus.allocator.block;

import core.memory: GC;

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
}

// allocate
@safe unittest
{
	auto block = GCAllocator.instance.allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}
