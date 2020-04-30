package dev.abla.llvm

import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.ClassDeclaration
import dev.abla.language.nodes.File
import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.FunctionLiteral
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.*
import org.bytedeco.llvm.global.LLVM.*
import java.util.*


class LLVMTypeGenerator(private val module: LLVMModuleRef) : ASTVisitor() {
    private val blocks = Stack<LLVMBasicBlockRef>()
    private val typeScopes = Stack<TypeScope>()

    override suspend fun visit(file: File) {
        super.visit(file)
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val name = typeScopes.map { it.name }.plus(functionDeclaration.name).joinToString("%")
        val argTypes =
            listOfNotNull(if (!typeScopes.empty()) LLVMPointerType(typeScopes.peek().type, 0) else null)
                .plus(functionDeclaration.parameters.map {
                    if (it.name == "fn")
                        LLVMPointerType(LLVMFunctionType(LLVMInt32Type(), PointerPointer<LLVMTypeRef>(), 0, 0), 0)
                    else if (it.type.identifier == "string")
                        LLVMPointerType(LLVMInt8Type(), 0)
                    else
                        LLVMInt32Type()
                })
        val function = module.addFunction(name, LLVMInt32Type(), argTypes.toTypedArray())
        typeScopes.lastOrNull()?.methods?.add(function)
        functionDeclaration.llvmValue = function.valueRef

        if (functionDeclaration.isExtern)
            function.valueRef.setLinkage(LLVMExternalLinkage)

        functionDeclaration.block?.let {
            function.valueRef.appendBasicBlock("entry") {
                functionDeclaration.llvmBlock = this
                blocks.push(this)
            }

            val offset = if (typeScopes.empty()) 0 else 1
            for ((index, param) in functionDeclaration.parameters.withIndex())
                param.llvmValue = LLVMGetParam(function.valueRef, index + offset)

            it.accept(this)

            blocks.pop()
        }
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        val struct = LLVMStructCreateNamed(LLVMGetGlobalContext(), classDeclaration.name)
        val scope = TypeScope(classDeclaration.name, struct)
        typeScopes.push(scope)
        super.visit(classDeclaration)
        val vTableType = module.registerTypeVtable(
            classDeclaration.name,
            scope.methods.map { it.type }.toTypedArray(),
            scope.methods.map { it.valueRef }.toTypedArray()
        )
        LLVMStructSetBody(
            struct,
            PointerPointer(*scope.fields.plus(LLVMPointerType(vTableType, 0)).toTypedArray()),
            scope.fields.size + 1,
            0
        )
        typeScopes.pop()
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        val function = module.addFunction("funliteral" + functionLiteral.hashCode(), LLVMInt32Type(), arrayOf())
            .valueRef.appendBasicBlock("entry") {
                functionLiteral.llvmBlock = this
                blocks.push(this)
            }
        functionLiteral.llvmValue = function
        super.visit(functionLiteral)
        blocks.pop()
    }
}
