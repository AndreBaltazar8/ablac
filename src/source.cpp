#include "abla/source.hpp"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace abla {

SourceFile::SourceFile(std::string path, std::string text)
    : path_(std::move(path)), text_(std::move(text)), line_starts_{0} {
    for (std::size_t i = 0; i < text_.size(); ++i) {
        if (text_[i] == '\n') {
            line_starts_.push_back(i + 1);
        }
    }
}

SourceFile SourceFile::read(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot open source file '" + path.string() + "'");
    }
    std::string text{
        std::istreambuf_iterator<char>(stream),
        std::istreambuf_iterator<char>()};
    if (stream.bad()) {
        throw std::runtime_error("cannot read source file '" + path.string() + "'");
    }
    return SourceFile(path.string(), std::move(text));
}

std::string_view SourceFile::slice(SourceSpan span) const {
    const auto begin = std::min(span.begin, text_.size());
    const auto end = std::min(std::max(span.end, begin), text_.size());
    return std::string_view(text_).substr(begin, end - begin);
}

SourceLocation SourceFile::location(std::size_t offset) const {
    offset = std::min(offset, text_.size());
    const auto after = std::upper_bound(line_starts_.begin(), line_starts_.end(), offset);
    const auto index = static_cast<std::size_t>(
        std::distance(line_starts_.begin(), after) - 1);
    return SourceLocation{offset, index + 1, offset - line_starts_[index] + 1};
}

std::string_view SourceFile::line(std::size_t one_based_line) const {
    if (one_based_line == 0 || one_based_line > line_starts_.size()) {
        return {};
    }
    const auto begin = line_starts_[one_based_line - 1];
    auto end = one_based_line < line_starts_.size()
        ? line_starts_[one_based_line] - 1
        : text_.size();
    if (end > begin && text_[end - 1] == '\r') {
        --end;
    }
    return std::string_view(text_).substr(begin, end - begin);
}

} // namespace abla
