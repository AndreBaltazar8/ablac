package dev.abla.di

import dev.abla.language.IParseService
import dev.abla.language.ParseService
import org.koin.dsl.module

val languageModule = module {
    single<IParseService> { ParseService() }
}
