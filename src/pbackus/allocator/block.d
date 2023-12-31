/++
Block type that represents an allocation.

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.allocator.block;

/++
A block of memory allocated by an `Allocator`.

A `Block` represents unique, exclusive ownership of a region of memory
allocated by an allocator. Typically, they are created by an allocator's
`allocate` method, and consumed by its `deallocate` method.

A `Block` that does not own any memory is called a "null block." `Block.init`
is guaranteed to be a null block. To check whether a `Block` is a null block,
use the [isNull] method.

A `Block` can only be created in `@system` or `@trusted` code. Before allowing
`@safe` code to access it, your `@trusted` code must ensure that the
[#safety-invariant|safety invariant] described below is upheld.

Safety_Invariant:

A `Block!Allocator` is a safe value as long as both of the following conditions
are upheld.

$(NUMBERED_LIST
	* One of the following is true:
	$(LIST
		* Its `memory` field is `null`.
		* The memory referred to by its `memory` field
		$(LIST
			* was last allocated by an instance of `Allocator` and, since then,
			  has not been deallocated; and
			* cannot be reached from `@safe` code, either directly or through
			  the use of [safe_interfaces]; and
			* is not referred to by any other `Block!Allocator`.
		)
	)
	* As long as the memory referred to by its `memory` field remains
	  allocated, the use of [safe_interfaces] cannot
	$(LIST
		* cause any part of that memory to be written to, or
		* cause any part of that memory to become inaccessible.
	)
)

Because maintenance of this invariant requires cooperation between the
implementation of `Block` (this module) and the implementation of `Allocator`,
it is ultimately the responsibility of the programmer to ensure that a given
version of `Block` is only used with allocators that are designed for it.

Any functional change to the requirements in this safety invariant should be
considered a breaking API change.

Link_References:

safe_interfaces = [https://dlang.org/spec/function.html#safe-interfaces|safe interfaces]
+/
struct Block(Allocator)
{
	/// A block of allocated memory, or `null`.
	@system void[] memory;

	/// Creating a `Block` is `@system`.
	@system pure nothrow @nogc
	this(void[] memory)
	{
		this.memory = memory;
	}

	/// Copying is disabled.
	@disable this(ref inout Block) inout;

	/// True if `memory` is `null`, otherwise false.
	@safe pure nothrow @nogc
	bool isNull() const
	{
		return size == 0;
	}

	/// Size of `memory` in bytes.
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
	static void[1] buf;
	TestBlock b1 = null;
	TestBlock b2 = buf[];

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

	static void[1] buf;
	TestBlock first = buf[];
	TestBlock second = move(first);

	assert(first.isNull);
	assert(!second.isNull);
}

// Can check a Block's size
@system unittest
{
	static void[123] buf;
	TestBlock b1;
	TestBlock b2 = buf[];
	assert(b1.size == 0);
	assert(b2.size == 123);
}

// Block.size is @safe
@safe unittest
{
	TestBlock block;
	size_t _ = block.size;
}

// All empty Blocks are null
@system unittest
{
	static void[1] buf;
	TestBlock block = buf[0 .. 0];

	assert(block.isNull);
}

/++
Safely access a `Block`'s memory.

The memory is passed to `callback` as a `scope void[]`, and `block` is set to
null for the duration of the borrow.

This function will be inferred as `@safe` if `callback` is `@safe`.

Params:
	callback = Function to receive the borrowed memory.
+/
template borrow(alias callback)
{
	/++
	The actual `borrow` function.

	Params:
		block = Block to borrow from.

	Returns: The return value of `callback`.
	+/
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

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static
		void swapMemory(ref Block!Allocator block, ref void[] borrowedMemory)
		{
			import pbackus.util: assumeNonScope;

			// Ok to cast away scope here because the only values this will be
			// called with are (a) the original value of block.memory and
			// (b) null, both of which are safe to store in either variable.
			void[] tmp = block.memory;
			block.memory = assumeNonScope(borrowedMemory);
			borrowedMemory = tmp;
		}

		scope void[] borrowedMemory = null;
		swapMemory(block, borrowedMemory);
		scope(exit) swapMemory(block, borrowedMemory);
		return callback(borrowedMemory[]);
	}
}

@system unittest
{
	static void[1] buf;
	TestBlock block = buf[];

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
