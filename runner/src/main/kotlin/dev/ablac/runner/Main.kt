package dev.ablac.runner

import dev.ablac.di.frontendModule
import dev.ablac.di.backendLLVMModule
import dev.ablac.di.languageModule
import dev.ablac.di.utilsModule
import org.koin.core.context.startKoin

val modules = listOf(
    frontendModule,
    backendLLVMModule,
    languageModule,
    utilsModule
)

fun main(args: Array<String>) {
    startKoin {
        printLogger()
        modules(modules)
    }
    Runner().run(args)
}
