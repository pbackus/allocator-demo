import std.meta: AliasSeq;

alias ModuleNames = AliasSeq!(
	"pbackus.allocator.alignment",
	"pbackus.allocator.block",
	"pbackus.allocator.gc_allocator",
	"pbackus.allocator.mallocator",
	"pbackus.allocator.region",

	"pbackus.container.status",
	"pbackus.container.unique",

	"pbackus.lifetime",
);

extern(C) int main()
{
	import core.stdc.stdio: printf;

	static foreach (moduleName; ModuleNames) {
		static foreach (test; __traits(getUnitTests, imported!moduleName)) {
			test();
		}
	}

	printf("%zu modules passed unittests\n", ModuleNames.length);
	return 0;
}
