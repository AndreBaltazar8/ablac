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
#include "llvm/CodeGen/CommandFlags.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Object/ArchiveWriter.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/TargetParser/Triple.h"
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
ABLA_NO_TARGET(Xtensa)
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

// Object emission in this process, as `llc` does it (#101): the release path's code generation flags (--function-sections, --data-sections, --align-loops) are options of
// the C++ API's TargetMachine and of the code generation passes, which the C API does not reach, so the compiler could not emit its release objects itself and ran llc.
// This builds the TargetMachine from llvm/CodeGen/CommandFlags.h's defaults, as llc does, and runs the same code generation pipeline over the same bitcode:
//
//   llc -filetype=obj -relocation-model=pic -O2 [--function-sections --data-sections] [--align-loops=N] [--disable-verify] BITCODE -o OBJECT
//
//   int abla_emit_object(const char *bitcode, const char *object, int verify, int sections, int alignLoops)
//
// Returns 0, or non-zero with the reason on standard error. (The compiler's targets only: X86, AArch64, WebAssembly.) The objects are byte for byte llc's
// (tools/test-codegen-inprocess.sh).
extern "C" {
void LLVMInitializeX86TargetInfo();
void LLVMInitializeX86Target();
void LLVMInitializeX86TargetMC();
void LLVMInitializeX86AsmPrinter();
void LLVMInitializeX86AsmParser();
void LLVMInitializeAArch64TargetInfo();
void LLVMInitializeAArch64Target();
void LLVMInitializeAArch64TargetMC();
void LLVMInitializeAArch64AsmPrinter();
void LLVMInitializeAArch64AsmParser();
void LLVMInitializeWebAssemblyTargetInfo();
void LLVMInitializeWebAssemblyTarget();
void LLVMInitializeWebAssemblyTargetMC();
void LLVMInitializeWebAssemblyAsmPrinter();
void LLVMInitializeWebAssemblyAsmParser();
}

static llvm::codegen::RegisterCodeGenFlags abla_codegen_flags;

extern "C" int abla_emit_object(const char *bitcode, const char *object, int verify, int sections, int alignLoops) {
    static bool initialized = false;
    static int aligned = -1;
    if (!initialized) {
        LLVMInitializeX86TargetInfo(); LLVMInitializeX86Target(); LLVMInitializeX86TargetMC(); LLVMInitializeX86AsmPrinter(); LLVMInitializeX86AsmParser();
        LLVMInitializeAArch64TargetInfo(); LLVMInitializeAArch64Target(); LLVMInitializeAArch64TargetMC(); LLVMInitializeAArch64AsmPrinter(); LLVMInitializeAArch64AsmParser();
        LLVMInitializeWebAssemblyTargetInfo(); LLVMInitializeWebAssemblyTarget(); LLVMInitializeWebAssemblyTargetMC(); LLVMInitializeWebAssemblyAsmPrinter(); LLVMInitializeWebAssemblyAsmParser();
        initialized = true;
    }
    if (aligned != alignLoops) {
        // llc's --align-loops is an option of the process.
        const std::string argument = "--align-loops=" + std::to_string(alignLoops);
        const char *arguments[] = {"abla", argument.c_str()};
        llvm::cl::ResetAllOptionOccurrences();
        llvm::cl::ParseCommandLineOptions(2, arguments, "", &llvm::errs());
        aligned = alignLoops;
    }
    llvm::LLVMContext context;
    llvm::SMDiagnostic diagnostic;
    std::unique_ptr<llvm::Module> module = llvm::parseIRFile(bitcode, diagnostic, context);
    if (!module) {
        diagnostic.print("abla", llvm::errs());
        return 1;
    }
    llvm::Triple triple(module->getTargetTriple());
    llvm::TargetOptions options = llvm::codegen::InitTargetOptionsFromCodeGenFlags(triple);
    if (sections) {
        options.FunctionSections = true;
        options.DataSections = true;
    }
    std::string error;
    const llvm::Target *target = llvm::TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        llvm::errs() << "abla: " << error << "\n";
        return 1;
    }
    std::unique_ptr<llvm::TargetMachine> machine(target->createTargetMachine(triple, llvm::codegen::getCPUStr(), llvm::codegen::getFeaturesStr(), options, llvm::Reloc::PIC_,
                                                                             llvm::codegen::getExplicitCodeModel(), llvm::CodeGenOptLevel::Default));
    if (!machine) {
        llvm::errs() << "abla: could not create a target machine\n";
        return 1;
    }
    module->setDataLayout(machine->createDataLayout());
    std::error_code failure;
    llvm::ToolOutputFile out(object, failure, llvm::sys::fs::OF_None);
    if (failure) {
        llvm::errs() << "abla: " << object << ": " << failure.message() << "\n";
        return 1;
    }
    llvm::legacy::PassManager passes;
    if (machine->addPassesToEmitFile(passes, out.os(), nullptr, llvm::CodeGenFileType::ObjectFile, /*DisableVerify=*/!verify)) {
        llvm::errs() << "abla: the target cannot emit an object file\n";
        return 1;
    }
    passes.run(*module);
    out.keep();
    return 0;
}

