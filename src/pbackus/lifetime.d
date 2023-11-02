module pbackus.lifetime;

import std.traits;

struct UninitializedBlock
{
	/+
	Safety invariant: either memory is null, or it refers to a chunk of memory
	that is uninitialized (i.e., does not contain an [object][1]) and that is
	not referred to by any other UninitializedBlock.

	[1]: https://dlang.org/spec/intro.html#object-model
	+/
	@system void[] memory;

	@system pure nothrow @nogc
	this(void[] memory) { this.memory = memory; }

	@disable this(ref inout UninitializedBlock) inout;

	@safe pure nothrow @nogc
	bool isNull() const
	{
		return this is UninitializedBlock.init;
	}

	@trusted pure nothrow @nogc
	size_t size() const
	{
		return memory.length;
	}

	@trusted pure nothrow @nogc
	bool isAlignedFor(T)() const
	{
		import core.stdc.stdint: uintptr_t;
		return (cast(uintptr_t) memory.ptr) % T.alignof == 0;
	}
}

// Can't access an UninitializedBlock's memory in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		UninitializedBlock block;
		void[] memory = block.memory;
	}));
}

// Can access an UninitializedBlock's memory in @system code
@system unittest
{
	UninitializedBlock block;
	void[] memory = block.memory;
}

// Can't create an aliasing UninitializedBlock in @safe code
@safe unittest
{
	assert(!__traits(compiles, () @safe {
		void[] memory;
		auto block = UninitializedBlock(memory);
	}));
}

// Can create an aliasing UninitializedBlock in @system code
@system unittest
{
	void[] memory;
	auto block = UninitializedBlock(memory);
}

// Blocks can only be moved, not copied
@safe unittest
{
	import core.lifetime: move;

	UninitializedBlock first;
	assert(!__traits(compiles, () {
		UninitializedBlock second = first;
	}));
	UninitializedBlock second = move(first);
}

// Can check for null
@system unittest
{
	UninitializedBlock b1 = null;
	UninitializedBlock b2 = new void[](1);

	assert(b1.isNull);
	assert(!b2.isNull);
}

// A default-initialized UninitializedBlock is null
@safe unittest
{
	UninitializedBlock block;
	assert(block.isNull);
}

// A moved-from UninitializedBlock is null
@system unittest
{
	import core.lifetime: move;

	UninitializedBlock first = new void[](1);
	UninitializedBlock second = move(first);

	assert(first.isNull);
	assert(!second.isNull);
}

// Can check an UninitializedBlock's size
@system unittest
{
	UninitializedBlock b1;
	UninitializedBlock b2 = new void[](123);
	assert(b1.size == 0);
	assert(b2.size == 123);
}

// UninitializedBlock.size is @safe
@safe unittest
{
	UninitializedBlock block;
	size_t _ = block.size;
}

// Can check an UninitializedBlock's alignment
@system unittest
{
	import core.stdc.stdlib: aligned_alloc, free;

	align(64) static struct S { int n; }

	void* p = aligned_alloc(S.alignof, S.sizeof);
	scope(exit) free(p);

	if (p) {
		auto b1 = UninitializedBlock(p[0 .. S.sizeof]);
		auto b2 = UninitializedBlock(p[1 .. S.sizeof]);
		assert(b1.isAlignedFor!S);
		assert(!b2.isAlignedFor!S);
	}
}

/++
Initializes a block of memory as an object of type `T`

The block's size and alignment must be sufficient to accomodate `T`. If they
are not, initialization will fail.

If initalization succeeds, `block` will be set to `UninitializedBlock.init`.
This ensures that the same block of memory cannot be initialized twice.

Params:
  block = the memory to initialize

Returns: a pointer to the initialized object on success, `null` on failure.
+/
T* initializeAs(T)(ref UninitializedBlock block)
{
	static assert(!is(immutable T == immutable void),
		"`void` cannot be intialized");

	if (block.sizeof < T.sizeof)
		return null;
	if (!block.isAlignedFor!T)
		return null;

	// Success is guaranteed from here on
	scope(exit) block = UninitializedBlock.init;

	static if (is(T == struct) || is(T == union)) {
		static immutable initSymbol = (T[1]).init;
		return () @trusted {
			block.memory[] = cast(void[]) initSymbol[];
			return cast(T*) block.memory.ptr;
		}();
	} else {
		return () @trusted {
			auto ptr = cast(Unqual!T*) block.memory.ptr;
			*ptr = T.init;
			return cast(T*) ptr;
		}();
	}
}

version (unittest) {
	private void checkInit(T)()
	{
		auto block = UninitializedBlock(new void[](T.sizeof));

		// Use T[1] to bypass possible .init member of user-defined types
		static immutable initSymbol = (T[1]).init;
		T* p = (() @safe => block.initializeAs!T)();

		assert(block.isNull);

		auto expected = cast(const(ubyte)[T.sizeof]*) &initSymbol[0];
		auto actual = cast(const(ubyte)[T.sizeof]*) p;

		assert(*actual == *expected);
	}
}

// Basic types
@system unittest
{
	import std.meta: AliasSeq, Map = staticMap;

	alias BasicTypes = AliasSeq!(
		bool,
		byte, short, int, long,
		ubyte, ushort, uint, ulong,
		float, double, real,
		char, wchar, dchar
	);


	static foreach (T; BasicTypes)
		checkInit!T();

	static foreach (T; Map!(ImmutableOf, BasicTypes))
		checkInit!T();
}

// Pointer, slice, and associative array types
@system unittest
{
	import std.meta: AliasSeq, Map = staticMap;

	alias TestTypes = AliasSeq!(
		int*, int[], int[int], int function(), int delegate(), typeof(null)
	);

	static foreach (T; TestTypes)
		checkInit!T();

	static foreach (T; Map!(ImmutableOf, TestTypes))
		checkInit!T();
}

// Struct and union types
@system unittest
{
	static struct DefaultValue { int x; }
	static struct CustomValue { int x = 0xDEADBEEF; }
	static struct NoDefaultInit { int x; @disable this(); }

	static struct InitMember
	{
		int x;
		enum InitMember init = { 0xDEADBEEF };
	}

	static struct OpAssign
	{
		int x;
		void opAssign(typeof(this) rhs) { x = 0xDEADBEEF; }
	}

	int n;
	struct Nested
	{
		int x = 1;
		int fun() { return n += x; }
	}
	static assert(__traits(isNested, Nested));

	static union Union
	{
		double d;
		int n;
	}

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		DefaultValue,
		CustomValue,
		NoDefaultInit,
		InitMember,
		OpAssign,
		Nested,
		Union
	);

	static foreach (T; TestTypes)
		checkInit!T();
}
