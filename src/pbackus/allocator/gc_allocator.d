/++
Allocator that uses D's built-in GC/

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.allocator.gc_allocator;

import pbackus.allocator.block;

import core.memory: GC;

version (D_BetterC) {} else:

/++
The D runtime's garbage-collected heap allocator.

Not available in BetterC.
+/
struct GCAllocator
{
	/++
	Allocates `size` bytes with the GC.

	Params:
		size = Bytes to allocate.

	Returns: The allocated block on success, or a null block on failure.
	+/
	@trusted pure nothrow
	Block!GCAllocator allocate(size_t size) const
	{
		if (size == 0)
			return Block!GCAllocator.init;

		void* p = GC.malloc(size);
		return p ? Block!GCAllocator(p[0 .. size]) : Block!GCAllocator.init;
	}

	/++
	True if `block` is not null.

	The only `@safe` way to get a `Block!GCAllocator` is to allocate it with
	`GCAllocator`, so this can only give an incorrect result when called with
	an unsafe `Block` from `@system` code.
	+/
	@safe pure nothrow @nogc
	bool owns(ref const Block!GCAllocator block) const
	{
		return !block.isNull;
	}

	/// Sets `block` to null so the GC can free it automatically.
	@safe pure nothrow @nogc
	void deallocate(Block!GCAllocator block) const
	{
		// Nothing to do
	}
}

// allocate
@safe unittest
{
	auto block = GCAllocator().allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// owns
@safe unittest
{
	auto alloc = GCAllocator();
	auto b1 = alloc.allocate(32);
	auto b2 = Block!GCAllocator.init;

	assert(alloc.owns(b1));
	assert(!alloc.owns(b2));
}

// deallocate
@safe unittest
{
	import core.lifetime: move;

	auto block = GCAllocator().allocate(32);
	GCAllocator().deallocate(move(block));
	assert(block.isNull);
}
