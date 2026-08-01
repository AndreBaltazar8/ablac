#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace abla {

struct SourceLocation {
    std::size_t offset{};
    std::size_t line{1};
    std::size_t column{1};
};

struct SourceSpan {
    std::size_t begin{};
    std::size_t end{};

    [[nodiscard]] bool empty() const noexcept { return begin == end; }
};

class SourceFile {
public:
    SourceFile(std::string path, std::string text);

    [[nodiscard]] static SourceFile read(const std::filesystem::path& path);
    [[nodiscard]] const std::string& path() const noexcept { return path_; }
    [[nodiscard]] const std::string& text() const noexcept { return text_; }
    [[nodiscard]] std::string_view slice(SourceSpan span) const;
    [[nodiscard]] SourceLocation location(std::size_t offset) const;
    [[nodiscard]] std::string_view line(std::size_t one_based_line) const;

private:
    std::string path_;
    std::string text_;
    std::vector<std::size_t> line_starts_;
};

} // namespace abla

