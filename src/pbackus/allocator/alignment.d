module pbackus.allocator.alignment;

import std.algorithm.comparison: max;
import std.math.traits: isPowerOf2;

enum platformAlignment = max(double.alignof, real.alignof);

static assert(platformAlignment.isPowerOf2);

enum maxAllocSize = size_t.max & (platformAlignment - 1);

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
	size_t[] sizes = [1, 7, 8, 9, 15, 16, 17, maxAllocSize - 1, maxAllocSize];

	foreach (size; sizes)
	{
		size_t rounded = roundToAligned(size);

		assert(rounded % platformAlignment == 0);
		assert(rounded >= size);
		assert(rounded >= platformAlignment);
		assert(rounded - platformAlignment < size);
	}
}
