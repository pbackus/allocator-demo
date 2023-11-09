module pbackus.container.status;

import core.attribute: mustuse;

/// Status code returned by container methods that allocate
@mustuse struct Status
{
	private int code;

	@safe pure nothrow @nogc
	private this(int code)
	{
		this.code = code;
	}

	/// Returned on success
	enum Status Ok = Status(0);

	/// Returned if allocation fails
	enum Status AllocFailed = Status(1);

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
		switch (code) {
			case 0: return "Success";
			case 1: return "Memory allocation failed";
			default: return "Unknown failure";
		}
	}
}

// Distinct values
@safe pure nothrow @nogc
unittest
{
	static assert(Status.Ok != Status.AllocFailed);
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
	string failMsg = Status.AllocFailed.message;
	assert(okMsg != failMsg);
}

// isOk
@safe pure nothrow @nogc
unittest
{
	assert(Status.Ok.isOk);
	assert(!Status.AllocFailed.isOk);
}

// assumeOk
version (D_Exceptions)
@system pure
unittest
{
	import std.exception: assertThrown, assertNotThrown;
	
	assertNotThrown!Error(Status.Ok.assumeOk);
	assertThrown!Error(Status.AllocFailed.assumeOk);
}

// enforceOk
version (D_Exceptions)
@safe pure
unittest
{
	import std.exception: assertThrown, assertNotThrown;

	assertNotThrown(Status.Ok.enforceOk);
	assertThrown(Status.AllocFailed.enforceOk);
}
