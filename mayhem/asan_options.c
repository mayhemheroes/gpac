/*
 * mayhem/asan_options.c — bake detect_leaks=0 into every fuzz binary.
 *
 * LeakSanitizer (LSan) is enabled by default when building with
 * -fsanitize=address.  At process exit LSan ptrace-attaches to its own
 * threads to walk the heap for leaks.  Mayhem's coverage-collection
 * environment ALREADY holds the process under ptrace; Linux allows only one
 * tracer at a time, so LSan's attach fails.  LSan then calls _exit(-1),
 * which the coverage engine sees as "Run Failed" — 0 edges recorded.
 *
 * Fix: override __asan_default_options (and __lsan_default_options for
 * belt-and-suspenders) with a STRONG symbol so it wins over the ASan
 * runtime's own weak default, regardless of link order or whole-archive.
 * detect_leaks=0 keeps ASan + UBSan fully active; only leak scanning is
 * off (leaks aren't crash oracles for fuzzing anyway).
 *
 * Linked into every fuzz binary via mayhem/build.sh.
 */

const char *__asan_default_options(void) {
    return "detect_leaks=0";
}

const char *__lsan_default_options(void) {
    return "detect_leaks=0";
}
