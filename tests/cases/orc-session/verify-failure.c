#include <dlfcn.h>
#include <stdlib.h>

int LLVMVerifyModule(void *module, int action, char **message) {
    int (*verify)(void *, int, char **) = dlsym(RTLD_NEXT, "LLVMVerifyModule");
    void *(*named_function)(void *, const char *) = dlsym(RTLD_NEXT, "LLVMGetNamedFunction");
    void *(*module_context)(void *) = dlsym(RTLD_NEXT, "LLVMGetModuleContext");
    void *(*append_block)(void *, void *, const char *) = dlsym(RTLD_NEXT, "LLVMAppendBasicBlockInContext");
    if (!verify || !named_function || !module_context || !append_block) abort();

    void *main_function = named_function(module, "main");
    if (!main_function) abort();
    append_block(module_context(module), main_function, "emit_llvm_injected_verify_failure");
    return verify(module, action, message);
}
