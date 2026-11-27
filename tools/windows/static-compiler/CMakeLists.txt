cmake_minimum_required(VERSION 3.20)
project(AblaWindowsCompiler LANGUAGES CXX)

# The LLVM component libraries can exceed the Windows command-line limit.
set(CMAKE_NINJA_FORCE_RESPONSE_FILE ON)

if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The Windows compiler requires a 64-bit MSVC toolchain")
endif()
set(ABLA_WINDOWS_MACHINE "x64" CACHE STRING "PE machine to link")
if(NOT ABLA_WINDOWS_MACHINE MATCHES "^(x64|arm64)$")
  message(FATAL_ERROR "The Windows compiler machine must be x64 or arm64")
endif()

find_package(LLD 23.1.3 EXACT REQUIRED CONFIG PATHS "${ABLA_LLVM_ROOT}/lib/cmake/lld" NO_DEFAULT_PATH)

file(GLOB windows_imports "${ABLA_IMPORT_DIR}/*.lib")
if(NOT EXISTS "${ABLA_COMPILER_OBJECT}" OR NOT windows_imports OR NOT EXISTS "${ABLA_IMPORT_DIR}/exports.def")
  message(FATAL_ERROR "A Windows compiler object, import libraries, and exports.def are required")
endif()

set_source_files_properties("${ABLA_COMPILER_OBJECT}" PROPERTIES EXTERNAL_OBJECT TRUE)
add_executable(ablac "${ABLA_COMPILER_OBJECT}" "../../../runtime/abla_lld_shim.cpp" crt-start.cpp)
set_property(TARGET ablac PROPERTY MSVC_RUNTIME_LIBRARY MultiThreaded)
target_compile_features(ablac PRIVATE cxx_std_17)
target_compile_definitions(ablac PRIVATE _HAS_EXCEPTIONS=0)
target_compile_options(ablac PRIVATE /GR- /EHs-c-)
target_include_directories(ablac PRIVATE ${LLVM_INCLUDE_DIRS} ${LLD_INCLUDE_DIRS})
# The compiler calls the ORC C API directly. LLD does not pull in its archive.
target_link_libraries(ablac PRIVATE lldCOFF lldELF lldWasm LLVMOptDriver LLVMOrcJIT ${windows_imports})
target_link_options(ablac PRIVATE
  /entry:wmainCRTStartup /subsystem:console "/machine:${ABLA_WINDOWS_MACHINE}" /brepro /stack:134217728
  "/def:${ABLA_IMPORT_DIR}/exports.def")

# The C runtime inventory (docs/design/windows-crt-free-compiler.md, measurement only; ablac above is unchanged). With
# -DABLA_CRT_INVENTORY=ON, more executables link the same inputs with the same options: ablac-crt-map with a link map
# and lld's /verbose member log, and four links that each leave one CRT archive out, which fail and list what that
# archive provided. None of them is shipped.
option(ABLA_CRT_INVENTORY "Define the C runtime inventory links" OFF)
if(ABLA_CRT_INVENTORY)
  function(abla_crt_probe name)
    add_executable(${name} "${ABLA_COMPILER_OBJECT}" "../../../runtime/abla_lld_shim.cpp" crt-start.cpp)
    set_property(TARGET ${name} PROPERTY MSVC_RUNTIME_LIBRARY MultiThreaded)
    target_compile_features(${name} PRIVATE cxx_std_17)
    target_compile_definitions(${name} PRIVATE _HAS_EXCEPTIONS=0)
    target_compile_options(${name} PRIVATE /GR- /EHs-c-)
    target_include_directories(${name} PRIVATE ${LLVM_INCLUDE_DIRS} ${LLD_INCLUDE_DIRS})
    target_link_libraries(${name} PRIVATE lldCOFF lldELF lldWasm LLVMOptDriver LLVMOrcJIT ${windows_imports})
    target_link_options(${name} PRIVATE
      /entry:wmainCRTStartup /subsystem:console "/machine:${ABLA_WINDOWS_MACHINE}" /brepro /stack:134217728
      "/def:${ABLA_IMPORT_DIR}/exports.def" ${ARGN})
  endfunction()
  # /lldmap gives each input section's bytes but names a member without its archive; the MSVC-style /map names
  # archive:member for each public symbol. CMake's vs_link_exe drops a successful link's /verbose output.
  abla_crt_probe(ablac-crt-map "/lldmap:${CMAKE_BINARY_DIR}/crt-inventory/ablac.map"
    "/map:${CMAKE_BINARY_DIR}/crt-inventory/ablac.msvc.map" /verbose)
  abla_crt_probe(ablac-crt-no-ucrt /nodefaultlib:libucrt.lib /errorlimit:0)
  abla_crt_probe(ablac-crt-no-ucrt-cmt /nodefaultlib:libucrt.lib /nodefaultlib:libcmt.lib /errorlimit:0)
  abla_crt_probe(ablac-crt-no-vcruntime /nodefaultlib:libvcruntime.lib /errorlimit:0)
  abla_crt_probe(ablac-crt-no-cpmt /nodefaultlib:libcpmt.lib /errorlimit:0)
  # Decision #163 (B): the candidate link, without the C library and its start-up, with VCRuntime named because libcmt's
  # objects are what bring its default-library directive. Each step of the plan lowers its undefined count; at 0 the
  # shipped link can switch.
  abla_crt_probe(ablac-crt-candidate /nodefaultlib:libucrt.lib /nodefaultlib:libcmt.lib /defaultlib:libvcruntime.lib
    /errorlimit:0)
endif()
