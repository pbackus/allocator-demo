/++
Allocator that draws from a single chunk of memory.

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.allocator.region;

import pbackus.allocator.alignment;
import pbackus.allocator.block;

/++
Bump-the-pointer allocator that uses an internal fixed-size buffer.

Bugs:

Because D does not support non-movable struct types (see issues
[17448](https://issues.dlang.org/show_bug.cgi?id=17448) and
[20321](https://issues.dlang.org/show_bug.cgi?id=20321)), `InSituRegion` must
be implemented as a `class`.

It can still be used for stack allocation via a [scope class
instance](https://dlang.org/spec/attribute.html#scope-class-var) (when the D
runtime is available) or manual emplacement into a stack buffer (in BetterC).

Params:
	bufferSize = Size of the internal buffer.
+/
extern(C++) final class InSituRegion(size_t bufferSize)
{
	extern(D):

	private @system {
		align(platformAlignment) void[bufferSize] storage;
		size_t inUse;
	}

	/// Can only be default constructed
	this() scope {}

	/// Copying is disabled.
	@disable this(ref inout InSituRegion) inout;

	/++
	Allocates at least `size` bytes.

	The requested size is rounded up to a multiple of [platformAlignment].

	Fails if this would cause the total amount allocated to exceed
	`bufferSize`.

	Params:
		size = Bytes to allocate.

	Returns: The allocated block on success, or a null block on failure.
	+/
	@trusted pure nothrow @nogc
	Block!InSituRegion allocate(size_t size) return scope
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

	/// True if `block` was allocated by this `InSituRegion`.
	@trusted pure nothrow @nogc
	bool owns(ref scope const Block!InSituRegion block) scope const
	{
		return !block.isNull
			&& &block.memory[0] >= &storage[0]
			&& &block.memory[$-1] <= &storage[$-1];
	}

	/++
	Attempts to deallocate `block`.

	Deallocation only succeeds if `block` is the most recent block allocated
	by this `InSituRegion`.

	`block` must be owned by this `InSituRegion`. If it is not, the program
	will be aborted.

	Params:
		block = The block to deallocate.
	+/
	@trusted pure nothrow @nogc
	void deallocate(ref scope Block!InSituRegion block) scope
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

version(D_BetterC)
// "scope new" doesn't work in BetterC
// Simplified test so we still have some coverage
@system nothrow @nogc
unittest
{
	import pbackus.lifetime;
	import pbackus.util;

	enum size = __traits(classInstanceSize, InSituRegion!128);
	enum alignment = __traits(classInstanceAlignment, InSituRegion!128);
	align(alignment) void[size] rawMem = void;

	auto ublock = mixin(trusted!"UninitializedBlock(rawMem[])");
	auto buf = emplace!(InSituRegion!128)(ublock);
	assert(buf !is null);

	() @safe {
		auto block = buf.allocate(32);
		assert(!block.isNull);
		assert(block.size >= 32);
		assert(buf.owns(block));
		buf.deallocate(block);
		assert(block.isNull);
	}();
}

// Allocates blocks of the correct size
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
	auto block = buf.allocate(32);
	assert(!block.isNull);
	assert(block.size >= 32);
}

// Can't over-allocate
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
	auto block = buf.allocate(256);
	assert(block.isNull);
}

// Can't allocate when full
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
	auto b1 = buf.allocate(128);
	auto b2 = buf.allocate(1);
	assert(!b1.isNull);
	assert(b2.isNull);
}

// owns
version (D_BetterC) {} else
@safe unittest
{
	scope buf1 = new InSituRegion!128;
	scope buf2 = new InSituRegion!128;
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
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
	auto block = buf.allocate(32);
	buf.deallocate(block);
	assert(block.isNull);
}

// Deallocated space can be allocated again
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
	auto block = buf.allocate(128);
	buf.deallocate(block);
	block = buf.allocate(32);
	assert(!block.isNull);
}

// Can only deallocate the most recently allocated block
version (D_BetterC) {} else
@safe unittest
{
	scope buf = new InSituRegion!128;
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
