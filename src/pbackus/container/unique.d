/++
Owning reference to a single value

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.container.unique;

import pbackus.allocator.block;
import pbackus.traits;
import pbackus.util;

import core.lifetime: move;
import std.traits: hasMember;

/++
A unique, owning reference to an instance of `T`

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

	static if (hasMember!(Allocator, "instance")) {
		alias allocator = Allocator.instance;
	} else {
		private @system Allocator allocator;
	}

	@system this(Block!Allocator storage, Allocator allocator)
	{
		this.storage = move(storage);
		this.allocator = allocator;
	}

	@disable this(ref inout typeof(this)) inout;

	/// Calls the value's destructor
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
	Destroys the value and deallocates its memory

	If deallocation fails, the memory will be leaked.
	+/
	~this()
	{
		if (empty)
			return;

		destroyValue();
		mixin(trusted!"allocator").deallocate(mixin(trusted!"storage"));
	}

	/// True if this `Unique` has no value
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
	}
}

// empty
@system unittest
{
	static int n;
	auto block = Block!AllocatorStub(cast(void[]) (&n)[0 .. 1]);

	auto u1 = Unique!(int, AllocatorStub).init;
	auto u2 = Unique!(int, AllocatorStub)(move(block), AllocatorStub());

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
		auto block = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);
		auto u = Unique!(Probe, AllocatorStub)(move(block), AllocatorStub());
		Probe.destroyed = false;
	}
	assert(Probe.destroyed == true);

	{
		auto block = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);
		auto u = Unique!(Probe, AllocatorStub)(move(block), AllocatorStub());
		Probe.destroyed = false;
		() @safe { destroy(u); }();
		assert(Probe.destroyed == true);
	}

	{
		auto block = Block!AllocatorStub(cast(void[]) (&probe)[0 .. 1]);
		auto u = Unique!(Probe, AllocatorStub)(move(block), AllocatorStub());
		Probe.destroyed = false;
		() @safe { u.destroyValue(); }();
		assert(Probe.destroyed == true);
	}
}
