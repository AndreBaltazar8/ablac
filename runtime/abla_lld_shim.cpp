// The one piece of C++ in Abla's own source, built only by tools/build-static-compiler.sh (never by an ordinary build) and linked into the
// statically linked compiler (src/orc_main_static.ab) so that a link runs in the compiler's own process: no ld.lld to ship, find or start.
// Why C++: lld has no C API, only the C++ entry `lld::lldMain`, and the Abla compiler can call only C functions.
// What it calls: lld::lldMain with the ELF and WebAssembly drivers (liblldELF.a, liblldWasm.a, liblldCommon.a, the same lld version as
// the ld.lld and wasm-ld the compiler otherwise runs, so the output is byte for byte the external link's).
//
//   int abla_lld_main(const char *arguments, const char *errors)   (and abla_archive_gnu, at the end: the archive writer of the code generation units)
//
// `arguments` is the command line, one argument per line (a newline is not valid in a path the compiler links), argument 0 the program name
// ("ld.lld" or "wasm-ld"). Diagnostics go to the file `errors` (standard error when null or empty). Returns lld's exit code, or -1 when lld
// cannot run again in this process (a link that exits early), so the caller links through the external linker instead.
// A static compiler built without this object (no ABLA_STATIC_LLD_LIB) gets a stub of the same name that returns -1 (src/toolchain.ab).
#include "lld/Common/Driver.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Object/ArchiveWriter.h"
#include "llvm/Plugins/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/FileSystem.h"
#include <string>
#include <vector>

LLD_HAS_DRIVER(elf)
LLD_HAS_DRIVER(wasm)

// What the prebuilt lld and LLVM archives name that the static compiler does not carry (weak: a real definition wins). lld's driver initialises every target
// it was built for, and the compiler's archives leave out the targets it has no use for (src/toolchain.ab, bootstrapStaticLlvmOtherTarget); none of them is
// ever asked for a target (only X86, AArch64 and WebAssembly objects are linked), so they do nothing. LLVM's LTO backend asks for Polly's plugin, which the
// archives were built without (an empty plugin: it registers nothing).
#define ABLA_NO_TARGET(name)                                                         \
    extern "C" __attribute__((weak)) void LLVMInitialize##name##Target() {}          \
    extern "C" __attribute__((weak)) void LLVMInitialize##name##TargetInfo() {}      \
    extern "C" __attribute__((weak)) void LLVMInitialize##name##TargetMC() {}        \
    extern "C" __attribute__((weak)) void LLVMInitialize##name##AsmPrinter() {}      \
    extern "C" __attribute__((weak)) void LLVMInitialize##name##AsmParser() {}
ABLA_NO_TARGET(AMDGPU)
ABLA_NO_TARGET(ARM)
ABLA_NO_TARGET(AVR)
ABLA_NO_TARGET(BPF)
ABLA_NO_TARGET(Hexagon)
ABLA_NO_TARGET(Lanai)
ABLA_NO_TARGET(LoongArch)
ABLA_NO_TARGET(Mips)
ABLA_NO_TARGET(MSP430)
ABLA_NO_TARGET(NVPTX)
ABLA_NO_TARGET(PowerPC)
ABLA_NO_TARGET(RISCV)
ABLA_NO_TARGET(Sparc)
ABLA_NO_TARGET(SPIRV)
ABLA_NO_TARGET(SystemZ)
ABLA_NO_TARGET(VE)
ABLA_NO_TARGET(XCore)
__attribute__((weak)) llvm::PassPluginLibraryInfo getPollyPluginInfo() {
    return {LLVM_PLUGIN_API_VERSION, "Polly", LLVM_VERSION_STRING, [](llvm::PassBuilder &) {}};
}

extern "C" int abla_lld_main(const char *arguments, const char *errors) {
    std::vector<std::string> owned;
    const std::string text(arguments);
    for (size_t start = 0; start <= text.size();) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        owned.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    // lld's output does not depend on its thread count, and the static compiler's thread library is not complete: one thread.
    owned.push_back("--threads=1");
    std::vector<const char *> argv;
    for (const std::string &argument : owned) argv.push_back(argument.c_str());
    std::string diagnostics;
    llvm::raw_string_ostream errorStream(diagnostics);
    lld::Result result = lld::lldMain(argv, llvm::outs(), errorStream, {{lld::Gnu, &lld::elf::link}, {lld::Wasm, &lld::wasm::link}});
    errorStream.flush();
    if (!diagnostics.empty()) {
        std::error_code failure;
        if (errors != nullptr && errors[0] != 0) {
            llvm::raw_fd_ostream file(errors, failure, llvm::sys::fs::OF_None);
            if (!failure) file << diagnostics;
        } else llvm::errs() << diagnostics;
    }
    return result.canRunAgain || result.retCode == 0 ? result.retCode : -1;
}

// An archive of object files, as `llvm-ar rcsD --format=gnu OUTPUT MEMBER...` writes it (what the compiler's code generation units are combined into: src/codegen_units.ab):
// the same library routine with the same options, so the same bytes.
//
//   int abla_archive_gnu(const char *arguments)
//
// `arguments` is one path per line: the archive, then its members, in order. Returns 0, or 1 with the reason on standard error.
extern "C" int abla_archive_gnu(const char *arguments) {
    std::vector<std::string> paths;
    const std::string text(arguments);
    for (size_t start = 0; start <= text.size();) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        paths.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    if (paths.size() < 2) return 1;
    std::vector<llvm::NewArchiveMember> members;
    for (size_t index = 1; index < paths.size(); index++) {
        llvm::Expected<llvm::NewArchiveMember> member = llvm::NewArchiveMember::getFile(paths[index], /*Deterministic=*/true);
        if (!member) {
            llvm::errs() << paths[index] << ": " << llvm::toString(member.takeError()) << "\n";
            return 1;
        }
        members.push_back(std::move(*member));
    }
    llvm::Error failure = llvm::writeArchive(paths[0], members, llvm::SymtabWritingMode::NormalSymtab, llvm::object::Archive::K_GNU, /*Deterministic=*/true, /*Thin=*/false);
    if (failure) {
        llvm::errs() << paths[0] << ": " << llvm::toString(std::move(failure)) << "\n";
        return 1;
    }
    return 0;
}
