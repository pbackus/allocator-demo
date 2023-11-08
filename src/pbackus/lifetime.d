module pbackus.lifetime;

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
Constructs or initializes an instance of `T` in uninitialized memory

Params:
  block = the memory to use
  args = initial value or constructor arguments

Returns: a pointer or class reference to the resulting object on success,
`null` on failure.

Bugs:

Because of [a compiler bug][issue8850], it is not possible for `emplace` to
call the constructor of a nested `struct`. To work around this limitation, call
the constructor first and pass the resulting struct instance to `emplace` as
the initializer.

[issue8850]: https://issues.dlang.org/show_bug.cgi?id=8850
+/
auto emplace(T, Args...)(ref UninitializedBlock block, auto ref Args args)
{
	import core.lifetime: forward;

	static if (Args.length == 0) {
		/+
		Default initialization
		+/
		return block.emplaceInitializer!T;
	} else {
		/+
		Non-default initialization
		+/
		static if (is(T == class))
			enum size = __traits(classInstanceSize, T);
		else
			enum size = T.sizeof;

		if (block.size < size)
			return null;
		if (!block.isAlignedFor!T)
			return null;

		version (D_Exceptions) {
			/+
			Leave block uninitialized if constructor throws
			@trusted ok because the aliasing is never exposed to @safe code
			+/
			void[] savedMemory = (() @trusted => block.memory)();
			scope(failure) () @trusted { block.memory = savedMemory; }();
		}

		static if (is(T == class)) {
			/+
			Classes
			+/
			import std.traits: Unqual;

			static if (__traits(isNested, T)) {
				alias Outer = typeof(T.outer);
				static assert(
					Args.length > 0 && is(typeof(args[0]) : Outer),
					"Initialization of nested class `" ~ T.stringof ~ "` " ~
					"requires instance of outer class `" ~ Outer.stringof ~ "` " ~
					"` as the first argument to `emplace`"
				);

				Unqual!T unqualResult = block.emplaceInitializer!(Unqual!T);
				if (unqualResult) {
					// Force implicit conversion
					Outer outerArg = forward!(args[0]);
					/+
					@trusted ok because Outer and Unqual!Outer have identical
					representation, and unsafe aliasing will not be exposed
					+/
					() @trusted {
						unqualResult.outer = *cast(Unqual!Outer*) &outerArg;
					}();
				}

				// @trusted ok because the aliasing is never exposed to @safe code
				T result = (() @trusted => cast(T) unqualResult)();
				alias ctorArgs = args[1 .. $];
			} else {
				T result = block.emplaceInitializer!T;
				alias ctorArgs = args;
			}

			static if (ctorArgs.length > 0 || __traits(hasMember, T, "__ctor")) {
				/+
				Instead of checking for a matching __ctor overload, let the call
				fail naturally so the user gets a meaningful error message.
				+/
				if (result)
					result.__ctor(forward!ctorArgs);
			}
			return result;
		} else static if (is(T == struct) || is(T == union)) {
			/+
			Structs and unions
			+/
			Emplaced!T* result = block.emplaceInitializer!(Emplaced!T);
			if (result)
				result.__ctor(forward!args);
			return &result.payload;
		} else {
			static assert(0, "Unimplemented");
		}
	}
}

/+
In D, initialization in a constructor is the only way to assign a value to
non-mutable memory without invoking undefined behavior. Since some types don't
have a constructor, this wrapper struct is used to guarantee that one exists.
+/
private struct Emplaced(T)
{
	T payload;
	this(Args...)(auto ref Args args)
	{
		import core.lifetime: forward;

		static if (Args.length == 1)
			// Compiler won't expand the sequence automatically
			payload = forward!(args[0]);
		else
			payload = forward!args;
	}
}

// No arguments -> default initialization
@system unittest
{
	auto block = UninitializedBlock(new void[double.sizeof]);
	() @safe pure nothrow @nogc {
		double* p = block.emplace!double;
		assert(p !is null);
		assert(*p is double.init);
	}();
}

// Classes
@system unittest
{
	static class C
	{
		int n;
		this(int n) @safe { this.n = n; }
	}

	enum size = __traits(classInstanceSize, C);
	auto block = UninitializedBlock(new void[](size));
	() @safe {
		C c = block.emplace!C(123);
		assert(c !is null);
		assert(c.n == 123);
	}();
}

// Classes with throwing constructors
@system unittest
{
	static class C
	{
		int n;
		this(int n) @safe { throw new Exception("oops"); }
	}

	enum size = __traits(classInstanceSize, C);
	auto block = UninitializedBlock(new void[](size));
	() @safe {
		C c;
		try {
			c = block.emplace!C(123);
			assert(0, "Exception should have been thrown");
		} catch (Exception e) {
			assert(c is null);
			assert(!block.isNull);
		}
	}();
}

