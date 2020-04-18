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
    fun example() {

        val error = BytePointer(null as Pointer?) // Used to retrieve messages from functions

        LLVMLinkInMCJIT()
        LLVMInitializeNativeAsmPrinter()
        LLVMInitializeNativeAsmParser()
        LLVMInitializeNativeDisassembler()
        LLVMInitializeNativeTarget()
        val mod: LLVMModuleRef = LLVMModuleCreateWithName("fac_module")
        val fac_args = arrayOf(LLVMInt32Type())
        val fac: LLVMValueRef = LLVMAddFunction(
            mod,
            "fac",
            LLVMFunctionType(LLVMInt32Type(), fac_args[0], 1, 0)
        )
        LLVMSetFunctionCallConv(fac, LLVMCCallConv)
        val n = LLVMGetParam(fac, 0)

        val entry: LLVMBasicBlockRef = LLVMAppendBasicBlock(fac, "entry")
        val iftrue: LLVMBasicBlockRef = LLVMAppendBasicBlock(fac, "iftrue")
        val iffalse: LLVMBasicBlockRef = LLVMAppendBasicBlock(fac, "iffalse")
        val end: LLVMBasicBlockRef = LLVMAppendBasicBlock(fac, "end")
        val builder = LLVMCreateBuilder()

        LLVMPositionBuilderAtEnd(builder, entry)
        val If: LLVMValueRef = LLVMBuildICmp(
            builder,
            LLVMIntEQ,
            n,
            LLVMConstInt(LLVMInt32Type(), 0, 0),
            "n == 0"
        )
        LLVMBuildCondBr(builder, If, iftrue, iffalse)

        LLVMPositionBuilderAtEnd(builder, iftrue)
        val res_iftrue =
            LLVMConstInt(LLVMInt32Type(), 1, 0)
        LLVMBuildBr(builder, end)

        LLVMPositionBuilderAtEnd(builder, iffalse)
        val n_minus: LLVMValueRef = LLVMBuildSub(
            builder,
            n,
            LLVMConstInt(LLVMInt32Type(), 1, 0),
            "n - 1"
        )
        val call_fac_args = arrayOf(n_minus)
        val call_fac: LLVMValueRef =
            LLVMBuildCall(builder, fac, PointerPointer(*call_fac_args), 1, "fac(n - 1)")
        val res_iffalse: LLVMValueRef = LLVMBuildMul(builder, n, call_fac, "n * fac(n - 1)")
        LLVMBuildBr(builder, end)

        LLVMPositionBuilderAtEnd(builder, end)
        val res: LLVMValueRef = LLVMBuildPhi(builder, LLVMInt32Type(), "result")
        val phi_vals = arrayOf(res_iftrue, res_iffalse)
        val phi_blocks = arrayOf(iftrue, iffalse)
        LLVMAddIncoming(res, PointerPointer(*phi_vals), PointerPointer(*phi_blocks), 2)
        LLVMBuildRet(builder, res)

        LLVMVerifyModule(mod, LLVMAbortProcessAction, error)
        LLVMDisposeMessage(error) // Handler == LLVMAbortProcessAction -> No need to check errors


        val engine = LLVMExecutionEngineRef()
        if (LLVMCreateJITCompilerForModule(engine, mod, 2, error) !== 0) {
            System.err.println(error.string)
            LLVMDisposeMessage(error)
            System.exit(-1)
        }

        val pass = LLVMCreatePassManager()
        LLVMAddConstantPropagationPass(pass)
        LLVMAddInstructionCombiningPass(pass)
        LLVMAddPromoteMemoryToRegisterPass(pass)
        // LLVMAddDemoteMemoryToRegisterPass(pass); // Demotes every possible value to memory
        // LLVMAddDemoteMemoryToRegisterPass(pass); // Demotes every possible value to memory
        LLVMAddGVNPass(pass)
        LLVMAddCFGSimplificationPass(pass)
        LLVMRunPassManager(pass, mod)
        LLVMDumpModule(mod)

        val exec_args = LLVMCreateGenericValueOfInt(
            LLVMInt32Type(),
            10,
            0
        )
        val exec_res: LLVMGenericValueRef = LLVMRunFunction(engine, fac, 1, exec_args)
        System.err.println()
        System.err.println("; Running fac(10) with JIT...")
        System.err.println("; Result: " + LLVMGenericValueToInt(exec_res, 0))

        LLVMDisposePassManager(pass)
        LLVMDisposeBuilder(builder)
        LLVMDisposeExecutionEngine(engine)
    }

    private val blocks = Stack<LLVMBasicBlockRef>()

    override suspend fun visit(file: File) {
        super.visit(file)
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val argTypes = functionDeclaration.parameters.map {
            LLVMInt32Type()
        }.toTypedArray()
        val function = module.addFunction(functionDeclaration.name, LLVMInt32Type(), argTypes)
        functionDeclaration.llvmValue = function

        if (functionDeclaration.isExtern)
            function.setLinkage(LLVMExternalLinkage)

        functionDeclaration.block?.let {
            function.appendBasicBlock("entry") {
                functionDeclaration.llvmBlock = this
                blocks.push(this)
            }

            for ((index, param) in functionDeclaration.parameters.withIndex())
                param.llvmValue = LLVMGetParam(function, index)

            it.accept(this)

            blocks.pop()
        }

    }
}