// ---- opt and llc in this process, for the cross targets (#101) -------------------------------------------------------------------------------------------------------------
// The compiler runs them as children of itself (`ablac --llvm-tool opt ARGUMENTS`, src/orc_main.ab), so each is a process of its own as the tools were and nothing of
// LLVM's global option state is reused. opt is LLVM's own driver (libLLVMOptDriver's optMain, which opt's main calls): its arguments, its passes, its bitcode. llc has no
// library driver, so this is its compileModule for the options the compiler passes (-filetype, -O, -mtriple, -relocation-model, --function-sections and the other code
// generation flags LLVM registers itself, --disable-verify, --discard-value-names, the input and -o): the same target machine, the same pipeline.
//
//   int abla_tool_main(const char *tool, const char *arguments)     tool "opt" or "llc"; the arguments one a line; the tool's exit code
//   int abla_shim_version()                                        2 here; the stub the build without the shim has returns 0
#include "llvm/CodeGen/MachineModuleInfo.h"
#include "llvm/Analysis/TargetLibraryInfo.h"

extern "C" int optMain(int argc, char **argv, llvm::ArrayRef<llvm::PassPlugin> PassPlugins);

extern "C" int abla_shim_version() { return 2; }

static std::vector<std::string> abla_lines(const char *text) {
    std::vector<std::string> lines;
    const std::string all(text);
    for (size_t start = 0; start <= all.size();) {
        size_t end = all.find('\n', start);
        if (end == std::string::npos) end = all.size();
        lines.push_back(all.substr(start, end - start));
        start = end + 1;
    }
    return lines;
}

