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
