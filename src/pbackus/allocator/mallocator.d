module pbackus.allocator.mallocator;

import pbackus.allocator.block;

struct Mallocator
{
	static shared Mallocator instance;

	@trusted pure nothrow @nogc
	Block!Mallocator allocate(size_t size) const shared
	{
		import core.memory: pureMalloc;

		if (size == 0)
			return Block!Mallocator.init;

		void* p = pureMalloc(size);
		return p ? Block!Mallocator(p[0 .. size]) : Block!Mallocator.init;
	}
}

// Allocates blocks of the correct size
@safe unittest
{
	auto block = Mallocator.instance.allocate(32);
	//scope(exit) Mallocator.instance.deallocate(block)
	assert(!block.isNull);
	assert(block.size >= 32);
}
