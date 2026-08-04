#include "abla/backend_c.hpp"

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <limits>
#include <ostream>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

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

bool may_allocate(ir::Opcode opcode) {
    using ir::Opcode;
    switch (opcode) {
    case Opcode::ConstantString:
    case Opcode::ConstantFrozen:
    case Opcode::ToString:
    case Opcode::StringConcat:
    case Opcode::Equal:
    case Opcode::NotEqual:
    case Opcode::Call:
    case Opcode::CallIndirect:
    case Opcode::ArrayCreate:
    case Opcode::ArrayAppend:
    case Opcode::StringGet:
    case Opcode::StringSlice:
    case Opcode::ObjectCreate:
    case Opcode::FieldSet:
        return true;
    default:
        return false;
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
    using LiveSet = std::unordered_set<ir::ValueId>;
    std::vector<LiveSet> uses(function.blocks.size());
    std::vector<LiveSet> definitions(function.blocks.size());
    std::vector<std::vector<ir::BlockId>> successors(function.blocks.size());
    for (const auto& block : function.blocks) {
        for (const auto& instruction : block.instructions) {
            for (const auto operand : instruction.operands) {
                if (!definitions[block.id].contains(operand)) {
                    uses[block.id].insert(operand);
                }
            }
            if (instruction.result != ir::no_value) {
                definitions[block.id].insert(instruction.result);
            }
        }
        if (block.terminator.value != ir::no_value &&
            !definitions[block.id].contains(block.terminator.value)) {
            uses[block.id].insert(block.terminator.value);
        }
        if (block.terminator.kind == ir::TerminatorKind::Jump) {
            successors[block.id].push_back(block.terminator.first);
        } else if (block.terminator.kind == ir::TerminatorKind::Branch) {
            successors[block.id].push_back(block.terminator.first);
            successors[block.id].push_back(block.terminator.second);
        }
    }
    std::vector<bool> reachable(function.blocks.size(), false);
    std::vector<ir::BlockId> pending{0};
    while (!pending.empty()) {
        const auto id = pending.back();
        pending.pop_back();
        if (id >= reachable.size() || reachable[id]) continue;
        reachable[id] = true;
        for (const auto successor : successors[id]) pending.push_back(successor);
    }
    std::vector<LiveSet> live_in(function.blocks.size());
    std::vector<LiveSet> live_out(function.blocks.size());
    bool changed = true;
    while (changed) {
        changed = false;
        for (std::size_t reverse = function.blocks.size(); reverse > 0; --reverse) {
            const auto block = reverse - 1;
            LiveSet next_out;
            for (const auto successor : successors[block]) {
                next_out.insert(live_in[successor].begin(), live_in[successor].end());
            }
            LiveSet next_in = uses[block];
            for (const auto value : next_out) {
                if (!definitions[block].contains(value)) next_in.insert(value);
            }
            if (next_in != live_in[block] || next_out != live_out[block]) {
                live_in[block] = std::move(next_in);
                live_out[block] = std::move(next_out);
                changed = true;
            }
        }
    }
    std::unordered_map<const ir::Instruction*, std::vector<ir::ValueId>> dead_after;
    for (const auto& block : function.blocks) {
        auto live = live_out[block.id];
        if (block.terminator.value != ir::no_value) {
            live.insert(block.terminator.value);
        }
        for (std::size_t reverse = block.instructions.size(); reverse > 0; --reverse) {
            const auto& instruction = block.instructions[reverse - 1];
            auto& dead = dead_after[&instruction];
            if (instruction.result != ir::no_value) {
                if (!live.contains(instruction.result)) {
                    dead.push_back(instruction.result);
                }
                live.erase(instruction.result);
            }
            for (const auto operand : instruction.operands) {
                if (!live.contains(operand)) dead.push_back(operand);
                live.insert(operand);
            }
        }
    }
    const auto local_count = std::max<std::size_t>(function.locals.size(), 1);
    const auto emitted_value_count = std::max<ir::ValueId>(value_count, 1);
    const auto root_count = local_count + emitted_value_count;
    output << "static AblaValue " << function_name(function.id)
           << "(const AblaValue* args, size_t count) {\n"
              "    (void)count;\n"
              "    (void)args;\n"
           << "    AblaValue locals[" << local_count << "] = {0};\n"
           << "    AblaValue values[" << emitted_value_count << "] = {0};\n"
           << "    void* abla_root_slots[" << root_count << "];\n"
              "    AblaRuntimeRootFrame abla_root_frame;\n"
           << "    for (size_t i = 0; i < " << local_count
           << "; ++i) abla_root_slots[i] = &locals[i];\n"
           << "    for (size_t i = 0; i < " << emitted_value_count
           << "; ++i) abla_root_slots[" << local_count
           << " + i] = &values[i];\n"
           << "    abla_runtime_roots_push(&abla_root_frame, abla_root_slots, "
           << root_count << ");\n"
              "    (void)locals;\n"
              "    (void)values;\n";
    for (std::size_t i = 0; i < function.parameters.size(); ++i) {
        output << "    locals[" << function.parameters[i] << "] = args[" << i << "];\n";
    }
    output << "    goto block_0;\n";
    for (const auto& block : function.blocks) {
        if (!reachable[block.id]) continue;
        output << "block_" << block.id << ": ;\n";
        for (const auto& instruction : block.instructions) {
            if (may_allocate(instruction.opcode)) {
                output << "    abla_runtime_memory_pressure();\n";
            }
            emit_instruction(output, instruction);
            for (const auto value : dead_after[&instruction]) {
                output << "    values[" << value << "] = abla_void();\n";
            }
            if (may_allocate(instruction.opcode)) {
                output << "    abla_runtime_memory_pressure();\n";
            }
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
        output << "    {\n        AblaValue abla_result = ";
        if (terminator.value == ir::no_value) output << "abla_void()";
        else output << "values[" << terminator.value << ']';
        output << ";\n        abla_runtime_roots_pop(&abla_root_frame);\n"
                  "        return abla_result;\n    }\n";
    } else if (terminator.kind == ir::TerminatorKind::Jump) {
        output << "    goto block_" << terminator.first << ";\n";
    } else if (terminator.kind == ir::TerminatorKind::Branch) {
        output << "    if (abla_as_bool(values[" << terminator.value << "])) "
               << "goto block_" << terminator.first << "; else goto block_"
               << terminator.second << ";\n";
    } else if (terminator.kind == ir::TerminatorKind::Unreachable) {
        output << "    abla_runtime_roots_pop(&abla_root_frame);\n"
                  "    return abla_void();\n";
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
    const auto global_count = std::max<std::size_t>(program_.globals.size(), 1);
    output << "    void* abla_root_slots[" << global_count << "];\n"
           << "    for (size_t i = 0; i < " << global_count
           << "; ++i) abla_root_slots[i] = &abla_globals[i];\n"
              "    AblaRuntimeRootFrame abla_root_frame;\n"
           << "    abla_runtime_roots_push(&abla_root_frame, abla_root_slots, "
           << global_count << ");\n";
    if (program_.globals.empty()) {
        output << "    (void)abla_globals;\n"
                  "    (void)abla_global_state;\n";
    }
    for (const auto& global : program_.globals) {
        output << "    (void)abla_global_get(" << global.id << ");\n";
    }
    output << "    AblaValue result = " << function_name(found->id)
           << "((const AblaValue*)0, 0);\n"
              "    abla_runtime_roots_pop(&abla_root_frame);\n"
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
