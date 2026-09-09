/* main_dc.cpp — the entry point for Dreamcast builds.
 *
 * The same shape as main_pc.cpp and for the same reason: reflaxe.CPP's generated `_main_.cpp`
 * discards argc and argv, so every build excludes it and links a platform entry point instead
 * (docs/specs/backend.md §1.1).
 *
 * On this machine that indirection earns its keep twice over. A Dreamcast booted from a disc has
 * no command line at all, so `bp_init` is where the launch parameters actually come from — a
 * recompsx.cfg on the disc, or the conventional file names next to it. When the same binary is
 * launched over dcload during development there *is* a command line, and it wins. Neither case
 * is visible above this file.
 *
 * KOS_INIT_FLAGS is deliberately not here: it lives in backend_kos.c, because it defines global
 * symbols by name and C++ would mangle them into overriding nothing at all.
 */

#include "backend_c_api.h"

#ifndef RECOMPSX_MAIN_HEADER
#define RECOMPSX_MAIN_HEADER "Main.h"
#define RECOMPSX_MAIN_CLASS Main
#endif

#include RECOMPSX_MAIN_HEADER

int main(int argc, char** argv) {
    /* Skip argv[0]: the runtime wants arguments, not the program path. Under dcload there may be
     * none at all, and then bp_init reads them from storage instead. */
    bp_set_args(argc > 0 ? argc - 1 : 0,
                argc > 0 ? (const char**)(argv + 1) : (const char**)argv);
    if (bp_init("recompsx") != 0) return 1;
    RECOMPSX_MAIN_CLASS::main();
    bp_shutdown();
    return 0;
}
