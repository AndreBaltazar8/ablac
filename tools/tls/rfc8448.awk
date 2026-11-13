# Extracts "{peer} heading" blocks and their "name (N octets): hex" values from an RFC 8448 section.
function flush() { if (name != "") { gsub(/[ \t]+/, "", hex); print section "|" heading "|" name "|" hex } name = ""; hex = "" }
{ sub(/^\f/, "") }
/^RFC 8448 / || /^Thomson / { next }
/^   \{(client|server)\} / {
    flush(); h = $0; sub(/^   /, "", h); sub(/:$/, "", h); heading = h; next
}
/^      [A-Za-z][A-Za-z0-9 ,.()\/-]*\([0-9]+ octets\): / {
    flush()
    line = $0; sub(/^      /, "", line)
    p = index(line, " octets):")
    name = substr(line, 1, p - 1); sub(/ *\([0-9]+$/, "", name)
    hex = substr(line, p + 10)
    next
}
/^      [A-Za-z][A-Za-z0-9 ,.()\/-]*:  / && name == "" {
    # a value like "salt:  0 (all zero octets)" (not hex): skip
    next
}
/^         [0-9a-f][0-9a-f]( [0-9a-f][0-9a-f])*$/ && name != "" { hex = hex " " $0; next }
/^$/ { next }
{ flush() }
END { flush() }
