/* main_pc.cpp — the entry point for desktop builds.
 *
 * reflaxe.CPP generates a `_main_.cpp` whose `main` discards argc and argv, which would leave the
 * runtime unable to see its own command line. Builds therefore exclude that file and use this one
 * instead: it hands the arguments to the backend and then calls the generated entry.
 *
 * Console ports supply their own equivalent. Keeping the entry point on the platform side also
 * means launch parameters arrive through the backend everywhere, including on systems that have
 * no command line at all — which is the reason this is a backend concern and not a runtime one.
 *
 * The entry class is a compile definition rather than a fixed name, because there is more than
 * one: the walking-skeleton demo is `Main`, a recompiled game is whatever its launcher is called.
 * CMake reads it out of the generated `_main_.cpp` so nothing has to be told twice.
 */

#include "backend_c_api.h"

#ifndef RECOMPSX_MAIN_HEADER
#define RECOMPSX_MAIN_HEADER "Main.h"
#define RECOMPSX_MAIN_CLASS Main
#endif

#include RECOMPSX_MAIN_HEADER

int main(int argc, const char** argv) {
    /* Skip argv[0]: the runtime wants arguments, not the program path. */
    bp_set_args(argc > 0 ? argc - 1 : 0, argc > 0 ? argv + 1 : argv);
    RECOMPSX_MAIN_CLASS::main();
    return 0;
}
