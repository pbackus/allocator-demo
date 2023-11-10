/++
Safe `emplace` implementation

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.lifetime;

import pbackus.traits;
import pbackus.util;

/++
A block of memory that can be safely initialized

An `UninitializedBlock` can only be created in `@system` or `@trusted` code.
Before allowing `@safe` code to access it, your `@trusted` code must ensure
that the safety invariant described below is upheld (for example, by using
memory that has just been allocated).

$(H2 Safety Invariant)

An `UninitializedBlock` is a safe value as long as one of the following is
true:

$(NUMBERED_LIST
	* Its `memory` field is `null`.
	* The block of memory referred to by its `memory` field
	$(LIST
		* does not contain any [objects] reachable from `@safe` code, and
		* is not referred to by any other `UninitializedBlock`.
	)
)

Link_References:

objects = https://dlang.org/spec/intro.html#object-model
+/
struct UninitializedBlock
{
	/// A block of uninitialized memory, or `null`
	@system void[] memory;

	/// Creating an `UninitializedBlock` is `@system`
	@system pure nothrow @nogc
	this(void[] memory) { this.memory = memory; }

	/// Copying is disabled
	@disable this(ref inout UninitializedBlock) inout;

	/// True if `memory` is `null`, otherwise false
	@safe pure nothrow @nogc
	bool isNull() const
	{
		return this is UninitializedBlock.init;
	}

	/// Size of `memory` in bytes
	@trusted pure nothrow @nogc
	size_t size() const
	{
		return memory.length;
	}

	/// True if `memory` is properly aligned to hold a `T`
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
	static void[1] buf;
	UninitializedBlock b1 = null;
	UninitializedBlock b2 = buf[];

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

	static void[1] buf;
	UninitializedBlock first = buf[];
	UninitializedBlock second = move(first);

	assert(first.isNull);
	assert(!second.isNull);
}

