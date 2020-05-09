package dev.abla.common

interface ICodeGenerator {
    suspend fun generateCode(
        compilationUnits: Collection<CompilationUnit>,
        codeGenParameters: CodeGenParameters
    )
}