package dev.ablac.llvm

import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.ClassDeclaration
import dev.ablac.language.nodes.File
import dev.ablac.language.nodes.FunctionDeclaration
import dev.ablac.language.nodes.FunctionLiteral
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
