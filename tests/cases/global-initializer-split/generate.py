# Writes a program with large literal tables: one global array of rows of many fields
# (a generated catalog's shape) and many more array globals. Its checksum() reads
# every field. Usage: generate.py <module.ab> <native.ab>
import sys

# Enough array globals that the initializer passes the size it is cut from.
EXTRAS = 4500

fields = []
for index in range(60):
    kind = ("int", "f64", "string", "bool")[index % 4]
    fields.append((f"f{index}", kind))

def value(row, index, kind):
    if kind == "int":
        return str(row * 61 + index)
    if kind == "f64":
        return f"{row}.{index % 10}5"
    if kind == "string":
        return f'"row-{row}-field-{index}"'
    return "true" if (row + index) % 3 == 0 else "false"

lines = ["import \"abla/float\"", ""]
lines.append("class Inner(val label: string, val weight: int, val marks: array<int>)")
lines.append("class Row(" + ", ".join(f"val {name}: {kind}" for name, kind in fields) +
             ", val tags: array<string>, val inner: Inner)")
lines.append("")
lines.append("val rows: array<Row> = [")
for row in range(750):
    args = ", ".join(f"{name} = {value(row, i, kind)}" for i, (name, kind) in enumerate(fields))
    lines.append(f"    Row({args}, tags = [\"t{row}\", \"u{row}\"], "
                 f"inner = Inner(label = \"inner-{row}\", weight = {row % 17}, marks = [{row}, {row + 1}, {row + 2}])),")
lines.append("]")
for index in range(EXTRAS):
    numbers = ", ".join(str(index * 7 + n) for n in range(40))
    lines.append(f"val extra{index}: array<int> = [{numbers}]")
lines.append("")
lines.append("fun checksum(): int {")
lines.append("    var total = 0")
lines.append("    for (row in rows) {")
for name, kind in fields:
    if kind == "int":
        lines.append(f"        total = total + row.{name}")
    elif kind == "f64":
        lines.append(f"        total = total + f64ToInt(row.{name} * 10.0)")
    elif kind == "string":
        lines.append(f"        total = total + row.{name}.size")
    else:
        lines.append(f"        if (row.{name}) total = total + 1")
lines.append("        total = total + row.tags[1].size + row.inner.weight + row.inner.marks[2]")
lines.append("    }")
for index in range(EXTRAS):
    lines.append(f"    total = total + extra{index}[{index % 40}]")
lines.append("    total % 1000000007")
lines.append("}")
body = "\n".join(lines) + "\n"
with open(sys.argv[1], "w") as module:
    module.write(body + "\n@export(\"checksum\")\nfun exportedChecksum(): int = checksum()\n")
with open(sys.argv[2], "w") as native:
    native.write("import \"abla/io\"\n" + body + "\nfun main: int {\n    println(\"${checksum()}\")\n    0\n}\n")
