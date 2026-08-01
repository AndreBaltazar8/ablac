#pragma once

#include "abla/diagnostic.hpp"
#include "abla/ir.hpp"
#include "abla/types.hpp"

#include <iosfwd>
#include <string>

namespace abla::backend {

class CEmitter {
public:
    CEmitter(
        const ir::Program& program,
        const sema::TypeStore& types,
        Diagnostics& diagnostics)
        : program_(program), types_(types), diagnostics_(diagnostics) {}

    void emit(std::ostream& output);

private:
    void emit_prototypes(std::ostream& output);
    void emit_globals(std::ostream& output);
    void emit_constants(std::ostream& output);
    void emit_dispatch(std::ostream& output);
    void emit_function(std::ostream& output, const ir::Function& function);
    void emit_external(std::ostream& output, const ir::Function& function);
    void emit_instruction(std::ostream& output, const ir::Instruction& instruction);
    void emit_terminator(std::ostream& output, const ir::Terminator& terminator);
    void emit_entry(std::ostream& output);
    [[nodiscard]] std::string operands(const ir::Instruction& instruction) const;
    [[nodiscard]] std::string native_type(sema::TypeId type, SourceSpan span);
    [[nodiscard]] std::string native_argument(
        sema::TypeId type,
        std::string value,
        SourceSpan span);
    [[nodiscard]] std::string native_result(
        sema::TypeId type,
        std::string expression,
        SourceSpan span);
    [[nodiscard]] static std::string c_string(const std::string& value);
    [[nodiscard]] static std::string function_name(ir::FunctionId id);

    const ir::Program& program_;
    const sema::TypeStore& types_;
    Diagnostics& diagnostics_;
};

} // namespace abla::backend
