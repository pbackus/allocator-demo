/++
Alignment-related utilities

License: Boost License 1.0
Authors: Paul Backus
+/
module pbackus.allocator.alignment;

import std.algorithm.comparison: max;
import std.math.traits: isPowerOf2;

/// Alignment sufficient for any type without an `align` attribute
enum platformAlignment = max(double.alignof, real.alignof);

@safe unittest
{
	static assert(platformAlignment.isPowerOf2);
}

/// Largest `size_t` that's a multiple of `platformAlignment`
enum maxAlignedSize = size_t.max & ~(platformAlignment - 1);

@safe unittest
{
	static assert(maxAlignedSize % platformAlignment == 0);
}

/// Rounds `size` up to a multiple of `platformAlignment`, if necessary
@safe pure nothrow @nogc
size_t roundToAligned(size_t size)
{
	size_t rem = size % platformAlignment;
	return rem ? size + (platformAlignment - rem) : size;
}

@safe unittest
{
	assert(roundToAligned(0) == 0);
}

@safe unittest
{
	import std.array: staticArray;

	auto sizes = staticArray(
		[1, 7, 8, 9, 15, 16, 17, maxAlignedSize - 1, maxAlignedSize]
	);

	foreach (size; sizes)
	{
		size_t rounded = roundToAligned(size);

		assert(rounded % platformAlignment == 0);
		assert(rounded >= size);
		assert(rounded >= platformAlignment);
		assert(rounded - platformAlignment < size);
	}
}
