#include "abla/backend_c.hpp"

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <limits>
#include <ostream>
#include <sstream>

namespace abla::backend {

namespace {

const char* runtime_binary(ir::Opcode opcode) {
    switch (opcode) {
    case ir::Opcode::Add: return "abla_add";
    case ir::Opcode::Subtract: return "abla_subtract";
    case ir::Opcode::Multiply: return "abla_multiply";
    case ir::Opcode::Divide: return "abla_divide";
    case ir::Opcode::Equal: return "abla_equal";
    case ir::Opcode::NotEqual: return "abla_not_equal";
    case ir::Opcode::Less: return "abla_less";
    case ir::Opcode::LessEqual: return "abla_less_equal";
    case ir::Opcode::Greater: return "abla_greater";
    case ir::Opcode::GreaterEqual: return "abla_greater_equal";
    default: return nullptr;
    }
}

} // namespace

void CEmitter::emit(std::ostream& output) {
    if (!program_.compile_actions.empty()) {
        diagnostics_.error({}, "C backend received unmaterialized compile actions");
        return;
    }
    output << "/* Generated deterministically by ablac0. */\n"
              "#include \"abla_runtime.h\"\n\n";
    emit_prototypes(output);
    emit_globals(output);
    emit_constants(output);
    emit_dispatch(output);
    for (const auto& function : program_.functions) {
        if (function.compile_only) continue;
        if (function.external) emit_external(output, function);
        else emit_function(output, function);
    }
    emit_entry(output);
}

void CEmitter::emit_prototypes(std::ostream& output) {
    for (const auto& function : program_.functions) {
        if (function.compile_only) continue;
        output << "static AblaValue " << function_name(function.id)
               << "(const AblaValue* args, size_t count);\n";
    }
    output << "static AblaValue abla_dispatch(uint32_t function, "
              "const AblaValue* args, size_t count);\n"
              "static AblaValue abla_global_get(uint32_t global);\n"
              "static void abla_global_set(uint32_t global, AblaValue value);\n\n";
}

void CEmitter::emit_globals(std::ostream& output) {
    const auto count = std::max<std::size_t>(program_.globals.size(), 1);
    output << "static AblaValue abla_globals[" << count << "];\n"
           << "static uint8_t abla_global_state[" << count << "];\n\n"
           << "static AblaValue abla_global_get(uint32_t global) {\n"
              "    switch (global) {\n";
    for (const auto& global : program_.globals) {
        output << "    case " << global.id << ":\n"
               << "        if (abla_global_state[" << global.id << "] == 1) "
                  "abla_platform_panic(\"cyclic global initialization\", 28);\n"
               << "        if (abla_global_state[" << global.id << "] == 0) {\n"
               << "            abla_global_state[" << global.id << "] = 1;\n"
               << "            abla_globals[" << global.id << "] = ";
        if (global.initializer == ir::no_function) output << "abla_void()";
        else output << function_name(global.initializer) << "((const AblaValue*)0, 0)";
        output << ";\n            abla_global_state[" << global.id << "] = 2;\n"
                  "        }\n"
               << "        return abla_globals[" << global.id << "];\n";
    }
    output << "    default: abla_platform_panic(\"invalid global\", 14);\n"
              "    }\n"
              "}\n\n"
              "static void abla_global_set(uint32_t global, AblaValue value) {\n"
              "    (void)value;\n"
              "    switch (global) {\n";
    for (const auto& global : program_.globals) {
        output << "    case " << global.id << ": abla_globals[" << global.id
               << "] = value; abla_global_state[" << global.id << "] = 2; return;\n";
    }
    output << "    default: abla_platform_panic(\"invalid global\", 14);\n"
              "    }\n"
              "}\n\n";
}

void CEmitter::emit_constants(std::ostream& output) {
    if (program_.constants.empty()) return;
    for (std::size_t i = 0; i < program_.constants.size(); ++i) {
        output << "static AblaValue abla_constant_" << i
               << "(AblaValue* cache, uint8_t* states);\n";
    }
    output << '\n';
    for (std::size_t i = 0; i < program_.constants.size(); ++i) {
        const auto& constant = program_.constants[i];
        output << "static AblaValue abla_constant_" << i
               << "(AblaValue* cache, uint8_t* states) {\n"
               << "    if (states[" << i << "] != 0) return cache[" << i << "];\n"
               << "    states[" << i << "] = 1;\n";
        switch (constant.kind) {
        case ir::ConstantKind::Null:
            output << "    cache[" << i << "] = abla_null();\n";
            break;
        case ir::ConstantKind::Integer:
            output << "    cache[" << i << "] = abla_i64(INT64_C("
                   << constant.integer << "));\n";
            break;
        case ir::ConstantKind::Boolean:
            output << "    cache[" << i << "] = abla_bool("
                   << (constant.integer ? "true" : "false") << ");\n";
            break;
        case ir::ConstantKind::String:
            if (constant.text.size() <= 750) {
                output << "    cache[" << i << "] = abla_string_static("
                       << c_string(constant.text) << ", " << constant.text.size()
                       << ");\n";
            } else {
                output << "    cache[" << i
                       << "] = abla_string_static(\"\", 0);\n";
                for (std::size_t begin = 0; begin < constant.text.size(); begin += 750) {
                    const auto chunk = constant.text.substr(begin, 750);
                    output << "    cache[" << i << "] = abla_string_concat(cache["
                           << i << "], abla_string_static(" << c_string(chunk)
                           << ", " << chunk.size() << "));\n";
                }
            }
            break;
        case ir::ConstantKind::Array:
            if (constant.elements.empty()) {
                output << "    cache[" << i
                       << "] = abla_array_create((const AblaValue*)0, 0);\n";
            } else {
                output << "    AblaValue elements[" << constant.elements.size() << "];\n";
                for (std::size_t element = 0;
                     element < constant.elements.size(); ++element) {
                    output << "    elements[" << element << "] = abla_constant_"
                           << constant.elements[element] << "(cache, states);\n";
                }
                output << "    cache[" << i << "] = abla_array_create(elements, "
                       << constant.elements.size() << ");\n";
            }
            break;
        case ir::ConstantKind::Object:
            output << "    cache[" << i << "] = abla_object_create("
                   << constant.symbol << ");\n";
            for (const auto& field : constant.fields) {
                output << "    abla_field_set(cache[" << i << "], " << field.symbol
                       << ", abla_constant_" << field.value << "(cache, states));\n";
            }
            break;
        }
        output << "    states[" << i << "] = 2;\n"
               << "    return cache[" << i << "];\n"
               << "}\n\n";
    }
    output << "static AblaValue abla_constant_get(uint32_t constant) {\n"
           << "    AblaValue cache[" << program_.constants.size() << "];\n"
           << "    uint8_t states[" << program_.constants.size() << "] = {0};\n"
           << "    switch (constant) {\n";
    for (std::size_t i = 0; i < program_.constants.size(); ++i) {
        output << "    case " << i << ": return abla_constant_" << i
               << "(cache, states);\n";
    }
    output << "    default: abla_platform_panic(\"invalid frozen constant\", 23);\n"
              "    }\n"
              "}\n\n";
}

void CEmitter::emit_dispatch(std::ostream& output) {
    output << "static AblaValue abla_dispatch(uint32_t function, "
              "const AblaValue* args, size_t count) {\n"
              "    switch (function) {\n";
    for (const auto& function : program_.functions) {
        if (function.compile_only) continue;
        output << "    case " << function.id << ": return "
               << function_name(function.id) << "(args, count);\n";
    }
    output << "    default: abla_platform_panic(\"invalid function\", 16);\n"
              "    }\n"
              "}\n\n";
}

void CEmitter::emit_function(
    std::ostream& output,
    const ir::Function& function) {
    ir::ValueId value_count = 0;
    for (const auto& block : function.blocks) {
        for (const auto& instruction : block.instructions) {
            if (instruction.result != ir::no_value) {
                value_count = std::max(value_count, instruction.result + 1);
            }
        }
    }
    output << "static AblaValue " << function_name(function.id)
           << "(const AblaValue* args, size_t count) {\n"
              "    (void)count;\n"
              "    (void)args;\n"
           << "    AblaValue locals[" << std::max<std::size_t>(function.locals.size(), 1)
           << "];\n"
           << "    AblaValue values[" << std::max<ir::ValueId>(value_count, 1)
           << "];\n"
              "    (void)locals;\n"
              "    (void)values;\n";
    for (std::size_t i = 0; i < function.parameters.size(); ++i) {
        output << "    locals[" << function.parameters[i] << "] = args[" << i << "];\n";
    }
    output << "    goto block_0;\n";
    for (const auto& block : function.blocks) {
        output << "block_" << block.id << ": ;\n";
        for (const auto& instruction : block.instructions) {
            emit_instruction(output, instruction);
        }
        emit_terminator(output, block.terminator);
    }
    output << "}\n\n";
}

void CEmitter::emit_external(
    std::ostream& output,
    const ir::Function& function) {
    if (function.native_library == "host" ||
        function.native_library == "intrinsic") {
        output << "static AblaValue " << function_name(function.id)
               << "(const AblaValue* args, size_t count) {\n"
                  "    (void)count;\n"
                  "    (void)args;\n"
                  "    return "
               << function.name << '(';
        for (std::size_t i = 0; i < function.parameters.size(); ++i) {
            if (i != 0) output << ", ";
            output << "args[" << i << ']';
        }
        output << ");\n}\n\n";
        return;
    }
    if (function.native_library != "c") {
        diagnostics_.error(
            {},
            "C backend currently requires extern library name \"c\"");
    }
    output << "extern " << native_type(function.result_type, {}) << ' '
           << function.name << '(';
    for (std::size_t i = 0; i < function.parameters.size(); ++i) {
        if (i != 0) output << ", ";
        output << native_type(function.locals[function.parameters[i]].type, {});
    }
    if (function.parameters.empty()) output << "void";
    output << ");\n"
           << "static AblaValue " << function_name(function.id)
           << "(const AblaValue* args, size_t count) {\n"
              "    (void)count;\n"
              "    (void)args;\n    ";
    const auto result_type = types_.get(function.result_type).kind;
    if (result_type != sema::TypeKind::Void) output << "return ";
    const auto call = [&]() {
        std::ostringstream expression;
        expression << function.name << '(';
        for (std::size_t i = 0; i < function.parameters.size(); ++i) {
            if (i != 0) expression << ", ";
            expression << native_argument(
                function.locals[function.parameters[i]].type,
                "args[" + std::to_string(i) + "]",
                {});
        }
        expression << ')';
        return expression.str();
    }();
    if (result_type == sema::TypeKind::Void) {
        output << call << ";\n    return abla_void();\n";
    } else {
        output << native_result(function.result_type, call, {}) << ";\n";
    }
    output << "}\n\n";
}

void CEmitter::emit_instruction(
    std::ostream& output,
    const ir::Instruction& instruction) {
    const auto assign = instruction.result == ir::no_value
        ? std::string("    ")
        : "    values[" + std::to_string(instruction.result) + "] = ";
    using ir::Opcode;
    switch (instruction.opcode) {
    case Opcode::ConstantInt:
        output << assign << "abla_i64(INT64_C(" << instruction.integer << "));\n";
        break;
    case Opcode::ConstantBool:
        output << assign << "abla_bool(" << (instruction.integer ? "true" : "false") << ");\n";
        break;
    case Opcode::ConstantNull:
        output << assign << "abla_null();\n";
        break;
    case Opcode::ConstantString:
        if (instruction.text.size() <= 750) {
            output << assign << "abla_string_static(" << c_string(instruction.text)
                   << ", " << instruction.text.size() << ");\n";
        } else {
            output << assign << "abla_string_static(\"\", 0);\n";
            for (std::size_t begin = 0; begin < instruction.text.size(); begin += 750) {
                const auto chunk = instruction.text.substr(begin, 750);
                output << "    values[" << instruction.result
                       << "] = abla_string_concat(values[" << instruction.result
                       << "], abla_string_static(" << c_string(chunk) << ", "
                       << chunk.size() << "));\n";
            }
        }
        break;
    case Opcode::ConstantFrozen:
        output << assign << "abla_constant_get(" << instruction.index << ");\n";
        break;
    case Opcode::CompileValue:
        diagnostics_.error(instruction.span, "unmaterialized compile value reached C backend");
        break;
    case Opcode::ToString:
        output << assign << "abla_to_string(values[" << instruction.operands[0] << "]);\n";
        break;
    case Opcode::StringConcat:
        output << assign << "abla_string_concat(" << operands(instruction) << ");\n";
        break;
    case Opcode::FunctionRef:
        output << assign << "abla_function(" << instruction.index << ");\n";
        break;
    case Opcode::LoadLocal:
        output << assign << "locals[" << instruction.index << "];\n";
        break;
    case Opcode::StoreLocal:
        output << "    locals[" << instruction.index << "] = values["
               << instruction.operands[0] << "];\n";
        break;
    case Opcode::LoadGlobal:
        output << assign << "abla_global_get(" << instruction.index << ");\n";
        break;
    case Opcode::StoreGlobal:
        output << "    abla_global_set(" << instruction.index << ", values["
               << instruction.operands[0] << "]);\n";
        break;
    case Opcode::Negate:
        output << assign << "abla_negate(values[" << instruction.operands[0] << "]);\n";
        break;
    case Opcode::LogicalNot:
        output << assign << "abla_not(values[" << instruction.operands[0] << "]);\n";
        break;
    case Opcode::Add:
    case Opcode::Subtract:
    case Opcode::Multiply:
    case Opcode::Divide:
    case Opcode::Equal:
    case Opcode::NotEqual:
    case Opcode::Less:
    case Opcode::LessEqual:
    case Opcode::Greater:
    case Opcode::GreaterEqual:
        output << assign << runtime_binary(instruction.opcode) << '('
               << operands(instruction) << ");\n";
        break;
    case Opcode::Call:
    case Opcode::CallIndirect: {
        const auto first_argument = instruction.opcode == Opcode::CallIndirect ? 1u : 0u;
        output << "    {\n";
        if (instruction.operands.size() > first_argument) {
            output << "        AblaValue call_args[] = {";
            for (std::size_t i = first_argument; i < instruction.operands.size(); ++i) {
                if (i != first_argument) output << ", ";
                output << "values[" << instruction.operands[i] << ']';
            }
            output << "};\n";
        }
        output << "        ";
        if (instruction.result != ir::no_value) {
            output << "values[" << instruction.result << "] = ";
        }
        if (instruction.opcode == Opcode::Call) {
            output << function_name(instruction.index);
        } else {
            output << "abla_dispatch(abla_as_function(values["
                   << instruction.operands[0] << "]), ";
            if (instruction.operands.size() > 1) output << "call_args, " << instruction.operands.size() - 1 << ");\n";
            else output << "(const AblaValue*)0, 0);\n";
            output << "    }\n";
            break;
        }
        if (instruction.operands.size() > first_argument) {
            output << "(call_args, " << instruction.operands.size() - first_argument << ");\n";
        } else {
            output << "((const AblaValue*)0, 0);\n";
        }
        output << "    }\n";
        break;
    }
    case Opcode::ArrayCreate:
        output << "    {\n";
        if (!instruction.operands.empty()) {
            output << "        AblaValue elements[] = {";
            for (std::size_t i = 0; i < instruction.operands.size(); ++i) {
                if (i != 0) output << ", ";
                output << "values[" << instruction.operands[i] << ']';
            }
            output << "};\n        values[" << instruction.result
                   << "] = abla_array_create(elements, " << instruction.operands.size() << ");\n";
        } else {
            output << "        values[" << instruction.result
                   << "] = abla_array_create((const AblaValue*)0, 0);\n";
        }
        output << "    }\n";
        break;
    case Opcode::ArrayLength:
        output << assign << "abla_array_length(values[" << instruction.operands[0]
               << "]);\n";
        break;
    case Opcode::ArrayAppend:
        output << assign << "abla_array_append(" << operands(instruction) << ");\n";
        break;
    case Opcode::ArrayGet:
        output << assign << "abla_array_get(" << operands(instruction) << ");\n";
        break;
    case Opcode::ArraySet:
        output << "    abla_array_set(" << operands(instruction) << ");\n";
        break;
    case Opcode::StringLength:
        output << assign << "abla_string_length(values[" << instruction.operands[0]
               << "]);\n";
        break;
    case Opcode::StringGet:
        output << assign << "abla_string_get(" << operands(instruction) << ");\n";
        break;
    case Opcode::StringSlice:
        output << assign << "abla_string_slice(" << operands(instruction) << ");\n";
        break;
    case Opcode::ObjectCreate:
        output << assign << "abla_object_create(" << instruction.symbol << ");\n";
        for (std::size_t i = 0; i < instruction.operands.size() &&
                                i < instruction.field_symbols.size(); ++i) {
            if (instruction.field_symbols[i] ==
                std::numeric_limits<sema::SymbolId>::max()) continue;
            output << "    abla_field_set(values[" << instruction.result << "], "
                   << instruction.field_symbols[i] << ", values["
                   << instruction.operands[i] << "]);\n";
        }
        break;
    case Opcode::FieldGet:
        output << assign << "abla_field_get(values[" << instruction.operands[0]
               << "], " << instruction.symbol << ");\n";
        break;
    case Opcode::FieldSet:
        output << "    abla_field_set(values[" << instruction.operands[0]
               << "], " << instruction.symbol << ", values["
               << instruction.operands[1] << "]);\n";
        break;
    }
}

void CEmitter::emit_terminator(
    std::ostream& output,
    const ir::Terminator& terminator) {
    if (terminator.kind == ir::TerminatorKind::Return) {
        output << "    return ";
        if (terminator.value == ir::no_value) output << "abla_void()";
        else output << "values[" << terminator.value << ']';
        output << ";\n";
    } else if (terminator.kind == ir::TerminatorKind::Jump) {
        output << "    goto block_" << terminator.first << ";\n";
    } else if (terminator.kind == ir::TerminatorKind::Branch) {
        output << "    if (abla_as_bool(values[" << terminator.value << "])) "
               << "goto block_" << terminator.first << "; else goto block_"
               << terminator.second << ";\n";
    }
}

void CEmitter::emit_entry(std::ostream& output) {
    const auto found = std::find_if(
        program_.functions.begin(), program_.functions.end(),
        [](const auto& function) {
            return function.name == "main" && !function.compile_only;
        });
    if (found == program_.functions.end()) {
        diagnostics_.error({}, "C backend requires a runtime 'main' function");
        return;
    }
    if (!found->parameters.empty()) {
        diagnostics_.error({}, "C backend main function cannot yet take parameters");
        return;
    }
    output << "int main(int argc, char** argv) {\n"
              "    abla_host_set_arguments(argc, argv);\n"
              "    (void)abla_dispatch;\n"
              "    (void)abla_global_get;\n"
              "    (void)abla_global_set;\n";
    if (program_.globals.empty()) {
        output << "    (void)abla_globals;\n"
                  "    (void)abla_global_state;\n";
    }
    for (const auto& global : program_.globals) {
        output << "    (void)abla_global_get(" << global.id << ");\n";
    }
    output << "    AblaValue result = " << function_name(found->id)
           << "((const AblaValue*)0, 0);\n"
              "    if (result.tag == ABLA_VOID) return 0;\n"
              "    return (int)abla_as_i64(result);\n"
              "}\n";
}

std::string CEmitter::operands(const ir::Instruction& instruction) const {
    std::string result;
    for (std::size_t i = 0; i < instruction.operands.size(); ++i) {
        if (i != 0) result += ", ";
        result += "values[" + std::to_string(instruction.operands[i]) + ']';
    }
    return result;
}

std::string CEmitter::native_type(sema::TypeId type, SourceSpan span) {
    switch (types_.get(type).kind) {
    case sema::TypeKind::Void: return "void";
    case sema::TypeKind::Integer: return "int64_t";
    case sema::TypeKind::Bool: return "bool";
    case sema::TypeKind::CString: return "const char*";
    default:
        diagnostics_.error(span, "type is not supported by the C native ABI adapter");
        return "AblaValue";
    }
}

std::string CEmitter::native_argument(
    sema::TypeId type,
    std::string value,
    SourceSpan span) {
    switch (types_.get(type).kind) {
    case sema::TypeKind::Integer: return "abla_as_i64(" + value + ')';
    case sema::TypeKind::Bool: return "abla_as_bool(" + value + ')';
    case sema::TypeKind::CString: return "abla_as_cstring(" + value + ')';
    default:
        diagnostics_.error(span, "argument type is not supported by C native ABI adapter");
        return value;
    }
}

std::string CEmitter::native_result(
    sema::TypeId type,
    std::string expression,
    SourceSpan span) {
    switch (types_.get(type).kind) {
    case sema::TypeKind::Integer: return "abla_i64(" + expression + ')';
    case sema::TypeKind::Bool: return "abla_bool(" + expression + ')';
    case sema::TypeKind::CString:
        diagnostics_.error(span, "native cstring return conversion is not yet owned safely");
        return "abla_void()";
    default:
        diagnostics_.error(span, "result type is not supported by C native ABI adapter");
        return "abla_void()";
    }
}

std::string CEmitter::c_string(const std::string& value) {
    std::ostringstream output;
    output << '"';
    std::size_t token_length = 0;
    for (const auto character : value) {
        const auto byte = static_cast<unsigned char>(character);
        std::string escaped;
        switch (character) {
        case '\\': escaped = "\\\\"; break;
        case '"': escaped = "\\\""; break;
        case '\n': escaped = "\\n"; break;
        case '\r': escaped = "\\r"; break;
        case '\t': escaped = "\\t"; break;
        default:
            if (byte < 0x20 || byte >= 0x7f) {
                std::ostringstream octal;
                octal << '\\' << std::oct << std::setw(3) << std::setfill('0')
                      << static_cast<unsigned>(byte);
                escaped = octal.str();
            } else {
                escaped.assign(1, character);
            }
        }
        if (token_length + escaped.size() > 3000) {
            output << "\"\n        \"";
            token_length = 0;
        }
        output << escaped;
        token_length += escaped.size();
    }
    output << '"';
    return output.str();
}

std::string CEmitter::function_name(ir::FunctionId id) {
    return "abla_function_" + std::to_string(id);
}

} // namespace abla::backend
