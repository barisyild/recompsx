/* main_pc.cpp — the desktop entry point.
 *
 * reflaxe.CPP generates a `_main_.cpp` whose `main` discards argc and argv, which would leave
 * the runtime unable to see its own command line. Builds therefore exclude that file and use
 * this one instead: it hands the arguments to the backend and then calls the generated entry.
 *
 * Console ports supply their own equivalent. Keeping the entry point on the platform side also
 * means launch parameters arrive through the backend everywhere, including on systems that have
 * no command line at all.
 */

#include "backend_c_api.h"
#include "Main.h"   /* generated: the Haxe class named by -main */

int main(int argc, const char** argv) {
    /* Skip argv[0]: the runtime wants arguments, not the program path. */
    bp_set_args(argc > 0 ? argc - 1 : 0, argc > 0 ? argv + 1 : argv);
    Main::main();
    return 0;
}
