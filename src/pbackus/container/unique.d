module pbackus.container.unique;

import pbackus.allocator.block;

import core.lifetime;
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

	@trusted
	bool empty() const
	{
		return storage.isNull;
	}
}

version (unittest) {
	private struct AllocatorStub {}
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