static int abla_llc(const std::vector<std::string> &arguments) {
    LLVMInitializeX86TargetInfo(); LLVMInitializeX86Target(); LLVMInitializeX86TargetMC(); LLVMInitializeX86AsmPrinter(); LLVMInitializeX86AsmParser();
    LLVMInitializeAArch64TargetInfo(); LLVMInitializeAArch64Target(); LLVMInitializeAArch64TargetMC(); LLVMInitializeAArch64AsmPrinter(); LLVMInitializeAArch64AsmParser();
    LLVMInitializeWebAssemblyTargetInfo(); LLVMInitializeWebAssemblyTarget(); LLVMInitializeWebAssemblyTargetMC(); LLVMInitializeWebAssemblyAsmPrinter(); LLVMInitializeWebAssemblyAsmParser();
    std::string input, output = "-", fileType = "asm", triplePrefix;
    int optLevel = 2;
    bool verify = true, discardNames = false;
    std::vector<std::string> options{"llc"};
    for (size_t index = 0; index < arguments.size(); index++) {
        const std::string &argument = arguments[index];
        if (argument == "-o" && index + 1 < arguments.size()) output = arguments[++index];
        else if (argument.rfind("-filetype=", 0) == 0) fileType = argument.substr(10);
        else if (argument == "-O0" || argument == "-O1" || argument == "-O2" || argument == "-O3") optLevel = argument[2] - '0';
        else if (argument == "--disable-verify" || argument == "-disable-verify") verify = false;
        else if (argument == "--discard-value-names" || argument == "-discard-value-names") discardNames = true;
        else if (argument.rfind("-mtriple=", 0) == 0) triplePrefix = argument.substr(9);
        else if (argument.rfind("--mtriple=", 0) == 0) triplePrefix = argument.substr(10);
        else if (!argument.empty() && argument[0] != '-') input = argument;
        else options.push_back(argument);
    }
    std::vector<const char *> argv;
    for (const std::string &option : options) argv.push_back(option.c_str());
    llvm::cl::ResetAllOptionOccurrences();
    if (!llvm::cl::ParseCommandLineOptions(static_cast<int>(argv.size()), argv.data(), "", &llvm::errs())) return 1;
    llvm::LLVMContext context;
    context.setDiscardValueNames(discardNames);
    llvm::SMDiagnostic diagnostic;
    std::unique_ptr<llvm::Module> module = llvm::parseIRFile(input, diagnostic, context);
    if (!module) {
        diagnostic.print("llc", llvm::errs());
        return 1;
    }
    llvm::Triple triple;
    if (!triplePrefix.empty()) module->setTargetTriple(llvm::Triple(triplePrefix));
    triple = module->getTargetTriple();
    std::string error;
    const llvm::Target *target = llvm::TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        llvm::errs() << "llc: " << error << "\n";
        return 1;
    }
    llvm::TargetOptions targetOptions = llvm::codegen::InitTargetOptionsFromCodeGenFlags(triple);
    llvm::CodeGenOptLevel level = optLevel == 0 ? llvm::CodeGenOptLevel::None : optLevel == 1 ? llvm::CodeGenOptLevel::Less
                                  : optLevel == 3 ? llvm::CodeGenOptLevel::Aggressive : llvm::CodeGenOptLevel::Default;
    llvm::codegen::setFunctionAttributes(*module, llvm::codegen::getCPUStr(), llvm::codegen::getFeaturesStr());
    std::unique_ptr<llvm::TargetMachine> machine(target->createTargetMachine(triple, llvm::codegen::getCPUStr(), llvm::codegen::getFeaturesStr(), targetOptions,
                                                                             llvm::codegen::getExplicitRelocModel(), llvm::codegen::getExplicitCodeModel(), level));
    if (!machine) {
        llvm::errs() << "llc: could not create a target machine\n";
        return 1;
    }
    module->setDataLayout(machine->createDataLayout());
    llvm::TargetLibraryInfoImpl libraryInfo(triple);
    std::error_code failure;
    llvm::ToolOutputFile out(output, failure, fileType == "obj" ? llvm::sys::fs::OF_None : llvm::sys::fs::OF_TextWithCRLF);
    if (failure) {
        llvm::errs() << "llc: " << output << ": " << failure.message() << "\n";
        return 1;
    }
    llvm::legacy::PassManager passes;
    passes.add(new llvm::TargetLibraryInfoWrapperPass(libraryInfo));
    auto *machineInfo = new llvm::MachineModuleInfoWrapperPass(machine.get());
    if (machine->addPassesToEmitFile(passes, out.os(), nullptr, fileType == "obj" ? llvm::CodeGenFileType::ObjectFile : llvm::CodeGenFileType::AssemblyFile, !verify, machineInfo)) {
        llvm::errs() << "llc: the target does not support generation of this file type\n";
        return 1;
    }
    passes.run(*module);
    out.keep();
    return 0;
}

extern "C" int abla_tool_main(const char *tool, const char *arguments) {
    std::vector<std::string> lines = abla_lines(arguments);
    if (std::string(tool) == "llc") return abla_llc(lines);
    if (std::string(tool) != "opt") return 127;
    lines.insert(lines.begin(), "opt");
    std::vector<char *> argv;
    for (std::string &line : lines) argv.push_back(&line[0]);
    return optMain(static_cast<int>(argv.size()), argv.data(), {});
}
