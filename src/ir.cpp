#include "abla/ir.hpp"

#include <algorithm>
#include <cassert>
#include <charconv>
#include <iomanip>
#include <ostream>
#include <sstream>
#include <utility>

namespace abla::ir {

namespace {

std::string_view opcode_name(Opcode opcode) {
    switch (opcode) {
    case Opcode::ConstantInt: return "const.int";
    case Opcode::ConstantBool: return "const.bool";
    case Opcode::ConstantNull: return "const.null";
    case Opcode::ConstantString: return "const.string";
    case Opcode::ConstantFrozen: return "const.frozen";
    case Opcode::CompileValue: return "compile.value";
    case Opcode::ToString: return "to_string";
    case Opcode::StringConcat: return "string.concat";
    case Opcode::FunctionRef: return "function.ref";
    case Opcode::LoadLocal: return "local.load";
    case Opcode::StoreLocal: return "local.store";
    case Opcode::LoadGlobal: return "global.load";
    case Opcode::StoreGlobal: return "global.store";
    case Opcode::Negate: return "neg";
    case Opcode::LogicalNot: return "not";
    case Opcode::Add: return "add";
    case Opcode::Subtract: return "sub";
    case Opcode::Multiply: return "mul";
    case Opcode::Divide: return "div";
    case Opcode::Equal: return "eq";
    case Opcode::NotEqual: return "ne";
    case Opcode::Less: return "lt";
    case Opcode::LessEqual: return "le";
    case Opcode::Greater: return "gt";
    case Opcode::GreaterEqual: return "ge";
    case Opcode::Call: return "call";
    case Opcode::CallIndirect: return "call.indirect";
    case Opcode::ArrayCreate: return "array.create";
    case Opcode::ArrayLength: return "array.length";
    case Opcode::ArrayAppend: return "array.append";
    case Opcode::ArrayGet: return "array.get";
    case Opcode::ArraySet: return "array.set";
    case Opcode::StringLength: return "string.length";
    case Opcode::StringGet: return "string.get";
    case Opcode::StringSlice: return "string.slice";
    case Opcode::ObjectCreate: return "object.create";
    case Opcode::FieldGet: return "field.get";
    case Opcode::FieldSet: return "field.set";
    }
    return "unknown";
}

bool produces_value(Opcode opcode) {
    switch (opcode) {
    case Opcode::StoreLocal:
    case Opcode::StoreGlobal:
    case Opcode::ArraySet:
    case Opcode::FieldSet:
        return false;
    default:
        return true;
    }
}

std::optional<Opcode> binary_opcode(TokenKind token) {
    switch (token) {
    case TokenKind::Plus: return Opcode::Add;
    case TokenKind::Minus: return Opcode::Subtract;
    case TokenKind::Star: return Opcode::Multiply;
    case TokenKind::Slash: return Opcode::Divide;
    case TokenKind::EqualEqual: return Opcode::Equal;
    case TokenKind::BangEqual: return Opcode::NotEqual;
    case TokenKind::Less: return Opcode::Less;
    case TokenKind::LessEqual: return Opcode::LessEqual;
    case TokenKind::Greater: return Opcode::Greater;
    case TokenKind::GreaterEqual: return Opcode::GreaterEqual;
    default: return std::nullopt;
    }
}

std::int64_t parse_integer(std::string text) {
    text.erase(std::remove(text.begin(), text.end(), '_'), text.end());
    std::int64_t value = 0;
    const auto hexadecimal = text.size() > 2 && text[0] == '0' &&
        (text[1] == 'x' || text[1] == 'X');
    const auto* begin = text.data() + (hexadecimal ? 2 : 0);
    const auto* end = text.data() + text.size();
    static_cast<void>(std::from_chars(begin, end, value, hexadecimal ? 16 : 10));
    return value;
}

bool is_static_import(const ast::UnaryExpression& expression) {
    if (!expression.operand ||
        expression.operand->kind != ast::Expression::Kind::Call) return false;
    const auto& call = static_cast<const ast::CallExpression&>(*expression.operand);
    if (!call.callee ||
        call.callee->kind != ast::Expression::Kind::Identifier) return false;
    return static_cast<const ast::ScalarExpression&>(*call.callee).value == "import";
}

} // namespace

Program Lowerer::lower() {
    program_ = Program{};
    functions_.clear();
    lambdas_.clear();
    globals_.clear();
    global_initializers_.clear();
    compile_actions_.clear();
    collect_declarations();

    for (std::size_t i = 0; i < program_.functions.size(); ++i) {
        auto& function = program_.functions[i];
        if (function.symbol != nullptr) {
            auto* declaration = const_cast<ast::FunctionDeclaration*>(
                dynamic_cast<const ast::FunctionDeclaration*>(function.symbol->declaration));
            if (declaration) lower_declared_function(function, *declaration);
            continue;
        }
        const auto lambda = std::find_if(
            lambdas_.begin(), lambdas_.end(),
            [&](const auto& entry) { return entry.second == function.id; });
        if (lambda != lambdas_.end()) {
            lower_lambda(function, *const_cast<ast::LambdaExpression*>(lambda->first));
            continue;
        }
        const auto initializer = global_initializers_.find(function.id);
        if (initializer != global_initializers_.end()) {
            begin_function(function);
            const auto value = lower_expression(*initializer->second);
            terminate(Terminator{
                TerminatorKind::Return, value, 0, 0, initializer->second->span});
        }
    }
    function_ = nullptr;
    block_ = nullptr;
    return std::move(program_);
}

void Lowerer::collect_declarations() {
    for (const auto& owned : semantics_.symbols()) {
        const auto* symbol = owned.get();
        if (symbol->kind == sema::SymbolKind::Function && symbol->declaration != nullptr) {
            const auto type = types_.symbol_type(*symbol);
            const auto& function_type = types_.types.get(type);
            add_function(
                symbol->name,
                symbol,
                symbol->module,
                type,
                function_type.kind == sema::TypeKind::Function
                    ? function_type.result
                    : types_.types.error());
        } else if (symbol->kind == sema::SymbolKind::Property &&
                   symbol->scope != nullptr && symbol->scope->is_module) {
            const auto id = static_cast<GlobalId>(program_.globals.size());
            globals_[symbol] = id;
            program_.globals.push_back(Global{
                id,
                symbol->name,
                symbol,
                types_.symbol_type(*symbol),
                no_function,
                symbol->mutable_value});
        }
    }

    for (const auto& module : graph_.modules()) {
        collect_module_ = module.get();
        if (!module->program) continue;
        for (auto& statement : module->program->declarations) {
            collect_lambdas(*statement);
        }
    }

    for (auto& global : program_.globals) {
        auto* property = const_cast<ast::PropertyDeclaration*>(
            dynamic_cast<const ast::PropertyDeclaration*>(global.symbol->declaration));
        if (!property || !property->initializer) continue;
        const auto function_type = types_.types.function({}, global.type);
        const auto id = add_function(
            "$init." + global.name,
            nullptr,
            global.symbol->module,
            function_type,
            global.type);
        global.initializer = id;
        global_initializers_[id] = property->initializer.get();
    }

    for (auto& function : program_.functions) {
        if (function.symbol == nullptr) continue;
        const auto* declaration = dynamic_cast<const ast::FunctionDeclaration*>(
            function.symbol->declaration);
        if (!declaration) continue;
        function.external = has_modifier(declaration->modifiers, ast::Modifier::Extern) ||
            (!declaration->body && !declaration->expression_body);
        function.compile_only = has_modifier(declaration->modifiers, ast::Modifier::Compile);
        const auto* library = dynamic_cast<const ast::StringExpression*>(
            declaration->modifiers.extern_library.get());
        if (library &&
            library->parts.size() == 1 &&
            library->parts.front()->kind ==
                ast::Expression::Kind::StringText) {
            function.native_library = static_cast<const ast::ScalarExpression&>(
                *library->parts.front()).value;
        }
    }
    collect_module_ = nullptr;
}

void Lowerer::collect_lambdas(ast::Statement& statement) {
    switch (statement.kind) {
    case ast::Statement::Kind::Expression: {
        auto& expression = static_cast<ast::ExpressionStatement&>(statement);
        if (expression.expression) collect_lambdas(*expression.expression);
        break;
    }
    case ast::Statement::Kind::Property: {
        auto& property = static_cast<ast::PropertyDeclaration&>(statement);
        if (property.initializer) collect_lambdas(*property.initializer);
        break;
    }
    case ast::Statement::Kind::Function: {
        auto& function = static_cast<ast::FunctionDeclaration&>(statement);
        for (auto& parameter : function.parameters) {
            if (parameter.default_value) collect_lambdas(*parameter.default_value);
        }
        if (function.expression_body) collect_lambdas(*function.expression_body);
        if (function.body) {
            for (auto& child : function.body->statements) collect_lambdas(*child);
        }
        break;
    }
    case ast::Statement::Kind::Class: {
        auto& declaration = static_cast<ast::ClassDeclaration&>(statement);
        if (declaration.body) {
            for (auto& child : declaration.body->statements) collect_lambdas(*child);
        }
        break;
    }
    case ast::Statement::Kind::While:
    case ast::Statement::Kind::DoWhile: {
        auto& loop = static_cast<ast::WhileStatement&>(statement);
        if (loop.condition) collect_lambdas(*loop.condition);
        if (loop.body) {
            for (auto& child : loop.body->statements) collect_lambdas(*child);
        }
        break;
    }
    }
}

void Lowerer::collect_lambdas(ast::Expression& expression) {
    using Kind = ast::Expression::Kind;
    if (expression.kind == Kind::Lambda) {
        auto& lambda = static_cast<ast::LambdaExpression&>(expression);
        const auto type = types_.expression_type(lambda);
        const auto& function_type = types_.types.get(type);
        const auto id = add_function(
            "$lambda." + std::to_string(lambdas_.size()),
            nullptr,
            collect_module_,
            type,
            function_type.kind == sema::TypeKind::Function
                ? function_type.result
                : types_.types.error());
        lambdas_[&lambda] = id;
        if (lambda.body) {
            for (auto& statement : lambda.body->statements) collect_lambdas(*statement);
        }
        return;
    }
    if (expression.kind == Kind::Unary || expression.kind == Kind::Compile) {
        auto& unary = static_cast<ast::UnaryExpression&>(expression);
        if (unary.operand) collect_lambdas(*unary.operand);
        if (expression.kind == Kind::Compile && !is_static_import(unary) &&
            !compile_actions_.contains(&unary)) {
            const auto type = types_.expression_type(unary);
            const auto function_type = types_.types.function({}, type);
            const auto function = add_function(
                "$compile." + std::to_string(compile_actions_.size()),
                nullptr,
                collect_module_,
                function_type,
                type);
            program_.functions[function].compile_only = true;
            const auto action = static_cast<std::uint32_t>(program_.compile_actions.size());
            compile_actions_[&unary] = action;
            program_.compile_actions.push_back(CompileAction{
                action, function, type, unary.span});
            global_initializers_[function] = unary.operand.get();
        }
    } else if (expression.kind == Kind::Binary || expression.kind == Kind::Assignment) {
        auto& binary = static_cast<ast::BinaryExpression&>(expression);
        collect_lambdas(*binary.left);
        collect_lambdas(*binary.right);
    } else if (expression.kind == Kind::Call) {
        auto& call = static_cast<ast::CallExpression&>(expression);
        collect_lambdas(*call.callee);
        for (auto& argument : call.arguments) collect_lambdas(*argument.value);
    } else if (expression.kind == Kind::Member) {
        collect_lambdas(*static_cast<ast::MemberExpression&>(expression).receiver);
    } else if (expression.kind == Kind::Index) {
        auto& index = static_cast<ast::IndexExpression&>(expression);
        collect_lambdas(*index.receiver);
        collect_lambdas(*index.index);
    } else if (expression.kind == Kind::Array) {
        for (auto& element : static_cast<ast::ArrayExpression&>(expression).elements) {
            collect_lambdas(*element);
        }
    } else if (expression.kind == Kind::String) {
        for (auto& part : static_cast<ast::StringExpression&>(expression).parts) {
            if (part->kind != Kind::StringText) collect_lambdas(*part);
        }
    } else if (expression.kind == Kind::If) {
        auto& conditional = static_cast<ast::IfExpression&>(expression);
        collect_lambdas(*conditional.condition);
        for (auto& statement : conditional.then_body->statements) collect_lambdas(*statement);
        if (conditional.else_body) {
            for (auto& statement : conditional.else_body->statements) collect_lambdas(*statement);
        }
    } else if (expression.kind == Kind::When) {
        auto& when = static_cast<ast::WhenExpression&>(expression);
        if (when.subject) collect_lambdas(*when.subject);
        for (auto& when_case : when.cases) {
            for (auto& match : when_case.matches) collect_lambdas(*match);
            for (auto& statement : when_case.body->statements) collect_lambdas(*statement);
        }
    }
}

FunctionId Lowerer::add_function(
    std::string name,
    const sema::Symbol* symbol,
    Module* module,
    sema::TypeId type,
    sema::TypeId result) {
    const auto id = static_cast<FunctionId>(program_.functions.size());
    program_.functions.push_back(Function{
        id,
        std::move(name),
        symbol,
        symbol == nullptr ? no_symbol : symbol->id,
        module,
        type,
        result,
        {},
        {},
        {},
        false,
        false,
        {}});
    if (symbol) functions_[symbol] = id;
    return id;
}

void Lowerer::lower_declared_function(
    Function& function,
    ast::FunctionDeclaration& declaration) {
    begin_function(function);
    const auto* scope = semantics_.scope_for(declaration);
    if (scope) {
        if (const auto* values = scope->local("this"); values && !values->empty()) {
            const auto* symbol = values->front();
            function.parameters.push_back(add_local(
                types_.symbol_type(*symbol), "this", symbol));
        }
        for (auto& parameter : declaration.parameters) {
            const auto* values = scope->local(parameter.name);
            if (values && !values->empty()) {
                const auto* symbol = values->front();
                function.parameters.push_back(add_local(
                    types_.symbol_type(*symbol), parameter.name, symbol));
            }
        }
    }
    if (function.external) {
        function.blocks.clear();
        block_ = nullptr;
        return;
    }
    ValueId result = no_value;
    if (declaration.body) result = lower_block(*declaration.body);
    if (declaration.expression_body) result = lower_expression(*declaration.expression_body);
    terminate(Terminator{
        TerminatorKind::Return,
        function.result_type == types_.types.void_type() ? no_value : result,
        0,
        0,
        declaration.span});
}

void Lowerer::lower_lambda(Function& function, ast::LambdaExpression& lambda) {
    begin_function(function);
    const auto* scope = semantics_.scope_for(lambda);
    if (scope) {
        for (auto& parameter : lambda.parameters) {
            const auto* values = scope->local(parameter.name);
            if (values && !values->empty()) {
                const auto* symbol = values->front();
                function.parameters.push_back(add_local(
                    types_.symbol_type(*symbol), parameter.name, symbol));
            }
        }
    }
    const auto result = lower_block(*lambda.body);
    terminate(Terminator{
        TerminatorKind::Return,
        function.result_type == types_.types.void_type() ? no_value : result,
        0,
        0,
        lambda.span});
}

void Lowerer::lower_global_initializers() {}

void Lowerer::begin_function(Function& function) {
    function_ = &function;
    function.locals.clear();
    function.parameters.clear();
    function.blocks.clear();
    locals_.clear();
    next_value_ = 0;
    add_block("entry");
    select_block(0);
}

LocalId Lowerer::add_local(
    sema::TypeId type,
    std::string name,
    const sema::Symbol* symbol) {
    const auto id = static_cast<LocalId>(function_->locals.size());
    function_->locals.push_back(Local{id, type, std::move(name), symbol});
    if (symbol) locals_[symbol] = id;
    return id;
}

BlockId Lowerer::add_block(std::string name) {
    const auto selected = block_ ? block_->id : std::numeric_limits<BlockId>::max();
    const auto id = static_cast<BlockId>(function_->blocks.size());
    function_->blocks.push_back(BasicBlock{id, std::move(name), {}, {}});
    if (selected != std::numeric_limits<BlockId>::max()) {
        block_ = &function_->blocks[selected];
    }
    return id;
}

void Lowerer::select_block(BlockId id) {
    block_ = &function_->blocks.at(id);
}

ValueId Lowerer::emit(Instruction instruction) {
    if (produces_value(instruction.opcode) &&
        instruction.type != types_.types.void_type()) {
        instruction.result = next_value_++;
    }
    const auto result = instruction.result;
    block_->instructions.push_back(std::move(instruction));
    return result;
}

void Lowerer::terminate(Terminator terminator) {
    if (block_->terminator.kind == TerminatorKind::None) {
        block_->terminator = terminator;
    }
}

ValueId Lowerer::lower_block(ast::Block& block) {
    ValueId result = no_value;
    for (auto& statement : block.statements) {
        if (statement->kind == ast::Statement::Kind::Expression) {
            auto& expression = static_cast<ast::ExpressionStatement&>(*statement);
            result = expression.expression
                ? lower_expression(*expression.expression)
                : no_value;
        } else {
            lower_statement(*statement);
            result = no_value;
        }
    }
    return result;
}

void Lowerer::lower_statement(ast::Statement& statement) {
    if (statement.kind == ast::Statement::Kind::Property) {
        auto& property = static_cast<ast::PropertyDeclaration&>(statement);
        const auto* symbol = semantics_.symbol_for(property);
        if (!symbol) return;
        const auto local = add_local(types_.symbol_type(*symbol), property.name, symbol);
        if (property.initializer) {
            const auto value = lower_expression(*property.initializer);
            Instruction store;
            store.opcode = Opcode::StoreLocal;
            store.type = types_.types.void_type();
            store.operands = {value};
            store.index = local;
            store.span = property.span;
            emit(std::move(store));
        }
        return;
    }
    if (statement.kind == ast::Statement::Kind::While ||
        statement.kind == ast::Statement::Kind::DoWhile) {
        auto& loop = static_cast<ast::WhileStatement&>(statement);
        const auto condition = add_block("loop.condition");
        const auto body = add_block("loop.body");
        const auto after = add_block("loop.after");
        terminate(Terminator{
            TerminatorKind::Jump,
            no_value,
            statement.kind == ast::Statement::Kind::DoWhile ? body : condition,
            0,
            statement.span});
        select_block(condition);
        const auto condition_value = lower_expression(*loop.condition);
        terminate(Terminator{
            TerminatorKind::Branch,
            condition_value,
            body,
            after,
            loop.condition->span});
        select_block(body);
        lower_block(*loop.body);
        terminate(Terminator{
            TerminatorKind::Jump, no_value, condition, 0, loop.body->span});
        select_block(after);
        return;
    }
    if (statement.kind == ast::Statement::Kind::Expression) {
        auto& expression = static_cast<ast::ExpressionStatement&>(statement);
        if (expression.expression) lower_expression(*expression.expression);
    }
}

ValueId Lowerer::lower_expression(ast::Expression& expression) {
    using Kind = ast::Expression::Kind;
    const auto type = types_.expression_type(expression);
    Instruction instruction;
    instruction.type = type;
    instruction.span = expression.span;
    switch (expression.kind) {
    case Kind::Identifier:
        return lower_identifier(expression);
    case Kind::Integer:
        instruction.opcode = Opcode::ConstantInt;
        instruction.integer = parse_integer(
            static_cast<ast::ScalarExpression&>(expression).value);
        return emit(std::move(instruction));
    case Kind::Boolean:
        instruction.opcode = Opcode::ConstantBool;
        instruction.integer =
            static_cast<ast::ScalarExpression&>(expression).value == "true" ? 1 : 0;
        return emit(std::move(instruction));
    case Kind::Null:
        instruction.opcode = Opcode::ConstantNull;
        return emit(std::move(instruction));
    case Kind::StringText:
        instruction.opcode = Opcode::ConstantString;
        instruction.text = static_cast<ast::ScalarExpression&>(expression).value;
        return emit(std::move(instruction));
    case Kind::String: {
        auto& string = static_cast<ast::StringExpression&>(expression);
        if (string.parts.empty()) {
            instruction.opcode = Opcode::ConstantString;
            return emit(std::move(instruction));
        }
        ValueId result = no_value;
        for (auto& part : string.parts) {
            auto value = lower_expression(*part);
            if (part->kind != Kind::StringText) {
                Instruction convert;
                convert.opcode = Opcode::ToString;
                convert.type = types_.types.string_type();
                convert.operands = {value};
                convert.span = part->span;
                value = emit(std::move(convert));
            }
            if (result == no_value) {
                result = value;
            } else {
                Instruction concatenate;
                concatenate.opcode = Opcode::StringConcat;
                concatenate.type = types_.types.string_type();
                concatenate.operands = {result, value};
                concatenate.span = expression.span;
                result = emit(std::move(concatenate));
            }
        }
        return result;
    }
    case Kind::Array: {
        instruction.opcode = Opcode::ArrayCreate;
        for (auto& element : static_cast<ast::ArrayExpression&>(expression).elements) {
            instruction.operands.push_back(lower_expression(*element));
        }
        return emit(std::move(instruction));
    }
    case Kind::Unary:
    case Kind::Compile: {
        auto& unary = static_cast<ast::UnaryExpression&>(expression);
        if (expression.kind == Kind::Compile) {
            const auto found = compile_actions_.find(&unary);
            if (found == compile_actions_.end()) {
                diagnostics().error(expression.span, "compile action was not collected");
                return no_value;
            }
            instruction.opcode = Opcode::CompileValue;
            instruction.index = found->second;
            return emit(std::move(instruction));
        }
        const auto operand = lower_expression(*unary.operand);
        if (unary.operation == TokenKind::Plus) return operand;
        instruction.opcode = unary.operation == TokenKind::Bang
            ? Opcode::LogicalNot
            : Opcode::Negate;
        instruction.operands = {operand};
        return emit(std::move(instruction));
    }
    case Kind::Assignment: {
        auto& assignment = static_cast<ast::BinaryExpression&>(expression);
        if (assignment.left->kind == Kind::Member) {
            auto& member = static_cast<ast::MemberExpression&>(*assignment.left);
            const auto receiver = lower_expression(*member.receiver);
            const auto value = lower_expression(*assignment.right);
            const auto& candidates = semantics_.candidates(member);
            if (candidates.size() == 1) {
                Instruction set;
                set.opcode = Opcode::FieldSet;
                set.type = types_.types.void_type();
                set.operands = {receiver, value};
                set.symbol = candidates.front()->id;
                set.span = expression.span;
                emit(std::move(set));
            }
            return value;
        }
        if (assignment.left->kind == Kind::Index) {
            auto& index = static_cast<ast::IndexExpression&>(*assignment.left);
            const auto receiver = lower_expression(*index.receiver);
            const auto subscript = lower_expression(*index.index);
            const auto value = lower_expression(*assignment.right);
            Instruction set;
            set.opcode = Opcode::ArraySet;
            set.type = types_.types.void_type();
            set.operands = {receiver, subscript, value};
            set.span = expression.span;
            emit(std::move(set));
            return value;
        }
        const auto value = lower_expression(*assignment.right);
        store_target(*assignment.left, value, expression.span);
        return value;
    }
    case Kind::Binary: {
        auto& binary = static_cast<ast::BinaryExpression&>(expression);
        if (binary.operation == TokenKind::AmpAmp || binary.operation == TokenKind::PipePipe) {
            // Preserve short-circuiting with the same control-flow shape as an if.
            const auto result_local = temporary(types_.types.bool_type(), "$logical");
            const auto left = lower_expression(*binary.left);
            Instruction store_left;
            store_left.opcode = Opcode::StoreLocal;
            store_left.type = types_.types.void_type();
            store_left.operands = {left};
            store_left.index = result_local;
            store_left.span = binary.left->span;
            emit(std::move(store_left));
            const auto evaluate_right = add_block("logical.right");
            const auto merge = add_block("logical.merge");
            terminate(Terminator{
                TerminatorKind::Branch,
                left,
                binary.operation == TokenKind::AmpAmp ? evaluate_right : merge,
                binary.operation == TokenKind::AmpAmp ? merge : evaluate_right,
                binary.left->span});
            select_block(evaluate_right);
            const auto right = lower_expression(*binary.right);
            Instruction store_right;
            store_right.opcode = Opcode::StoreLocal;
            store_right.type = types_.types.void_type();
            store_right.operands = {right};
            store_right.index = result_local;
            store_right.span = binary.right->span;
            emit(std::move(store_right));
            terminate(Terminator{
                TerminatorKind::Jump, no_value, merge, 0, binary.right->span});
            select_block(merge);
            Instruction load;
            load.opcode = Opcode::LoadLocal;
            load.type = types_.types.bool_type();
            load.index = result_local;
            load.span = expression.span;
            return emit(std::move(load));
        }
        const auto opcode = binary_opcode(binary.operation);
        if (!opcode) return no_value;
        instruction.opcode = *opcode;
        instruction.operands = {
            lower_expression(*binary.left),
            lower_expression(*binary.right)};
        return emit(std::move(instruction));
    }
    case Kind::Call:
        return lower_call(static_cast<ast::CallExpression&>(expression));
    case Kind::Member: {
        auto& member = static_cast<ast::MemberExpression&>(expression);
        const auto& receiver_type = types_.types.get(
            types_.expression_type(*member.receiver));
        if (member.member == "size" &&
            (receiver_type.kind == sema::TypeKind::Array ||
             receiver_type.kind == sema::TypeKind::String)) {
            instruction.opcode = receiver_type.kind == sema::TypeKind::Array
                ? Opcode::ArrayLength
                : Opcode::StringLength;
            instruction.operands = {lower_expression(*member.receiver)};
            return emit(std::move(instruction));
        }
        const auto& candidates = semantics_.candidates(member);
        if (candidates.size() != 1 ||
            candidates.front()->kind == sema::SymbolKind::Function) {
            diagnostics().error(member.span, "bound method values require closure lowering");
            return no_value;
        }
        instruction.opcode = Opcode::FieldGet;
        instruction.operands = {lower_expression(*member.receiver)};
        instruction.symbol = candidates.front()->id;
        return emit(std::move(instruction));
    }
    case Kind::Index: {
        auto& index = static_cast<ast::IndexExpression&>(expression);
        const auto& receiver_type = types_.types.get(
            types_.expression_type(*index.receiver));
        instruction.opcode = receiver_type.kind == sema::TypeKind::String
            ? Opcode::StringGet
            : Opcode::ArrayGet;
        instruction.operands = {
            lower_expression(*index.receiver),
            lower_expression(*index.index)};
        return emit(std::move(instruction));
    }
    case Kind::If:
        return lower_if(static_cast<ast::IfExpression&>(expression));
    case Kind::When:
        return lower_when(static_cast<ast::WhenExpression&>(expression));
    case Kind::Lambda:
        return lower_lambda_ref(static_cast<ast::LambdaExpression&>(expression));
    }
    return no_value;
}

ValueId Lowerer::lower_identifier(ast::Expression& expression) {
    const auto& candidates = semantics_.candidates(expression);
    if (candidates.size() != 1) return no_value;
    return load_symbol(*candidates.front(), expression.span);
}

ValueId Lowerer::lower_call(ast::CallExpression& call) {
    if (call.callee->kind == ast::Expression::Kind::Member) {
        auto& member = static_cast<ast::MemberExpression&>(*call.callee);
        const auto& receiver_type = types_.types.get(
            types_.expression_type(*member.receiver));
        if (receiver_type.kind == sema::TypeKind::Array &&
            member.member == "append") {
            Instruction append;
            append.opcode = Opcode::ArrayAppend;
            append.type = types_.expression_type(call);
            append.span = call.span;
            append.operands.push_back(lower_expression(*member.receiver));
            for (auto& argument : call.arguments) {
                append.operands.push_back(lower_expression(*argument.value));
            }
            return emit(std::move(append));
        }
        if (receiver_type.kind == sema::TypeKind::String &&
            member.member == "slice") {
            Instruction slice;
            slice.opcode = Opcode::StringSlice;
            slice.type = types_.expression_type(call);
            slice.span = call.span;
            slice.operands.push_back(lower_expression(*member.receiver));
            for (auto& argument : call.arguments) {
                slice.operands.push_back(lower_expression(*argument.value));
            }
            return emit(std::move(slice));
        }
    }
    const auto* selected = types_.selected_call(call);
    if (selected != nullptr && selected->kind == sema::SymbolKind::Type) {
        Instruction create;
        create.opcode = Opcode::ObjectCreate;
        create.type = types_.expression_type(call);
        create.symbol = selected->id;
        create.span = call.span;
        const auto* declaration = dynamic_cast<const ast::ClassDeclaration*>(
            selected->declaration);
        const auto* scope = declaration ? semantics_.scope_for(*declaration) : nullptr;
        if (declaration && scope) {
            for (std::size_t i = 0; i < declaration->constructor_parameters.size(); ++i) {
                const auto& parameter = declaration->constructor_parameters[i];
                if (i < call.arguments.size()) {
                    create.operands.push_back(lower_expression(*call.arguments[i].value));
                } else if (parameter.default_value) {
                    create.operands.push_back(lower_expression(*parameter.default_value));
                }
                if (!parameter.property_mutability.has_value()) {
                    create.field_symbols.push_back(
                        std::numeric_limits<sema::SymbolId>::max());
                    continue;
                }
                const auto* fields = scope->local(parameter.name);
                create.field_symbols.push_back(
                    fields && !fields->empty()
                        ? fields->front()->id
                        : std::numeric_limits<sema::SymbolId>::max());
            }
        } else {
            for (auto& argument : call.arguments) {
                create.operands.push_back(lower_expression(*argument.value));
            }
        }
        return emit(std::move(create));
    }
    if (selected != nullptr) {
        const auto target = function_for(*selected);
        if (!target) {
            diagnostics().error(call.span, "selected function has no IR declaration");
            return no_value;
        }
        if (program_.functions[*target].compile_only && !function_->compile_only) {
            diagnostics().error(
                call.span,
                "compile-only function cannot be called from runtime code");
        }
        Instruction invoke;
        invoke.opcode = Opcode::Call;
        invoke.type = types_.expression_type(call);
        invoke.index = *target;
        invoke.span = call.span;
        if (call.callee->kind == ast::Expression::Kind::Member) {
            invoke.operands.push_back(lower_expression(
                *static_cast<ast::MemberExpression&>(*call.callee).receiver));
        }
        for (auto& argument : call.arguments) {
            invoke.operands.push_back(lower_expression(*argument.value));
        }
        if (const auto* declaration = dynamic_cast<const ast::FunctionDeclaration*>(
                selected->declaration)) {
            for (std::size_t i = call.arguments.size();
                 i < declaration->parameters.size(); ++i) {
                if (declaration->parameters[i].default_value) {
                    invoke.operands.push_back(lower_expression(
                        *declaration->parameters[i].default_value));
                }
            }
        }
        return emit(std::move(invoke));
    }
    Instruction invoke;
    invoke.opcode = Opcode::CallIndirect;
    invoke.type = types_.expression_type(call);
    invoke.span = call.span;
    invoke.operands.push_back(lower_expression(*call.callee));
    for (auto& argument : call.arguments) {
        invoke.operands.push_back(lower_expression(*argument.value));
    }
    return emit(std::move(invoke));
}

ValueId Lowerer::lower_if(ast::IfExpression& conditional) {
    const auto type = types_.expression_type(conditional);
    const auto has_value = type != types_.types.void_type();
    const auto result_local = has_value ? temporary(type, "$if") : 0;
    const auto condition = lower_expression(*conditional.condition);
    const auto then_block = add_block("if.then");
    const auto else_block = add_block("if.else");
    const auto merge = add_block("if.merge");
    terminate(Terminator{
        TerminatorKind::Branch, condition, then_block, else_block, conditional.span});

    select_block(then_block);
    const auto then_value = lower_block(*conditional.then_body);
    if (has_value) {
        Instruction store;
        store.opcode = Opcode::StoreLocal;
        store.type = types_.types.void_type();
        store.operands = {then_value};
        store.index = result_local;
        store.span = conditional.then_body->span;
        emit(std::move(store));
    }
    terminate(Terminator{
        TerminatorKind::Jump, no_value, merge, 0, conditional.then_body->span});

    select_block(else_block);
    if (conditional.else_body) {
        const auto else_value = lower_block(*conditional.else_body);
        if (has_value) {
            Instruction store;
            store.opcode = Opcode::StoreLocal;
            store.type = types_.types.void_type();
            store.operands = {else_value};
            store.index = result_local;
            store.span = conditional.else_body->span;
            emit(std::move(store));
        }
    }
    terminate(Terminator{
        TerminatorKind::Jump, no_value, merge, 0, conditional.span});

    select_block(merge);
    if (!has_value) return no_value;
    Instruction load;
    load.opcode = Opcode::LoadLocal;
    load.type = type;
    load.index = result_local;
    load.span = conditional.span;
    return emit(std::move(load));
}

ValueId Lowerer::lower_when(ast::WhenExpression& when) {
    const auto type = types_.expression_type(when);
    const auto has_value = type != types_.types.void_type();
    const auto result_local = has_value ? temporary(type, "$when") : 0;
    std::optional<LocalId> subject_local;
    if (when.subject) {
        const auto subject = lower_expression(*when.subject);
        subject_local = temporary(types_.expression_type(*when.subject), "$when.subject");
        Instruction store;
        store.opcode = Opcode::StoreLocal;
        store.type = types_.types.void_type();
        store.operands = {subject};
        store.index = *subject_local;
        store.span = when.subject->span;
        emit(std::move(store));
    }
    const auto merge = add_block("when.merge");
    for (std::size_t case_index = 0; case_index < when.cases.size(); ++case_index) {
        auto& when_case = when.cases[case_index];
        const auto body = add_block("when.case." + std::to_string(case_index));
        if (when_case.is_else) {
            terminate(Terminator{
                TerminatorKind::Jump, no_value, body, 0, when_case.span});
        } else {
            for (std::size_t match_index = 0; match_index < when_case.matches.size(); ++match_index) {
                ValueId condition = no_value;
                if (subject_local) {
                    Instruction load;
                    load.opcode = Opcode::LoadLocal;
                    load.type = function_->locals[*subject_local].type;
                    load.index = *subject_local;
                    load.span = when_case.matches[match_index]->span;
                    const auto subject = emit(std::move(load));
                    Instruction equal;
                    equal.opcode = Opcode::Equal;
                    equal.type = types_.types.bool_type();
                    equal.operands = {
                        subject,
                        lower_expression(*when_case.matches[match_index])};
                    equal.span = when_case.matches[match_index]->span;
                    condition = emit(std::move(equal));
                } else {
                    condition = lower_expression(*when_case.matches[match_index]);
                }
                const auto next = add_block(
                    "when.test." + std::to_string(case_index) + '.' +
                    std::to_string(match_index));
                terminate(Terminator{
                    TerminatorKind::Branch, condition, body, next, when_case.span});
                select_block(next);
            }
        }
        const auto next_case_block = block_->id;
        select_block(body);
        const auto value = lower_block(*when_case.body);
        if (has_value) {
            Instruction store;
            store.opcode = Opcode::StoreLocal;
            store.type = types_.types.void_type();
            store.operands = {value};
            store.index = result_local;
            store.span = when_case.body->span;
            emit(std::move(store));
        }
        terminate(Terminator{
            TerminatorKind::Jump, no_value, merge, 0, when_case.body->span});
        select_block(next_case_block);
    }
    terminate(Terminator{
        TerminatorKind::Jump, no_value, merge, 0, when.span});
    select_block(merge);
    if (!has_value) return no_value;
    Instruction load;
    load.opcode = Opcode::LoadLocal;
    load.type = type;
    load.index = result_local;
    load.span = when.span;
    return emit(std::move(load));
}

ValueId Lowerer::lower_lambda_ref(ast::LambdaExpression& lambda) {
    const auto found = lambdas_.find(&lambda);
    if (found == lambdas_.end()) return no_value;
    Instruction reference;
    reference.opcode = Opcode::FunctionRef;
    reference.type = types_.expression_type(lambda);
    reference.index = found->second;
    reference.span = lambda.span;
    return emit(std::move(reference));
}

ValueId Lowerer::load_symbol(const sema::Symbol& symbol, SourceSpan span) {
    if (const auto local = locals_.find(&symbol); local != locals_.end()) {
        Instruction load;
        load.opcode = Opcode::LoadLocal;
        load.type = types_.symbol_type(symbol);
        load.index = local->second;
        load.span = span;
        return emit(std::move(load));
    }
    if (const auto global = global_for(symbol)) {
        Instruction load;
        load.opcode = Opcode::LoadGlobal;
        load.type = types_.symbol_type(symbol);
        load.index = *global;
        load.span = span;
        return emit(std::move(load));
    }
    if (const auto function = function_for(symbol)) {
        Instruction reference;
        reference.opcode = Opcode::FunctionRef;
        reference.type = types_.symbol_type(symbol);
        reference.index = *function;
        reference.span = span;
        return emit(std::move(reference));
    }
    if (symbol.kind == sema::SymbolKind::Property) {
        const auto this_local = std::find_if(
            function_->locals.begin(), function_->locals.end(),
            [](const auto& local) { return local.name == "this"; });
        if (this_local != function_->locals.end()) {
            Instruction load_this;
            load_this.opcode = Opcode::LoadLocal;
            load_this.type = this_local->type;
            load_this.index = this_local->id;
            load_this.span = span;
            const auto receiver = emit(std::move(load_this));
            Instruction field;
            field.opcode = Opcode::FieldGet;
            field.type = types_.symbol_type(symbol);
            field.operands = {receiver};
            field.symbol = symbol.id;
            field.span = span;
            return emit(std::move(field));
        }
    }
    diagnostics().error(
        span,
        "captured or unavailable value '" + symbol.name +
            "' cannot yet be represented in IR");
    return no_value;
}

void Lowerer::store_target(
    ast::Expression& target,
    ValueId value,
    SourceSpan span) {
    if (target.kind != ast::Expression::Kind::Identifier) return;
    const auto& candidates = semantics_.candidates(target);
    if (candidates.size() != 1) return;
    const auto& symbol = *candidates.front();
    if (const auto local = locals_.find(&symbol); local != locals_.end()) {
        Instruction store;
        store.opcode = Opcode::StoreLocal;
        store.type = types_.types.void_type();
        store.operands = {value};
        store.index = local->second;
        store.span = span;
        emit(std::move(store));
        return;
    }
    if (const auto global = global_for(symbol)) {
        Instruction store;
        store.opcode = Opcode::StoreGlobal;
        store.type = types_.types.void_type();
        store.operands = {value};
        store.index = *global;
        store.span = span;
        emit(std::move(store));
        return;
    }
    if (symbol.kind == sema::SymbolKind::Property) {
        const auto this_local = std::find_if(
            function_->locals.begin(), function_->locals.end(),
            [](const auto& local) { return local.name == "this"; });
        if (this_local != function_->locals.end()) {
            Instruction load;
            load.opcode = Opcode::LoadLocal;
            load.type = this_local->type;
            load.index = this_local->id;
            load.span = span;
            const auto receiver = emit(std::move(load));
            Instruction store;
            store.opcode = Opcode::FieldSet;
            store.type = types_.types.void_type();
            store.operands = {receiver, value};
            store.symbol = symbol.id;
            store.span = span;
            emit(std::move(store));
        }
    }
}

LocalId Lowerer::temporary(sema::TypeId type, std::string name) {
    return add_local(type, std::move(name));
}

LocalId Lowerer::local_for(const sema::Symbol& symbol) {
    const auto found = locals_.find(&symbol);
    return found == locals_.end()
        ? std::numeric_limits<LocalId>::max()
        : found->second;
}

std::optional<GlobalId> Lowerer::global_for(const sema::Symbol& symbol) const {
    const auto found = globals_.find(&symbol);
    return found == globals_.end() ? std::nullopt : std::optional(found->second);
}

std::optional<FunctionId> Lowerer::function_for(const sema::Symbol& symbol) const {
    const auto found = functions_.find(&symbol);
    return found == functions_.end() ? std::nullopt : std::optional(found->second);
}

bool Lowerer::has_modifier(
    const ast::Modifiers& modifiers,
    ast::Modifier modifier) {
    return std::find(modifiers.values.begin(), modifiers.values.end(), modifier) !=
        modifiers.values.end();
}

Diagnostics& Lowerer::diagnostics() {
    assert(function_ != nullptr && function_->module != nullptr);
    return function_->module->diagnostics;
}

bool Verifier::verify(const Program& program) {
    bool valid = true;
    std::unordered_set<sema::SymbolId> function_symbols;
    for (const auto& function : program.functions) {
        if (function.symbol_id != no_symbol &&
            !function_symbols.insert(function.symbol_id).second) {
            diagnostics_.error({}, "IR function reflection handle is not unique");
            valid = false;
        }
    }
    for (std::size_t i = 0; i < program.constants.size(); ++i) {
        const auto& constant = program.constants[i];
        const auto valid_child = [&](ConstantId child) {
            if (child < i) return true;
            diagnostics_.error(
                {},
                "IR frozen constant must reference an earlier constant");
            return false;
        };
        if (constant.kind == ConstantKind::Array) {
            for (const auto child : constant.elements) {
                valid = valid_child(child) && valid;
            }
        } else if (constant.kind == ConstantKind::Object) {
            sema::SymbolId previous{};
            bool first = true;
            for (const auto& field : constant.fields) {
                valid = valid_child(field.value) && valid;
                if (!first && field.symbol <= previous) {
                    diagnostics_.error(
                        {},
                        "IR frozen object fields are not strictly ordered");
                    valid = false;
                }
                previous = field.symbol;
                first = false;
            }
        }
    }
    for (const auto& function : program.functions) {
        valid = verify_function(program, function) && valid;
    }
    for (const auto& global : program.globals) {
        if (global.initializer != no_function &&
            global.initializer >= program.functions.size()) {
            diagnostics_.error({}, "IR global initializer references invalid function");
            valid = false;
        }
    }
    return valid;
}

bool Verifier::verify_function(const Program& program, const Function& function) {
    bool valid = true;
    if (function.external) {
        if (!function.blocks.empty()) {
            diagnostics_.error({}, "external IR function must not have blocks");
            return false;
        }
        return true;
    }
    if (function.blocks.empty()) {
        diagnostics_.error({}, "IR function has no entry block");
        return false;
    }
    for (std::size_t i = 0; i < function.locals.size(); ++i) {
        if (function.locals[i].id != i) {
            diagnostics_.error({}, "IR local IDs are not contiguous");
            valid = false;
        }
    }
    for (const auto parameter : function.parameters) {
        if (parameter >= function.locals.size()) {
            diagnostics_.error({}, "IR parameter references invalid local");
            valid = false;
        }
    }

    std::unordered_map<ValueId, sema::TypeId> all_values;
    for (std::size_t block_index = 0; block_index < function.blocks.size(); ++block_index) {
        const auto& block = function.blocks[block_index];
        if (block.id != block_index) {
            diagnostics_.error({}, "IR block IDs are not contiguous");
            valid = false;
        }
        std::unordered_map<ValueId, sema::TypeId> visible;
        for (const auto& instruction : block.instructions) {
            for (const auto operand : instruction.operands) {
                if (!visible.contains(operand)) {
                    diagnostics_.error(
                        instruction.span,
                        "IR operand " + std::to_string(operand) +
                            " is not defined earlier in block " +
                            std::to_string(block.id) + " of function '" +
                            function.name + "'");
                    valid = false;
                }
            }
            valid = verify_instruction(
                program, function, block, instruction, visible) && valid;
            if (instruction.result != no_value) {
                if (all_values.contains(instruction.result)) {
                    diagnostics_.error(instruction.span, "IR value is defined more than once");
                    valid = false;
                }
                all_values[instruction.result] = instruction.type;
                visible[instruction.result] = instruction.type;
            }
        }
        const auto& terminator = block.terminator;
        if (terminator.kind == TerminatorKind::None) {
            diagnostics_.error({}, "IR basic block has no terminator");
            valid = false;
        } else if (terminator.kind == TerminatorKind::Return) {
            if (function.result_type == types_.void_type()) {
                if (terminator.value != no_value) {
                    diagnostics_.error(terminator.span, "void IR function returns a value");
                    valid = false;
                }
            } else if (!visible.contains(terminator.value) ||
                       !types_.can_assign(
                           function.result_type, visible[terminator.value])) {
                diagnostics_.error(terminator.span, "IR return value has invalid type");
                valid = false;
            }
        } else if (terminator.kind == TerminatorKind::Jump) {
            if (terminator.first >= function.blocks.size()) {
                diagnostics_.error(terminator.span, "IR jump has invalid target");
                valid = false;
            }
        } else if (terminator.kind == TerminatorKind::Branch) {
            if (!visible.contains(terminator.value) ||
                visible[terminator.value] != types_.bool_type()) {
                diagnostics_.error(terminator.span, "IR branch condition is not bool");
                valid = false;
            }
            if (terminator.first >= function.blocks.size() ||
                terminator.second >= function.blocks.size()) {
                diagnostics_.error(terminator.span, "IR branch has invalid target");
                valid = false;
            }
        }
    }
    return valid;
}

bool Verifier::verify_instruction(
    const Program& program,
    const Function& function,
    const BasicBlock&,
    const Instruction& instruction,
    const std::unordered_map<ValueId, sema::TypeId>& values) {
    const auto arity = instruction.operands.size();
    const auto require_arity = [&](std::size_t expected) {
        if (arity == expected) return true;
        diagnostics_.error(instruction.span, "IR instruction has invalid operand count");
        return false;
    };
    switch (instruction.opcode) {
    case Opcode::ConstantInt:
    case Opcode::ConstantBool:
    case Opcode::ConstantNull:
    case Opcode::ConstantString:
    case Opcode::ConstantFrozen:
    case Opcode::CompileValue:
    case Opcode::FunctionRef:
    case Opcode::LoadLocal:
    case Opcode::LoadGlobal:
        if (!require_arity(0)) return false;
        break;
    case Opcode::ToString:
    case Opcode::Negate:
    case Opcode::LogicalNot:
    case Opcode::ArrayLength:
    case Opcode::StringLength:
    case Opcode::StoreLocal:
    case Opcode::StoreGlobal:
    case Opcode::FieldGet:
        if (!require_arity(1)) return false;
        break;
    case Opcode::StringConcat:
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
    case Opcode::ArrayAppend:
    case Opcode::ArrayGet:
    case Opcode::StringGet:
    case Opcode::FieldSet:
        if (!require_arity(2)) return false;
        break;
    case Opcode::ArraySet:
    case Opcode::StringSlice:
        if (!require_arity(3)) return false;
        break;
    case Opcode::Call:
    case Opcode::CallIndirect:
    case Opcode::ArrayCreate:
    case Opcode::ObjectCreate:
        break;
    }
    if ((instruction.opcode == Opcode::LoadLocal ||
         instruction.opcode == Opcode::StoreLocal) &&
        instruction.index >= function.locals.size()) {
        diagnostics_.error(instruction.span, "IR instruction references invalid local");
        return false;
    }
    if ((instruction.opcode == Opcode::LoadGlobal ||
         instruction.opcode == Opcode::StoreGlobal) &&
        instruction.index >= program.globals.size()) {
        diagnostics_.error(instruction.span, "IR instruction references invalid global");
        return false;
    }
    if (instruction.opcode == Opcode::FunctionRef &&
        instruction.index >= program.functions.size()) {
        diagnostics_.error(instruction.span, "IR function reference is invalid");
        return false;
    }
    if (instruction.opcode == Opcode::ConstantFrozen &&
        instruction.index >= program.constants.size()) {
        diagnostics_.error(instruction.span, "IR frozen constant reference is invalid");
        return false;
    }
    if (instruction.opcode == Opcode::Call) {
        if (instruction.index >= program.functions.size()) {
            diagnostics_.error(instruction.span, "IR call target is invalid");
            return false;
        }
        const auto& target = program.functions[instruction.index];
        if (target.parameters.size() != instruction.operands.size()) {
            diagnostics_.error(instruction.span, "IR call argument count does not match target");
            return false;
        }
        for (std::size_t i = 0; i < instruction.operands.size(); ++i) {
            const auto actual_value = values.find(instruction.operands[i]);
            if (actual_value == values.end()) {
                diagnostics_.error(
                    instruction.span,
                    "IR call argument is not defined at the call site");
                return false;
            }
            const auto actual = actual_value->second;
            const auto expected = target.locals[target.parameters[i]].type;
            if (!types_.can_assign(expected, actual)) {
                diagnostics_.error(instruction.span, "IR call argument type does not match target");
                return false;
            }
        }
    }
    return true;
}

void print(
    std::ostream& output,
    const Program& program,
    const sema::TypeStore& types) {
    for (std::size_t i = 0; i < program.constants.size(); ++i) {
        const auto& constant = program.constants[i];
        output << "constant @" << i << ' ';
        switch (constant.kind) {
        case ConstantKind::Null: output << "null"; break;
        case ConstantKind::Integer: output << "int " << constant.integer; break;
        case ConstantKind::Boolean: output << "bool " << constant.integer; break;
        case ConstantKind::String: output << "string " << std::quoted(constant.text); break;
        case ConstantKind::Array:
            output << "array";
            for (const auto element : constant.elements) output << " @" << element;
            break;
        case ConstantKind::Object:
            output << "object #" << constant.symbol;
            for (const auto& field : constant.fields) {
                output << " #" << field.symbol << "=@" << field.value;
            }
            break;
        }
        output << '\n';
    }
    for (const auto& global : program.globals) {
        output << "global @" << global.id << ' ' << global.name << ": "
               << types.to_string(global.type);
        if (global.initializer != no_function) output << " init @" << global.initializer;
        output << '\n';
    }
    for (const auto& function : program.functions) {
        output << "fun @" << function.id << ' ' << function.name << '(';
        for (std::size_t i = 0; i < function.parameters.size(); ++i) {
            if (i != 0) output << ", ";
            const auto& local = function.locals[function.parameters[i]];
            output << '%' << local.id << ' ' << local.name << ": "
                   << types.to_string(local.type);
        }
        output << "): " << types.to_string(function.result_type);
        if (function.external) output << " extern[" << function.native_library << ']';
        if (function.compile_only) output << " compile";
        output << '\n';
        for (const auto& local : function.locals) {
            if (std::find(function.parameters.begin(), function.parameters.end(), local.id) ==
                function.parameters.end()) {
                output << "  local %" << local.id << ' ' << local.name << ": "
                       << types.to_string(local.type) << '\n';
            }
        }
        for (const auto& block : function.blocks) {
            output << "  block ^" << block.id << ' ' << block.name << '\n';
            for (const auto& instruction : block.instructions) {
                output << "    ";
                if (instruction.result != no_value) output << 'v' << instruction.result << " = ";
                output << opcode_name(instruction.opcode);
                if (instruction.opcode == Opcode::ConstantInt ||
                    instruction.opcode == Opcode::ConstantBool) {
                    output << ' ' << instruction.integer;
                } else if (instruction.opcode == Opcode::ConstantString) {
                    output << ' ' << std::quoted(instruction.text);
                } else if (instruction.opcode == Opcode::ConstantFrozen) {
                    output << " @" << instruction.index;
                } else if (instruction.opcode == Opcode::CompileValue) {
                    output << " #" << instruction.index;
                } else if (instruction.opcode == Opcode::LoadLocal ||
                           instruction.opcode == Opcode::StoreLocal) {
                    output << " %" << instruction.index;
                } else if (instruction.opcode == Opcode::LoadGlobal ||
                           instruction.opcode == Opcode::StoreGlobal ||
                           instruction.opcode == Opcode::Call ||
                           instruction.opcode == Opcode::FunctionRef) {
                    output << " @" << instruction.index;
                } else if (instruction.opcode == Opcode::FieldGet ||
                           instruction.opcode == Opcode::FieldSet ||
                           instruction.opcode == Opcode::ObjectCreate) {
                    output << " #" << instruction.symbol;
                }
                for (const auto operand : instruction.operands) output << " v" << operand;
                if (instruction.result != no_value) {
                    output << ": " << types.to_string(instruction.type);
                }
                output << '\n';
            }
            const auto& terminator = block.terminator;
            output << "    ";
            if (terminator.kind == TerminatorKind::Return) {
                output << "return";
                if (terminator.value != no_value) output << " v" << terminator.value;
            } else if (terminator.kind == TerminatorKind::Jump) {
                output << "jump ^" << terminator.first;
            } else if (terminator.kind == TerminatorKind::Branch) {
                output << "branch v" << terminator.value << " ^"
                       << terminator.first << " ^" << terminator.second;
            } else {
                output << "<unterminated>";
            }
            output << '\n';
        }
    }
}

} // namespace abla::ir
