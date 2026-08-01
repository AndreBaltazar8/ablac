#pragma once

#include "abla/diagnostic.hpp"
#include "abla/ir.hpp"
#include "abla/types.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

namespace abla::vm {

struct VoidValue {
    bool operator==(const VoidValue&) const = default;
};

struct NullValue {
    bool operator==(const NullValue&) const = default;
};

struct FunctionValue {
    ir::FunctionId id{};
    bool operator==(const FunctionValue&) const = default;
};

struct HostValue {
    enum class Kind : std::uint32_t { ParserCursor, SyntaxExpression };

    Kind kind{};
    std::uint64_t handle{};
    bool operator==(const HostValue&) const = default;
};

struct ArrayValue;
struct ObjectValue;

class Value {
public:
    using Storage = std::variant<
        VoidValue,
        NullValue,
        std::int64_t,
        bool,
        std::string,
        FunctionValue,
        HostValue,
        std::shared_ptr<ArrayValue>,
        std::shared_ptr<ObjectValue>>;

    Value() : storage_(VoidValue{}) {}
    explicit Value(Storage storage) : storage_(std::move(storage)) {}

    [[nodiscard]] static Value void_value() { return Value(VoidValue{}); }
    [[nodiscard]] static Value null_value() { return Value(NullValue{}); }
    [[nodiscard]] static Value integer(std::int64_t value) { return Value(value); }
    [[nodiscard]] static Value boolean(bool value) { return Value(value); }
    [[nodiscard]] static Value string(std::string value) { return Value(std::move(value)); }
    [[nodiscard]] static Value function(ir::FunctionId id) { return Value(FunctionValue{id}); }
    [[nodiscard]] static Value host(HostValue::Kind kind, std::uint64_t handle) {
        return Value(HostValue{kind, handle});
    }

    [[nodiscard]] bool is_void() const { return std::holds_alternative<VoidValue>(storage_); }
    [[nodiscard]] bool is_null() const { return std::holds_alternative<NullValue>(storage_); }
    [[nodiscard]] std::int64_t as_integer() const { return std::get<std::int64_t>(storage_); }
    [[nodiscard]] bool as_boolean() const { return std::get<bool>(storage_); }
    [[nodiscard]] const std::string& as_string() const { return std::get<std::string>(storage_); }
    [[nodiscard]] FunctionValue as_function() const { return std::get<FunctionValue>(storage_); }
    [[nodiscard]] HostValue as_host() const { return std::get<HostValue>(storage_); }
    [[nodiscard]] std::shared_ptr<ArrayValue> as_array() const {
        return std::get<std::shared_ptr<ArrayValue>>(storage_);
    }
    [[nodiscard]] std::shared_ptr<ObjectValue> as_object() const {
        return std::get<std::shared_ptr<ObjectValue>>(storage_);
    }
    [[nodiscard]] const Storage& storage() const noexcept { return storage_; }

private:
    Storage storage_;
};

struct ArrayValue {
    std::vector<Value> elements;
};

struct ObjectValue {
    sema::SymbolId type_symbol{};
    std::unordered_map<sema::SymbolId, Value> fields;
};

using NativeFunction = std::function<Value(const std::vector<Value>&)>;

class NativeRegistry {
public:
    void add(std::string library, std::string name, NativeFunction function);
    [[nodiscard]] const NativeFunction* find(
        std::string_view library,
        std::string_view name) const;

private:
    [[nodiscard]] static std::string key(
        std::string_view library,
        std::string_view name);

    std::unordered_map<std::string, NativeFunction> functions_;
};

struct Limits {
    std::uint64_t max_instructions{1'000'000};
    std::uint32_t max_call_depth{1'024};
};

struct CompilerServices {
    std::function<bool(std::string, ir::FunctionId)> register_subparser;
};

class Machine {
public:
    Machine(
        const ir::Program& program,
        const sema::TypeStore& types,
        Diagnostics& diagnostics,
        const NativeRegistry* natives = nullptr,
        Limits limits = {},
        CompilerServices* compiler_services = nullptr)
        : program_(program),
          types_(types),
          diagnostics_(diagnostics),
          natives_(natives),
          limits_(limits),
          compiler_services_(compiler_services) {}

    [[nodiscard]] Value run(ir::FunctionId function, std::vector<Value> arguments = {});
    void reset();
    [[nodiscard]] Value invoke(ir::FunctionId function, std::vector<Value> arguments = {});
    [[nodiscard]] std::optional<ir::FunctionId> find_function(std::string_view name) const;
    [[nodiscard]] std::uint64_t instructions_executed() const noexcept {
        return instructions_executed_;
    }

private:
    enum class GlobalState { Uninitialized, Initializing, Ready };

    struct Frame {
        const ir::Function* function{};
        std::vector<Value> locals;
        std::unordered_map<ir::ValueId, Value> values;
    };

    Value execute(ir::FunctionId function, const std::vector<Value>& arguments);
    Value execute_external(const ir::Function& function, const std::vector<Value>& arguments);
    Value execute_compiler_intrinsic(
        const ir::Function& function,
        const std::vector<Value>& arguments);
    Value execute_instruction(Frame& frame, const ir::Instruction& instruction);
    Value operand(const Frame& frame, ir::ValueId value) const;
    Value thaw_constant(ir::ConstantId constant);
    Value thaw_constant(
        ir::ConstantId constant,
        std::unordered_map<ir::ConstantId, Value>& values);
    Value load_global(ir::GlobalId global);
    bool tick(SourceSpan span);
    void runtime_error(SourceSpan span, std::string message);
    [[nodiscard]] static bool equal(const Value& left, const Value& right);
    [[nodiscard]] static std::string to_string(const Value& value);

    const ir::Program& program_;
    const sema::TypeStore& types_;
    Diagnostics& diagnostics_;
    const NativeRegistry* natives_{};
    Limits limits_;
    CompilerServices* compiler_services_{};
    std::vector<Value> globals_;
    std::vector<GlobalState> global_states_;
    std::uint64_t instructions_executed_{};
    std::uint32_t call_depth_{};
};

[[nodiscard]] bool materialize_compile_actions(
    ir::Program& program,
    Machine& machine,
    Diagnostics& diagnostics);

} // namespace abla::vm
