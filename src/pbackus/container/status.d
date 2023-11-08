module pbackus.container.status;

import core.attribute: mustuse;

/// Status code returned by container methods that allocate
@mustuse struct Status
{
	private Code code;

	@safe pure nothrow @nogc
	private this(Code code)
	{
		this.code = code;
	}

	/// Returned on success
	enum Status Ok = Status(Code.Ok);

	/// Returned if allocation fails
	enum Status AllocationFailure = Status(Code.AllocationFailure);

	/// True if this `Status` is `Ok`
	@safe pure nothrow @nogc
	bool isOk() const
	{
		return this == Ok;
	}

	/// Abort process if not `Ok`
	@safe pure nothrow @nogc
	void assumeOk() const
	{
		if (!isOk)
			assert(0, message);
	}

	version (D_Exceptions)
	/// Throw an exception if not `Ok`
	@safe pure
	void enforceOk() const
	{
		import std.exception: enforce;
		enforce(isOk, message);
	}

	/// Description of this `Status`
	@safe pure nothrow @nogc
	string message() const
	{
		import std.traits: EnumMembers, getUDAs;

		final switch (code) {
			static foreach (member; EnumMembers!Code) {
				case member:
					return getUDAs!(member, Message)[0].text;
			}
		}
	}
}

// Distinct values
@safe pure nothrow @nogc
unittest
{
	static assert(Status.Ok != Status.AllocationFailure);
}

// Can't be ignored
@safe pure nothrow @nogc
unittest
{
	static Status getStatus() { return Status.Ok; }

	assert(!__traits(compiles, { getStatus(); }));
}

// Distinct messages
@safe pure nothrow @nogc
unittest
{
	string okMsg = Status.Ok.message;
	string failMsg = Status.AllocationFailure.message;
	assert(okMsg != failMsg);
}

// isOk
@safe pure nothrow @nogc
unittest
{
	assert(Status.Ok.isOk);
	assert(!Status.AllocationFailure.isOk);
}

// assumeOk
version (D_Exceptions)
@system pure
unittest
{
	import std.exception: assertThrown, assertNotThrown;
	
	assertNotThrown!Error(Status.Ok.assumeOk);
	assertThrown!Error(Status.AllocationFailure.assumeOk);
}

// enforceOk
version (D_Exceptions)
@safe pure
unittest
{
	import std.exception: assertThrown, assertNotThrown;

	assertNotThrown(Status.Ok.enforceOk);
	assertThrown(Status.AllocationFailure.enforceOk);
}

// Code values and messages
private enum Code
{
	@Message("Success")
	Ok,

	@Message("Memory allocation failed")
	AllocationFailure,
}

// UDA for Code enum
private struct Message
{
	string text;
}
