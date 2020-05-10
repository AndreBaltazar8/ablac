package dev.abla.llvm

import dev.abla.common.elseSymbolTable
import dev.abla.common.ifSymbolTable
import dev.abla.common.symbolTable
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
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
                    LLVMBuildRet(builder, generatorContext.topValue)
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
        val value = currentBlock.table.find(identifierExpression.identifier)
            ?: throw Exception("Unknown value for identifier ${identifierExpression.identifier}")

        if (value.node.llvmValue == null)
            throw Exception("Cannot get llvm value for ${identifierExpression.identifier}. Is it a compiler function?")

        val node = value.node
        val llvmValue = if (node is PropertyDeclaration && !node.isFinal) {
            if (returnForAssignment == 0) {
                val builder = generatorContext.topBlock.createBuilderAtEnd()
                LLVMBuildLoad(builder, node.llvmValue, "")
            } else
                node.llvmValue
        } else if (returnForAssignment > 0)
            throw java.lang.IllegalStateException("Cannot assign value to final identifier ${identifierExpression.identifier}")
        else
            node.llvmValue

        generatorContext.values.push(llvmValue)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        functionCall.primaryExpression.accept(this)
        val node = generatorContext.topValuePop

        generatorContext.topBlock.createBuilderAtEnd { builder ->
            val args = functionCall.arguments.map {
                it.value.accept(this)
                generatorContext.topValuePop
            }.toTypedArray()

            generatorContext.values.push(LLVMBuildCall(
                builder,
                node,
                PointerPointer(*args),
                functionCall.arguments.size,
                ""
            ))
        }
    }

    override suspend fun visit(integer: Integer) {
        generatorContext.values.push(LLVMConstInt(LLVMInt32Type(), integer.number.toLong(), 0))
    }

    override suspend fun visit(stringLiteral: StringLiteral) {
        val builder = LLVMCreateBuilder()
        LLVMPositionBuilderAtEnd(builder, generatorContext.topBlock.block)
        if (stringLiteral.stringParts.all { it is StringLiteral.StringConst }) {
            val string = stringLiteral.stringParts.joinToString("") { (it as StringLiteral.StringConst).string }
            val globalValue = LLVMBuildGlobalStringPtr(builder, string, stringLiteral.hashCode().toString())
            generatorContext.values.push(globalValue)
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
                    LLVMBuildRet(builder, generatorContext.topValue)
                else
                    LLVMBuildRet(builder, LLVMConstInt(LLVMInt32Type(), 1, 0))
            }
            currentBlock.hasReturned = true
        }
        repeat(generatorContext.values.size - numValues) {
            generatorContext.values.pop()
        }
        generatorContext.popBlock(false)
        generatorContext.values.push(functionLiteral.llvmValue!!)
    }

    override suspend fun visit(binaryOperation: BinaryOperation) {
        binaryOperation.lhs.accept(this)
        val lhsValue = generatorContext.topValuePop
        binaryOperation.rhs.accept(this)
        val rhsValue = generatorContext.topValuePop
        generatorContext.topBlock.createBuilderAtEnd { builder ->
            val result = when (binaryOperation.operator) {
                BinaryOperator.Plus -> LLVMBuildAdd(builder, lhsValue, rhsValue, "")
                BinaryOperator.Minus -> LLVMBuildSub(builder, lhsValue, rhsValue, "")
                BinaryOperator.Mul -> LLVMBuildMul(builder, lhsValue, rhsValue, "")
                BinaryOperator.Div -> LLVMBuildSDiv(builder, lhsValue, rhsValue, "")
                BinaryOperator.Equals -> LLVMBuildICmp(builder, LLVMIntEQ, lhsValue, rhsValue, "")
                BinaryOperator.NotEquals -> LLVMBuildICmp(builder, LLVMIntNE, lhsValue, rhsValue, "")
                BinaryOperator.GreaterThan -> LLVMBuildICmp(builder, LLVMIntSGT, lhsValue, rhsValue, "")
                BinaryOperator.LesserThan -> LLVMBuildICmp(builder, LLVMIntSLT, lhsValue, rhsValue, "")
                BinaryOperator.GreaterThanEqual -> LLVMBuildICmp(builder, LLVMIntSGE, lhsValue, rhsValue, "")
                BinaryOperator.LesserThanEqual -> LLVMBuildICmp(builder, LLVMIntSLE, lhsValue, rhsValue, "")
            }
            generatorContext.values.push(result)
        }
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        val ifBlock = ifElseExpression.llvmIfBlock!!
        val elseBlock = ifElseExpression.llvmElseBlock!!

        val builder = generatorContext.topBlock.createBuilderAtEnd()

        ifElseExpression.condition.accept(this)
        val condition = generatorContext.topValuePop

        // TODO: not easy to determine if this if is an expression or statement
        val ifElseResult = LLVMBuildAlloca(builder, LLVMInt32Type(), "")
        LLVMBuildCondBr(builder, condition, ifBlock, elseBlock)

        val codeIfBlock = generatorContext.withBlock(ifBlock, ifElseExpression.ifSymbolTable!!) {
            val ifBody = ifElseExpression.ifBody
            ifBody?.accept(this@CodeGeneratorVisitor)
            createBuilderAtEnd {
                LLVMBuildStore(it, generatorContext.topValuePop, ifElseResult)
            }
        }
        val ifRetuned = codeIfBlock.hasReturned

        val codeElseBlock = generatorContext.withBlock(elseBlock, ifElseExpression.elseSymbolTable!!) {
            val elseBody = ifElseExpression.elseBody
            elseBody?.accept(this@CodeGeneratorVisitor)
            if (elseBody != null) {
                createBuilderAtEnd { builder ->
                    LLVMBuildStore(builder, generatorContext.topValuePop, ifElseResult)
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
                generatorContext.values.push(LLVMBuildLoad(builder, ifElseResult, ""))
            }
        }
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        if (propertyDeclaration.isFinal) {
            val value = propertyDeclaration.value
                ?: throw IllegalStateException("${propertyDeclaration.name} must have an initialization")
            value.accept(this)
            propertyDeclaration.llvmValue = generatorContext.topValuePop
        } else {
            generatorContext.topBlock.createBuilderAtEnd { builder ->
                val allocation = LLVMBuildAlloca(builder, LLVMInt32Type(), "")
                val value = propertyDeclaration.value
                if (value != null) {
                    value.accept(this)
                    LLVMBuildStore(builder, generatorContext.topValuePop, allocation)
                }
                propertyDeclaration.llvmValue = allocation
            }
        }
    }

    private var returnForAssignment: Int = 0
    override suspend fun visit(assignment: Assignment) {
        returnForAssignment++
        assignment.lhs.accept(this)
        returnForAssignment--

        val allocation = generatorContext.topValuePop

        assignment.rhs.accept(this)

        generatorContext.topBlock.createBuilderAtEnd { builder ->
            LLVMBuildStore(builder, generatorContext.topValue, allocation)
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
                LLVMBuildCondBr(builder, condition, mainBlock, continuationBlock)
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
