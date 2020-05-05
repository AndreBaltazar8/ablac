package dev.abla.llvm

import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.*
import org.bytedeco.llvm.global.LLVM.*
import java.util.*


class LLVMTypeGenerator(private val module: LLVMModuleRef) : ASTVisitor() {
    private val blocks = Stack<LLVMBasicBlockRef>()
    private val functions = Stack<LLVMValueRef>()
    private val typeScopes = Stack<TypeScope>()

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        if (functionDeclaration.isCompiler)
            return

        val name = typeScopes.map { it.name }.plus(functionDeclaration.name).joinToString("%")
        val argTypes =
            listOfNotNull(if (!typeScopes.empty()) LLVMPointerType(typeScopes.peek().type, 0) else null)
                .plus(functionDeclaration.parameters.map {
                    try {
                        it.type.llvmType
                    } catch (e: Exception) {
                        throw Exception("${it.name}: ${e.message}", e)
                    }
                })
        val function = module.addFunction(
            name,
            functionDeclaration.returnType?.llvmType ?: LLVMVoidType(),
            argTypes.toTypedArray()
        )
        typeScopes.lastOrNull()?.methods?.add(function)
        functionDeclaration.llvmValue = function.valueRef
        functions.push(function.valueRef)

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
        functions.pop()
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        val struct = LLVMStructCreateNamed(LLVMGetGlobalContext(), classDeclaration.name)
        val scope = TypeScope(classDeclaration.name, struct)
        typeScopes.push(scope)
        super.visit(classDeclaration)
        val vTableType = module.registerTypeVtable(
            classDeclaration.name,
            scope.methods.map { LLVMPointerType(it.type, 0) }.toTypedArray(),
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

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        val function = functions[functions.lastIndex]

        ifElseExpression.condition.accept(this)

        function.appendBasicBlock("if_block") {
            ifElseExpression.llvmIfBlock = this
            blocks.push(this)
        }
        ifElseExpression.ifBody?.accept(this)
        blocks.pop()

        function.appendBasicBlock("else_block") {
            ifElseExpression.llvmElseBlock = this
            blocks.push(this)
        }
        ifElseExpression.elseBody?.accept(this)
        blocks.pop()

        function.appendBasicBlock("if_cont_block") {
            ifElseExpression.llvmContBlock = this
            blocks.pop()
            blocks.push(this)
        }
    }
}
