package dev.abla.runner

import dev.abla.di.frontendModule
import dev.abla.di.backendLLVMModule
import dev.abla.di.languageModule
import dev.abla.di.utilsModule
import org.koin.core.context.startKoin

val modules = listOf(
    frontendModule,
    backendLLVMModule,
    languageModule,
    utilsModule
)

fun main(args: Array<String>) {
    startKoin {
        modules(modules)
    }
    Runner().run(args)
}
