package dev.abla.llvm

import dev.abla.common.Scope
import dev.abla.common.scope
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
        if (classDeclaration.isCompiler)
            return
        val struct = LLVMStructCreateNamed(LLVMGetGlobalContext(), classDeclaration.name)
        val scope = TypeScope(classDeclaration.name, struct)
        typeScopes.push(scope)
        classDeclaration.struct = struct
        val name = typeScopes.map { it.name }.plus("%constructor").joinToString("%")
        classDeclaration.constructorFunction = module.addFunction(name, LLVMPointerType(struct, 0), arrayOf())
            .valueRef.appendBasicBlock("entry") {
                classDeclaration.llvmBlock = this
                blocks.push(this)
            }
        classDeclaration.llvmValue = classDeclaration.constructorFunction
        super.visit(classDeclaration)
        blocks.pop()
        val vTableType = module.registerTypeVtable(
            classDeclaration.name,
            scope.methods.map { LLVMPointerType(it.type, 0) }.toTypedArray(),
            scope.methods.map { it.valueRef }.toTypedArray()
        )
        LLVMStructSetBody(
            struct,
            PointerPointer(LLVMPointerType(vTableType, 0), *scope.fields.toTypedArray()),
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

    override suspend fun visit(whileStatement: WhileStatement) {
        val function = functions[functions.lastIndex]
        function.appendBasicBlock("while_condition_block") {
            whileStatement.llvmConditionBlock = this
            blocks.push(this)
        }
        whileStatement.condition.accept(this)
        blocks.pop()

        function.appendBasicBlock("while_block") {
            whileStatement.llvmBlock = this
            blocks.push(this)
        }
        whileStatement.block?.accept(this)
        blocks.pop()

        function.appendBasicBlock("while_cont_block") {
            whileStatement.llvmContBlock = this
            blocks.pop()
            blocks.push(this)
        }
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        if (propertyDeclaration.scope == Scope.Global) {
            LLVMAddGlobal(module, (propertyDeclaration.type ?: UserType.Any).llvmType, "")
        } else if (propertyDeclaration.scope == Scope.Class) {
            val typeScope = typeScopes.peek()
            typeScope.fields.add((propertyDeclaration.type ?: UserType.Any).llvmType)
        }
        super.visit(propertyDeclaration)
    }
}
