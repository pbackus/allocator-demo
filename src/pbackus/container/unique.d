/++
Owning reference to a single value.

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.container.unique;

import pbackus.allocator.block;
import pbackus.container.status;
import pbackus.lifetime;
import pbackus.traits;
import pbackus.util;

import core.lifetime: move, forward;
import std.traits: hasMember;
import std.typecons: nullable, Nullable;

/++
A unique, owning reference to an instance of `T`.

The value is stored in memory allocated by an `Allocator`.

`Unique` destroys its value and deallocates its memory when it goes out of
scope. To extend (or shorten) its lifetime, use `core.lifetime.move`.
+/
struct Unique(T, Allocator)
{
	/+
	Safety invariant: a `Unique` is a safe value as long as both its `storage`
	and its `allocator` are safe values, and one of the following is true:
		1. Its `storage` is `null`.
		2. Its `storage` was allocated by its `allocator` and contains an
		   instance of `T` at offset 0.
	+/

	private @system Block!Allocator storage;
	private @system Allocator allocator;

	/// Creates a `Unique` using a given allocator instance.
	this(Allocator allocator)
	{
		this.allocator = allocator;
	}

	/// Copying is disabled.
	@disable this(ref inout typeof(this)) inout;

	/++
	Constructs a new value in this `Unique`'s storage.

	Storage will be allocated if it does not already exist.

	If allocation of new storage succeeds, but construction fails, an attempt
	will be made to deallocate the new storage. If deallocation fails, the
	memory will be leaked.

	Params:
		args = New value or arguments to construct it.

	Returns: A [pbackus.container.status.Status|Status] indicating success or
	failure.
	+/
	Status emplace(Args...)(auto ref Args args)
	{
		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		// Use setter in addition to ref getter for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=21286
		@trusted static void setStorage(ref Unique this_, Block!Allocator block)
		{
			this_.storage = move(block);
		}

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static ref getStorage(ref Unique this_)
		{
			return this_.storage;
		}

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static ref getAllocator(ref Unique this_)
		{
			return this_.allocator;
		}

		bool wasEmpty = empty;

		if (wasEmpty) {
			setStorage(this, getAllocator(this).allocate(storageSize!T));

			if (empty)
				return Status.AllocFailed;
		} else {
			destroyValue;
		}

		bool initialized;

		scope(exit) {
			if (wasEmpty && !initialized) {
				getAllocator(this).deallocate(move(getStorage(this)));
			}
		}

		initialized = getStorage(this).borrow!((scope void[] memory) {
			@trusted static auto toUblock(ref void[] memory)
			{
				return UninitializedBlock(memory);
			}

			auto ublock = toUblock(memory);
			auto ptr = ublock.emplace!T(forward!args);
			return ptr !is null;
		});

		if (!initialized)
			return Status.EmplaceFailed;

		return Status.Ok;
	}

	/// Calls the value's destructor.
	void destroyValue()
	{
		if (empty)
			return;

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static ref getStorage(ref Unique this_)
		{
			return this_.storage;
		}

		getStorage(this).borrow!((scope void[] memory) {
			// Use static nested function for correct scope inference
			// https://issues.dlang.org/show_bug.cgi?id=22977
			@trusted static auto getPtr(ref void[] memory)
			{
				return cast(RefType!T) memory.ptr;
			}

			auto ptr = getPtr(memory);
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

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static ref getAllocator(ref Unique this_)
		{
			return this_.allocator;
		}

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static ref getStorage(ref Unique this_)
		{
			return this_.storage;
		}

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		// Use setter in addition to ref getter for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=21286
		@trusted static void setStorage(ref Unique this_, Block!Allocator block)
		{
			this_.storage = move(block);
		}

		destroyValue;
		getAllocator(this).deallocate(move(getStorage(this)));
	}

	/// True if this `Unique` has no value.
	@trusted
	bool empty() const
	{
		return storage.isNull;
	}

	/++
	Returns the stored value.

	This method is `@system` if `T` is a reference type (`class` or
	`interface`).

	It is an error to call this method on an empty `Unique`.
	+/
	inout(T) value() inout
	{
		if (empty)
			assert(0, "Can't get the value of an empty `" ~ typeof(this).stringof ~ "`");

		// Use static nested function for correct scope inference
		// https://issues.dlang.org/show_bug.cgi?id=22977
		@trusted static inout(RefType!T) getValuePtr(ref inout Unique this_)
		{
			return cast(inout(RefType!T)) this_.storage.memory.ptr;
		}

		static if (is(T == class) || is(T == interface)) {
			// Escaping a reference to the stored value is @system
			forceInferSystem;
			return getValuePtr(this);
		} else {
			return *getValuePtr(this);
		}
	}

	static if (!(is(T == class) || is(T == interface))) {
		/++
		Sets the stored value.

		This method cannot be used if `T` is a reference type (`class` or
		`interface`). Instead, use `makeUnique` to create a new `Unique`.

		It is an error to call this method on an empty `Unique'.
		+/
		void value(T value)
		{
			if (empty)
				assert(0, "Can't set the value of an empty `" ~ typeof(this).stringof ~ "`");

			@trusted static ref T getValueRef(ref Unique this_)
			{
				return *cast(T*) this_.storage.memory.ptr;
			}

			getValueRef(this) = forward!value;
		}
	} else {
		/// ditto
		@disable void value(T value);
	}
}

version (unittest) {
	private struct AllocatorStub
	{
		@safe pure nothrow @nogc:
		void deallocate(Block!AllocatorStub) {}
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
		~this() scope @safe { destroyed = true; }
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

// emplace - destroys existing value
@system unittest
{
	static struct Probe
	{
		static bool destroyed;
		~this() { destroyed = true; }
	}

	static Probe probe;

	Unique!(Probe, AllocatorStub) u;
	u.storage = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);

	// Use lvalue to avoid destruction of temporaries
	Probe newProbe;
	Probe.destroyed = false;
	cast(void) u.emplace(newProbe);
	assert(Probe.destroyed == true);
}

// value
@system unittest
{
	static int n = 123;

	Unique!(int, AllocatorStub) u;
	u.storage = Block!AllocatorStub(cast(void[]) (&n)[0 .. 1]);

	() @safe pure nothrow @nogc {
		assert(u.value == 123);
		u.value = 456;
		assert(u.value == 456);
	}();
}

/++
Creates a `Unique` reference to a `T` value allocated with `allocator`.

If memory allocation or construction of the value fails, an empty `Unique!(T,
Allocator)` is returned.

If construction of the value fails, `makeUnique` will attempt to deallocate the
allocated memory. If deallocation fails, the memory will be leaked. To avoid
this, construct a `T` value first, then pass it to `makeUnique` as the initial
value.

If `T`'s constructor escapes a reference to the constructed object,
`makeUnique!T` will be `@system`.

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
	cast(void) result.emplace(forward!args);
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
	assert(u.value == 123);
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
		void deallocate(Block!AllocCounter block)
		{
			count--;
		}
	}

	try
		auto u = AllocCounter().makeUnique!ThrowsInCtor(123);
	catch (Exception e)
		assert(AllocCounter.count == 0);
}

// Escape in ctor is @system
@safe unittest
{
	import pbackus.allocator.mallocator;

	static extern(C++) class EscapeThis
	{
		extern(D) static int* p;

		int n;
		this() @safe
		{
			p = &this.n;
		}
	}

	// Forbidden in @safe
	assert(!__traits(compiles, Mallocator().makeUnique!EscapeThis));

	// Ok in @system
	@system void test()
	{
		auto u = Mallocator().makeUnique!EscapeThis;
	}
}
