module pbackus.traits;

/// Amount of memory needed to hold an instance of `T`
template storageSize(T)
{
	static if (is(T == class))
		enum storageSize = __traits(classInstanceSize, T);
	else
		enum storageSize = T.sizeof;
}

version (D_BetterC) {} else
@safe pure nothrow @nogc
unittest
{
	static class C { ubyte[123] data; }

	static assert(storageSize!int == int.sizeof);
	static assert(storageSize!C == __traits(classInstanceSize, C));
}

/// Type of a reference to an instance of `T`
template RefType(T)
{
	static if (is(T == class))
		alias RefType = T;
	else
		alias RefType = T*;
}

version (D_BetterC) {} else
@safe pure nothrow @nogc
unittest
{
	static class C { int data; }

	static assert(is(RefType!int == int*));
	static assert(is(RefType!C == C));
}
