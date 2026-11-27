# Groups the cases where the two decoders disagree (fields: case, Go, Abla): "stricter" (Abla refuses a block Go takes: RFC 7541 rules Go relaxes and
# Abla's tighter integer and huffman length limits) is counted; "looser" and "different" (other fields) are printed to standard error: findings.
BEGIN { FS = "\t" }
$2 != $3 {
  ng = split($2, g, "|"); na = split($3, a, "|")
  kind = "different"
  # walk blocks; first block where they differ
  for (i = 1; i <= (ng > na ? ng : na); i++) {
    if (g[i] == a[i]) continue
    if (a[i] == "E" && g[i] != "E") kind = "stricter"
    else if (g[i] == "E" && a[i] != "E") kind = "looser"
    else kind = "different"
    break
  }
  count[kind]++
  if (kind != "stricter") print kind "\t" $1 "\t" $2 "\t" $3 > "/dev/stderr"
}
END { for (k in count) print k, count[k] }
