package dev.abla.di

import dev.abla.frontend.CompileService
import dev.abla.frontend.ICompileService
import org.koin.dsl.module

val frontendModule = module {
    single<ICompileService> { CompileService(get(), get(), get()) }
}
