module pbackus.allocator.block;

struct Block
{
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

// Can't access a block's memory in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		Block block;
		void[] memory = block.memory;
	}));
}

// Can access a block's memory in @system code
@system unittest
{
	Block block;
	void[] memory = block.memory;
}

// Can't create an aliasing Block in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		void[] memory;
		auto block = Block(memory);
	}));
}

// Can create an aliasing block in @system code
@system unittest
{
	void[] memory;
	auto block = Block(memory);
}

// Blocks can only be moved, not copied
@safe unittest
{
	import core.lifetime: move;

	Block first;
	assert(!__traits(compiles, () {
		Block second = first;
	}));
	Block second = move(first);
}

// Can check for null
@system unittest
{
	Block b1 = null;
	Block b2 = new void[](1);

	assert(b1.isNull);
	assert(!b2.isNull);
}

// A default-initialized Block is null
@safe unittest
{
	Block block;
	assert(block.isNull);
}

// A moved-from Block is null
@system unittest
{
	import core.lifetime: move;

	Block first = new void[](1);
	Block second = move(first);

	assert(first.isNull);
	assert(!second.isNull);
}

// Can check a Block's size
@system unittest
{
	Block b1;
	Block b2 = new void[](123);
	assert(b1.size == 0);
	assert(b2.size == 123);
}

// Block.size is @safe
@safe unittest
{
	Block block;
	size_t _ = block.size;
}