// Nested classes
@system unittest
{
	static class Outer
	{
		int n;
		this(int n) @safe { this.n = n; }
		this(int n) immutable @safe { this.n = n; }
		class Inner
		{
			int m;
			this(int m) @safe { this.m = m; }
			this(int m) immutable @safe { this.m = m; }
			int fun() const @safe { return n; }
		}
		class Inner2
		{
			int m;
			int fun() @safe { return n; }
		}
		class Inner3
		{
			int m;
			this() @safe { this.m = 456; }
			int fun() @safe { return n; }
		}
	}

	// Constructor initialization
	{
		enum size = __traits(classInstanceSize, Outer.Inner);
		auto block = UninitializedBlock(new void[](size));
		() @safe {
			static assert(!__traits(compiles,
				block.emplace!(Outer.Inner)(456)
			));
			auto inner = block.emplace!(Outer.Inner)(new Outer(123), 456);
			assert(inner !is null);
			assert(inner.m == 456);
			assert(inner.fun() == 123);
		}();
	}
	// ... with immutable
	{
		enum size = __traits(classInstanceSize, Outer.Inner);
		auto block = UninitializedBlock(new void[](size));
		() @safe {
			auto inner = block.emplace!(immutable(Outer.Inner))(
				new immutable(Outer)(123), 456
			);
			assert(inner !is null);
			assert(inner.m == 456);
			assert(inner.fun() == 123);
		}();
	}
	// Default initialization
	{
		enum size = __traits(classInstanceSize, Outer.Inner2);
		auto block = UninitializedBlock(new void[](size));
		() @safe {
			auto inner2 = block.emplace!(Outer.Inner2)(new Outer(123));
			assert(inner2 !is null);
			assert(inner2.m == 0);
			assert(inner2.fun() == 123);
		}();
	}
	// Default construction
	{
		enum size = __traits(classInstanceSize, Outer.Inner3);
		auto block = UninitializedBlock(new void[](size));
		() @safe {
			auto inner3 = block.emplace!(Outer.Inner3)(new Outer(123));
			assert(inner3 !is null);
			assert(inner3.m == 456);
			assert(inner3.fun() == 123);
		}();
	}
}

// Nested class + immutable + opCast on outer class
@system unittest
{
	static class Outer
	{
		int n;
		this(int n) immutable @safe { this.n = n; }
		auto opCast(T)() const { return cast(T) null; }

		class Inner
		{
			int m;
			this(int m) immutable @safe { this.m = m; }
			int fun() const @safe { return n; }
		}
	}

	enum size = __traits(classInstanceSize, Outer.Inner);
	auto block = UninitializedBlock(new void[](size));
	() @safe {
		auto inner = block.emplace!(immutable(Outer.Inner))(
			new immutable(Outer)(123), 456
		);
		assert(inner !is null);
		assert(inner.m == 456);
		assert(inner.fun() == 123);
	}();
}

// Nested class + immutable + alias this
@system unittest
{
	static class Outer
	{
		int n;
		this(int n) immutable @safe { this.n = n; }
		auto opCast(T)() const { return cast(T) null; }

		class Inner
		{
			int m;
			this(int m) immutable @safe { this.m = m; }
			int fun() const @safe { return n; }
		}
	}

	struct Wrapper
	{
		void* p;
		Outer outer;
		this(immutable Outer outer) immutable @safe
		{
			this.outer = outer;
		}
		alias this = outer;
	}

	enum size = __traits(classInstanceSize, Outer.Inner);
	auto block = UninitializedBlock(new void[](size));
	() @safe {
		auto inner = block.emplace!(immutable(Outer.Inner))(
			immutable(Wrapper)(new immutable(Outer)(123)), 456
		);
		assert(inner !is null);
		assert(inner.m == 456);
		assert(inner.fun() == 123);
	}();
}

// Structs with constructors
@system unittest
{
	static struct S
	{
		int n;
		string s;
		this(int n, string s) @safe
		{
			this.n = n;
			this.s = s;
		}
	}

	auto block = UninitializedBlock(new void[](S.sizeof));
	() @safe {
		S* s = block.emplace!S(123, "hello");
		assert(s !is null);
		assert(s.n == 123);
		assert(s.s == "hello");
	}();
}

// Unions with constructors
@system unittest
{
	static union U
	{
		int n;
		string s;
		this(int n) @safe { this.n = n; }
		this(string s) @safe { this.s = s; }
	}

	{
		auto block = UninitializedBlock(new void[](U.sizeof));
		() @safe {
			U* u = block.emplace!U(123);
			assert(u !is null);
			assert(u.n == 123);
		}();
	}
	{
		auto block = UninitializedBlock(new void[](U.sizeof));
		() @safe {
			U* u = block.emplace!U("hello");
			assert(u !is null);
			() @trusted { assert(u.s == "hello"); }();
		}();
	}
}

