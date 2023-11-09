module pbackus.container.unique;

import pbackus.allocator.block;
import pbackus.traits;

import core.lifetime: move;
import std.traits: hasMember;

struct Unique(T, Allocator)
{
	static assert(!(is(T == class) || is(T == interface)),
		"Reference types are not supported yet");

	/+
	Safety invariant: if block is not null, the start of its memory contains a
	valid object of type T.
	+/
	@system Block!Allocator storage;

	static if (hasMember!(Allocator, "instance")) {
		alias allocator = Allocator.instance;
	} else {
		/+
		Safety invariant: between the time a block is allocated with it and
		the time that block is deallocated, allocator must not be mutated.
		+/
		private @system Allocator allocator;
	}

	@system this(Block!Allocator storage, Allocator allocator)
	{
		this.storage = move(storage);
		this.allocator = allocator;
	}

	@disable this(ref inout typeof(this)) inout;

	void destroyValue()
	{
		if (empty)
			return;

		auto storagePtr = (() @trusted => &storage)();
		(*storagePtr).borrow!((void[] mem) {
			auto ptr = (() @trusted => cast(RefType!T) mem.ptr)();
			static if (is(T == class) || is(T == interface))
				destroy(ptr);
			else
				destroy(*ptr);
		});
	}

	~this()
	{
		if (empty)
			return;

		destroyValue();

		// Best effort - leak on deallocation failure
		auto allocatorPtr = (() @trusted => &allocator)();
		auto storagePtr = (() @trusted => &storage)();
		(*allocatorPtr).deallocate(*storagePtr);
	}

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
