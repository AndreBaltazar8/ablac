package dev.abla.di

import dev.abla.llvm.ILLVMCodeGenerator
import dev.abla.llvm.LLVMCodeGenerator
import org.koin.dsl.module

val backendLLVMModule = module {
    single<ILLVMCodeGenerator> { LLVMCodeGenerator() }
}
