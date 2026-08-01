#include "abla/diagnostic.hpp"

#include <algorithm>
#include <ostream>
#include <string_view>

namespace abla {

namespace {

std::string_view severity_name(DiagnosticSeverity severity) {
    switch (severity) {
    case DiagnosticSeverity::Error:
        return "error";
    case DiagnosticSeverity::Warning:
        return "warning";
    case DiagnosticSeverity::Note:
        return "note";
    }
    return "diagnostic";
}

} // namespace

void Diagnostics::add(
    DiagnosticSeverity severity,
    SourceSpan span,
    std::string message) {
    if (severity == DiagnosticSeverity::Error) {
        ++error_count_;
    }
    entries_.push_back(Diagnostic{severity, span, std::move(message)});
}

void Diagnostics::error(SourceSpan span, std::string message) {
    add(DiagnosticSeverity::Error, span, std::move(message));
}

void Diagnostics::warning(SourceSpan span, std::string message) {
    add(DiagnosticSeverity::Warning, span, std::move(message));
}

void Diagnostics::note(SourceSpan span, std::string message) {
    add(DiagnosticSeverity::Note, span, std::move(message));
}

void Diagnostics::render(std::ostream& output, const SourceFile& source) const {
    for (const auto& diagnostic : entries_) {
        const auto location = source.location(diagnostic.span.begin);
        output << source.path() << ':' << location.line << ':' << location.column
               << ": " << severity_name(diagnostic.severity) << ": "
               << diagnostic.message << '\n';

        const auto source_line = source.line(location.line);
        output << "  " << source_line << '\n' << "  ";
        for (std::size_t i = 1; i < location.column; ++i) {
            output << (source_line[i - 1] == '\t' ? '\t' : ' ');
        }
        const auto requested = diagnostic.span.end > diagnostic.span.begin
            ? diagnostic.span.end - diagnostic.span.begin
            : 1;
        const auto available = source_line.size() >= location.column - 1
            ? source_line.size() - (location.column - 1)
            : std::size_t{1};
        output << '^';
        for (std::size_t i = 1; i < std::min(requested, available); ++i) {
            output << '~';
        }
        output << '\n';
    }
}

} // namespace abla

