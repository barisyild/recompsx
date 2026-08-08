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
set(RECOMPSX_FLAGS -fwrapv)

# Generated code is enormous and machine-written; its warnings are noise we cannot act on.
set(RECOMPSX_GEN_FLAGS -Wno-unused-value -Wno-unused-variable -Wno-parentheses-equality)

find_program(CCACHE ccache)
if(CCACHE)
  set(CMAKE_C_COMPILER_LAUNCHER ${CCACHE})
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE})
endif()

# The generated sources, minus the entry point: reflaxe.CPP's _main_.cpp discards argv, so the
# backend supplies main instead (docs/specs/backend.md §1.1).
file(GLOB_RECURSE GEN_SRC CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cpp/src/*.cpp")
list(FILTER GEN_SRC EXCLUDE REGEX "_main_\\.cpp$")
if(GEN_SRC STREQUAL "")
  message(FATAL_ERROR "no generated sources under ${CMAKE_CURRENT_SOURCE_DIR}/cpp/src — run the Haxe build first")
endif()
set_source_files_properties(${GEN_SRC} PROPERTIES COMPILE_OPTIONS "${RECOMPSX_GEN_FLAGS}")

set(BACKEND_SRC
  "${RECOMPSX_ROOT}/src/backend/pc/backend_sdl2.c"
  "${RECOMPSX_ROOT}/src/backend/pc/main_pc.cpp")

add_executable(recompsx ${GEN_SRC} ${BACKEND_SRC})

target_include_directories(recompsx PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/cpp/include"
  "${RECOMPSX_ROOT}/src/backend/api")

target_compile_options(recompsx PRIVATE ${RECOMPSX_FLAGS})

find_package(SDL2 REQUIRED)
if(TARGET SDL2::SDL2)
  target_link_libraries(recompsx PRIVATE SDL2::SDL2)
else()
  # Older SDL2 CMake packages export variables instead of a target.
  target_include_directories(recompsx PRIVATE ${SDL2_INCLUDE_DIRS})
  target_link_libraries(recompsx PRIVATE ${SDL2_LIBRARIES})
endif()

# Forward-compat: Linux and Windows need no changes here beyond however SDL2 is discovered.
# Console targets replace BACKEND_SRC and the SDL2 dependency with their SDK's equivalents;
# the generated sources and flags stay exactly as they are.
