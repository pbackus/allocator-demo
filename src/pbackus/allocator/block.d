module pbackus.allocator.block;

struct Block(Allocator)
{
	/+
	Safety invariant: if a Block is accessible to @safe code, one of the
	following must always be true.

	  1. memory is null
	  2. memory is a unique reference to a valid memory allocation returned
	     from Allocator.allocate
	
	This safety invariant is relied upon by @trusted code in other modules,
	including both allocators and containers.
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

template borrow(alias callback)
{
	auto borrow(Allocator)(ref Block!Allocator block)
	{
		import std.algorithm.mutation: swap;

		/+
		Using `scope` on `borrowedMemory` ensures that no additional references
		to the block's memory can exist outside this function after the
		callback returns.

		Swapping the block's memory with a null slice for the duration of the
		borrow ensures that no violation of the block's safety invariant can be
		observed, even if it is accessed during the call to `callback`.

		Passing an rvalue slice of borrowedMemory to the callback ensures that
		borrowedMemory cannot be overwritten during the call to `callback`.

		Therefore, the number of references to the block's memory when this
		function returns must be the same as the number when it was called.

		Therefore, this function cannot violate the block's safety invariant.
		+/
		scope void[] borrowedMemory = null;
		() @trusted { swap(block.memory, borrowedMemory); }();
		scope(exit) () @trusted { swap(block.memory, borrowedMemory); }();
		return callback(borrowedMemory[]);
	}
}

int[] global;
@safe unittest
{
	scope int[] local;
	static assert(!__traits(compiles, global = local));
}

@system unittest
{
	TestBlock block = new void[](1);

	() @safe {
		// Memory is successfully borrowed...
		block.borrow!((void[] mem) {
			assert(mem !is null);
			assert(block.isNull);
			// ...but only once...
			block.borrow!((void[] mem2) {
				assert(mem2 is null);
			});
		});
		// ...and then returned
		assert(!block.isNull);

		// Temporary workaround for a compiler bug:
		// https://issues.dlang.org/show_bug.cgi?id=24208
		// Will be fixed in the next release.
		static if (__VERSION__ >= 2106) {
			// Can't escape into a local variable
			void[] escapeLocal;
			assert(!__traits(compiles,
					block.borrow!((void[] mem) {
						escapeLocal = mem;
					})
			));
		}

		// ...or into a static variable
		static void[] escapeStatic;
		assert(!__traits(compiles,
			block.borrow!((void[] mem) {
				escapeStatic = mem;
			})
		));

		// Can't borrow by reference
		assert(!__traits(compiles,
			block.borrow!((ref void[] mem) {})
		));
	}();
}
