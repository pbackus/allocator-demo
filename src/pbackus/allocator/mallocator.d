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

	@safe pure nothrow @nogc
	bool owns(ref const Block!Mallocator block) const shared
	{
		return !block.isNull;
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

// owns
@safe unittest
{
	alias alloc = Mallocator.instance;
	auto b1 = alloc.allocate(32);
	//scope(exit) alloc.free(b1);
	Block!Mallocator b2;

	assert(alloc.owns(b1));
	assert(!alloc.owns(b2));
}
