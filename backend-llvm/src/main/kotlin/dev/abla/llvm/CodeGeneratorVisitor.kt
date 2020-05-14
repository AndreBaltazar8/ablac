package dev.abla.llvm

import dev.abla.common.*
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.global.LLVM.*

class CodeGeneratorVisitor(private val module: LLVMModuleRef) : ASTVisitor() {
    private val generatorContext = GeneratorContext()

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        if (functionDeclaration.isExtern || functionDeclaration.isCompiler)
            return

        val function = functionDeclaration.llvmValue!!
        if (functionDeclaration.name == "main") {
            function.setName("%%_main")

            module.addFunction("main", LLVMInt16Type(), arrayOf()).valueRef
                .setLinkage(LLVMExternalLinkage)
                .appendBasicBlock("entry") {
                    createBuilderAtEnd { builder ->
                        val call = LLVMBuildCall(
                            builder,
                            functionDeclaration.llvmValue!!,
                            PointerPointer<LLVMTypeRef>(),
                            0,
                            ""
                        )
                        LLVMBuildRet(
                            builder,
                            if (functionDeclaration.returnType == UserType.Int)
                                call
                            else
                                LLVMConstInt(LLVMInt16Type(),0, 0)
                        )
                    }
                }
        }

        val block = functionDeclaration.llvmBlock!!
        val symbolTable = functionDeclaration.symbolTable!!
        val currentBlock = generatorContext.pushBlock(block, symbolTable)