// Structs/unions without constructors
@system unittest
{
	static struct S { int n; string s; }
	static union U { int n; string s; }

	{
		auto block = UninitializedBlock(new void[](S.sizeof));
		() @safe {
			S* s = block.emplace!S(S(123, "hello"));
			assert(s !is null);
			assert(s.n == 123);
			assert(s.s == "hello");
		}();
	}
	{
		auto block = UninitializedBlock(new void[](U.sizeof));
		() @safe {
			U* u = block.emplace!U(U(123));
			assert(u !is null);
			assert(u.n == 123);
		}();
	}
	{
		auto block = UninitializedBlock(new void[](U.sizeof));
		() @safe {
			U initializer = { s: "hello" };
			U* u = block.emplace!U(initializer);
			assert(u !is null);
			() @trusted { assert(u.s == "hello"); }();
		}();
	}
}

// Immutable structs
@system unittest
{
	static struct S { int n; }

	auto block = UninitializedBlock(new void[](S.sizeof));
	() @safe {
		auto s = block.emplace!(immutable(S))(immutable(S)(123));
		assert(s !is null);
		assert(s.n == 123);
	}();
}

// Nested structs
@system unittest
{
	int n = 456;
	struct Nested
	{
		int m;
		this(int m) @safe { this.m = m; }
		int fun() @safe { return n; }
	}

	// From rvalue
	{
		auto block = UninitializedBlock(new void[](Nested.sizeof));
		() @safe {
			auto nested = block.emplace!Nested(Nested(123));
			assert(nested !is null);
			assert(nested.m == 123);
			assert(nested.fun() == 456);
		}();
	}
	// From ctor args
	/+
	Disabled due to https://issues.dlang.org/show_bug.cgi?id=8850
	Attempting to compile this test produces the following errors:

	Error: cannot access frame pointer of `pbackus.lifetime.__unittest_L508_C9.Nested`
	Error: template instance `pbackus.lifetime.Emplaced!(Nested).Emplaced.__ctor!int` error instantiating
	instantiated from here: `emplace!(Nested, int)`

	core.lifetime.emplace handles this even worse--it silently sets the context pointer to null.
	See https://issues.dlang.org/show_bug.cgi?id=14402
	+/
	version (none)
	{
		auto block = UninitializedBlock(new void[](Nested.sizeof));
		() @safe {
			auto nested = block.emplace!Nested(123);
			assert(nested !is null);
			assert(nested.m == 123);
			assert(nested.fun() == 456);
		}();
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
auto emplaceInitializer(T)(ref UninitializedBlock block)
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

		No initSymbol, and T.init may be large, so recursively initialize each
		element one by one.

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
			auto eptr = eblock.emplaceInitializer!E;
			assert(eptr !is null);
		}

		return (() @trusted => cast(T*) block.memory.ptr)();
	} else {
		/+
		Builtin types and enums

		No initSymbol, so we have to create our own.
		+/
		static immutable initSymbol = T.init;
		return () @trusted {
			auto initializer = cast(const(void[])) (&initSymbol)[0 .. 1];
			block.memory[0 .. size] = initializer[];
			return cast(T*) block.memory.ptr;
		}();
	}
}

version (unittest) {
	private void checkInit(T)()
	{
		static if (is(T == class))
			enum size = __traits(classInstanceSize, T);
		else
			enum size = T.sizeof;

		auto block = UninitializedBlock(new void[](size));

		static if (is(T == class)) {
			auto expected = cast(const(ubyte[])) __traits(initSymbol, T);
		} else {
			// Use T[1] to bypass possible user-defined .init
			static immutable initSymbol = (T[1]).init;
			auto expected = cast(const(ubyte[])) (&initSymbol)[0 .. 1];
		}

		auto p = () @safe pure nothrow @nogc {
			return block.emplaceInitializer!T;
		}();
		auto actual = (cast(const(ubyte)*) p)[0 .. size];

		assert(block.isNull);
		assert(actual == expected,
			"`checkInit!(" ~ T.stringof ~ ")` failed");
	}
}

// Basic types
@system unittest
{
	import std.meta: AliasSeq, Map = staticMap;
	import std.traits: ImmutableOf;

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
	import std.traits: ImmutableOf;

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
		 auto p = block.emplaceInitializer!(__vector(T));
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

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		IntEnum, StringEnum, StructEnum, ClassEnum, ArrayEnum
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Enum with immutable field in base type
@system unittest
{
	static struct S { immutable int n = 123; }
	enum E : S { a = S.init }

	checkInit!E();
}

// Enum with throwing destructor in base type
@system unittest
{
	static struct S
	{
		int n = 123;
		~this() @safe pure { throw new Exception("oops"); }
	}
	enum E : S { a = S.init }
	
	checkInit!E();
}

// Oversized blocks
@system unittest
{
	static struct S { int n; }
	static class C { int n; }

	auto b1 = UninitializedBlock(new void[](32));
	auto p1 = b1.emplaceInitializer!S;
	assert(p1 !is null);

	auto b2 = UninitializedBlock(new void[](32));
	auto p2 = b2.emplaceInitializer!C;
	assert(p2 !is null);
}
