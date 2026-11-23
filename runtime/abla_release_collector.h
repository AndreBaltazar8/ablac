// Native release collector partition for the static compiler. LLVM exposes
// cloning by definition predicate and used-list maintenance in its C++ API.
#include "llvm-c/Transforms/PassBuilder.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Support/MemoryBuffer.h"
#include <set>
#include <string>
#include <vector>

namespace {
using namespace llvm;

static StringRef sourceName(const Function &function) {
    if (!function.hasFnAttribute("abla.source"))
        return {};
    StringRef name = function.getFnAttribute("abla.source").getValueAsString();
    size_t qualified = name.rfind("__ablaRuntime");
    return qualified == StringRef::npos ? name : name.drop_front(qualified);
}

static bool movable(StringRef name) {
    if (name == "__ablaRuntimePlatformMemoryCollect")
        return true;
    if (!name.consume_front("__ablaRuntimeHost"))
        return false;
    return name.starts_with("Background") || name.starts_with("Collection") ||
           name.starts_with("Mark") || name.starts_with("TraceMarked") ||
           name.starts_with("TraceParallel") || name.starts_with("Sweep") ||
           name.starts_with("GcAdaptive") || name.starts_with("GcWorkersDefault") ||
           name.starts_with("GcUseParallel") || name.starts_with("FreeWait") ||
           name.starts_with("FreeStart") || name.starts_with("FreeWorker") ||
           name.starts_with("FreeState") || name.starts_with("FreeBatch");
}

static void hidden(GlobalValue &value) {
    value.setLinkage(GlobalValue::ExternalLinkage);
    value.setVisibility(GlobalValue::HiddenVisibility);
    value.setDSOLocal(true);
}

static void dependencies(const Value &value, std::set<const GlobalValue *> &seen,
                         std::vector<const GlobalValue *> &pending) {
    if (const auto *global = dyn_cast<GlobalValue>(&value)) {
        if (seen.insert(global).second)
            pending.push_back(global);
    } else if (const auto *constant = dyn_cast<Constant>(&value)) {
        for (const Value *operand : constant->operands())
            dependencies(*operand, seen, pending);
    }
}

// Specialize the collector only when the program proves these hot allocator
// values stay at their standard initial values.
struct FixedAllocatorGlobal { const char *name; int64_t initial; };
static constexpr FixedAllocatorGlobal fixedAllocatorGlobals[] = {
    {"abla_global_412418841_845196761", 0}, // HostHeapMutex
    {"abla_global_159068239_50111472", 4611686018427387903LL}, // HostLimit
    {"abla_global_883777728_843902360", 134217728}, // HostSmallLimit
};

static bool fixedAllocatorGlobal(StringRef name) {
    for (const auto &global : fixedAllocatorGlobals)
        if (name == global.name) return true;
    return false;
}

static bool canFoldAllocatorGlobals(const Module &module) {
    for (const auto &fixed : fixedAllocatorGlobals) {
        const GlobalVariable *global = module.getNamedGlobal(fixed.name);
        if (!global || !global->hasLocalLinkage() || !global->hasInitializer() ||
            !global->getValueType()->isIntegerTy(64)) return false;
        const auto *initial = dyn_cast<ConstantInt>(global->getInitializer());
        if (!initial || initial->getSExtValue() != fixed.initial) return false;
        for (const User *user : global->users()) {
            const auto *load = dyn_cast<LoadInst>(user);
            if (!load || load->isVolatile() || load->isAtomic()) return false;
        }
    }
    return true;
}
static bool cloneHelper(const Function &function) {
    if (function.hasFnAttribute(Attribute::AlwaysInline)) return true;
    const StringRef name = sourceName(function);
    return function.hasLocalLinkage() && !function.hasAddressTaken() &&
           name.starts_with("__ablaRuntime") &&
           !name.starts_with("__ablaRuntimeMemoryPressure") &&
           !name.starts_with("__ablaRuntimeHostPressure");
}

// Keep a native ABI only for values the unsplit side can reach.
static bool needsCollectorExport(const GlobalValue &entry,
                                 const std::set<const GlobalValue *> &region) {
    std::vector<const User *> pending(entry.user_begin(), entry.user_end());
    std::set<const User *> seen;
    for (size_t index = 0; index < pending.size(); ++index) {
        const User *user = pending[index];
        if (!seen.insert(user).second) continue;
        if (const auto *instruction = dyn_cast<Instruction>(user)) {
            if (!region.count(instruction->getFunction())) return true;
        } else if (isa<GlobalValue>(user)) {
            return true;
        } else {
            pending.insert(pending.end(), user->user_begin(), user->user_end());
        }
    }
    return false;
}

static bool writeNames(StringRef path, const std::set<std::string> &names) {
    std::error_code error;
    raw_fd_ostream output(path, error);
    if (error) return false;
    for (const auto &name : names) output << name << '\n';
    output.close();
    return !output.has_error();
}

static bool produce(Module &module, const std::set<const GlobalValue *> &region,
                    StringRef directory, const char *passes,
                    LLVMTargetMachineRef machine, LLVMPassBuilderOptionsRef options) {
    std::set<const GlobalValue *> seen = region, kept = region;
    std::vector<const GlobalValue *> pending(region.begin(), region.end());
    std::set<std::string> imports, exports, moved;
    for (const GlobalValue *value : region)
        moved.insert(value->getName().str());
    for (const GlobalValue *value : region)
        if (needsCollectorExport(*value, region)) exports.insert(value->getName().str());
    for (size_t index = 0; index < pending.size(); ++index) {
        const GlobalValue *value = pending[index];
        if (const auto *global = dyn_cast<GlobalVariable>(value)) {
            if (global->hasInitializer() &&
                (global->isConstant() || fixedAllocatorGlobal(global->getName())) &&
                global->hasLocalLinkage()) {
                kept.insert(global);
                dependencies(*global->getInitializer(), seen, pending);
            }
        }
        if (const auto *function = dyn_cast<Function>(value)) {
            if (!function->isDeclaration() &&
                (region.count(function) || cloneHelper(*function))) {
                kept.insert(function);
                for (const BasicBlock &block : *function)
                    for (const Instruction &instruction : block)
                        for (const Value *operand : instruction.operands())
                            dependencies(*operand, seen, pending);
            }
        }
        if (!kept.count(value) && !value->isDeclaration())
            imports.insert(value->getName().str());
    }
    ValueToValueMapTy mapping;
    std::unique_ptr<Module> artifact = CloneModule(
        module, mapping, [&](const GlobalValue *value) { return kept.count(value) != 0; });
    artifact->setModuleInlineAsm(ArrayRef<Module::GlobalAsmFragment>{});
    for (const auto &fixed : fixedAllocatorGlobals)
        if (auto *global = artifact->getNamedGlobal(fixed.name))
            if (global->hasInitializer()) global->setConstant(true);
    for (const auto &name : exports)
        hidden(*artifact->getNamedValue(name));
    for (const auto &name : moved) {
        if (exports.count(name)) continue;
        auto *function = cast<Function>(artifact->getNamedValue(name));
        function->setLinkage(GlobalValue::InternalLinkage);
        function->setVisibility(GlobalValue::DefaultVisibility);
    }
    for (const auto &name : imports)
        hidden(*artifact->getNamedValue(name));
    for (const GlobalValue *value : kept) {
        if (region.count(value))
            continue;
        if (auto *function = dyn_cast<Function>(artifact->getNamedValue(value->getName()))) {
            function->setLinkage(GlobalValue::InternalLinkage);
            function->setVisibility(GlobalValue::DefaultVisibility);
        }
    }
    if (LLVMErrorRef error = LLVMRunPasses(wrap(artifact.get()), passes, machine, options)) {
        LLVMConsumeError(error);
        return false;
    }
    std::error_code error;
    raw_fd_ostream bytecode((directory + "/collector.bc").str(), error);
    if (error) return false;
    WriteBitcodeToFile(*artifact, bytecode);
    bytecode.close();
    return !bytecode.has_error() && writeNames((directory + "/exports").str(), exports) &&
           writeNames((directory + "/region").str(), moved) &&
           writeNames((directory + "/potential-imports").str(), imports);
}

static bool readNames(StringRef path, std::set<std::string> &names) {
    auto file = MemoryBuffer::getFile(path, false, false);
    if (!file || (*file)->getBufferSize() > 65536) return false;
    SmallVector<StringRef> lines;
    (*file)->getBuffer().split(lines, '\n', -1, false);
    for (StringRef name : lines) names.insert(name.str());
    return true;
}

static bool finalizeCollector(StringRef directory) {
    std::set<std::string> potential, imports;
    if (!readNames((directory + "/potential-imports").str(), potential)) return false;
    auto binary = object::ObjectFile::createObjectFile((directory + "/collector.o").str());
    if (!binary) {
        consumeError(binary.takeError());
        return false;
    }
    for (auto symbol : binary->getBinary()->symbols()) {
        auto flags = symbol.getFlags();
        if (!flags) {
            consumeError(flags.takeError());
            return false;
        }
        if (!(*flags & object::BasicSymbolRef::SF_Undefined)) continue;
        auto name = symbol.getName();
        if (!name) {
            consumeError(name.takeError());
            return false;
        }
        if (potential.count(name->str())) imports.insert(name->str());
    }
    return writeNames((directory + "/imports").str(), imports);
}

static bool consume(Module &module, const std::set<const GlobalValue *> &region,
                    StringRef directory) {
    std::set<std::string> imports, shipped, publicSymbols;
    if (!readNames((directory + "/imports").str(), imports) ||
        !readNames((directory + "/exports").str(), publicSymbols) ||
        !readNames((directory + "/region").str(), shipped)) return false;
    for (const GlobalValue *function : region) {
        if (!shipped.count(function->getName().str()) ||
            (needsCollectorExport(*function, region) && !publicSymbols.count(function->getName().str()))) {
            return false;
        }
    }
    std::vector<GlobalValue *> required;
    for (const auto &name : imports) {
        GlobalValue *value = module.getNamedValue(name);
        if (!value || value->isDeclaration()) {
            return false;
        }
        required.push_back(value);
    }
    for (GlobalValue *value : required)
        hidden(*value);
    appendToUsed(module, required);
    for (const GlobalValue *value : region) {
        Function &function = cast<Function>(*module.getNamedValue(value->getName()));
        function.deleteBody();
        function.removeFnAttr(Attribute::AlwaysInline);
        hidden(function);
    }
    return true;
}

} // namespace

// Zero means the ordinary release path. A positive result certifies that
// the module was split, or that the requested producer step succeeded.
extern "C" int abla_release_collector(LLVMModuleRef ref, const char *directory,
                                     int mode, const char *passes,
                                     LLVMTargetMachineRef machine,
                                     LLVMPassBuilderOptionsRef options) {
    if (mode == 2) return finalizeCollector(directory);
    Module &module = *unwrap(ref);
    if (!module.getFunction("main") || module.getFunction("LLVMRunPasses") ||
        module.getTargetTriple().getArch() != Triple::x86_64 ||
        !canFoldAllocatorGlobals(module)) return 0;
    std::set<const GlobalValue *> region;
    bool background = false;
    for (const Function &function : module) {
        if (function.isDeclaration()) continue;
        const StringRef name = sourceName(function);
        if (movable(name)) region.insert(&function);
        background |= name == "__ablaRuntimeHostGcWorkersDefault";
    }
    if (!background || region.empty()) return 0;
    return mode == 1 ? produce(module, region, directory, passes, machine, options)
                     : consume(module, region, directory);
}
