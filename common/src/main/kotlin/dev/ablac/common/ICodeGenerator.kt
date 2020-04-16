package dev.ablac.common

interface ICodeGenerator {
    suspend fun generateCode(compilationUnits: Collection<CompilationUnit>)
}