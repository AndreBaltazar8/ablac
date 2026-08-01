#pragma once

#include "abla/source.hpp"

#include <iosfwd>
#include <string>
#include <vector>

namespace abla {

enum class DiagnosticSeverity {
    Error,
    Warning,
    Note,
};

struct Diagnostic {
    DiagnosticSeverity severity;
    SourceSpan span;
    std::string message;
};

class Diagnostics {
public:
    void error(SourceSpan span, std::string message);
    void warning(SourceSpan span, std::string message);
    void note(SourceSpan span, std::string message);

    [[nodiscard]] bool has_errors() const noexcept { return error_count_ != 0; }
    [[nodiscard]] std::size_t error_count() const noexcept { return error_count_; }
    [[nodiscard]] const std::vector<Diagnostic>& entries() const noexcept {
        return entries_;
    }
    void render(std::ostream& output, const SourceFile& source) const;

private:
    void add(DiagnosticSeverity severity, SourceSpan span, std::string message);

    std::vector<Diagnostic> entries_;
    std::size_t error_count_{};
};

} // namespace abla

