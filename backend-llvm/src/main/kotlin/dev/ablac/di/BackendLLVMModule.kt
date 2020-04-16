package dev.ablac.di

import dev.ablac.common.ICodeGenerator
import dev.ablac.llvm.ILLVMCodeGenerator
import dev.ablac.llvm.LLVMCodeGenerator
import org.koin.dsl.module

val backendLLVMModule = module {
    single<ILLVMCodeGenerator> { LLVMCodeGenerator() }
}
