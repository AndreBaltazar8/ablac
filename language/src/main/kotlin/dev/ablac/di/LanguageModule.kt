package dev.ablac.di

import dev.ablac.language.IParseService
import dev.ablac.language.ParseService
import org.koin.dsl.module

val languageModule = module {
    single<IParseService> { ParseService() }
}
