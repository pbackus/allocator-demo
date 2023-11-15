/++
Owning reference to a single value.

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.container.unique;

import pbackus.allocator.block;
import pbackus.lifetime;
import pbackus.traits;
import pbackus.util;

import core.lifetime: move, forward;
import std.traits: hasMember;

/++
A unique, owning reference to an instance of `T`.

The value is stored in memory allocated by an `Allocator`.

`Unique` destroys its value and deallocates its memory when it goes out of
scope. To extend (or shorten) its lifetime, use `core.lifetime.move`.
+/
struct Unique(T, Allocator)
{
	/+
	Safety invariant: a `Unique` is a safe value as long as one of the
	following is true:
		1. Its `storage` is `null`.
		2. Its `storage` was allocated by its `allocator` and contains an
		   instance of `T` at offset 0.
	+/

	private @system Block!Allocator storage;
	private @system Allocator allocator;

	/// Creates a `Unique` using a given allocator instance
	this(Allocator allocator)
	{
		this.allocator = allocator;
	}

	@disable this(ref inout typeof(this)) inout;

	/// Calls the value's destructor.
	void destroyValue()
	{
		if (empty)
			return;

		mixin(trusted!"storage").borrow!((void[] mem) {
			auto ptr = mixin(trusted!q{cast(RefType!T) mem.ptr});
			static if (is(T == class) || is(T == interface))
				destroy(ptr);
			else
				destroy(*ptr);
		});
	}

	/++
	Destroys the value and deallocates its memory.

	If deallocation fails, the memory will be leaked.
	+/
	~this()
	{
		if (empty)
			return;

		destroyValue;
		mixin(trusted!"allocator").deallocate(mixin(trusted!"storage"));
	}

	/// True if this `Unique` has no value.
	@trusted
	bool empty() const
	{
		return storage.isNull;
	}
}

version (unittest) {
	private struct AllocatorStub
	{
		@safe pure nothrow @nogc:
		void deallocate(ref Block!AllocatorStub) {}
		Block!AllocatorStub allocate(size_t) { return typeof(return).init; }
	}
}

// empty
@system unittest
{
	static int n;

	Unique!(int, AllocatorStub) u1, u2;
	u2.storage = Block!AllocatorStub(cast(void[]) (&n)[0 .. 1]);

	() @safe pure nothrow @nogc {
		assert(u1.empty);
		assert(!u2.empty);
	}();
}

// destruction
@system unittest
{
	struct Probe
	{
		static bool destroyed;
		~this()  @safe { destroyed = true; }
	}

	static Probe probe;

	{
		Unique!(Probe, AllocatorStub) u;
		u.storage = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);

		Probe.destroyed = false;
	}
	assert(Probe.destroyed == true);

	{
		Unique!(Probe, AllocatorStub) u;
		u.storage = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);

		Probe.destroyed = false;
		() @safe { destroy(u); }();
		assert(Probe.destroyed == true);
	}

	{
		Unique!(Probe, AllocatorStub) u;
		u.storage = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);

		Probe.destroyed = false;
		() @safe { u.destroyValue; }();
		assert(Probe.destroyed == true);
	}
}

/++
Creates a `Unique` reference to a `T` value allocated with `allocator`.

If memory allocation or construction of the value fails, an empty `Unique!(T,
Allocator)` is returned.

If construction of the value fails, `makeUnique` will attempt to deallocate the
allocated memory. If deallocation fails, the memory will be leaked. To avoid
this, construct a `T` value first, then pass it to `makeUnique` as the initial
value.

Params:
	allocator = The allocator to use.
	args = Initial value or constructor arguments.

Returns: a `Unique!(T, Allocator)` that holds the allocated `T` value on
success, or an empty `Unique!(T, Allocator)` on failure.
+/
Unique!(T, Allocator)
makeUnique(T, Allocator, Args...)(Allocator allocator, auto ref Args args)
{
	auto result = Unique!(T, Allocator)(allocator);
	auto block = mixin(trusted!"result.allocator").allocate(storageSize!T);

	if (!block.isNull) {
		bool initialized;

		scope(exit) {
			if (initialized)
				() @trusted { result.storage = move(block); }();
			else
				mixin(trusted!"result.allocator").deallocate(block);
		}

		initialized = block.borrow!((scope void[] memory) {
			scope ublock = mixin(trusted!q{UninitializedBlock(memory)});
			auto ptr = ublock.emplace!T(forward!args);
			return ptr !is null;
		});

	}

	return result;
}

// Allocation failure
@safe unittest
{
	auto u = AllocatorStub().makeUnique!int(123);
	assert(u.empty);
}

// Allocation success
@safe unittest
{
	import pbackus.allocator.mallocator;

	auto u = Mallocator().makeUnique!int(123);
	assert(!u.empty);
}

// Construction failure frees memory
version (D_BetterC) {} else
@safe unittest
{
	static struct ThrowsInCtor
	{
		this(int n) @safe { throw new Exception("oops"); }
	}

	static struct AllocCounter
	{
		static size_t count;

		@trusted nothrow
		Block!AllocCounter allocate(size_t size)
		{
			count++;
			return typeof(return)(new void[](size));
		}

		@safe nothrow
		void deallocate(ref Block!AllocCounter block)
		{
			count--;
			block = typeof(block).init;
		}
	}

	try
		auto u = AllocCounter().makeUnique!ThrowsInCtor(123);
	catch (Exception e)
		assert(AllocCounter.count == 0);
}
