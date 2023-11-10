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