        super.visit(functionDeclaration)

        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.createBuilderAtEnd { builder ->
                if (generatorContext.values.isNotEmpty() && !functionDeclaration.returnType.isNullOrVoid())
                    LLVMBuildRet(builder, generatorContext.topValue.ref)
                else
                    LLVMBuildRetVoid(builder)
            }
            currentBlock.hasReturned = true
        }

        generatorContext.values.clear()
        generatorContext.popBlock(false)
    }

    override suspend fun visit(block: Block) {
        val topBlock = generatorContext.topBlock
        for (statement in block.statements) {
            if (topBlock.hasReturned)
                return // the rest of statements are dead code
            statement.accept(this)
        }
    }

    override suspend fun visit(identifierExpression: IdentifierExpression) {
        val currentBlock = generatorContext.topBlock
        val symbol = currentBlock.table.find(identifierExpression.identifier)
            ?: throw Exception("Unknown value for identifier ${identifierExpression.identifier}")

        // TODO: if class select most appropriate constructor
        if (symbol.node.llvmValue == null)
            throw Exception("Cannot get llvm value for ${identifierExpression.identifier}. Is it a compiler function?")

        val node = symbol.node
        val value = if (node is PropertyDeclaration && !node.isFinal) {
            if (!identifierExpression.returnForAssignment) {
                val builder = generatorContext.topBlock.createBuilderAtEnd()
                GeneratorContext.Value(node.type!!, LLVMBuildLoad(builder, node.llvmValue, ""))
            } else
                GeneratorContext.Value(node.type!!, node.llvmValue!!)
        } else if (identifierExpression.returnForAssignment)
            throw java.lang.IllegalStateException("Cannot assign value to final identifier ${identifierExpression.identifier}")
        else {
            val type = when (symbol) {
                is Symbol.Function -> (node as FunctionDeclaration).toType()
                is Symbol.Variable -> if (node is PropertyDeclaration) node.type!! else UserType.Any
                is Symbol.Class -> (node as ClassDeclaration).toType()
            }
            GeneratorContext.Value(type, node.llvmValue!!)
        }

        generatorContext.values.push(value)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        functionCall.primaryExpression.accept(this)
        val functionToCall = generatorContext.topValuePop
        val returnType = when (val functionType = functionToCall.type) {
            is FunctionType -> functionType.returnType
            is UserType -> functionType
            else -> throw IllegalStateException("Expecting function type in function call")
        }

        val isMethodCall = functionCall.primaryExpression is MemberAccess
        val thisClass = if (isMethodCall) generatorContext.topValuePop else null

        generatorContext.topBlock.createBuilderAtEnd { builder ->
            val args = listOfNotNull(thisClass?.ref).plus(functionCall.arguments.map {
                it.value.accept(this)
                generatorContext.topValuePop.ref
            }).toTypedArray()

            generatorContext.values.push(GeneratorContext.Value(returnType, LLVMBuildCall(
                builder,
                functionToCall.ref,
                PointerPointer(*args),
                functionCall.arguments.size + if (isMethodCall) 1 else 0,
                ""
            )))
        }
    }

    override suspend fun visit(memberAccess: MemberAccess) {
        super.visit(memberAccess)
        val classType = generatorContext.topValue.type
        if (classType !is UserType)
            throw NotImplementedError("Unsupported")
        val symbol = generatorContext.topBlock.table.find(classType.identifier)
        if (symbol !is Symbol.Class)
            throw NotImplementedError("Unsupported")
        generatorContext.withBlock(generatorContext.topBlock.block, symbol.node.symbolTable!!) {
            IdentifierExpression(memberAccess.name, memberAccess.position).accept(this@CodeGeneratorVisitor)
        }
    }

    override suspend fun visit(integer: Integer) {
        val value = GeneratorContext.Value(UserType.Int, LLVMConstInt(LLVMInt32Type(), integer.number.toLong(), 0))
        generatorContext.values.push(value)
    }

    override suspend fun visit(stringLiteral: StringLiteral) {
        val builder = LLVMCreateBuilder()
        LLVMPositionBuilderAtEnd(builder, generatorContext.topBlock.block)
        if (stringLiteral.stringParts.all { it is StringLiteral.StringConst }) {
            val string = stringLiteral.stringParts.joinToString("") { (it as StringLiteral.StringConst).string }
            val globalValue = LLVMBuildGlobalStringPtr(builder, string, stringLiteral.hashCode().toString())
            generatorContext.values.push(GeneratorContext.Value(UserType.String, globalValue))
        } else {
            /*val globalValue = LLVMBuildGlobalStringPtr(builder, "hi", stringLiteral.hashCode().toString())
            val string = LLVMBuildArrayAlloca(builder, LLVMInt8Type(), LLVMConstInt(LLVMInt32Type(), 3, 0), "")
            LLVMBuildMemCpy(builder, string, 0, globalValue, 0, LLVMConstInt(LLVMInt32Type(), 2, 0))
            generatorContext.values.push(string)*/
            TODO("String with expression not available at run time")
            // Either build the code for concat here or add a small C func to do it
        }
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        val numValues = generatorContext.values.size
        val block = functionLiteral.llvmBlock!!
        val currentBlock = generatorContext.pushBlock(block, generatorContext.topBlock.table)
        functionLiteral.block.accept(this)
        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.createBuilderAtEnd { builder ->
                if (generatorContext.values.isNotEmpty())
                    LLVMBuildRet(builder, generatorContext.topValue.ref)
                else
                    LLVMBuildRet(builder, LLVMConstInt(LLVMInt32Type(), 1, 0))
            }
            currentBlock.hasReturned = true
        }
        repeat(generatorContext.values.size - numValues) {
            generatorContext.values.pop()
        }
        generatorContext.popBlock(false)
        val type = FunctionType(arrayOf(), UserType.Int, null, positionZero)
        generatorContext.values.push(GeneratorContext.Value(type, functionLiteral.llvmValue!!))
    }

    override suspend fun visit(binaryOperation: BinaryOperation) {
        binaryOperation.lhs.accept(this)
        val lhsValue = generatorContext.topValuePop
        val lhsValueRef = lhsValue.ref
        binaryOperation.rhs.accept(this)
        val rhsValueRef = generatorContext.topValuePop.ref
        generatorContext.topBlock.createBuilderAtEnd { builder ->
            val result = when (binaryOperation.operator) {
                BinaryOperator.Plus -> LLVMBuildAdd(builder, lhsValueRef, rhsValueRef, "")
                BinaryOperator.Minus -> LLVMBuildSub(builder, lhsValueRef, rhsValueRef, "")
                BinaryOperator.Mul -> LLVMBuildMul(builder, lhsValueRef, rhsValueRef, "")
                BinaryOperator.Div -> LLVMBuildSDiv(builder, lhsValueRef, rhsValueRef, "")
                BinaryOperator.Equals -> LLVMBuildICmp(builder, LLVMIntEQ, lhsValueRef, rhsValueRef, "")
                BinaryOperator.NotEquals -> LLVMBuildICmp(builder, LLVMIntNE, lhsValueRef, rhsValueRef, "")
                BinaryOperator.GreaterThan -> LLVMBuildICmp(builder, LLVMIntSGT, lhsValueRef, rhsValueRef, "")
                BinaryOperator.LesserThan -> LLVMBuildICmp(builder, LLVMIntSLT, lhsValueRef, rhsValueRef, "")
                BinaryOperator.GreaterThanEqual -> LLVMBuildICmp(builder, LLVMIntSGE, lhsValueRef, rhsValueRef, "")
                BinaryOperator.LesserThanEqual -> LLVMBuildICmp(builder, LLVMIntSLE, lhsValueRef, rhsValueRef, "")
            }
            generatorContext.values.push(GeneratorContext.Value(lhsValue.type, result))
        }
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        val ifBlock = ifElseExpression.llvmIfBlock!!
        val elseBlock = ifElseExpression.llvmElseBlock!!

        val builder = generatorContext.topBlock.createBuilderAtEnd()

        ifElseExpression.condition.accept(this)
        val condition = generatorContext.topValuePop.ref

        // TODO: not easy to determine if this if is an expression or statement
        val ifElseResult = LLVMBuildAlloca(builder, LLVMInt32Type(), "")
        LLVMBuildCondBr(builder, condition, ifBlock, elseBlock)

        val codeIfBlock = generatorContext.withBlock(ifBlock, ifElseExpression.ifSymbolTable!!) {
            val ifBody = ifElseExpression.ifBody
            ifBody?.accept(this@CodeGeneratorVisitor)
            createBuilderAtEnd {
                LLVMBuildStore(it, generatorContext.topValuePop.ref, ifElseResult)
            }
        }
        val ifRetuned = codeIfBlock.hasReturned

        val codeElseBlock = generatorContext.withBlock(elseBlock, ifElseExpression.elseSymbolTable!!) {
            val elseBody = ifElseExpression.elseBody
            elseBody?.accept(this@CodeGeneratorVisitor)
            if (elseBody != null) {
                createBuilderAtEnd { builder ->
                    LLVMBuildStore(builder, generatorContext.topValuePop.ref, ifElseResult)
                }
            }
        }
        val elseRetuned = codeElseBlock.hasReturned

        val contBlock = ifElseExpression.llvmContBlock!!
        if (!ifRetuned) {
            codeIfBlock.block.createBuilderAtEnd {
                LLVMBuildBr(it, contBlock)
            }
        }

        if (!elseRetuned) {
            codeElseBlock.block.createBuilderAtEnd {
                LLVMBuildBr(it, contBlock)
            }
        }

        generatorContext.pushReplaceBlock(contBlock, generatorContext.topBlock.table) {
            createBuilderAtEnd { builder ->
                val result = GeneratorContext.Value(UserType.Any, LLVMBuildLoad(builder, ifElseResult, ""))
                generatorContext.values.push(result)
            }
        }
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        if (propertyDeclaration.isFinal) {
            val value = propertyDeclaration.value
                ?: throw IllegalStateException("${propertyDeclaration.name} must have an initialization")
            value.accept(this)
            propertyDeclaration.llvmValue = generatorContext.topValuePop.ref
        } else {
            generatorContext.topBlock.createBuilderAtEnd { builder ->
                val allocation = LLVMBuildAlloca(builder, LLVMInt32Type(), "")
                val value = propertyDeclaration.value
                if (value != null) {
                    value.accept(this)
                    LLVMBuildStore(builder, generatorContext.topValuePop.ref, allocation)
                }
                propertyDeclaration.llvmValue = allocation
            }
        }
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        generatorContext.withBlock(classDeclaration.llvmBlock!!, classDeclaration.symbolTable!!) {
            super.visit(classDeclaration)
            createBuilderAtEnd {
                LLVMBuildRet(it, LLVMBuildMalloc(it, classDeclaration.struct, ""))
            }
        }
    }

    override suspend fun visit(assignment: Assignment) {
        assignment.lhs.accept(this)

        val allocation = generatorContext.topValuePop.ref

        assignment.rhs.accept(this)

        generatorContext.topBlock.createBuilderAtEnd { builder ->
            LLVMBuildStore(builder, generatorContext.topValue.ref, allocation)
        }
    }

    override suspend fun visit(whileStatement: WhileStatement) {
        val conditionBlock = whileStatement.llvmConditionBlock!!
        val mainBlock = whileStatement.llvmBlock!!
        val continuationBlock = whileStatement.llvmContBlock!!

        generatorContext.topBlock.createBuilderAtEnd { builder ->
            LLVMBuildBr(builder, conditionBlock)
        }

        // Condition block
        generatorContext.withBlock(conditionBlock, whileStatement.symbolTable!!) {
            whileStatement.condition.accept(this@CodeGeneratorVisitor)
            val condition = generatorContext.topValuePop
            createBuilderAtEnd { builder ->
                LLVMBuildCondBr(builder, condition.ref, mainBlock, continuationBlock)
            }
        }

        // Main block
        generatorContext.withBlock(mainBlock, whileStatement.symbolTable!!) {
            whileStatement.block?.accept(this@CodeGeneratorVisitor)
            createBuilderAtEnd { builder ->
                LLVMBuildBr(builder, conditionBlock)
            }
        }

        // Continuation block
        generatorContext.pushReplaceBlock(continuationBlock, generatorContext.topBlock.table)
    }
}