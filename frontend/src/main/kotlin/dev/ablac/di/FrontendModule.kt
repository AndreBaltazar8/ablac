package dev.ablac.di

import dev.ablac.frontend.CompileService
import dev.ablac.frontend.ICompileService
import org.koin.dsl.module

val frontendModule = module {
    single<ICompileService> { CompileService(get(), get(), get()) }
}
