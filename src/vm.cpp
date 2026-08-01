#include "abla/vm.hpp"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <unordered_set>
#include <utility>

namespace abla::vm {

void NativeRegistry::add(
    std::string library,
    std::string name,
    NativeFunction function) {
    functions_[key(library, name)] = std::move(function);
}

const NativeFunction* NativeRegistry::find(
    std::string_view library,
    std::string_view name) const {
    const auto found = functions_.find(key(library, name));
    return found == functions_.end() ? nullptr : &found->second;
}

std::string NativeRegistry::key(
    std::string_view library,
    std::string_view name) {
    std::string result(library);
    result.push_back('\0');
    result.append(name);
    return result;
}

Value Machine::run(ir::FunctionId function, std::vector<Value> arguments) {
    reset();
    return invoke(function, std::move(arguments));
}

void Machine::reset() {
    instructions_executed_ = 0;
    call_depth_ = 0;
    globals_.assign(program_.globals.size(), Value::void_value());
    global_states_.assign(program_.globals.size(), GlobalState::Uninitialized);
    for (ir::GlobalId id = 0; id < program_.globals.size(); ++id) {
        static_cast<void>(load_global(id));
        if (diagnostics_.has_errors()) return;
    }
}

Value Machine::invoke(ir::FunctionId function, std::vector<Value> arguments) {
    return execute(function, arguments);
}

std::optional<ir::FunctionId> Machine::find_function(std::string_view name) const {
    const auto found = std::find_if(
        program_.functions.begin(), program_.functions.end(),
        [&](const auto& function) { return function.name == name; });
    return found == program_.functions.end()
        ? std::nullopt
        : std::optional(found->id);
}

Value Machine::execute(
    ir::FunctionId function_id,
    const std::vector<Value>& arguments) {
    if (function_id >= program_.functions.size()) {
        runtime_error({}, "call references an invalid function");
        return Value::void_value();
    }
    const auto& function = program_.functions[function_id];
    if (arguments.size() != function.parameters.size()) {
        runtime_error({}, "runtime call argument count does not match function");
        return Value::void_value();
    }
    if (function.external) return execute_external(function, arguments);
    if (++call_depth_ > limits_.max_call_depth) {
        --call_depth_;
        runtime_error({}, "compile-time/runtime VM call-depth limit exceeded");
        return Value::void_value();
    }

    Frame frame;
    frame.function = &function;
    frame.locals.assign(function.locals.size(), Value::void_value());
    for (std::size_t i = 0; i < arguments.size(); ++i) {
        frame.locals[function.parameters[i]] = arguments[i];
    }

    ir::BlockId block_id = 0;
    while (!diagnostics_.has_errors()) {
        if (block_id >= function.blocks.size()) {
            runtime_error({}, "VM reached an invalid basic block");
            break;
        }
        const auto& block = function.blocks[block_id];
        frame.values.clear();
        for (const auto& instruction : block.instructions) {
            if (!tick(instruction.span)) break;
            auto value = execute_instruction(frame, instruction);
            if (instruction.result != ir::no_value) {
                frame.values[instruction.result] = std::move(value);
            }
        }
        if (diagnostics_.has_errors()) break;

        const auto& terminator = block.terminator;
        if (!tick(terminator.span)) break;
        if (terminator.kind == ir::TerminatorKind::Return) {
            --call_depth_;
            return terminator.value == ir::no_value
                ? Value::void_value()
                : operand(frame, terminator.value);
        }
        if (terminator.kind == ir::TerminatorKind::Jump) {
            block_id = terminator.first;
            continue;
        }
        if (terminator.kind == ir::TerminatorKind::Branch) {
            try {
                block_id = operand(frame, terminator.value).as_boolean()
                    ? terminator.first
                    : terminator.second;
            } catch (const std::bad_variant_access&) {
                runtime_error(terminator.span, "VM branch condition is not bool");
            }
            continue;
        }
        runtime_error(terminator.span, "VM reached unterminated basic block");
    }
    --call_depth_;
    return Value::void_value();
}

Value Machine::execute_external(
    const ir::Function& function,
    const std::vector<Value>& arguments) {
    if (function.native_library == "compiler") {
        return execute_compiler_intrinsic(function, arguments);
    }
    if (function.native_library == "host") {
        try {
            if (function.name == "ablaHostArgumentCount" && arguments.empty()) {
                return Value::integer(0);
            }
            if (function.name == "ablaHostReadFile" && arguments.size() == 1) {
                std::ifstream stream(arguments[0].as_string(), std::ios::binary);
                if (!stream) throw std::runtime_error("cannot open input file");
                return Value::string(std::string(
                    std::istreambuf_iterator<char>(stream),
                    std::istreambuf_iterator<char>()));
            }
            if (function.name == "ablaHostWriteStdout" && arguments.size() == 1) {
                std::cout << arguments[0].as_string();
                return Value::void_value();
            }
            if (function.name == "ablaHostWriteStderr" && arguments.size() == 1) {
                std::cerr << arguments[0].as_string();
                return Value::void_value();
            }
            if (function.name == "ablaHostArgument" && arguments.size() == 1) {
                throw std::runtime_error("VM invocation has no process arguments");
            }
            throw std::runtime_error("unknown host function");
        } catch (const std::exception& error) {
            runtime_error({}, "host function failed: " + std::string(error.what()));
            return Value::void_value();
        }
    }
    if (natives_ == nullptr) {
        runtime_error({}, "native function registry is not configured");
        return Value::void_value();
    }
    const auto* native = natives_->find(function.native_library, function.name);
    if (native == nullptr) {
        runtime_error(
            {},
            "native function '" + function.native_library + ':' +
                function.name + "' is not registered");
        return Value::void_value();
    }
    try {
        return (*native)(arguments);
    } catch (const std::exception& error) {
        runtime_error({}, "native function failed: " + std::string(error.what()));
        return Value::void_value();
    }
}

Value Machine::execute_compiler_intrinsic(
    const ir::Function& function,
    const std::vector<Value>& arguments) {
    if (!function.compile_only) {
        runtime_error({}, "compiler intrinsics must be declared compile-only");
        return Value::void_value();
    }
    std::vector<const ir::Function*> functions;
    for (const auto& candidate : program_.functions) {
        if (candidate.symbol_id != ir::no_symbol &&
            candidate.native_library != "compiler") {
            functions.push_back(&candidate);
        }
    }
    const auto require_arguments = [&](std::size_t expected) {
        if (arguments.size() == expected) return true;
        runtime_error({}, "compiler intrinsic received an invalid argument count");
        return false;
    };
    const auto by_handle = [&](std::int64_t handle) -> const ir::Function* {
        if (handle < 0) return nullptr;
        const auto found = std::find_if(
            functions.begin(), functions.end(), [&](const auto* candidate) {
                return candidate->symbol_id == static_cast<sema::SymbolId>(handle);
            });
        return found == functions.end() ? nullptr : *found;
    };
    const auto argument_handle = [&]() -> const ir::Function* {
        if (!require_arguments(1)) return nullptr;
        const auto* handle = std::get_if<std::int64_t>(&arguments[0].storage());
        if (handle == nullptr) {
            runtime_error({}, "compiler reflection handle must be an integer");
            return nullptr;
        }
        const auto* reflected = by_handle(*handle);
        if (reflected == nullptr) {
            runtime_error({}, "compiler reflection function handle is invalid");
        }
        return reflected;
    };

    if (function.name == "compilerFunctions") {
        if (!require_arguments(0)) return Value::void_value();
        auto result = std::make_shared<ArrayValue>();
        for (const auto* reflected : functions) {
            result->elements.push_back(
                Value::integer(static_cast<std::int64_t>(reflected->symbol_id)));
        }
        return Value(result);
    }
    if (function.name == "compilerFindFunction") {
        if (!require_arguments(1)) return Value::void_value();
        const auto* name = std::get_if<std::string>(&arguments[0].storage());
        if (name == nullptr) {
            runtime_error({}, "compiler reflection name must be a string");
            return Value::void_value();
        }
        const auto found = std::find_if(
            functions.begin(), functions.end(), [&](const auto* candidate) {
                return candidate->name == *name;
            });
        return Value::integer(
            found == functions.end()
                ? -1
                : static_cast<std::int64_t>((*found)->symbol_id));
    }
    if (function.name == "compilerFunctionName") {
        const auto* reflected = argument_handle();
        return reflected == nullptr
            ? Value::void_value()
            : Value::string(reflected->name);
    }
    if (function.name == "compilerFunctionParameterCount") {
        const auto* reflected = argument_handle();
        return reflected == nullptr
            ? Value::void_value()
            : Value::integer(static_cast<std::int64_t>(reflected->parameters.size()));
    }
    if (function.name == "compilerFunctionResultType") {
        const auto* reflected = argument_handle();
        return reflected == nullptr
            ? Value::void_value()
            : Value::string(types_.to_string(reflected->result_type));
    }
    if (function.name == "compilerFunctionIsCompileOnly") {
        const auto* reflected = argument_handle();
        return reflected == nullptr
            ? Value::void_value()
            : Value::boolean(reflected->compile_only);
    }
    if (function.name == "compilerRegisterSubparser") {
        if (!require_arguments(2)) return Value::void_value();
        const auto* name = std::get_if<std::string>(&arguments[0].storage());
        const auto* parser = std::get_if<FunctionValue>(&arguments[1].storage());
        if (name == nullptr || parser == nullptr) {
            runtime_error(
                {},
                "compilerRegisterSubparser expects a name and parser function");
            return Value::void_value();
        }
        if (compiler_services_ == nullptr) return Value::void_value();
        if (!compiler_services_->register_subparser ||
            !compiler_services_->register_subparser(*name, parser->id)) {
            runtime_error({}, "subparser registration was rejected");
        }
        return Value::void_value();
    }
    runtime_error({}, "unknown compiler intrinsic '" + function.name + "'");
    return Value::void_value();
}

Value Machine::execute_instruction(
    Frame& frame,
    const ir::Instruction& instruction) {
    using ir::Opcode;
    try {
        switch (instruction.opcode) {
        case Opcode::ConstantInt:
            return Value::integer(instruction.integer);
        case Opcode::ConstantBool:
            return Value::boolean(instruction.integer != 0);
        case Opcode::ConstantNull:
            return Value::null_value();
        case Opcode::ConstantString:
            return Value::string(instruction.text);
        case Opcode::ConstantFrozen:
            return thaw_constant(instruction.index);
        case Opcode::CompileValue:
            runtime_error(
                instruction.span,
                "unmaterialized compile-time value reached VM execution");
            return Value::void_value();
        case Opcode::ToString:
            return Value::string(to_string(operand(frame, instruction.operands[0])));
        case Opcode::StringConcat:
            return Value::string(
                operand(frame, instruction.operands[0]).as_string() +
                operand(frame, instruction.operands[1]).as_string());
        case Opcode::FunctionRef:
            return Value::function(instruction.index);
        case Opcode::LoadLocal:
            return frame.locals.at(instruction.index);
        case Opcode::StoreLocal:
            frame.locals.at(instruction.index) = operand(frame, instruction.operands[0]);
            return Value::void_value();
        case Opcode::LoadGlobal:
            return load_global(instruction.index);
        case Opcode::StoreGlobal:
            globals_.at(instruction.index) = operand(frame, instruction.operands[0]);
            global_states_.at(instruction.index) = GlobalState::Ready;
            return Value::void_value();
        case Opcode::Negate:
            return Value::integer(-operand(frame, instruction.operands[0]).as_integer());
        case Opcode::LogicalNot:
            return Value::boolean(!operand(frame, instruction.operands[0]).as_boolean());
        case Opcode::Add:
            return Value::integer(
                operand(frame, instruction.operands[0]).as_integer() +
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::Subtract:
            return Value::integer(
                operand(frame, instruction.operands[0]).as_integer() -
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::Multiply:
            return Value::integer(
                operand(frame, instruction.operands[0]).as_integer() *
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::Divide: {
            const auto divisor = operand(frame, instruction.operands[1]).as_integer();
            if (divisor == 0) {
                runtime_error(instruction.span, "division by zero");
                return Value::void_value();
            }
            return Value::integer(
                operand(frame, instruction.operands[0]).as_integer() / divisor);
        }
        case Opcode::Equal:
            return Value::boolean(equal(
                operand(frame, instruction.operands[0]),
                operand(frame, instruction.operands[1])));
        case Opcode::NotEqual:
            return Value::boolean(!equal(
                operand(frame, instruction.operands[0]),
                operand(frame, instruction.operands[1])));
        case Opcode::Less:
            return Value::boolean(
                operand(frame, instruction.operands[0]).as_integer() <
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::LessEqual:
            return Value::boolean(
                operand(frame, instruction.operands[0]).as_integer() <=
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::Greater:
            return Value::boolean(
                operand(frame, instruction.operands[0]).as_integer() >
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::GreaterEqual:
            return Value::boolean(
                operand(frame, instruction.operands[0]).as_integer() >=
                operand(frame, instruction.operands[1]).as_integer());
        case Opcode::Call: {
            std::vector<Value> arguments;
            for (const auto id : instruction.operands) arguments.push_back(operand(frame, id));
            return execute(instruction.index, arguments);
        }
        case Opcode::CallIndirect: {
            const auto target = operand(frame, instruction.operands[0]).as_function().id;
            std::vector<Value> arguments;
            for (std::size_t i = 1; i < instruction.operands.size(); ++i) {
                arguments.push_back(operand(frame, instruction.operands[i]));
            }
            return execute(target, arguments);
        }
        case Opcode::ArrayCreate: {
            auto array = std::make_shared<ArrayValue>();
            for (const auto id : instruction.operands) array->elements.push_back(operand(frame, id));
            return Value(array);
        }
        case Opcode::ArrayLength: {
            const auto array = operand(frame, instruction.operands[0]).as_array();
            if (array->elements.size() >
                static_cast<std::size_t>(std::numeric_limits<std::int64_t>::max())) {
                runtime_error(instruction.span, "array length does not fit in int");
                return Value::void_value();
            }
            return Value::integer(static_cast<std::int64_t>(array->elements.size()));
        }
        case Opcode::ArrayAppend: {
            const auto array = operand(frame, instruction.operands[0]).as_array();
            array->elements.push_back(operand(frame, instruction.operands[1]));
            return Value::void_value();
        }
        case Opcode::ArrayGet: {
            const auto array = operand(frame, instruction.operands[0]).as_array();
            const auto index = operand(frame, instruction.operands[1]).as_integer();
            if (index < 0 || static_cast<std::size_t>(index) >= array->elements.size()) {
                runtime_error(instruction.span, "array index out of bounds");
                return Value::void_value();
            }
            return array->elements[static_cast<std::size_t>(index)];
        }
        case Opcode::ArraySet: {
            const auto array = operand(frame, instruction.operands[0]).as_array();
            const auto index = operand(frame, instruction.operands[1]).as_integer();
            if (index < 0 || static_cast<std::size_t>(index) >= array->elements.size()) {
                runtime_error(instruction.span, "array index out of bounds");
                return Value::void_value();
            }
            array->elements[static_cast<std::size_t>(index)] =
                operand(frame, instruction.operands[2]);
            return Value::void_value();
        }
        case Opcode::StringLength: {
            const auto value = operand(frame, instruction.operands[0]);
            const auto& string = value.as_string();
            if (string.size() >
                static_cast<std::size_t>(std::numeric_limits<std::int64_t>::max())) {
                runtime_error(instruction.span, "string length does not fit in int");
                return Value::void_value();
            }
            return Value::integer(static_cast<std::int64_t>(string.size()));
        }
        case Opcode::StringGet: {
            const auto value = operand(frame, instruction.operands[0]);
            const auto& string = value.as_string();
            const auto index = operand(frame, instruction.operands[1]).as_integer();
            if (index < 0 || static_cast<std::size_t>(index) >= string.size()) {
                runtime_error(instruction.span, "string index out of bounds");
                return Value::void_value();
            }
            return Value::integer(static_cast<unsigned char>(
                string[static_cast<std::size_t>(index)]));
        }
        case Opcode::StringSlice: {
            const auto value = operand(frame, instruction.operands[0]);
            const auto& string = value.as_string();
            const auto begin = operand(frame, instruction.operands[1]).as_integer();
            const auto end = operand(frame, instruction.operands[2]).as_integer();
            if (begin < 0 || end < begin ||
                static_cast<std::size_t>(end) > string.size()) {
                runtime_error(instruction.span, "string slice is out of bounds");
                return Value::void_value();
            }
            return Value::string(string.substr(
                static_cast<std::size_t>(begin),
                static_cast<std::size_t>(end - begin)));
        }
        case Opcode::ObjectCreate: {
            auto object = std::make_shared<ObjectValue>();
            object->type_symbol = instruction.symbol;
            for (std::size_t i = 0; i < instruction.operands.size() &&
                                    i < instruction.field_symbols.size(); ++i) {
                const auto field = instruction.field_symbols[i];
                if (field != std::numeric_limits<sema::SymbolId>::max()) {
                    object->fields[field] = operand(frame, instruction.operands[i]);
                }
            }
            return Value(object);
        }
        case Opcode::FieldGet: {
            const auto object = operand(frame, instruction.operands[0]).as_object();
            const auto found = object->fields.find(instruction.symbol);
            if (found == object->fields.end()) {
                runtime_error(instruction.span, "object field is uninitialized");
                return Value::void_value();
            }
            return found->second;
        }
        case Opcode::FieldSet: {
            const auto object = operand(frame, instruction.operands[0]).as_object();
            object->fields[instruction.symbol] = operand(frame, instruction.operands[1]);
            return Value::void_value();
        }
        }
    } catch (const std::bad_variant_access&) {
        runtime_error(instruction.span, "VM value does not match verified instruction type");
    } catch (const std::out_of_range&) {
        runtime_error(instruction.span, "VM instruction references an invalid slot");
    }
    return Value::void_value();
}

Value Machine::operand(const Frame& frame, ir::ValueId value) const {
    return frame.values.at(value);
}

Value Machine::thaw_constant(ir::ConstantId constant) {
    std::unordered_map<ir::ConstantId, Value> values;
    return thaw_constant(constant, values);
}

Value Machine::thaw_constant(
    ir::ConstantId constant,
    std::unordered_map<ir::ConstantId, Value>& values) {
    if (const auto found = values.find(constant); found != values.end()) {
        return found->second;
    }
    const auto& frozen = program_.constants.at(constant);
    Value value;
    switch (frozen.kind) {
    case ir::ConstantKind::Null:
        value = Value::null_value();
        break;
    case ir::ConstantKind::Integer:
        value = Value::integer(frozen.integer);
        break;
    case ir::ConstantKind::Boolean:
        value = Value::boolean(frozen.integer != 0);
        break;
    case ir::ConstantKind::String:
        value = Value::string(frozen.text);
        break;
    case ir::ConstantKind::Array: {
        auto array = std::make_shared<ArrayValue>();
        for (const auto element : frozen.elements) {
            array->elements.push_back(thaw_constant(element, values));
        }
        value = Value(array);
        break;
    }
    case ir::ConstantKind::Object: {
        auto object = std::make_shared<ObjectValue>();
        object->type_symbol = frozen.symbol;
        for (const auto& field : frozen.fields) {
            object->fields[field.symbol] = thaw_constant(field.value, values);
        }
        value = Value(object);
        break;
    }
    }
    values.emplace(constant, value);
    return value;
}

Value Machine::load_global(ir::GlobalId global) {
    if (global >= program_.globals.size()) {
        runtime_error({}, "global reference is out of range");
        return Value::void_value();
    }
    if (global_states_[global] == GlobalState::Ready) return globals_[global];
    if (global_states_[global] == GlobalState::Initializing) {
        runtime_error({}, "cyclic global initialization");
        return Value::void_value();
    }
    global_states_[global] = GlobalState::Initializing;
    const auto initializer = program_.globals[global].initializer;
    globals_[global] = initializer == ir::no_function
        ? Value::void_value()
        : execute(initializer, {});
    global_states_[global] = GlobalState::Ready;
    return globals_[global];
}

bool Machine::tick(SourceSpan span) {
    ++instructions_executed_;
    if (instructions_executed_ <= limits_.max_instructions) return true;
    runtime_error(span, "compile-time/runtime VM instruction limit exceeded");
    return false;
}

void Machine::runtime_error(SourceSpan span, std::string message) {
    diagnostics_.error(span, std::move(message));
}

bool Machine::equal(const Value& left, const Value& right) {
    if (left.storage().index() != right.storage().index()) return false;
    if (left.is_void() || left.is_null()) return true;
    if (const auto* value = std::get_if<std::int64_t>(&left.storage())) {
        return *value == std::get<std::int64_t>(right.storage());
    }
    if (const auto* value = std::get_if<bool>(&left.storage())) {
        return *value == std::get<bool>(right.storage());
    }
    if (const auto* value = std::get_if<std::string>(&left.storage())) {
        return *value == std::get<std::string>(right.storage());
    }
    if (const auto* value = std::get_if<FunctionValue>(&left.storage())) {
        return *value == std::get<FunctionValue>(right.storage());
    }
    if (const auto* value = std::get_if<HostValue>(&left.storage())) {
        return *value == std::get<HostValue>(right.storage());
    }
    if (const auto* value = std::get_if<std::shared_ptr<ArrayValue>>(&left.storage())) {
        return *value == std::get<std::shared_ptr<ArrayValue>>(right.storage());
    }
    return std::get<std::shared_ptr<ObjectValue>>(left.storage()) ==
        std::get<std::shared_ptr<ObjectValue>>(right.storage());
}

std::string Machine::to_string(const Value& value) {
    if (value.is_void()) return "void";
    if (value.is_null()) return "null";
    if (const auto* integer = std::get_if<std::int64_t>(&value.storage())) {
        return std::to_string(*integer);
    }
    if (const auto* boolean = std::get_if<bool>(&value.storage())) {
        return *boolean ? "true" : "false";
    }
    if (const auto* string = std::get_if<std::string>(&value.storage())) return *string;
    if (const auto* function = std::get_if<FunctionValue>(&value.storage())) {
        return "<function@" + std::to_string(function->id) + '>';
    }
    if (std::holds_alternative<HostValue>(value.storage())) {
        return "<compiler-handle>";
    }
    if (std::holds_alternative<std::shared_ptr<ArrayValue>>(value.storage())) return "<array>";
    return "<object>";
}

bool materialize_compile_actions(
    ir::Program& program,
    Machine& machine,
    Diagnostics& diagnostics) {
    if (program.compile_actions.empty()) return true;
    const auto constant_base = program.constants.size();
    machine.reset();

    const auto release_rejected_graph = [](const Value& root) {
        std::unordered_set<const void*> visited;
        const auto release = [&](const auto& self, const Value& value) -> void {
            if (const auto* array =
                    std::get_if<std::shared_ptr<ArrayValue>>(&value.storage())) {
                if (!*array || !visited.insert(array->get()).second) return;
                auto elements = std::move((*array)->elements);
                (*array)->elements.clear();
                for (const auto& element : elements) self(self, element);
            } else if (const auto* object =
                           std::get_if<std::shared_ptr<ObjectValue>>(&value.storage())) {
                if (!*object || !visited.insert(object->get()).second) return;
                auto fields = std::move((*object)->fields);
                (*object)->fields.clear();
                for (const auto& [symbol, field] : fields) {
                    static_cast<void>(symbol);
                    self(self, field);
                }
            }
        };
        release(release, root);
    };

    struct MaterializedValue {
        Value scalar;
        std::optional<ir::ConstantId> frozen;
    };
    class Freezer {
    public:
        Freezer(ir::Program& program, Diagnostics& diagnostics, SourceSpan span)
            : program_(program), diagnostics_(diagnostics), span_(span) {}

        std::optional<ir::ConstantId> freeze(const Value& value) {
            ir::Constant constant;
            if (value.is_null()) {
                constant.kind = ir::ConstantKind::Null;
            } else if (const auto* integer =
                           std::get_if<std::int64_t>(&value.storage())) {
                constant.kind = ir::ConstantKind::Integer;
                constant.integer = *integer;
            } else if (const auto* boolean = std::get_if<bool>(&value.storage())) {
                constant.kind = ir::ConstantKind::Boolean;
                constant.integer = *boolean ? 1 : 0;
            } else if (const auto* string =
                           std::get_if<std::string>(&value.storage())) {
                constant.kind = ir::ConstantKind::String;
                constant.text = *string;
            } else if (const auto* array =
                           std::get_if<std::shared_ptr<ArrayValue>>(&value.storage())) {
                return freeze_array(*array);
            } else if (const auto* object =
                           std::get_if<std::shared_ptr<ObjectValue>>(&value.storage())) {
                return freeze_object(*object);
            } else {
                diagnostics_.error(
                    span_,
                    "compile-time function, compiler handle, and void values cannot be frozen");
                return std::nullopt;
            }
            return append(std::move(constant));
        }

    private:
        std::optional<ir::ConstantId> freeze_array(
            const std::shared_ptr<ArrayValue>& array) {
            if (!array) return invalid_pointer();
            if (const auto found = completed_.find(array.get()); found != completed_.end()) {
                return found->second;
            }
            if (!active_.insert(array.get()).second) return cycle();
            ir::Constant constant;
            constant.kind = ir::ConstantKind::Array;
            for (const auto& element : array->elements) {
                const auto child = freeze(element);
                if (!child) {
                    active_.erase(array.get());
                    return std::nullopt;
                }
                constant.elements.push_back(*child);
            }
            active_.erase(array.get());
            const auto id = append(std::move(constant));
            completed_.emplace(array.get(), id);
            return id;
        }

        std::optional<ir::ConstantId> freeze_object(
            const std::shared_ptr<ObjectValue>& object) {
            if (!object) return invalid_pointer();
            if (const auto found = completed_.find(object.get()); found != completed_.end()) {
                return found->second;
            }
            if (!active_.insert(object.get()).second) return cycle();
            std::vector<std::pair<sema::SymbolId, const Value*>> fields;
            fields.reserve(object->fields.size());
            for (const auto& [symbol, field] : object->fields) {
                fields.emplace_back(symbol, &field);
            }
            std::sort(fields.begin(), fields.end(), [](const auto& left, const auto& right) {
                return left.first < right.first;
            });
            ir::Constant constant;
            constant.kind = ir::ConstantKind::Object;
            constant.symbol = object->type_symbol;
            for (const auto& [symbol, field] : fields) {
                const auto child = freeze(*field);
                if (!child) {
                    active_.erase(object.get());
                    return std::nullopt;
                }
                constant.fields.push_back({symbol, *child});
            }
            active_.erase(object.get());
            const auto id = append(std::move(constant));
            completed_.emplace(object.get(), id);
            return id;
        }

        ir::ConstantId append(ir::Constant constant) {
            const auto id = static_cast<ir::ConstantId>(program_.constants.size());
            program_.constants.push_back(std::move(constant));
            return id;
        }

        std::optional<ir::ConstantId> cycle() {
            diagnostics_.error(span_, "cyclic compile-time value cannot be frozen");
            return std::nullopt;
        }

        std::optional<ir::ConstantId> invalid_pointer() {
            diagnostics_.error(span_, "invalid compile-time compound value");
            return std::nullopt;
        }

        ir::Program& program_;
        Diagnostics& diagnostics_;
        SourceSpan span_;
        std::unordered_set<const void*> active_;
        std::unordered_map<const void*, ir::ConstantId> completed_;
    };

    std::vector<MaterializedValue> values;
    values.reserve(program.compile_actions.size());
    for (const auto& action : program.compile_actions) {
        auto value = machine.invoke(action.function);
        if (diagnostics.has_errors()) {
            program.constants.resize(constant_base);
            return false;
        }
        MaterializedValue materialized;
        if (std::holds_alternative<std::shared_ptr<ArrayValue>>(value.storage()) ||
            std::holds_alternative<std::shared_ptr<ObjectValue>>(value.storage())) {
            materialized.frozen = Freezer(program, diagnostics, action.span).freeze(value);
            if (!materialized.frozen) {
                release_rejected_graph(value);
                program.constants.resize(constant_base);
                return false;
            }
        } else {
            materialized.scalar = std::move(value);
        }
        values.push_back(std::move(materialized));
    }

    bool valid = true;
    for (auto& function : program.functions) {
        for (auto& block : function.blocks) {
            for (auto& instruction : block.instructions) {
                if (instruction.opcode != ir::Opcode::CompileValue) continue;
                if (instruction.index >= values.size()) {
                    diagnostics.error(
                        instruction.span,
                        "compile-time value references invalid action");
                    valid = false;
                    continue;
                }
                const auto& materialized = values[instruction.index];
                if (materialized.frozen) {
                    instruction.opcode = ir::Opcode::ConstantFrozen;
                    instruction.index = *materialized.frozen;
                    continue;
                }
                const auto& value = materialized.scalar;
                if (const auto* integer = std::get_if<std::int64_t>(&value.storage())) {
                    instruction.opcode = ir::Opcode::ConstantInt;
                    instruction.integer = *integer;
                } else if (const auto* boolean = std::get_if<bool>(&value.storage())) {
                    instruction.opcode = ir::Opcode::ConstantBool;
                    instruction.integer = *boolean ? 1 : 0;
                } else if (const auto* string = std::get_if<std::string>(&value.storage())) {
                    instruction.opcode = ir::Opcode::ConstantString;
                    instruction.text = *string;
                } else if (value.is_null()) {
                    instruction.opcode = ir::Opcode::ConstantNull;
                } else {
                    diagnostics.error(
                        instruction.span,
                        "compile-time value cannot yet be embedded in runtime IR");
                    valid = false;
                }
                instruction.index = 0;
            }
        }
    }
    if (valid) program.compile_actions.clear();
    return valid;
}

} // namespace abla::vm
