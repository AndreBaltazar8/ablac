package dev.ablac.di

import dev.ablac.utils.*
import org.koin.dsl.module

val utilsModule = module {
    single<IMeasurementService> { MeasurementService() }
    single<ILockService> { LockService() }
}
