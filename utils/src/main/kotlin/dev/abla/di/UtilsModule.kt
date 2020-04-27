package dev.abla.di

import dev.abla.utils.*
import org.koin.dsl.module

val utilsModule = module {
    single<IMeasurementService> { MeasurementService() }
    single<ILockService> { LockService() }
}
