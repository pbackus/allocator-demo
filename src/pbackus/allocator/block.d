module pbackus.allocator.block;

struct Block(Allocator)
{
	/+
	Invariant: either `memory is null`, or `memory` is the only reference to a
	valid block of memory.
	+/
	@system void[] memory;

	@system pure nothrow @nogc
	this(void[] memory)
	{
		this.memory = memory;
	}

	@disable this(ref inout Block) inout;

	@safe pure nothrow @nogc
	bool isNull() const
	{
		return this is Block.init;
	}

	@trusted pure nothrow @nogc
	size_t size() const
	{
		return memory.length;
	}
}

version (unittest) {
	private struct AllocatorStub {}
	private alias TestBlock = Block!AllocatorStub;
}

// Can't access a block's memory in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		TestBlock block;
		void[] memory = block.memory;
	}));
}

// Can access a block's memory in @system code
@system unittest
{
	TestBlock block;
	void[] memory = block.memory;
}

// Can't create an aliasing Block in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		void[] memory;
		auto block = TestBlock(memory);
	}));
}

// Can create an aliasing block in @system code
@system unittest
{
	void[] memory;
	auto block = TestBlock(memory);
}

// Blocks can only be moved, not copied
@safe unittest
{
	import core.lifetime: move;

	TestBlock first;
	assert(!__traits(compiles, () {
		TestBlock second = first;
	}));
	TestBlock second = move(first);
}

// Can check for null
@system unittest
{
	TestBlock b1 = null;
	TestBlock b2 = new void[](1);

	assert(b1.isNull);
	assert(!b2.isNull);
}

// A default-initialized Block is null
@safe unittest
{
	TestBlock block;
	assert(block.isNull);
}

// A moved-from Block is null
@system unittest
{
	import core.lifetime: move;

	TestBlock first = new void[](1);
	TestBlock second = move(first);

	assert(first.isNull);
	assert(!second.isNull);
}

// Can check a Block's size
@system unittest
{
	TestBlock b1;
	TestBlock b2 = new void[](123);
	assert(b1.size == 0);
	assert(b2.size == 123);
}

// Block.size is @safe
@safe unittest
{
	TestBlock block;
	size_t _ = block.size;
}
