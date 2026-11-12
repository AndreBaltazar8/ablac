# Writes the body of a program with large literal tables: one global array of rows of
# many fields (a generated catalog's shape) and many more array globals. Its
# checksum() reads every field. Usage: awk -f generate.awk > body.ab
function value(row, index_, kind) {
    if (kind == "int") return row * 61 + index_
    if (kind == "f64") return row "." (index_ % 10) "5"
    if (kind == "string") return "\"row-" row "-field-" index_ "\""
    return ((row + index_) % 3 == 0) ? "true" : "false"
}
BEGIN {
    # Enough array globals that the initializer passes the size it is cut from.
    EXTRAS = 4500
    split("int f64 string bool", kinds, " ")
    for (i = 0; i < 60; i++) { name[i] = "f" i; kind[i] = kinds[i % 4 + 1] }
    print "import \"abla/float\""
    print ""
    print "class Inner(val label: string, val weight: int, val marks: array<int>)"
    declaration = "class Row("
    for (i = 0; i < 60; i++) declaration = declaration (i ? ", " : "") "val " name[i] ": " kind[i]
    print declaration ", val tags: array<string>, val inner: Inner)"
    print ""
    print "val rows: array<Row> = ["
    for (row = 0; row < 750; row++) {
        args = ""
        for (i = 0; i < 60; i++) args = args (i ? ", " : "") name[i] " = " value(row, i, kind[i])
        print "    Row(" args ", tags = [\"t" row "\", \"u" row "\"], inner = Inner(label = \"inner-" row "\", weight = " row % 17 ", marks = [" row ", " row + 1 ", " row + 2 "])),"
    }
    print "]"
    for (index_ = 0; index_ < EXTRAS; index_++) {
        numbers = ""
        for (n = 0; n < 40; n++) numbers = numbers (n ? ", " : "") index_ * 7 + n
        print "val extra" index_ ": array<int> = [" numbers "]"
    }
    print ""
    print "fun checksum(): int {"
    print "    var total = 0"
    print "    for (row in rows) {"
    for (i = 0; i < 60; i++) {
        if (kind[i] == "int") print "        total = total + row." name[i]
        else if (kind[i] == "f64") print "        total = total + f64ToInt(row." name[i] " * 10.0)"
        else if (kind[i] == "string") print "        total = total + row." name[i] ".size"
        else print "        if (row." name[i] ") total = total + 1"
    }
    print "        total = total + row.tags[1].size + row.inner.weight + row.inner.marks[2]"
    print "    }"
    for (index_ = 0; index_ < EXTRAS; index_++) print "    total = total + extra" index_ "[" index_ % 40 "]"
    print "    total % 1000000007"
    print "}"
}
