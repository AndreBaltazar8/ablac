package dev.ablac.llvm

import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.File
import dev.ablac.language.nodes.FunctionDeclaration
import org.bytedeco.javacpp.BytePointer
import org.bytedeco.javacpp.Pointer
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.*
import org.bytedeco.llvm.global.LLVM.*
import java.util.*


class LLVMTypeGenerator(private val module: LLVMModuleRef) : ASTVisitor() {
    private val blocks = Stack<LLVMBasicBlockRef>()

    override suspend fun visit(file: File) {
        super.visit(file)
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val function = module.addFunction(functionDeclaration.name, LLVMInt32Type(), arrayOf())
        functionDeclaration.llvmValue = function

        functionDeclaration.block?.let {
            function.appendBasicBlock("entry") {
                functionDeclaration.llvmBlock = this
                blocks.push(this)
            }

            // TODO: args

            it.accept(this)

            blocks.pop()
        }

    }
}
