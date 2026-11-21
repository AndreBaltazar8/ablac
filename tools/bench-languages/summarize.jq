def stats:
  if length == 0 then error("missing measurement samples") else
    sort | {
      median: (if length % 2 == 1 then .[length / 2 | floor]
               else (.[length / 2 - 1] + .[length / 2]) / 2 end),
      min: .[0], max: .[-1]
    }
  end;
def ratio($baseline): if $baseline > 0 then . / $baseline else null end;

. as $data |
($data.samples | group_by(.program) | map({
  key: .[0].program,
  value: {languages: (group_by(.language) | map({
    key: .[0].language,
    value: {
      status: "verified",
      wallSeconds: ([.[] | select(.kind == "runtime") | .wallSeconds] | stats),
      rssBytes: ([.[] | select(.kind == "runtime") | .rssBytes] | stats),
      compileSeconds: ([.[] | select(.kind == "compile") | .wallSeconds] | stats),
      rawBytes: ([.[] | select(.kind == "size") | .rawBytes][0]),
      strippedBytes: ([.[] | select(.kind == "size") | .strippedBytes][0])
    } + (if .[0].program == "hello" then {
      startupSeconds: ([.[] | select(.kind == "startup") | .wallSeconds] | stats)
    } else {} end) + (if .[0].program == "http-echo" then {
      requestsPerSecond: ([.[] | select(.kind == "runtime") | .requestsPerSecond] | stats)
    } else {} end)
  }) | from_entries)}
}) | from_entries) as $programs |
$data + {programs: ($programs | with_entries(
  .value.languages as $langs |
  .value.languages |= with_entries(.value += {ratiosToC: ({
    wallSeconds: (.value.wallSeconds.median | ratio($langs.c.wallSeconds.median)),
    rssBytes: (.value.rssBytes.median | ratio($langs.c.rssBytes.median)),
    compileSeconds: (.value.compileSeconds.median | ratio($langs.c.compileSeconds.median)),
    strippedBytes: (.value.strippedBytes | ratio($langs.c.strippedBytes))
  } + (if .value | has("startupSeconds") then {
    startupSeconds: (.value.startupSeconds.median | ratio($langs.c.startupSeconds.median))
  } else {} end) + (if .value | has("requestsPerSecond") then {
    requestsPerSecond: (.value.requestsPerSecond.median | ratio($langs.c.requestsPerSecond.median))
  } else {} end))})
))}
