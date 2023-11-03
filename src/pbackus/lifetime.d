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

		static if (is(T == class))
			enum alignment = __traits(classInstanceAlignment, T);
		else
			enum alignment = T.alignof;

		return (cast(uintptr_t) memory.ptr) % alignment == 0;
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

// Alignment for classes
@system unittest
{
	import core.stdc.stdlib: aligned_alloc, free;

	static class C { align(64) ubyte[32] n; }

	enum alignment = __traits(classInstanceAlignment, C);
	enum size = __traits(classInstanceSize, C);

	void* p = aligned_alloc(alignment, size);
	scope(exit) free(p);

	if (p) {
		auto b1 = UninitializedBlock(p[0 .. size]);
		auto b2 = UninitializedBlock(p[C.sizeof .. size]);
		assert(b1.isAlignedFor!C);
		assert(!b2.isAlignedFor!C);
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

Returns: a pointer or class reference to the initialized object on success,
`null` on failure.
+/
auto initializeAs(T)(ref UninitializedBlock block)
{
	static assert(!is(immutable T == immutable void),
		"`void` cannot be intialized");
	static assert(!is(T == interface),
		"`interface " ~ T.stringof ~ "` cannot be initialized");

	static if (is(T == class))
		enum size = __traits(classInstanceSize, T);
	else
		enum size = T.sizeof;

	if (block.size < size)
		return null;
	if (!block.isAlignedFor!T)
		return null;

	// Success is guaranteed from here on
	scope(exit) block = UninitializedBlock.init;

	static if (is(T == class)) {
		/+
		Classes

		Since classes are reference types, initialize the instance that T
		points to rather than T itself.
		+/
		return () @trusted {
			block.memory[0 .. size] = __traits(initSymbol, T)[];
			return cast(T) block.memory.ptr;
		}();
	} else static if (__traits(isZeroInit, T)) {
		/+
		Zero-initialized value types

		Handling these all at once here is simpler and more efficient than
		doing it individually in each branch.
		+/
		return () @trusted {
			block.memory[0 .. size] = (void[size]).init;
			return cast(T*) block.memory.ptr;
		}();
	} else static if (is(T == struct) || is(T == union)) {
		/+
		Structs and unions

		Might have overloaded assignment, so initalize with an untyped byte
		copy instead of assigning T.init.
		+/
		return () @trusted {
			// isZeroInit case is handled earlier, so initSymbol won't be null
			block.memory[0 .. size] = __traits(initSymbol, T)[];
			return cast(T*) block.memory.ptr;
		}();
	} else static if (is(T == E[n], E, size_t n)) {
		/+
		Static arrays

		No initSymbol and might have non-trivial assignment, so initialize each
		element individually with a recursive call.

		Arrays of void and arrays of class/interface references, which would
		not be handled correctly by recursion, are already handled by the
		isZeroInitCase.
		+/
		foreach (i; 0 .. n) {
			size_t offset = i * E.sizeof;
			auto eblock = (() @trusted => UninitializedBlock(
				block.memory[offset .. offset + E.sizeof]
			))();
			// Exclude recursive call from @trusted for correct inference
			auto eptr = eblock.initializeAs!E;
			assert(eptr !is null);
		}

		return (() @trusted => cast(T*) block.memory.ptr)();
	} else {
		/+
		Types with trivial assignment

		Includes basic types, pointers, slices, associative arrays, SIMD
		vectors, typeof(null), noreturn, and enums (regardless of base type).

		Because trivial assignment is equivalent to blitting, we can blit
		T.init using the normal assignment operator.
		+/
		return () @trusted {
			auto ptr = cast(Unqual!T*) block.memory.ptr;
			*ptr = T.init;
			return cast(T*) ptr;
		}();
	}
}

version (unittest) {
	private void checkInit(T)()
		if (!is(T == class))
	{
		auto block = UninitializedBlock(new void[](T.sizeof));

		/+
		Use T[1] to bypass possible .init member of user-defined types.

		immutable is ok because the raw bytes of .init are the same
		for all qualified versions of a type.
		+/
		static immutable initBytes = (T[1]).init;
		T* p = () @safe pure nothrow @nogc {
			return block.initializeAs!T;
		}();

		assert(block.isNull);

		auto expected = cast(const(ubyte)[T.sizeof]*) &initBytes[0];
		auto actual = cast(const(ubyte)[T.sizeof]*) p;

		assert(*actual == *expected,
			"`checkInit!(" ~ T.stringof ~ ")` failed");
	}

	private void checkInit(T)()
		if (is(T == class))
	{
		enum size = __traits(classInstanceSize, T);

		auto block = UninitializedBlock(new void[](size));

		const(void)[] initBytes = __traits(initSymbol, T);
		T p = () @safe pure nothrow @nogc {
			return block.initializeAs!T;
		}();

		assert(block.isNull);

		auto expected = cast(const(ubyte)[size]*) &initBytes[0];
		auto actual = cast(const(ubyte)[size]*) p;

		assert(*actual == *expected,
			"`checkInit!(" ~ T.stringof ~ ")` failed");
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
		int fun() { return n; }
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

// Class types
@system unittest
{
	static class DefaultValue { int x; }
	static class CustomValue { int x = 0xDEADBEEF; }
	static class NoDefaultInit { int x; @disable this(); }

	static class InitMember
	{
		int x;
		this(int x) immutable { this.x = x; }
		static immutable init = new immutable(InitMember)(0xDEADBEEF);
	}

	int n;
	class Nested
	{
		int fun() { return n; }
	}
	static assert(__traits(isNested, Nested));

	class Big
	{
		int[100] a;
	}

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		DefaultValue,
		CustomValue,
		NoDefaultInit,
		InitMember,
		Nested,
		Big
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Static array types
@system unittest
{
	static struct S { int x = 0xDEADBEEF; }
	static class C { int x = 0xDEADBEEF; }
	static interface I {}

	int n;
	struct Nested
	{
		int fun() { return n; }
	}

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		int[0], char[1], double[2], S[3], C[4], I[5], Nested[6], void[7]
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Vector types
version (D_SIMD)
@system unittest
{
	import core.simd;
	import std.meta: AliasSeq;

	alias BaseTypes = AliasSeq!(void[16], float[4], int[4]);

	static foreach (T; BaseTypes) {{
		 auto block = UninitializedBlock(new void[](T.sizeof));
		 auto p = block.initializeAs!(__vector(T));
		 assert(p !is null);

		 auto actual = *cast(const(ubyte)[T.sizeof]*) p;
		 auto expected = cast(ubyte[T.sizeof]) T.init;
		 assert(actual == expected);
	}}
}

// Enum types
@system unittest
{
	static struct S { int x = 123; }

	static struct OpAssign
	{
		int x = 123;
		void opAssign(typeof(this)) { this.x = 456; }
	}

	static class C
	{
		int x = 123;
		this(int x) { this.x = x; }
	}

	int n;
	struct Nested
	{
		int x = 123;
		int fun() { return n; }
	}

	enum IntEnum : int { a = 123 }
	enum StringEnum : string { a = "hello" }
	enum StructEnum : S { a = S(456) }
	enum AssignEnum : OpAssign { a = OpAssign(789) }
	enum ClassEnum : C { a = new C(456) }
	enum NestedEnum : Nested { a = Nested(456) }
	enum ArrayEnum : int[5] { a = [1, 2, 3, 4, 5] }

	import std.meta: AliasSeq, Map = staticMap;

	alias TestTypes = AliasSeq!(
		IntEnum, StringEnum, StructEnum, ClassEnum, ArrayEnum
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Oversized blocks
@system unittest
{
	static struct S { int n; }
	static class C { int n; }

	auto b1 = UninitializedBlock(new void[](32));
	auto p1 = b1.initializeAs!S;
	assert(p1 !is null);

	auto b2 = UninitializedBlock(new void[](32));
	auto p2 = b2.initializeAs!C;
	assert(p2 !is null);
}
