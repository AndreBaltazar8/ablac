#pragma once

#include "abla/module.hpp"
#include "abla/sema.hpp"
#include "abla/types.hpp"

#include <cstdint>
#include <iosfwd>
#include <limits>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace abla::ir {

using ValueId = std::uint32_t;
using LocalId = std::uint32_t;
using BlockId = std::uint32_t;
using FunctionId = std::uint32_t;
using GlobalId = std::uint32_t;
using ConstantId = std::uint32_t;

inline constexpr auto no_value = std::numeric_limits<ValueId>::max();
inline constexpr auto no_function = std::numeric_limits<FunctionId>::max();
inline constexpr auto no_symbol = std::numeric_limits<sema::SymbolId>::max();

enum class Opcode {
    ConstantInt,
    ConstantBool,
    ConstantNull,
    ConstantString,
    ConstantFrozen,
    CompileValue,
    ToString,
    StringConcat,
    FunctionRef,
    LoadLocal,
    StoreLocal,
    LoadGlobal,
    StoreGlobal,
    Negate,
    LogicalNot,
    Add,
    Subtract,
    Multiply,
    Divide,
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    Call,
    CallIndirect,
    ArrayCreate,
    ArrayLength,
    ArrayAppend,
    ArrayGet,
    ArraySet,
    StringLength,
    StringGet,
    StringSlice,
    ObjectCreate,
    FieldGet,
    FieldSet,
};

struct Instruction {
    Opcode opcode{};
    sema::TypeId type{};
    ValueId result{no_value};
    std::vector<ValueId> operands;
    std::int64_t integer{};
    std::string text;
    std::uint32_t index{};
    sema::SymbolId symbol{};
    std::vector<sema::SymbolId> field_symbols;
    SourceSpan span;
};

enum class TerminatorKind { None, Return, Jump, Branch, Unreachable };

struct Terminator {
    TerminatorKind kind{TerminatorKind::None};
    ValueId value{no_value};
    BlockId first{};
    BlockId second{};
    SourceSpan span;
};

struct BasicBlock {
    BlockId id{};
    std::string name;
    std::vector<Instruction> instructions;
    Terminator terminator;
};

struct Local {
    LocalId id{};
    sema::TypeId type{};
    std::string name;
    const sema::Symbol* symbol{};
};

struct Function {
    FunctionId id{};
    std::string name;
    const sema::Symbol* symbol{};
    sema::SymbolId symbol_id{no_symbol};
    Module* module{};
    sema::TypeId type{};
    sema::TypeId result_type{};
    std::vector<LocalId> parameters;
    std::vector<Local> locals;
    std::vector<BasicBlock> blocks;
    bool external{};
    bool compile_only{};
    std::string native_library;
};

struct Global {
    GlobalId id{};
    std::string name;
    const sema::Symbol* symbol{};
    sema::TypeId type{};
    FunctionId initializer{no_function};
    bool mutable_value{};
};

struct CompileAction {
    std::uint32_t id{};
    FunctionId function{};
    sema::TypeId type{};
    SourceSpan span;
};

enum class ConstantKind { Null, Integer, Boolean, String, Array, Object };

struct ConstantField {
    sema::SymbolId symbol{};
    ConstantId value{};
};

struct Constant {
    ConstantKind kind{ConstantKind::Null};
    std::int64_t integer{};
    std::string text;
    std::vector<ConstantId> elements;
    sema::SymbolId symbol{};
    std::vector<ConstantField> fields;
};

struct Program {
    std::vector<Function> functions;
    std::vector<Global> globals;
    std::vector<CompileAction> compile_actions;
    std::vector<Constant> constants;
};

class Lowerer {
public:
    Lowerer(
        ModuleGraph& graph,
        sema::SemanticModel& semantics,
        sema::TypedProgram& types)
        : graph_(graph), semantics_(semantics), types_(types) {}

    [[nodiscard]] Program lower();

private:
    void collect_declarations();
    void collect_lambdas(ast::Statement& statement);
    void collect_lambdas(ast::Expression& expression);
    FunctionId add_function(
        std::string name,
        const sema::Symbol* symbol,
        Module* module,
        sema::TypeId type,
        sema::TypeId result);
    void lower_declared_function(Function& function, ast::FunctionDeclaration& declaration);
    void lower_lambda(Function& function, ast::LambdaExpression& lambda);
    void lower_global_initializers();
    void begin_function(Function& function);
    LocalId add_local(sema::TypeId type, std::string name, const sema::Symbol* symbol = nullptr);
    BlockId add_block(std::string name);
    void select_block(BlockId id);
    ValueId emit(Instruction instruction);
    void terminate(Terminator terminator);
    ValueId lower_block(ast::Block& block);
    void lower_statement(ast::Statement& statement);
    ValueId lower_expression(ast::Expression& expression);
    ValueId lower_identifier(ast::Expression& expression);
    ValueId lower_call(ast::CallExpression& call);
    ValueId lower_if(ast::IfExpression& conditional);
    ValueId lower_when(ast::WhenExpression& when);
    ValueId lower_lambda_ref(ast::LambdaExpression& lambda);
    ValueId load_symbol(const sema::Symbol& symbol, SourceSpan span);
    void store_target(ast::Expression& target, ValueId value, SourceSpan span);
    LocalId temporary(sema::TypeId type, std::string name);
    [[nodiscard]] LocalId local_for(const sema::Symbol& symbol);
    [[nodiscard]] std::optional<GlobalId> global_for(const sema::Symbol& symbol) const;
    [[nodiscard]] std::optional<FunctionId> function_for(const sema::Symbol& symbol) const;
    [[nodiscard]] static bool has_modifier(
        const ast::Modifiers& modifiers,
        ast::Modifier modifier);
    Diagnostics& diagnostics();

    ModuleGraph& graph_;
    sema::SemanticModel& semantics_;
    sema::TypedProgram& types_;
    Program program_;
    std::unordered_map<const sema::Symbol*, FunctionId> functions_;
    std::unordered_map<const ast::LambdaExpression*, FunctionId> lambdas_;
    std::unordered_map<const ast::UnaryExpression*, std::uint32_t> compile_actions_;
    std::unordered_map<const sema::Symbol*, GlobalId> globals_;
    std::unordered_map<FunctionId, ast::Expression*> global_initializers_;
    std::unordered_map<const sema::Symbol*, LocalId> locals_;
    Function* function_{};
    BasicBlock* block_{};
    ValueId next_value_{};
    Module* collect_module_{};
};

class Verifier {
public:
    Verifier(const sema::TypeStore& types, Diagnostics& diagnostics)
        : types_(types), diagnostics_(diagnostics) {}

    [[nodiscard]] bool verify(const Program& program);

private:
    bool verify_function(const Program& program, const Function& function);
    bool verify_instruction(
        const Program& program,
        const Function& function,
        const BasicBlock& block,
        const Instruction& instruction,
        const std::unordered_map<ValueId, sema::TypeId>& values);

    const sema::TypeStore& types_;
    Diagnostics& diagnostics_;
};

void print(std::ostream& output, const Program& program, const sema::TypeStore& types);

} // namespace abla::ir
