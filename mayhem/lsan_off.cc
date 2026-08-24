// Leak detection is off by default for this target: ASan's leak checker fires on decode-path
// allocations that are not the memory-corruption bugs this fleet fuzzes for. This is a build-time
// hook (the sanctioned mechanism), not a runtime toggle.
extern "C" int __lsan_is_turned_off() { return 1; }
