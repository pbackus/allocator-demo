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

	@trusted pure nothrow @nogc
	void deallocate(ref Block!Mallocator block) const shared
	{
		import core.memory: pureFree;

		if (block.isNull)
			return;

		pureFree(block.memory.ptr);
		block = Block!Mallocator.init;
	}
}

// Allocates blocks of the correct size
@safe unittest
{
	auto block = Mallocator.instance.allocate(32);
	scope(exit) Mallocator.instance.deallocate(block);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// owns
@safe unittest
{
	alias alloc = Mallocator.instance;
	auto b1 = alloc.allocate(32);
	scope(exit) alloc.deallocate(b1);
	Block!Mallocator b2;

	assert(alloc.owns(b1));
	assert(!alloc.owns(b2));
}

// deallocate
@safe unittest
{
	auto block = Mallocator.instance.allocate(32);
	Mallocator.instance.deallocate(block);
	assert(block.isNull);
}
