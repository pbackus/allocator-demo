/++
Miscellaneous utilities.

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.util;

/// String mixin that evaluates `expr` in a @trusted context.
enum trusted(string expr) = "(auto ref () @trusted => " ~ expr ~ ")()";

@safe unittest
{
	@system int n = 123;

	assert(!__traits(compiles, n == 123));
	assert(mixin(trusted!"n") == 123);
	assert(mixin(trusted!"2*n + 1") == 247);
}

/// A function that calls this will be inferred as `@system`
pure nothrow @nogc
void forceInferSystem() {}

// hasFunctionAttributes uses druntime features in CTFE
version (D_BetterC) {} else
@safe unittest
{
	import std.traits: hasFunctionAttributes;

	static void test()
	{
		forceInferSystem;
	}

	static assert(hasFunctionAttributes!(test, "@system"));
}


/// Casts away `scope` from `arg`
auto ref assumeNonScope(T)(auto ref scope T arg)
{
	import core.stdc.stdint: uintptr_t;

	return *(cast(T*) cast(uintptr_t) &arg);
}

@system unittest
{
	() @safe {
		int n;
		scope int* p1 = &n;
		scope int* p2 = p1;

		// Can't assign to variable with longer lifetime
		static assert(!__traits(compiles, p1 = p2));
	}();

	() @safe {
		int n;
		scope int* p1 = &n;
		int* p2 = ((p) @trusted => assumeNonScope(p))(p1);

		// Ok - p2 has had scope stripped away
		p1 = p2;
	}();
}
