package dev.abla.llvm

import dev.abla.common.*
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import dev.abla.utils.statementOrder
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.*
import org.bytedeco.llvm.global.LLVM.*
import java.util.*


class LLVMTypeGenerator(private val module: LLVMModuleRef) : ASTVisitor() {
    private val llvmContext = LLVMGetModuleContext(module)
    private val blocks = Stack<LLVMBasicBlockRef>()
    private val functions = Stack<LLVMValueRef>()
    private val typeScopes = Stack<TypeScope>()
    private val names = Stack<String>()

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        if (functionDeclaration.isCompiler)
            return

        val name = names.plus(functionDeclaration.name).joinToString("%")

        val receiver = functionDeclaration.symbol.receiver
        val hasReceiver = receiver != null
        val classType = receiver?.node?.toType()?.llvmType(receiver.node.symbolTable!!)

        val argTypes = listOfNotNull(classType)
            .plus(functionDeclaration.parameters.map {
                try {
                    it.type.llvmType(functionDeclaration.symbolTable!!)
                } catch (e: Exception) {
                    throw Exception("${it.name}: ${e.message}", e)
                }
            })
        val function = module.addFunction(
            name,
            functionDeclaration.returnType?.llvmType(functionDeclaration.symbolTable!!) ?: LLVMVoidType(),
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

            val builder = functionDeclaration.llvmBlock!!.createBuilderAtEnd()

            val offset = if (hasReceiver) 1 else 0
            if (hasReceiver) {
                val parameter = functionDeclaration.receiverParameter!!
                val parameterValueRef = LLVMGetParam(function.valueRef, 0)
                val allocation = LLVMBuildAlloca(builder, argTypes[0], "")
                LLVMBuildStore(builder, parameterValueRef, allocation)
                parameter.llvmValue = LLVMBuildLoad(builder, allocation, "")
            }
            for ((index, param) in functionDeclaration.parameters.withIndex()) {
                val parameterValueRef = LLVMGetParam(function.valueRef, index + offset)
                val allocation = LLVMBuildAlloca(builder, argTypes[index + offset], "")
                LLVMBuildStore(builder, parameterValueRef, allocation)
                param.llvmValue = LLVMBuildLoad(builder, allocation, "")
            }

            names.push(functionDeclaration.name)
            it.accept(this)
            names.pop()

            blocks.pop()
        }
        functions.pop()
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        if (classDeclaration.isCompiler)
            return
        val isBuiltin = classDeclaration.toType().isBuiltIn
        val struct = if (!isBuiltin)
            LLVMStructCreateNamed(llvmContext, classDeclaration.name)
        else
            classDeclaration.toType().llvmType(classDeclaration.symbolTable!!)

        val scope = TypeScope(classDeclaration.name, struct, isBuiltin)
        typeScopes.push(scope)
        names.push(classDeclaration.name)
        classDeclaration.struct = struct
        if (!isBuiltin) {
            val name = names.plus("%constructor").joinToString("%")
            val ctorArgs = classDeclaration.constructor?.parameters?.map {
                when (it) {
                    is PropertyDeclaration -> it.type!!
                    is Parameter -> it.type
                    else -> throw Exception("Unknown!")
                }.llvmType(classDeclaration.symbolTable!!)
            }?.toTypedArray() ?: arrayOf()
            classDeclaration.constructorFunction = module.addFunction(name, LLVMPointerType(struct, 0), ctorArgs)
                .valueRef.appendBasicBlock("entry") {
                    classDeclaration.llvmBlock = this
                    blocks.push(this)
                }

            val constructor = classDeclaration.constructor
            if (constructor != null) {
                for ((index, param) in constructor.parameters.withIndex())
                    param.llvmValue = LLVMGetParam(classDeclaration.constructorFunction, index)
            }

            classDeclaration.llvmValue = classDeclaration.constructorFunction
        }
        super.visit(classDeclaration)
        if (!isBuiltin) {
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
        }
        typeScopes.pop()
        names.pop()
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        val table = functionLiteral.block.symbolTable!!
        val returnType = functionLiteral.forcedReturnType ?: functionLiteral.block.returnType ?: UserType.Void
        val argTypes = functionLiteral.parameters.map {
            try {
                it.type!!.llvmType(table)
            } catch (e: Exception) {
                throw Exception("${it.name}: ${e.message}", e)
            }
        }
        val function = module.addFunction("funliteral" + functionLiteral.hashCode(), returnType.llvmType(table), argTypes.toTypedArray())
        functionLiteral.llvmValue = function.valueRef

        val block = function.createBasicBlock("entry")
        functionLiteral.llvmBlock = block
        blocks.push(block)
        val builder = block.createBuilderAtEnd()
        for ((index, param) in functionLiteral.parameters.withIndex()) {
            val parameterValueRef = LLVMGetParam(function.valueRef, index)
            val allocation = LLVMBuildAlloca(builder, argTypes[index], "")
            LLVMBuildStore(builder, parameterValueRef, allocation)
            param.llvmValue = LLVMBuildLoad(builder, allocation, "")
        }
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
        ifElseExpression.ifBody.accept(this)
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

        statementOrder(
            whileStatement.doWhile,
            {
                function.appendBasicBlock("while_condition_block") {
                    whileStatement.llvmConditionBlock = this
                    blocks.push(this)
                }
                whileStatement.condition.accept(this)
                blocks.pop()
            },
            {
                function.appendBasicBlock("while_block") {
                    whileStatement.llvmBlock = this
                    blocks.push(this)
                }
                whileStatement.block.accept(this)
                blocks.pop()
            }
        )

        function.appendBasicBlock("while_cont_block") {
            whileStatement.llvmContBlock = this
            blocks.pop()
            blocks.push(this)
        }
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        if (propertyDeclaration.scope == Scope.Global) {
            LLVMAddGlobal(module, (propertyDeclaration.inferredType ?: UserType.Any).llvmType(propertyDeclaration.symbolTable!!), "")
        } else if (propertyDeclaration.scope == Scope.Class) {
            val typeScope = typeScopes.peek()
            if (typeScope.isBuiltin)
                throw Exception("Cannot declare properties on builtin types")
            typeScope.fields.add((propertyDeclaration.inferredType ?: UserType.Any).llvmType(propertyDeclaration.symbolTable!!))
        }
        super.visit(propertyDeclaration)
    }

    override suspend fun visit(whenExpression: WhenExpression) {
        val function = functions[functions.lastIndex]

        whenExpression.condition?.accept(this)
        for ((index, case) in whenExpression.cases.withIndex()) {
            if (case is WhenExpression.ExpressionCase) {
                case.expressions.forEachIndexed { expIndex, expression ->
                    expression.accept(this)
                    function.appendBasicBlock("case_test_${index}_${expIndex}") {
                        expression.llvmBlock = this
                        blocks.pop()
                        blocks.push(this)
                    }
                }
            }
        }

        for ((index, case) in whenExpression.cases.withIndex()) {
            function.appendBasicBlock("case_$index") {
                case.body.llvmBlock = this
                blocks.push(this)
            }
            case.body.accept(this)
            blocks.pop()
        }

        function.appendBasicBlock("when_cont_block") {
            whenExpression.llvmBlock = this
            blocks.pop()
            blocks.push(this)
        }
    }
}
