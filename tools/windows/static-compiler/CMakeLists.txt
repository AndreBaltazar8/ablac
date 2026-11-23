cmake_minimum_required(VERSION 3.20)
project(AblaWindowsCompiler LANGUAGES CXX)

# The LLVM component libraries can exceed the Windows command-line limit.
set(CMAKE_NINJA_FORCE_RESPONSE_FILE ON)

if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The Windows compiler requires an x64 MSVC toolchain")
endif()

find_package(LLD 23.1.3 EXACT REQUIRED CONFIG PATHS "${ABLA_LLVM_ROOT}/lib/cmake/lld" NO_DEFAULT_PATH)
llvm_map_components_to_libnames(llvm_components all)

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
target_link_libraries(ablac PRIVATE lldCOFF lldELF lldWasm LLVMOptDriver ${llvm_components} ${windows_imports})
target_link_options(ablac PRIVATE
  /entry:wmainCRTStartup /subsystem:console /machine:x64 /brepro /stack:134217728
  "/def:${ABLA_IMPORT_DIR}/exports.def")
