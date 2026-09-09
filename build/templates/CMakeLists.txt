# CMakeLists.txt — template copied next to a generated C++ tree.
#
# Expects, relative to this file:
#   cpp/include/   cpp/src/    the reflaxe.CPP output
# and RECOMPSX_ROOT pointing at the repository root (defaults to two levels up).
#
# Configure with:  cmake -S <dir> -B <dir>/build -G Ninja
cmake_minimum_required(VERSION 3.20)
project(recompsx C CXX)

if(NOT DEFINED RECOMPSX_ROOT)
  get_filename_component(RECOMPSX_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# -fwrapv is NOT optional. Haxe Int maps to C++ int, and MIPS semantics require two's-complement
# wrapping on overflow. Without it the compiler is entitled to assume overflow never happens and
# a bit-exact emulator becomes bit-approximate in ways that only show up in one game, once.
# (PROGRESS.md [M0-VERIFY] #17.)
# -fno-strict-aliasing is its sibling: emulated memory is untyped bytes that shim.MemA reads as
# aligned halfwords and words while everything else reads them as bytes, and this flag is how a
# C++ compiler is told that both views of the same storage are real. Same class of flag as
# -fwrapv — "the emulated machine's rules, not C++'s abstract ones" — and what emulators build
# with generally.
set(RECOMPSX_FLAGS -fwrapv -fno-strict-aliasing)

# Generated code is enormous and machine-written; its warnings are noise we cannot act on.
# -Wno-parentheses-equality is Clang's spelling and GCC has no such warning, so console
# toolchains (which are GCC) get the two flags they recognise and nothing else.
set(RECOMPSX_GEN_FLAGS -Wno-unused-value -Wno-unused-variable)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  list(APPEND RECOMPSX_GEN_FLAGS -Wno-parentheses-equality)
endif()

find_program(CCACHE ccache)
if(CCACHE)
  set(CMAKE_C_COMPILER_LAUNCHER ${CCACHE})
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE})
endif()

# The generated sources, minus the entry point: reflaxe.CPP's _main_.cpp discards argv, so the
# backend supplies main instead (docs/specs/backend.md §1.1).
file(GLOB_RECURSE GEN_SRC CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cpp/src/*.cpp")
list(FILTER GEN_SRC EXCLUDE REGEX "_main_\\.cpp$")

# Which class holds the entry point. Read out of the file being excluded rather than passed in:
# the Haxe build already knows it, and anything told to the build twice eventually disagrees.
# reflaxe.CPP emits exactly `<Class>::main();`, and a FATAL_ERROR here is the right failure —
# if that ever changes, the build should stop, not silently link the wrong entry.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/cpp/src/_main_.cpp" GEN_MAIN_SRC)
string(REGEX MATCH "([A-Za-z_][A-Za-z0-9_]*)::main\\(\\)" _ "${GEN_MAIN_SRC}")
set(RECOMPSX_MAIN "${CMAKE_MATCH_1}")
if(NOT RECOMPSX_MAIN)
  message(FATAL_ERROR "could not find the entry class in cpp/src/_main_.cpp")
endif()
message(STATUS "recompsx entry class: ${RECOMPSX_MAIN}")
if(GEN_SRC STREQUAL "")
  message(FATAL_ERROR "no generated sources under ${CMAKE_CURRENT_SOURCE_DIR}/cpp/src — run the Haxe build first")
endif()
set_source_files_properties(${GEN_SRC} PROPERTIES COMPILE_OPTIONS "${RECOMPSX_GEN_FLAGS}")

# Which backend answers the ABI. `null` is not a lesser build — it is how a run is made
# reproducible: no window, no audio device, no host clock reaching emulated state, so a headless
# digest means the same thing on a build machine as on a desk.
if(NOT DEFINED RECOMPSX_BACKEND)
  set(RECOMPSX_BACKEND "pc")
endif()

if(RECOMPSX_BACKEND STREQUAL "null")
  set(BACKEND_SRC
    "${RECOMPSX_ROOT}/src/backend/null/backend_null.c"
    "${RECOMPSX_ROOT}/src/backend/pc/main_pc.cpp")
elseif(RECOMPSX_BACKEND STREQUAL "dreamcast")
  set(BACKEND_SRC
    "${RECOMPSX_ROOT}/src/backend/dreamcast/backend_kos.c"
    "${RECOMPSX_ROOT}/src/backend/dreamcast/main_dc.cpp")
else()
  set(BACKEND_SRC
    "${RECOMPSX_ROOT}/src/backend/pc/backend_sdl2.c"
    "${RECOMPSX_ROOT}/src/backend/pc/main_pc.cpp")
endif()

# The emulated machine's memories live in their own translation unit on every C-linking target:
# as arrays with link-time addresses rather than pointers, which is worth two dependent loads and
# an interlock on every emulated memory access. Reasoning in the header itself.
set(SHIM_SRC "${RECOMPSX_ROOT}/src/shims/cxx/native/recompsx_arena.c")

add_executable(recompsx ${GEN_SRC} ${BACKEND_SRC} ${SHIM_SRC})

target_include_directories(recompsx PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/cpp/include"
  "${RECOMPSX_ROOT}/src/backend/api"
  "${RECOMPSX_ROOT}/src/shims/cxx/native")

target_compile_options(recompsx PRIVATE ${RECOMPSX_FLAGS})

target_compile_definitions(recompsx PRIVATE
  RECOMPSX_MAIN_HEADER=\"${RECOMPSX_MAIN}.h\"
  RECOMPSX_MAIN_CLASS=${RECOMPSX_MAIN})

if(RECOMPSX_BACKEND STREQUAL "dreamcast")
  # Nothing to find and nothing to link: the KOS toolchain file points the compiler at kos-cc,
  # which already carries KallistiOS's include paths, its linker script and libkallisti. The
  # only things worth saying here are about size, because 16 MB is the whole machine and the
  # generated code is most of what goes in it — dropping unreferenced functions and data at link
  # time is free and, on this target, not optional.
  target_compile_options(recompsx PRIVATE -ffunction-sections -fdata-sections)
  target_link_options(recompsx PRIVATE -Wl,--gc-sections)
  # dcload and every disc-mastering tool expect the ELF to say so in its name.
  set_target_properties(recompsx PROPERTIES SUFFIX ".elf")
elseif(NOT RECOMPSX_BACKEND STREQUAL "null")
  find_package(SDL2 REQUIRED)
  if(TARGET SDL2::SDL2)
    target_link_libraries(recompsx PRIVATE SDL2::SDL2)
  else()
    # Older SDL2 CMake packages export variables instead of a target.
    target_include_directories(recompsx PRIVATE ${SDL2_INCLUDE_DIRS})
    target_link_libraries(recompsx PRIVATE ${SDL2_LIBRARIES})
  endif()
endif()

# Forward-compat: Linux and Windows need no changes here beyond however SDL2 is discovered.
# Console targets replace BACKEND_SRC and the SDL2 dependency with their SDK's equivalents;
# the generated sources and flags stay exactly as they are. The Dreamcast above is the worked
# example — nine lines, no runtime changes, and the same CMakeLists everything else uses.