// Can check an UninitializedBlock's size
@system unittest
{
	static void[123] buf;
	UninitializedBlock b1;
	UninitializedBlock b2 = buf[];
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
version (D_BetterC) {} else
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

The block's size and alignment must be sufficient to accomodate `T`. If they
are not, initialization will fail.

If initialization succeeds, `block` is set to `UninitializedBlock.init` so that
the same block cannot be used twice.

Params:
	block = The memory to use
	args = Initial value or constructor arguments

Returns: A pointer or class reference to the resulting object on success,
`null` on failure.

Bugs:

Because of [a D compiler bug](https://issues.dlang.org/show_bug.cgi?id=8850),
it is not possible for `emplace` to call the constructor of a nested `struct`
type. To work around this limitation, call the constructor first and pass the
resulting struct instance to `emplace` as the initial value.
+/
RefType!T emplace(T, Args...)(ref UninitializedBlock block, auto ref Args args)
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
		enum size = storageSize!T;

		if (block.size < size)
			return null;
		if (!block.isAlignedFor!T)
			return null;

		version (D_Exceptions) {
			/+
			Leave block uninitialized if constructor throws
			@trusted ok because the aliasing is never exposed to @safe code
			+/
			void[] savedMemory = mixin(trusted!"block.memory");
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
					"` as the first constructor argument"
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
		} else {
			/+
			Value types
			+/
			Emplaced!T* result = block.emplaceInitializer!(Emplaced!T);
			if (result)
				result.__ctor(forward!args);
			return &result.payload;
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

		/+
		Instead of checking for a valid initializer, let it fail naturally so
		the user gets a meaningful error message.
		+/
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
	static align(double.alignof) void[double.sizeof] buf;
	auto block = UninitializedBlock(buf[]);
	() @safe pure nothrow @nogc {
		double* p = block.emplace!double;
		assert(p !is null);
		assert(*p is double.init);
	}();
}

// Classes
version (D_BetterC) {} else
@system unittest
{
	static class C
	{
		int n;
		this(int n) @safe { this.n = n; }
	}

	enum size = __traits(classInstanceSize, C);
	enum alignment = __traits(classInstanceAlignment, C);

	static align(alignment) void[size] buf;
	auto block = UninitializedBlock(buf[]);
	() @safe {
		C c = block.emplace!C(123);
		assert(c !is null);
		assert(c.n == 123);
	}();
}

// Classes with throwing constructors
version (D_BetterC) {} else
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
version (D_BetterC) {} else
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
version (D_BetterC) {} else
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
version (D_BetterC) {} else
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

	static align(S.alignof) void[S.sizeof] buf;
	auto block = UninitializedBlock(buf[]);
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
		static align(U.alignof) void[U.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
		() @safe {
			U* u = block.emplace!U(123);
			assert(u !is null);
			assert(u.n == 123);
		}();
	}
	{
		static align(U.alignof) void[U.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
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
		static align(S.alignof) void[S.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
		() @safe {
			S* s = block.emplace!S(S(123, "hello"));
			assert(s !is null);
			assert(s.n == 123);
			assert(s.s == "hello");
		}();
	}
	{
		static align(U.alignof) void[U.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
		() @safe {
			U* u = block.emplace!U(U(123));
			assert(u !is null);
			assert(u.n == 123);
		}();
	}
	{
		static align(U.alignof) void[U.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
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

	static align(S.alignof) void[S.sizeof] buf;
	auto block = UninitializedBlock(buf[]);
	() @safe {
		auto s = block.emplace!(immutable(S))(immutable(S)(123));
		assert(s !is null);
		assert(s.n == 123);
	}();
}

// Nested structs
version (D_BetterC) {} else
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

// BetterC-compatible builtins and enums
@system unittest
{
	import std.meta: AliasSeq;

	enum E { a = 123 }

	alias TestTypes = AliasSeq!(
		int, double, char,
		int*, int[], int function(), typeof(null),
		E
	);

	alias testValues = AliasSeq!(
		123, 1.23, 'a',
		null, [1, 2, 3], function int() => 123, null,
		E.a
	);

	static foreach (i, T; TestTypes) {{
		static align(T.alignof) void[T.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
		() @safe {
			auto ptr = block.emplace!T(testValues[i]);
			assert(ptr !is null);
			assert(*ptr == testValues[i]);
		}();
	}}
}

// Druntime-dependent builtins
version (D_BetterC) {} else
@system unittest
{
	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(int[int]);
	alias testValues = AliasSeq!([1: 2, 3: 4]);

	static foreach (i, T; TestTypes) {{
		auto block = UninitializedBlock(new void[](T.sizeof));
		() @safe {
			auto ptr = block.emplace!T(testValues[i]);
			assert(ptr !is null);
			assert(*ptr == testValues[i]);
		}();
	}}
}

/++
Default-initializes an instance of `T` in uninitialized memory

The block's size and alignment must be sufficient to accomodate `T`. If they
are not, initialization will fail.

If initialization succeeds, `block` is set to `UninitializedBlock.init` so that
the same block cannot be used twice.

Params:
	block = The memory to initialize

Returns: a pointer or class reference to the initialized object on success,
`null` on failure.
+/
auto emplaceInitializer(T)(ref UninitializedBlock block)
{
	static assert(!is(immutable T == immutable void),
		"`void` cannot be intialized");
	static assert(!is(T == interface),
		"`interface " ~ T.stringof ~ "` cannot be initialized");

	enum size = storageSize!T;

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
			auto eblock = mixin(trusted!q{
				UninitializedBlock(block.memory[offset .. offset + E.sizeof])
			});
			// Exclude recursive call from @trusted for correct inference
			auto eptr = eblock.emplaceInitializer!E;
			assert(eptr !is null);
		}

		return mixin(trusted!q{cast(T*) block.memory.ptr});
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
		enum size = storageSize!T;

		static if (is(T == class))
			enum alignment = __traits(classInstanceAlignment, T);
		else
			enum alignment = T.alignof;

		static align(alignment) void[size] buf;
		auto block = UninitializedBlock(buf[]);

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
		Union
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Nested struct
version (D_BetterC) {} else
@system unittest
{
	int n;
	struct Nested
	{
		int fun() { return n; }
	}
	static assert(__traits(isNested, Nested));

	checkInit!Nested();
}

// Class types
version (D_BetterC) {} else
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
		Big
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Nested class
version (D_BetterC) {} else
@system unittest
{
	int n;
	class Nested
	{
		int fun() { return n; }
	}
	static assert(__traits(isNested, Nested));

	checkInit!Nested();
}

// Static array types
@system unittest
{
	static struct S { int x = 0xDEADBEEF; }

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		int[0], char[1], double[2], S[3], void[4]
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Static array of nested struct
version (D_BetterC) {} else
@system unittest
{
	int n;
	struct Nested
	{
		int fun() { return n; }
	}

	checkInit!(Nested[5]);
}

// Static array of class
version (D_BetterC) {} else
@system unittest
{
	static class C { int x = 0xDEADBEEF; }
	static interface I {}

	checkInit!(C[5]);
	checkInit!(I[5]);
}

// Vector types
// Disabled in BetterC due to https://issues.dlang.org/show_bug.cgi?id=19946
version (D_BetterC) {} else
version (D_SIMD)
@system unittest
{
	import core.simd;
	import std.meta: AliasSeq;

	alias BaseTypes = AliasSeq!(void[16], float[4], int[4]);

	static foreach (T; BaseTypes) {{
		alias Vec = __vector(T);
		static align(Vec.alignof) void[Vec.sizeof] buf;
		auto block = UninitializedBlock(buf[]);
		auto p = block.emplaceInitializer!Vec;
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

	enum IntEnum : int { a = 123 }
	enum StringEnum : string { a = "hello" }
	enum StructEnum : S { a = S(456) }
	enum AssignEnum : OpAssign { a = OpAssign(789) }
	enum ArrayEnum : int[5] { a = [1, 2, 3, 4, 5] }

	import std.meta: AliasSeq;

	alias TestTypes = AliasSeq!(
		IntEnum, StringEnum, StructEnum, ArrayEnum
	);

	static foreach (T; TestTypes)
		checkInit!T();
}

// Enum with nested-struct base type
version (D_BetterC) {} else
@system unittest
{
	int n;
	struct Nested
	{
		int x = 123;
		int fun() { return n; }
	}

	enum NestedEnum : Nested { a = Nested(456) }

	checkInit!NestedEnum();
}

// Enum with class base type
version (D_BetterC) {} else
@system unittest
{
	static class C
	{
		int x = 123;
		this(int x) { this.x = x; }
	}

	enum ClassEnum : C { a = new C(456) }

	checkInit!ClassEnum();
}

// Enum with immutable field in base type
@system unittest
{
	static struct S { immutable int n = 123; }
	enum E : S { a = S.init }

	checkInit!E();
}

// Enum with throwing destructor in base type
version (D_Exceptions)
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

	static align(S.alignof) void[32] buf;
	auto b1 = UninitializedBlock(buf[]);
	auto p1 = b1.emplaceInitializer!S;
	assert(p1 !is null);

	version (D_BetterC) {} else {
		static class C { int n; }

		auto b2 = UninitializedBlock(new void[](32));
		auto p2 = b2.emplaceInitializer!C;
		assert(p2 !is null);
	}
}
