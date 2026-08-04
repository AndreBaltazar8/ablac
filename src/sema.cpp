#include "abla/sema.hpp"

#include <algorithm>
#include <cassert>
#include <utility>

namespace abla::sema {

namespace {

const std::vector<Symbol*> empty_candidates;

bool overloadable(SymbolKind kind) {
    return kind == SymbolKind::Function;
}

} // namespace

const std::vector<Symbol*>* Scope::local(std::string_view name) const {
    const auto found = names.find(std::string(name));
    return found == names.end() ? nullptr : &found->second;
}

const std::vector<Symbol*>& SemanticModel::candidates(
    const ast::Expression& expression) const {
    const auto found = bindings_.find(&expression);
    return found == bindings_.end() ? empty_candidates : found->second;
}

const Symbol* SemanticModel::type_symbol(const ast::TypeSyntax& type) const {
    const auto found = type_bindings_.find(&type);
    return found == type_bindings_.end() ? nullptr : found->second;
}

const Scope* SemanticModel::module_scope(const Module& module) const {
    const auto found = module_scopes_.find(&module);
    return found == module_scopes_.end() ? nullptr : found->second;
}

const Scope* SemanticModel::scope_for(const ast::Node& node) const {
    const auto found = node_scopes_.find(&node);
    return found == node_scopes_.end() ? nullptr : found->second;
}

const Symbol* SemanticModel::symbol_for(const ast::Statement& declaration) const {
    const auto found = declaration_symbols_.find(&declaration);
    return found == declaration_symbols_.end() ? nullptr : found->second;
}

SemanticModel Resolver::resolve() {
    model_ = SemanticModel{};
    declaration_symbols_.clear();
    install_prelude();

    for (const auto& module : graph_.modules()) {
        auto& scope = make_scope(nullptr, module.get(), module->program.get(), true);
        model_.module_scopes_.emplace(module.get(), &scope);
    }
    for (const auto& module : graph_.modules()) {
        current_module_ = module.get();
        auto& scope = *model_.module_scopes_.at(module.get());
        if (!module->program) {
            continue;
        }
        for (auto& declaration : module->program->declarations) {
            prepare_declaration(scope, *declaration);
        }
    }
    for (const auto& module : graph_.modules()) {
        current_module_ = module.get();
        auto& scope = *model_.module_scopes_.at(module.get());
        if (!module->program) {
            continue;
        }
        for (auto& declaration : module->program->declarations) {
            resolve_statement(scope, *declaration);
        }
    }
    current_module_ = nullptr;
    return std::move(model_);
}

Scope& Resolver::make_scope(
    Scope* parent,
    Module* module,
    const ast::Node* owner,
    bool is_module) {
    auto scope = std::make_unique<Scope>();
    scope->parent = parent;
    scope->module = module;
    scope->owner = owner;
    scope->is_module = is_module;
    auto* result = scope.get();
    model_.scopes_.push_back(std::move(scope));
    if (owner != nullptr) {
        model_.node_scopes_[owner] = result;
    }
    return *result;
}

Symbol* Resolver::declare(
    Scope& scope,
    SymbolKind kind,
    std::string name,
    const ast::Node* declaration,
    bool mutable_value) {
    auto& existing = scope.names[name];
    if (!existing.empty() &&
        !(overloadable(kind) && std::all_of(existing.begin(), existing.end(), [](auto* symbol) {
            return overloadable(symbol->kind);
        }))) {
        diagnostics().error(
            declaration != nullptr ? declaration->span : SourceSpan{},
            "duplicate declaration of '" + name + "'");
        return existing.front();
    }

    auto symbol = std::make_unique<Symbol>();
    symbol->id = static_cast<SymbolId>(model_.symbols_.size());
    symbol->kind = kind;
    symbol->name = std::move(name);
    symbol->declaration = declaration;
    symbol->module = current_module_;
    symbol->scope = &scope;
    symbol->mutable_value = mutable_value;
    auto* result = symbol.get();
    model_.symbols_.push_back(std::move(symbol));
    existing.push_back(result);
    return result;
}

void Resolver::install_prelude() {
    prelude_ = &make_scope(nullptr, nullptr, nullptr);
    static constexpr const char* builtin_types[] = {
        "void", "never", "bool", "i8", "i16", "i32", "i64", "int",
        "u8", "u16", "u32", "u64", "f32", "f64", "char",
        "string", "cstring", "array", "any"};
    for (const auto* name : builtin_types) {
        declare(*prelude_, SymbolKind::BuiltinType, name, nullptr);
    }
    static constexpr const char* compiler_functions[] = {
        "import", "code", "declareFun"};
    for (const auto* name : compiler_functions) {
        declare(*prelude_, SymbolKind::Function, name, nullptr);
    }
}

void Resolver::prepare_declaration(Scope& scope, ast::Statement& statement) {
    switch (statement.kind) {
    case ast::Statement::Kind::Function: {
        auto& function = static_cast<ast::FunctionDeclaration&>(statement);
        declaration_symbols_[&statement] = declare(
            scope, SymbolKind::Function, function.name, &statement);
        model_.declaration_symbols_[&statement] = declaration_symbols_[&statement];
        break;
    }
    case ast::Statement::Kind::Class: {
        auto& declaration = static_cast<ast::ClassDeclaration&>(statement);
        declaration_symbols_[&statement] = declare(
            scope, SymbolKind::Type, declaration.name, &statement);
        model_.declaration_symbols_[&statement] = declaration_symbols_[&statement];
        auto& class_scope = make_scope(&scope, current_module_, &declaration);
        for (auto& parameter : declaration.type_parameters) {
            declare(class_scope, SymbolKind::TypeParameter, parameter.name, &declaration);
        }
        prepare_class_members(declaration, class_scope);
        break;
    }
    case ast::Statement::Kind::Property: {
        auto& property = static_cast<ast::PropertyDeclaration&>(statement);
        declaration_symbols_[&statement] = declare(
            scope,
            scope.is_module || (scope.owner != nullptr &&
                dynamic_cast<const ast::ClassDeclaration*>(scope.owner) != nullptr)
                ? SymbolKind::Property
                : SymbolKind::Local,
            property.name,
            &statement,
            property.mutable_value);
        model_.declaration_symbols_[&statement] = declaration_symbols_[&statement];
        break;
    }
    case ast::Statement::Kind::Expression:
    case ast::Statement::Kind::While:
    case ast::Statement::Kind::DoWhile:
        break;
    }
}

void Resolver::prepare_class_members(
    ast::ClassDeclaration& declaration,
    Scope& class_scope) {
    for (auto& parameter : declaration.constructor_parameters) {
        if (parameter.property_mutability.has_value()) {
            declare(
                class_scope,
                SymbolKind::Property,
                parameter.name,
                &declaration,
                *parameter.property_mutability);
        }
    }
    if (!declaration.body) {
        return;
    }
    for (auto& member : declaration.body->statements) {
        prepare_declaration(class_scope, *member);
    }
}

void Resolver::resolve_statement(Scope& scope, ast::Statement& statement) {
    switch (statement.kind) {
    case ast::Statement::Kind::Expression: {
        auto& expression = static_cast<ast::ExpressionStatement&>(statement);
        if (expression.expression) {
            resolve_expression(scope, *expression.expression);
        }
        break;
    }
    case ast::Statement::Kind::Property:
        resolve_property(scope, static_cast<ast::PropertyDeclaration&>(statement));
        break;
    case ast::Statement::Kind::Function:
        resolve_function(scope, static_cast<ast::FunctionDeclaration&>(statement));
        break;
    case ast::Statement::Kind::Class:
        resolve_class(scope, static_cast<ast::ClassDeclaration&>(statement));
        break;
    case ast::Statement::Kind::While:
    case ast::Statement::Kind::DoWhile: {
        auto& loop = static_cast<ast::WhileStatement&>(statement);
        if (loop.condition) {
            resolve_expression(scope, *loop.condition);
        }
        if (loop.body) {
            resolve_block(scope, *loop.body);
        }
        break;
    }
    }
}

void Resolver::resolve_block(Scope& parent, ast::Block& block) {
    auto& scope = make_scope(&parent, current_module_, &block);
    for (auto& statement : block.statements) {
        if (statement->kind == ast::Statement::Kind::Function ||
            statement->kind == ast::Statement::Kind::Class) {
            prepare_declaration(scope, *statement);
        }
    }
    for (auto& statement : block.statements) {
        resolve_statement(scope, *statement);
        if (statement->kind == ast::Statement::Kind::Property &&
            !is_predeclared(*statement)) {
            prepare_declaration(scope, *statement);
        }
    }
}

void Resolver::resolve_function(
    Scope& parent,
    ast::FunctionDeclaration& declaration) {
    resolve_modifiers(parent, declaration.modifiers);
    auto& function_scope = make_scope(&parent, current_module_, &declaration);
    for (auto& parameter : declaration.type_parameters) {
        auto* symbol = declare(
            function_scope,
            SymbolKind::TypeParameter,
            parameter.name,
            &declaration);
        if (parameter.constraint) {
            resolve_type(function_scope, *parameter.constraint);
        }
        static_cast<void>(symbol);
    }
    if (declaration.receiver) {
        resolve_type(function_scope, *declaration.receiver);
        declare(function_scope, SymbolKind::Parameter, "this", &declaration);
    } else if (parent.owner != nullptr &&
               dynamic_cast<const ast::ClassDeclaration*>(parent.owner) != nullptr) {
        declare(function_scope, SymbolKind::Parameter, "this", &declaration);
    }
    if (has_modifier(declaration.modifiers, ast::Modifier::Compile)) {
        declare(function_scope, SymbolKind::Parameter, "compilerContext", &declaration);
    }
    for (auto& parameter : declaration.parameters) {
        resolve_modifiers(function_scope, parameter.modifiers);
        resolve_type(function_scope, parameter.type);
        if (parameter.default_value) {
            resolve_expression(function_scope, *parameter.default_value);
        }
        declare(
            function_scope,
            SymbolKind::Parameter,
            parameter.name,
            &declaration,
            false);
    }
    if (declaration.return_type) {
        resolve_type(function_scope, *declaration.return_type);
    }
    if (declaration.body) {
        resolve_block(function_scope, *declaration.body);
    }
    if (declaration.expression_body) {
        resolve_expression(function_scope, *declaration.expression_body);
    }
}

void Resolver::resolve_class(Scope&, ast::ClassDeclaration& declaration) {
    auto* class_scope = model_.node_scopes_.at(&declaration);
    resolve_modifiers(*class_scope, declaration.modifiers);
    for (auto& parameter : declaration.type_parameters) {
        if (parameter.constraint) {
            resolve_type(*class_scope, *parameter.constraint);
        }
    }
    for (auto& parameter : declaration.constructor_parameters) {
        resolve_modifiers(*class_scope, parameter.modifiers);
        resolve_type(*class_scope, parameter.type);
        if (parameter.default_value) {
            resolve_expression(*class_scope, *parameter.default_value);
        }
        if (!parameter.property_mutability.has_value()) {
            declare(
                *class_scope,
                SymbolKind::Parameter,
                parameter.name,
                &declaration);
        }
    }
    if (declaration.body) {
        for (auto& member : declaration.body->statements) {
            resolve_statement(*class_scope, *member);
        }
    }
}

void Resolver::resolve_property(
    Scope& scope,
    ast::PropertyDeclaration& declaration) {
    resolve_modifiers(scope, declaration.modifiers);
    if (declaration.type) {
        resolve_type(scope, *declaration.type);
    }
    if (declaration.initializer) {
        resolve_expression(scope, *declaration.initializer);
    }
}

void Resolver::resolve_expression(Scope& scope, ast::Expression& expression) {
    using Kind = ast::Expression::Kind;
    switch (expression.kind) {
    case Kind::Identifier: {
        auto candidates = lookup(scope, static_cast<ast::ScalarExpression&>(expression).value);
        if (candidates.empty()) {
            diagnostics().error(
                expression.span,
                "unknown identifier '" +
                    static_cast<ast::ScalarExpression&>(expression).value + "'");
        } else {
            model_.bindings_[&expression] = std::move(candidates);
        }
        break;
    }
    case Kind::Integer:
    case Kind::Boolean:
    case Kind::Null:
    case Kind::StringText:
        break;
    case Kind::String: {
        auto& string = static_cast<ast::StringExpression&>(expression);
        for (auto& part : string.parts) {
            if (part->kind != Kind::StringText) {
                resolve_expression(scope, *part);
            }
        }
        break;
    }
    case Kind::Array: {
        for (auto& element : static_cast<ast::ArrayExpression&>(expression).elements) {
            if (element) resolve_expression(scope, *element);
        }
        break;
    }
    case Kind::Unary:
    case Kind::Compile: {
        auto& unary = static_cast<ast::UnaryExpression&>(expression);
        if (unary.operand) resolve_expression(scope, *unary.operand);
        break;
    }
    case Kind::Return: {
        auto& returned = static_cast<ast::ReturnExpression&>(expression);
        if (returned.value) resolve_expression(scope, *returned.value);
        break;
    }
    case Kind::Binary:
    case Kind::Assignment: {
        auto& binary = static_cast<ast::BinaryExpression&>(expression);
        if (binary.left) resolve_expression(scope, *binary.left);
        if (binary.right) resolve_expression(scope, *binary.right);
        break;
    }
    case Kind::Call: {
        auto& call = static_cast<ast::CallExpression&>(expression);
        if (call.callee) resolve_expression(scope, *call.callee);
        for (auto& type : call.type_arguments) resolve_type(scope, type);
        for (auto& argument : call.arguments) {
            if (argument.value) resolve_expression(scope, *argument.value);
        }
        break;
    }
    case Kind::Member: {
        auto& member = static_cast<ast::MemberExpression&>(expression);
        if (member.receiver) resolve_expression(scope, *member.receiver);
        break;
    }
    case Kind::Index: {
        auto& index = static_cast<ast::IndexExpression&>(expression);
        if (index.receiver) resolve_expression(scope, *index.receiver);
        if (index.index) resolve_expression(scope, *index.index);
        break;
    }
    case Kind::If: {
        auto& conditional = static_cast<ast::IfExpression&>(expression);
        if (conditional.condition) resolve_expression(scope, *conditional.condition);
        if (conditional.then_body) resolve_block(scope, *conditional.then_body);
        if (conditional.else_body) resolve_block(scope, *conditional.else_body);
        break;
    }
    case Kind::When: {
        auto& when = static_cast<ast::WhenExpression&>(expression);
        if (when.subject) resolve_expression(scope, *when.subject);
        for (auto& when_case : when.cases) {
            for (auto& match : when_case.matches) {
                if (match) resolve_expression(scope, *match);
            }
            if (when_case.body) resolve_block(scope, *when_case.body);
        }
        break;
    }
    case Kind::Lambda: {
        auto& lambda = static_cast<ast::LambdaExpression&>(expression);
        auto& lambda_scope = make_scope(&scope, current_module_, &lambda);
        for (auto& parameter : lambda.parameters) {
            if (parameter.type) resolve_type(lambda_scope, *parameter.type);
            declare(
                lambda_scope,
                SymbolKind::Parameter,
                parameter.name,
                &lambda);
        }
        if (lambda.body) resolve_block(lambda_scope, *lambda.body);
        break;
    }
    }
}

void Resolver::resolve_type(Scope& scope, ast::TypeSyntax& type) {
    if (type.is_function()) {
        if (type.receiver) resolve_type(scope, *type.receiver);
        for (auto& parameter : type.parameter_types) resolve_type(scope, parameter);
        resolve_type(scope, *type.return_type);
        return;
    }
    auto candidates = lookup(scope, type.name);
    const auto found = std::find_if(candidates.begin(), candidates.end(), [](const auto* symbol) {
        return symbol->kind == SymbolKind::BuiltinType ||
            symbol->kind == SymbolKind::Type ||
            symbol->kind == SymbolKind::TypeParameter;
    });
    if (found == candidates.end()) {
        diagnostics().error(type.span, "unknown type '" + type.name + "'");
    } else {
        model_.type_bindings_[&type] = *found;
    }
    for (auto& argument : type.arguments) resolve_type(scope, argument);
}

void Resolver::resolve_modifiers(Scope& scope, ast::Modifiers& modifiers) {
    resolve_annotations(scope, modifiers.annotations);
    if (modifiers.extern_library) {
        resolve_expression(scope, *modifiers.extern_library);
    }
}

void Resolver::resolve_annotations(
    Scope& scope,
    std::vector<ast::Annotation>& annotations) {
    for (auto& annotation : annotations) {
        auto candidates = lookup(scope, annotation.name);
        if (std::none_of(candidates.begin(), candidates.end(), [](const auto* symbol) {
                return symbol->kind == SymbolKind::Type;
            })) {
            diagnostics().error(
                annotation.span,
                "unknown annotation type '" + annotation.name + "'");
        }
        for (auto& argument : annotation.arguments) {
            if (argument.value) resolve_expression(scope, *argument.value);
        }
    }
}

std::vector<Symbol*> Resolver::lookup(Scope& scope, std::string_view name) {
    Scope* current = &scope;
    while (current != nullptr && !current->is_module) {
        if (const auto* local = current->local(name)) {
            return *local;
        }
        current = current->parent;
    }
    if (current != nullptr) {
        if (const auto* local = current->local(name)) {
            return *local;
        }
        std::unordered_set<const Module*> visited;
        std::vector<Symbol*> imported;
        lookup_imports(*current->module, name, visited, imported);
        std::sort(imported.begin(), imported.end(), [](const auto* left, const auto* right) {
            return left->id < right->id;
        });
        imported.erase(std::unique(imported.begin(), imported.end()), imported.end());
        if (!imported.empty()) {
            return imported;
        }
    }
    if (const auto* builtin = prelude_->local(name)) {
        return *builtin;
    }
    return {};
}

void Resolver::lookup_imports(
    Module& module,
    std::string_view name,
    std::unordered_set<const Module*>& visited,
    std::vector<Symbol*>& result) {
    if (!visited.insert(&module).second) {
        return;
    }
    for (const auto& edge : module.imports) {
        if (edge.target == nullptr) continue;
        auto* imported_scope = model_.module_scopes_.at(edge.target);
        if (const auto* local = imported_scope->local(name)) {
            result.insert(result.end(), local->begin(), local->end());
        } else {
            lookup_imports(*edge.target, name, visited, result);
        }
    }
}

bool Resolver::is_predeclared(const ast::Statement& statement) const {
    return declaration_symbols_.contains(&statement);
}

bool Resolver::has_modifier(
    const ast::Modifiers& modifiers,
    ast::Modifier modifier) {
    return std::find(modifiers.values.begin(), modifiers.values.end(), modifier) !=
        modifiers.values.end();
}

Diagnostics& Resolver::diagnostics() {
    assert(current_module_ != nullptr);
    return current_module_->diagnostics;
}

} // namespace abla::sema
