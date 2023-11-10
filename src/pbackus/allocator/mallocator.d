/++
Allocator that uses the C library's `malloc`

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.allocator.mallocator;

import pbackus.allocator.block;

/// The standard C heap allocator
struct Mallocator
{
	/// Global instance
	static shared Mallocator instance;

	/++
	Allocates `size` bytes with `malloc`

	Params:
		size = Bytes to allocate

	Returns: The allocated block on success, or a null block on failure.
	+/
	@trusted pure nothrow @nogc
	Block!Mallocator allocate(size_t size) const shared
	{
		import core.memory: pureMalloc;

		if (size == 0)
			return Block!Mallocator.init;

		void* p = pureMalloc(size);
		return p ? Block!Mallocator(p[0 .. size]) : Block!Mallocator.init;
	}

	/++
	True if `block` is not null

	The only `@safe` way to get a `Block!Mallocator` is to allocate it with
	`Mallocator`, so this can only give an incorrect result when called with an
	unsafe `Block` from `@system` code.
	+/
	@safe pure nothrow @nogc
	bool owns(ref const Block!Mallocator block) const shared
	{
		return !block.isNull;
	}

	/// Deallocates `block` with `free`
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
