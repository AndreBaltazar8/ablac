#include "abla/types.hpp"

#include <algorithm>
#include <cassert>
#include <sstream>
#include <utility>

namespace abla::sema {

TypeStore::TypeStore() {
    const auto simple = [this](TypeKind kind, const char* name) {
        types_.push_back(Type{kind, name, {}, 0, 0, 0, false});
    };
    simple(TypeKind::Error, "<error>");
    simple(TypeKind::Unknown, "<unknown>");
    simple(TypeKind::Void, "void");
    simple(TypeKind::Bool, "bool");
    simple(TypeKind::Null, "null");
    simple(TypeKind::Any, "any");
    simple(TypeKind::String, "string");
    simple(TypeKind::CString, "cstring");
    simple(TypeKind::Char, "char");
    i64_ = integer(64, true);
}

const Type& TypeStore::get(TypeId id) const {
    return types_.at(id);
}

TypeId TypeStore::intern(Type type) {
    const auto found = std::find(types_.begin(), types_.end(), type);
    if (found != types_.end()) {
        return static_cast<TypeId>(std::distance(types_.begin(), found));
    }
    types_.push_back(std::move(type));
    return static_cast<TypeId>(types_.size() - 1);
}

TypeId TypeStore::integer(std::uint16_t bits, bool is_signed) {
    return intern(Type{
        TypeKind::Integer,
        std::string(is_signed ? "i" : "u") + std::to_string(bits),
        {}, 0, 0, bits, is_signed});
}

TypeId TypeStore::floating(std::uint16_t bits) {
    return intern(Type{
        TypeKind::Float,
        "f" + std::to_string(bits),
        {}, 0, 0, bits, false});
}

TypeId TypeStore::nominal(
    SymbolId symbol,
    std::string name,
    std::vector<TypeId> arguments) {
    return intern(Type{
        TypeKind::Nominal,
        std::move(name),
        std::move(arguments),
        0,
        symbol});
}

TypeId TypeStore::type_parameter(SymbolId symbol, std::string name) {
    return intern(Type{TypeKind::TypeParameter, std::move(name), {}, 0, symbol});
}

TypeId TypeStore::array(TypeId element) {
    return intern(Type{TypeKind::Array, "array", {element}});
}

TypeId TypeStore::function(std::vector<TypeId> parameters, TypeId result) {
    return intern(Type{
        TypeKind::Function,
        "<function>",
        std::move(parameters),
        result});
}

TypeId TypeStore::nullable(TypeId base) {
    return intern(Type{TypeKind::Nullable, "?", {base}});
}

TypeId TypeStore::pointer(TypeId pointee) {
    return intern(Type{TypeKind::Pointer, "*", {pointee}});
}

std::string TypeStore::to_string(TypeId id) const {
    const auto& type = get(id);
    switch (type.kind) {
    case TypeKind::Function: {
        std::ostringstream output;
        output << '(';
        for (std::size_t i = 0; i < type.arguments.size(); ++i) {
            if (i != 0) output << ", ";
            output << to_string(type.arguments[i]);
        }
        output << ") -> " << to_string(type.result);
        return output.str();
    }
    case TypeKind::Nullable:
        return to_string(type.arguments.front()) + '?';
    case TypeKind::Pointer:
        return to_string(type.arguments.front()) + '*';
    case TypeKind::Array:
        return "array<" + to_string(type.arguments.front()) + '>';
    case TypeKind::Nominal:
        if (type.arguments.empty()) return type.name;
        break;
    default:
        return type.name;
    }
    std::string result = type.name + '<';
    for (std::size_t i = 0; i < type.arguments.size(); ++i) {
        if (i != 0) result += ", ";
        result += to_string(type.arguments[i]);
    }
    return result + '>';
}

bool TypeStore::is_numeric(TypeId id) const {
    return get(id).kind == TypeKind::Integer || get(id).kind == TypeKind::Float;
}

bool TypeStore::is_integer(TypeId id) const {
    return get(id).kind == TypeKind::Integer;
}

bool TypeStore::can_assign(TypeId target, TypeId source) const {
    if (target == error() || source == error() ||
        target == unknown() || source == unknown()) {
        return true;
    }
    if (target == source || target == any_type()) {
        return true;
    }
    const auto& target_type = get(target);
    if (target_type.kind == TypeKind::Nullable) {
        return source == null_type() ||
            source == target_type.arguments.front() ||
            (get(source).kind == TypeKind::Nullable && source == target);
    }
    const auto& source_type = get(source);
    if (target_type.kind == TypeKind::Array &&
        source_type.kind == TypeKind::Array &&
        source_type.arguments.front() == unknown()) {
        return true;
    }
    return false;
}

TypeId TypedProgram::expression_type(const ast::Expression& expression) const {
    const auto found = expression_types_.find(&expression);
    return found == expression_types_.end() ? types.error() : found->second;
}

TypeId TypedProgram::symbol_type(const Symbol& symbol) const {
    const auto found = symbol_types_.find(&symbol);
    return found == symbol_types_.end() ? types.error() : found->second;
}

TypeId TypedProgram::syntax_type(const ast::TypeSyntax& syntax) const {
    const auto found = syntax_types_.find(&syntax);
    return found == syntax_types_.end() ? types.error() : found->second;
}

const Symbol* TypedProgram::selected_call(const ast::CallExpression& call) const {
    const auto found = selected_calls_.find(&call);
    return found == selected_calls_.end() ? nullptr : found->second;
}

TypedProgram TypeChecker::check() {
    typed_ = TypedProgram{};
    states_.clear();
    prepare_symbols();
    for (const auto& module : graph_.modules()) {
        current_module_ = module.get();
        if (!module->program) continue;
        for (auto& statement : module->program->declarations) {
            check_statement(*statement);
        }
    }
    current_module_ = nullptr;
    return std::move(typed_);
}

void TypeChecker::prepare_symbols() {
    for (const auto& owned : semantics_.symbols()) {
        const auto& symbol = *owned;
        if (symbol.kind == SymbolKind::BuiltinType) {
            TypeId type = typed_.types.error();
            if (symbol.name == "void") type = typed_.types.void_type();
            else if (symbol.name == "bool") type = typed_.types.bool_type();
            else if (symbol.name == "any") type = typed_.types.any_type();
            else if (symbol.name == "string") type = typed_.types.string_type();
            else if (symbol.name == "cstring") type = typed_.types.cstring_type();
            else if (symbol.name == "char") type = typed_.types.char_type();
            else if (symbol.name == "int" || symbol.name == "i64") {
                type = typed_.types.integer(64, true);
            } else if (symbol.name == "i8") type = typed_.types.integer(8, true);
            else if (symbol.name == "i16") type = typed_.types.integer(16, true);
            else if (symbol.name == "i32") type = typed_.types.integer(32, true);
            else if (symbol.name == "u8") type = typed_.types.integer(8, false);
            else if (symbol.name == "u16") type = typed_.types.integer(16, false);
            else if (symbol.name == "u32") type = typed_.types.integer(32, false);
            else if (symbol.name == "u64") type = typed_.types.integer(64, false);
            else if (symbol.name == "f32") type = typed_.types.floating(32);
            else if (symbol.name == "f64") type = typed_.types.floating(64);
            typed_.symbol_types_[&symbol] = type;
        } else if (symbol.kind == SymbolKind::Type && symbol.declaration != nullptr) {
            typed_.symbol_types_[&symbol] = typed_.types.nominal(symbol.id, symbol.name);
        } else if (symbol.kind == SymbolKind::Function && symbol.declaration == nullptr) {
            if (symbol.name == "import") {
                typed_.symbol_types_[&symbol] = typed_.types.function(
                    {typed_.types.string_type()}, typed_.types.int_type());
            } else {
                typed_.symbol_types_[&symbol] = typed_.types.function(
                    {typed_.types.any_type()}, typed_.types.any_type());
            }
        }
    }

    for (const auto& module : graph_.modules()) {
        current_module_ = module.get();
        if (!module->program) continue;
        for (auto& statement : module->program->declarations) {
            prepare_statement(*statement);
        }
    }
}

void TypeChecker::prepare_statement(ast::Statement& statement) {
    const auto* symbol = declaration_symbol(statement);
    switch (statement.kind) {
    case ast::Statement::Kind::Function:
        if (symbol) prepare_function(
            static_cast<ast::FunctionDeclaration&>(statement), *symbol);
        break;
    case ast::Statement::Kind::Class:
        if (symbol) prepare_class(static_cast<ast::ClassDeclaration&>(statement), *symbol);
        break;
    case ast::Statement::Kind::Property: {
        auto& property = static_cast<ast::PropertyDeclaration&>(statement);
        if (symbol && property.type) {
            typed_.symbol_types_[symbol] = type_from_syntax(*property.type);
        }
        break;
    }
    case ast::Statement::Kind::Expression:
    case ast::Statement::Kind::While:
    case ast::Statement::Kind::DoWhile:
        break;
    }
}

void TypeChecker::prepare_function(
    ast::FunctionDeclaration& declaration,
    const Symbol& symbol) {
    auto* scope = semantics_.node_scopes_.at(&declaration);
    for (auto& type_parameter : declaration.type_parameters) {
        if (auto* parameter_symbol = scope_symbol(declaration, type_parameter.name)) {
            typed_.symbol_types_[parameter_symbol] = typed_.types.type_parameter(
                parameter_symbol->id, parameter_symbol->name);
        }
    }
    std::vector<TypeId> parameters;
    for (auto& parameter : declaration.parameters) {
        const auto type = type_from_syntax(parameter.type);
        parameters.push_back(type);
        if (const auto* values = scope->local(parameter.name); values && !values->empty()) {
            typed_.symbol_types_[values->front()] = type;
        }
    }
    if (const auto* values = scope->local("this"); values && !values->empty()) {
        TypeId this_type = typed_.types.error();
        if (declaration.receiver) {
            this_type = type_from_syntax(*declaration.receiver);
        } else if (scope->parent && scope->parent->owner) {
            const auto* owner = dynamic_cast<const ast::ClassDeclaration*>(scope->parent->owner);
            if (owner) {
                const auto* owner_symbol = semantics_.symbol_for(*owner);
                if (owner_symbol) this_type = type_of_symbol(*owner_symbol);
            }
        }
        typed_.symbol_types_[values->front()] = this_type;
    }
    if (const auto* values = scope->local("compilerContext"); values && !values->empty()) {
        typed_.symbol_types_[values->front()] = typed_.types.any_type();
    }
    const auto result = declaration.return_type
        ? type_from_syntax(*declaration.return_type)
        : typed_.types.unknown();
    typed_.symbol_types_[&symbol] = typed_.types.function(std::move(parameters), result);
    states_[&symbol] = CheckState::Unchecked;
}

void TypeChecker::prepare_class(
    ast::ClassDeclaration& declaration,
    const Symbol&) {
    auto* scope = semantics_.node_scopes_.at(&declaration);
    for (auto& type_parameter : declaration.type_parameters) {
        if (const auto* values = scope->local(type_parameter.name); values && !values->empty()) {
            typed_.symbol_types_[values->front()] = typed_.types.type_parameter(
                values->front()->id, values->front()->name);
        }
    }
    for (auto& parameter : declaration.constructor_parameters) {
        const auto type = type_from_syntax(parameter.type);
        if (const auto* values = scope->local(parameter.name); values && !values->empty()) {
            typed_.symbol_types_[values->front()] = type;
        }
    }
    if (declaration.body) {
        for (auto& member : declaration.body->statements) prepare_statement(*member);
    }
}

void TypeChecker::check_statement(ast::Statement& statement) {
    switch (statement.kind) {
    case ast::Statement::Kind::Expression: {
        auto& value = static_cast<ast::ExpressionStatement&>(statement);
        if (value.expression) check_expression(*value.expression);
        break;
    }
    case ast::Statement::Kind::Property:
        check_property(static_cast<ast::PropertyDeclaration&>(statement));
        break;
    case ast::Statement::Kind::Function: {
        const auto* symbol = declaration_symbol(statement);
        if (symbol) check_function(
            static_cast<ast::FunctionDeclaration&>(statement), *symbol);
        break;
    }
    case ast::Statement::Kind::Class:
        check_class(static_cast<ast::ClassDeclaration&>(statement));
        break;
    case ast::Statement::Kind::While:
    case ast::Statement::Kind::DoWhile: {
        auto& loop = static_cast<ast::WhileStatement&>(statement);
        if (loop.condition) {
            require_assignable(
                typed_.types.bool_type(),
                check_expression(*loop.condition),
                loop.condition->span,
                "loop condition");
        }
        if (loop.body) check_block(*loop.body);
        break;
    }
    }
}

void TypeChecker::check_function(
    ast::FunctionDeclaration& declaration,
    const Symbol& symbol) {
    const auto state = states_[&symbol];
    if (state == CheckState::Checked) return;
    if (state == CheckState::Checking) {
        const auto current_type = type_of_symbol(symbol);
        if (typed_.types.get(current_type).result == typed_.types.unknown()) {
            diagnostics().error(
                declaration.span,
                "recursive function '" + declaration.name +
                    "' requires an explicit return type");
        }
        return;
    }
    states_[&symbol] = CheckState::Checking;
    auto* saved_module = current_module_;
    current_module_ = symbol.module;

    for (auto& parameter : declaration.parameters) {
        if (parameter.default_value) {
            require_assignable(
                type_from_syntax(parameter.type),
                check_expression(*parameter.default_value),
                parameter.default_value->span,
                "default argument");
        }
    }
    TypeId body_type = typed_.types.void_type();
    if (declaration.body) body_type = check_block(*declaration.body);
    if (declaration.expression_body) body_type = check_expression(*declaration.expression_body);

    const auto function_type_id = type_of_symbol(symbol);
    const auto function_type = typed_.types.get(function_type_id);
    auto result = function_type.result;
    if (result == typed_.types.unknown()) {
        result = body_type;
        typed_.symbol_types_[&symbol] = typed_.types.function(function_type.arguments, result);
    } else if (result != typed_.types.void_type() &&
               (declaration.body || declaration.expression_body)) {
        require_assignable(result, body_type, declaration.span, "function result");
    }
    states_[&symbol] = CheckState::Checked;
    current_module_ = saved_module;
}

void TypeChecker::check_class(ast::ClassDeclaration& declaration) {
    for (auto& parameter : declaration.constructor_parameters) {
        if (parameter.default_value) {
            require_assignable(
                type_from_syntax(parameter.type),
                check_expression(*parameter.default_value),
                parameter.default_value->span,
                "constructor default argument");
        }
    }
    if (declaration.body) {
        for (auto& member : declaration.body->statements) check_statement(*member);
    }
}

TypeId TypeChecker::check_property(ast::PropertyDeclaration& declaration) {
    const auto* symbol = declaration_symbol(declaration);
    TypeId declared = typed_.types.unknown();
    if (declaration.type) declared = type_from_syntax(*declaration.type);
    TypeId initializer = typed_.types.unknown();
    if (declaration.initializer) initializer = check_expression(*declaration.initializer);
    if (declared == typed_.types.unknown()) {
        if (initializer == typed_.types.unknown()) {
            diagnostics().error(
                declaration.span,
                "property '" + declaration.name + "' needs a type or initializer");
            declared = typed_.types.error();
        } else {
            declared = initializer;
        }
    } else if (declaration.initializer) {
        require_assignable(declared, initializer, declaration.initializer->span, "initializer");
    }
    if (symbol) typed_.symbol_types_[symbol] = declared;
    return declared;
}

TypeId TypeChecker::check_block(ast::Block& block) {
    TypeId result = typed_.types.void_type();
    for (auto& statement : block.statements) {
        check_statement(*statement);
        if (statement->kind == ast::Statement::Kind::Expression) {
            auto& expression = static_cast<ast::ExpressionStatement&>(*statement);
            result = expression.expression
                ? check_expression(*expression.expression)
                : typed_.types.void_type();
        } else {
            result = typed_.types.void_type();
        }
    }
    return result;
}

TypeId TypeChecker::check_expression(ast::Expression& expression) {
    if (const auto found = typed_.expression_types_.find(&expression);
        found != typed_.expression_types_.end()) {
        return found->second;
    }
    using Kind = ast::Expression::Kind;
    TypeId result = typed_.types.error();
    switch (expression.kind) {
    case Kind::Identifier: {
        const auto& candidates = semantics_.candidates(expression);
        if (candidates.size() == 1) {
            result = type_of_symbol(*candidates.front());
        } else if (candidates.size() > 1) {
            diagnostics().error(expression.span, "overloaded name requires a call context");
        }
        break;
    }
    case Kind::Integer: result = typed_.types.int_type(); break;
    case Kind::Boolean: result = typed_.types.bool_type(); break;
    case Kind::Null: result = typed_.types.null_type(); break;
    case Kind::StringText:
    case Kind::String: {
        result = typed_.types.string_type();
        if (expression.kind == Kind::String) {
            for (auto& part : static_cast<ast::StringExpression&>(expression).parts) {
                if (part->kind != Kind::StringText) check_expression(*part);
            }
        }
        break;
    }
    case Kind::Array: {
        auto& array = static_cast<ast::ArrayExpression&>(expression);
        if (array.elements.empty()) {
            // Preserve an unknown element until an annotated assignment or call
            // supplies context. Runtime arrays carry values rather than a host
            // element layout, so this does not erase backend information.
            result = typed_.types.array(typed_.types.unknown());
        } else {
            auto element = check_expression(*array.elements.front());
            for (std::size_t i = 1; i < array.elements.size(); ++i) {
                element = common_type(
                    element,
                    check_expression(*array.elements[i]),
                    array.elements[i]->span);
            }
            result = typed_.types.array(element);
        }
        break;
    }
    case Kind::Unary:
    case Kind::Compile: {
        auto& unary = static_cast<ast::UnaryExpression&>(expression);
        result = unary.operand ? check_expression(*unary.operand) : typed_.types.error();
        if (unary.operation == TokenKind::Bang) {
            require_assignable(typed_.types.bool_type(), result, expression.span, "'!' operand");
            result = typed_.types.bool_type();
        } else if ((unary.operation == TokenKind::Minus || unary.operation == TokenKind::Plus) &&
                   !typed_.types.is_numeric(result)) {
            diagnostics().error(expression.span, "unary numeric operator requires a number");
            result = typed_.types.error();
        }
        break;
    }
    case Kind::Binary:
    case Kind::Assignment: {
        auto& binary = static_cast<ast::BinaryExpression&>(expression);
        const auto left = check_expression(*binary.left);
        const auto right = check_expression(*binary.right);
        if (expression.kind == Kind::Assignment) {
            require_assignable(left, right, expression.span, "assignment");
            if (binary.left->kind == Kind::Identifier) {
                const auto& candidates = semantics_.candidates(*binary.left);
                if (candidates.size() == 1 && !candidates.front()->mutable_value) {
                    diagnostics().error(binary.left->span, "cannot assign to immutable value");
                }
            } else if (binary.left->kind == Kind::Member) {
                const auto& member =
                    static_cast<const ast::MemberExpression&>(*binary.left);
                if (member.member == "size") {
                    diagnostics().error(binary.left->span, "cannot assign to size");
                }
                const auto& candidates = semantics_.candidates(*binary.left);
                if (candidates.size() == 1 && !candidates.front()->mutable_value) {
                    diagnostics().error(binary.left->span, "cannot assign to immutable property");
                }
            } else if (binary.left->kind == Kind::Index) {
                const auto& index =
                    static_cast<const ast::IndexExpression&>(*binary.left);
                if (typed_.types.get(typed_.expression_type(*index.receiver)).kind ==
                    TypeKind::String) {
                    diagnostics().error(binary.left->span, "cannot assign to a string byte");
                }
            }
            result = right;
        } else if (binary.operation == TokenKind::AmpAmp ||
                   binary.operation == TokenKind::PipePipe) {
            require_assignable(typed_.types.bool_type(), left, binary.left->span, "logical operand");
            require_assignable(typed_.types.bool_type(), right, binary.right->span, "logical operand");
            result = typed_.types.bool_type();
        } else if (binary.operation == TokenKind::EqualEqual ||
                   binary.operation == TokenKind::BangEqual ||
                   binary.operation == TokenKind::Less ||
                   binary.operation == TokenKind::LessEqual ||
                   binary.operation == TokenKind::Greater ||
                   binary.operation == TokenKind::GreaterEqual) {
            static_cast<void>(common_type(left, right, expression.span));
            result = typed_.types.bool_type();
        } else {
            const auto common = common_type(left, right, expression.span);
            if (!typed_.types.is_numeric(common)) {
                diagnostics().error(expression.span, "arithmetic operator requires numeric operands");
                result = typed_.types.error();
            } else {
                result = common;
            }
        }
        break;
    }
    case Kind::Call:
        result = check_call(static_cast<ast::CallExpression&>(expression));
        break;
    case Kind::Member:
        result = check_member(static_cast<ast::MemberExpression&>(expression));
        break;
    case Kind::Index: {
        auto& index = static_cast<ast::IndexExpression&>(expression);
        const auto receiver = check_expression(*index.receiver);
        const auto index_type = check_expression(*index.index);
        if (!typed_.types.is_integer(index_type)) {
            diagnostics().error(index.index->span, "index must be an integer");
        }
        const auto& receiver_type = typed_.types.get(receiver);
        if (receiver_type.kind == TypeKind::String) {
            result = typed_.types.int_type();
        } else if (receiver_type.kind != TypeKind::Array) {
            diagnostics().error(index.receiver->span, "indexing requires an array or string");
        } else {
            result = receiver_type.arguments.front();
        }
        break;
    }
    case Kind::If: {
        auto& conditional = static_cast<ast::IfExpression&>(expression);
        require_assignable(
            typed_.types.bool_type(),
            check_expression(*conditional.condition),
            conditional.condition->span,
            "if condition");
        const auto then_type = check_block(*conditional.then_body);
        result = conditional.else_body
            ? common_type(then_type, check_block(*conditional.else_body), expression.span)
            : typed_.types.void_type();
        break;
    }
    case Kind::When: {
        auto& when = static_cast<ast::WhenExpression&>(expression);
        const auto subject = when.subject
            ? check_expression(*when.subject)
            : typed_.types.bool_type();
        result = typed_.types.unknown();
        for (auto& when_case : when.cases) {
            for (auto& match : when_case.matches) {
                const auto match_type = check_expression(*match);
                if (when.subject) static_cast<void>(common_type(subject, match_type, match->span));
                else require_assignable(
                    typed_.types.bool_type(), match_type, match->span, "when condition");
            }
            const auto body = check_block(*when_case.body);
            result = result == typed_.types.unknown()
                ? body
                : common_type(result, body, when_case.span);
        }
        if (result == typed_.types.unknown()) result = typed_.types.void_type();
        break;
    }
    case Kind::Lambda: {
        auto& lambda = static_cast<ast::LambdaExpression&>(expression);
        std::vector<TypeId> parameters;
        for (auto& parameter : lambda.parameters) {
            TypeId type = typed_.types.unknown();
            if (parameter.type) type = type_from_syntax(*parameter.type);
            else diagnostics().error(
                parameter.span,
                "lambda parameter type needs a call context or annotation");
            parameters.push_back(type);
            if (auto* symbol = scope_symbol(lambda, parameter.name)) {
                typed_.symbol_types_[symbol] = type;
            }
        }
        result = typed_.types.function(std::move(parameters), check_block(*lambda.body));
        break;
    }
    }
    typed_.expression_types_[&expression] = result;
    return result;
}

TypeId TypeChecker::check_call(ast::CallExpression& call) {
    std::vector<TypeId> arguments;
    for (auto& argument : call.arguments) {
        arguments.push_back(check_expression(*argument.value));
    }

    if (call.callee->kind == ast::Expression::Kind::Member) {
        check_member(static_cast<ast::MemberExpression&>(*call.callee));
    }
    const auto& candidates = semantics_.candidates(*call.callee);
    std::vector<const Symbol*> matches;
    for (const auto* candidate : candidates) {
        if (candidate->kind == SymbolKind::Type) {
            const auto* declaration = dynamic_cast<const ast::ClassDeclaration*>(candidate->declaration);
            if (!declaration || arguments.size() > declaration->constructor_parameters.size()) continue;
            std::size_t required = 0;
            bool compatible = true;
            for (std::size_t i = 0; i < declaration->constructor_parameters.size(); ++i) {
                const auto& parameter = declaration->constructor_parameters[i];
                if (!parameter.default_value) ++required;
                if (i < arguments.size() &&
                    !typed_.types.can_assign(type_from_syntax(
                        const_cast<ast::TypeSyntax&>(parameter.type)), arguments[i])) {
                    compatible = false;
                }
            }
            if (compatible && arguments.size() >= required) matches.push_back(candidate);
            continue;
        }
        if (candidate->kind != SymbolKind::Function) continue;
        if (candidate->declaration != nullptr) {
            const auto* declared_function =
                dynamic_cast<const ast::FunctionDeclaration*>(candidate->declaration);
            if (declared_function == nullptr) continue;
            auto& declaration =
                *const_cast<ast::FunctionDeclaration*>(declared_function);
            check_function(declaration, *candidate);
        }
        const auto function_id = type_of_symbol(*candidate);
        const auto& function = typed_.types.get(function_id);
        if (function.kind != TypeKind::Function || arguments.size() > function.arguments.size()) continue;
        std::size_t required = function.arguments.size();
        if (const auto* declaration = dynamic_cast<const ast::FunctionDeclaration*>(candidate->declaration)) {
            required = static_cast<std::size_t>(std::count_if(
                declaration->parameters.begin(), declaration->parameters.end(),
                [](const auto& parameter) { return !parameter.default_value; }));
        }
        if (arguments.size() < required) continue;
        bool compatible = true;
        for (std::size_t i = 0; i < arguments.size(); ++i) {
            compatible = compatible &&
                typed_.types.can_assign(function.arguments[i], arguments[i]);
        }
        if (compatible) matches.push_back(candidate);
    }

    if (matches.size() == 1) {
        const auto* selected = matches.front();
        typed_.selected_calls_[&call] = selected;
        if (selected->kind == SymbolKind::Type) return type_of_symbol(*selected);
        return typed_.types.get(type_of_symbol(*selected)).result;
    }
    if (matches.size() > 1) {
        diagnostics().error(call.span, "call is ambiguous between multiple declarations");
        return typed_.types.error();
    }

    const auto callee_type = check_expression(*call.callee);
    const auto& function = typed_.types.get(callee_type);
    if (function.kind == TypeKind::Function && function.arguments.size() == arguments.size()) {
        for (std::size_t i = 0; i < arguments.size(); ++i) {
            require_assignable(function.arguments[i], arguments[i], call.arguments[i].span, "argument");
        }
        return function.result;
    }
    diagnostics().error(call.span, "no callable declaration matches these arguments");
    return typed_.types.error();
}

TypeId TypeChecker::check_member(ast::MemberExpression& member) {
    if (typed_.expression_types_.contains(&member)) {
        return typed_.expression_types_.at(&member);
    }
    const auto receiver = check_expression(*member.receiver);
    const auto& type = typed_.types.get(receiver);
    if (member.member == "size" &&
        (type.kind == TypeKind::Array || type.kind == TypeKind::String)) {
        const auto result = typed_.types.int_type();
        typed_.expression_types_[&member] = result;
        return result;
    }
    if (member.member == "append" && type.kind == TypeKind::Array) {
        const auto result = typed_.types.function(
            {type.arguments.front()}, typed_.types.void_type());
        typed_.expression_types_[&member] = result;
        return result;
    }
    if (member.member == "slice" && type.kind == TypeKind::String) {
        const auto result = typed_.types.function(
            {typed_.types.int_type(), typed_.types.int_type()},
            typed_.types.string_type());
        typed_.expression_types_[&member] = result;
        return result;
    }
    std::vector<Symbol*> candidates;
    if (type.kind == TypeKind::Nominal) {
        const auto found = std::find_if(
            semantics_.symbols().begin(), semantics_.symbols().end(),
            [&](const auto& symbol) { return symbol->id == type.symbol; });
        if (found != semantics_.symbols().end()) {
            const auto* declaration = dynamic_cast<const ast::ClassDeclaration*>((*found)->declaration);
            if (declaration) {
                const auto* scope = semantics_.scope_for(*declaration);
                if (scope) {
                    if (const auto* local = scope->local(member.member)) candidates = *local;
                }
            }
        }
    }
    for (const auto& owned : semantics_.symbols()) {
        if (owned->kind != SymbolKind::Function || owned->name != member.member) continue;
        const auto* declaration = dynamic_cast<const ast::FunctionDeclaration*>(owned->declaration);
        if (!declaration || !declaration->receiver) continue;
        if (type_from_syntax(
                const_cast<ast::TypeSyntax&>(*declaration->receiver)) == receiver) {
            candidates.push_back(owned.get());
        }
    }
    if (candidates.empty()) {
        diagnostics().error(
            member.span,
            "type '" + typed_.types.to_string(receiver) +
                "' has no member named '" + member.member + "'");
        typed_.expression_types_[&member] = typed_.types.error();
        return typed_.types.error();
    }
    semantics_.bindings_[&member] = candidates;
    TypeId result = typed_.types.unknown();
    if (candidates.size() == 1) result = type_of_symbol(*candidates.front());
    typed_.expression_types_[&member] = result;
    return result;
}

TypeId TypeChecker::type_from_syntax(ast::TypeSyntax& syntax) {
    if (const auto found = typed_.syntax_types_.find(&syntax);
        found != typed_.syntax_types_.end()) return found->second;
    TypeId result = typed_.types.error();
    if (syntax.is_function()) {
        std::vector<TypeId> parameters;
        for (auto& parameter : syntax.parameter_types) {
            parameters.push_back(type_from_syntax(parameter));
        }
        result = typed_.types.function(
            std::move(parameters), type_from_syntax(*syntax.return_type));
    } else if (const auto* symbol = semantics_.type_symbol(syntax)) {
        if (symbol->kind == SymbolKind::BuiltinType) {
            result = type_of_symbol(*symbol);
            if (symbol->name == "array") {
                if (syntax.arguments.size() != 1) {
                    diagnostics().error(syntax.span, "array type requires one type argument");
                    result = typed_.types.array(typed_.types.error());
                } else {
                    result = typed_.types.array(type_from_syntax(syntax.arguments.front()));
                }
            } else if (!syntax.arguments.empty()) {
                diagnostics().error(syntax.span, "builtin type does not accept type arguments");
            }
        } else if (symbol->kind == SymbolKind::TypeParameter) {
            result = typed_.types.type_parameter(symbol->id, symbol->name);
        } else {
            std::vector<TypeId> arguments;
            for (auto& argument : syntax.arguments) arguments.push_back(type_from_syntax(argument));
            result = typed_.types.nominal(symbol->id, symbol->name, std::move(arguments));
        }
    }
    if (syntax.nullable) {
        if (result == typed_.types.void_type()) {
            diagnostics().error(syntax.span, "void cannot be nullable");
        } else {
            result = typed_.types.nullable(result);
        }
    }
    for (std::size_t i = 0; i < syntax.pointer_depth; ++i) {
        result = typed_.types.pointer(result);
    }
    typed_.syntax_types_[&syntax] = result;
    return result;
}

TypeId TypeChecker::type_of_symbol(const Symbol& symbol) {
    const auto found = typed_.symbol_types_.find(&symbol);
    if (found != typed_.symbol_types_.end()) return found->second;
    if (const auto* property = dynamic_cast<const ast::PropertyDeclaration*>(symbol.declaration)) {
        return check_property(*const_cast<ast::PropertyDeclaration*>(property));
    }
    return typed_.types.error();
}

TypeId TypeChecker::common_type(TypeId left, TypeId right, SourceSpan span) {
    if (left == right) return left;
    if (typed_.types.can_assign(left, right)) return left;
    if (typed_.types.can_assign(right, left)) return right;
    diagnostics().error(
        span,
        "incompatible types '" + typed_.types.to_string(left) +
            "' and '" + typed_.types.to_string(right) + "'");
    return typed_.types.error();
}

void TypeChecker::require_assignable(
    TypeId target,
    TypeId source,
    SourceSpan span,
    std::string_view context) {
    if (!typed_.types.can_assign(target, source)) {
        diagnostics().error(
            span,
            std::string(context) + " expects '" + typed_.types.to_string(target) +
                "', found '" + typed_.types.to_string(source) + "'");
    }
}

const Symbol* TypeChecker::declaration_symbol(const ast::Statement& statement) const {
    return semantics_.symbol_for(statement);
}

Symbol* TypeChecker::scope_symbol(const ast::Node& owner, std::string_view name) const {
    const auto* scope = semantics_.scope_for(owner);
    if (!scope) return nullptr;
    const auto* values = scope->local(name);
    return values && !values->empty() ? values->front() : nullptr;
}

Module* TypeChecker::module_for(const ast::Node& node) const {
    for (const auto& module : graph_.modules()) {
        if (module->program && node.span.end <= module->source.text().size()) {
            // Source spans are module-local; callers normally use symbol.module.
            // This fallback is only used while walking the current module.
            return current_module_ ? current_module_ : module.get();
        }
    }
    return current_module_;
}

Diagnostics& TypeChecker::diagnostics() {
    assert(current_module_ != nullptr);
    return current_module_->diagnostics;
}

} // namespace abla::sema
