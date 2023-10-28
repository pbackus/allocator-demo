module pbackus.allocator.block;

struct Block
{
	@system void[] memory;

	@system
	this(void[] memory)
	{
		this.memory = memory;
	}

	@disable this(ref inout Block) inout;
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
