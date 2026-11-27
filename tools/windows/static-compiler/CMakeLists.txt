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
  # The probes link the shipped compiler object; the candidate links ABLA_CANDIDATE_OBJECT when it is given (the same
  # compiler with the Windows C library of src/orc_windows_main_crtfree.ab, steps 2 to 6), with its own import libraries.
  set(abla_probe_object "${ABLA_COMPILER_OBJECT}")
  set(abla_probe_import_directory "${ABLA_IMPORT_DIR}")
  set(abla_probe_import_libraries ${windows_imports})
  function(abla_crt_probe name)
    add_executable(${name} "${abla_probe_object}" "../../../runtime/abla_lld_shim.cpp" crt-start.cpp)
    set_property(TARGET ${name} PROPERTY MSVC_RUNTIME_LIBRARY MultiThreaded)
    target_compile_features(${name} PRIVATE cxx_std_17)
    target_compile_definitions(${name} PRIVATE _HAS_EXCEPTIONS=0)
    target_compile_options(${name} PRIVATE /GR- /EHs-c-)
    target_include_directories(${name} PRIVATE ${LLVM_INCLUDE_DIRS} ${LLD_INCLUDE_DIRS})
    target_link_libraries(${name} PRIVATE lldCOFF lldELF lldWasm LLVMOptDriver LLVMOrcJIT ${abla_probe_import_libraries})
    target_link_options(${name} PRIVATE
      /entry:wmainCRTStartup /subsystem:console "/machine:${ABLA_WINDOWS_MACHINE}" /brepro /stack:134217728
      "/def:${abla_probe_import_directory}/exports.def" ${ARGN})
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
  if(ABLA_CANDIDATE_OBJECT)
    set(abla_probe_object "${ABLA_CANDIDATE_OBJECT}")
    set(abla_probe_import_directory "${ABLA_CANDIDATE_IMPORT_DIR}")
    file(GLOB abla_probe_import_libraries "${ABLA_CANDIDATE_IMPORT_DIR}/*.lib")
    set_source_files_properties("${ABLA_CANDIDATE_OBJECT}" PROPERTIES EXTERNAL_OBJECT TRUE)
  endif()
  # The C names the Abla runtime declares itself are exported under others (src/static_libc/memory.ab and windows/string.ab) and
  # bound here, as the Linux link's --defsym binds them.
  abla_crt_probe(ablac-crt-candidate /nodefaultlib:libucrt.lib /nodefaultlib:libcmt.lib /defaultlib:libvcruntime.lib
    /alternatename:malloc=abla_libc_malloc /alternatename:calloc=abla_libc_calloc /alternatename:free=abla_libc_free
    /alternatename:realloc=abla_libc_realloc /alternatename:atoi=abla_windows_atoi /errorlimit:0)
  # Step 1: libcmt's start-up and C++ support of our own (crt-free-start.cpp, built without /GS checks of its own, as it
  # defines them, and naming no default library).
  target_sources(ablac-crt-candidate PRIVATE crt-free-start.cpp)
  set_source_files_properties(crt-free-start.cpp PROPERTIES COMPILE_OPTIONS "/GS-;/Zl")
  # The /GS exception handlers (__GSHandlerCheck and its _SEH/_EH/_EH4 forms, which check a frame's cookie when an
  # exception is dispatched through it) and ARM64's __security_push_cookie/__security_pop_cookie stay Microsoft's own:
  # their members are taken out of libcmt.lib (on LIB, as the link finds it) and linked as objects, as the /MT link
  # links them today.
  # LIB is ;-separated on every host, as CMake lists are (PATHS ENV would split it on : off Windows).
  find_file(ABLA_LIBCMT libcmt.lib PATHS $ENV{LIB} NO_DEFAULT_PATH NO_CACHE)
  if(NOT ABLA_LIBCMT)
    message(FATAL_ERROR "libcmt.lib is not on LIB; the candidate link takes its /GS handler members")
  endif()
  # llvm-ar (beside clang-cl, or on PATH): llvm-lib lists members but has no /extract.
  get_filename_component(abla_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
  find_program(ABLA_LLVM_AR llvm-ar HINTS "${abla_compiler_directory}" NO_CACHE REQUIRED)
  execute_process(COMMAND "${ABLA_LLVM_AR}" t "${ABLA_LIBCMT}" OUTPUT_VARIABLE libcmt_members
    RESULT_VARIABLE libcmt_status)
  if(NOT libcmt_status EQUAL 0)
    message(FATAL_ERROR "${ABLA_LLVM_AR} could not list ${ABLA_LIBCMT}")
  endif()
  string(REPLACE "\n" ";" libcmt_members "${libcmt_members}")
  set(libcmt_directory "${CMAKE_BINARY_DIR}/libcmt-members")
  set(libcmt_folder amd64)
  if(ABLA_WINDOWS_MACHINE STREQUAL "arm64")
    set(libcmt_folder arm64)
  endif()
  file(REMOVE_RECURSE "${libcmt_directory}")
  set(libcmt_objects)
  foreach(member IN LISTS libcmt_members)
    string(STRIP "${member}" member)
    # Only the machine's own folder: ARM64's libcmt also holds arm64ec and amd64 builds of these members.
    if(member MATCHES "[\\\\/]${libcmt_folder}[\\\\/](gshandler[a-z0-9_]*|secpushpop)\\.obj$")
      # Each member alone in a directory: the file llvm-ar writes is named after the member, which is a Windows path
      # (its last part on Windows, all of it elsewhere).
      set(name "${CMAKE_MATCH_1}")
      set(scratch "${libcmt_directory}/${name}")
      file(MAKE_DIRECTORY "${scratch}")
      execute_process(COMMAND "${ABLA_LLVM_AR}" x "${ABLA_LIBCMT}" "${member}" WORKING_DIRECTORY "${scratch}"
        RESULT_VARIABLE extract_status)
      file(GLOB extracted LIST_DIRECTORIES false "${scratch}/*")
      list(LENGTH extracted extracted_count)
      if(NOT extract_status EQUAL 0 OR NOT extracted_count EQUAL 1)
        message(FATAL_ERROR "${ABLA_LLVM_AR} could not extract ${member} from ${ABLA_LIBCMT}")
      endif()
      set(object "${libcmt_directory}/${name}.obj")
      file(RENAME "${extracted}" "${object}")
      list(APPEND libcmt_objects "${object}")
    endif()
  endforeach()
  if(NOT libcmt_objects)
    message(FATAL_ERROR "${ABLA_LIBCMT} has no gshandler members")
  endif()
  message(STATUS "Candidate link: libcmt members ${libcmt_objects}")
  set_source_files_properties(${libcmt_objects} PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
  target_sources(ablac-crt-candidate PRIVATE ${libcmt_objects})
endif()
