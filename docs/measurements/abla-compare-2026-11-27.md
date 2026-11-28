# HTTP server throughput across releases (2026-11-27)

The `abla-compare` HTTP benchmark (21 scenarios, an Abla web server against Go, Rust and Zig
peers), rerun on 2026-11-27 against its 2026-11-06 baseline to look for regressions.

Method: an i9-13900K (CPUs 12 and 13 offline), Linux 6.17.3, pinned nixpkgs 6510408d, the
server inputs frozen at one `abla.lock`; `oha` with 64 connections, 3 s warm-up and three
10 s runs, the median shown; the machine otherwise idle. Compilers: v0.2.46 (its compiler
matches the baseline's, so it is the control), v0.2.78 and master 3045428c2. The peers were
not rerun; "best peer" is the 2026-11-06 figure.

Requests per second, one server worker (selected scenarios):

| scenario | 2026-11-06 | best peer | v0.2.46 now | v0.2.78 | master 3045428c2 |
|---|--:|--:|--:|--:|--:|
| plaintext | 333,399 | 276,928 | 315,982 | 301,807 | 292,525 |
| parameters | 276,924 | 308,076 | 303,830 | 284,607 | 287,718 |
| context | 289,434 | 269,362 | 294,411 | 273,551 | 266,633 |
| body-16k | 176,454 | 146,070 | 178,787 | 137,217 | 132,746 |
| headers-32 | 217,171 | 255,180 | 227,165 | 227,625 | 212,182 |
| json-items-128 | 82,045 | 45,420 | 82,902 | 75,896 | 67,562 |
| json-strings-4k | 91,781 | 120,887 | 92,388 | 138,601 | 138,216 |
| body-64k | 67,207 | 62,425 | 68,187 | 65,659 | 65,498 |

Abla led the 2026-11-06 peers in 17 of 21 scenarios then, and in 16 with v0.2.78 and
master. With six workers and 256 connections, plaintext was 1,717,173 (2026-11-06) and
1,700,086 (v0.2.78), body-16k 971,566 and 802,183.

What was found, counting user instructions per request (`perf stat -e instructions:u` on
the server while `oha` sends a fixed number of requests over one connection, which is
steady under load where requests per second are not):

- body-16k lost 23% from v0.2.66: the server read a body with a checked word-copy loop
  (83% of its instructions). v0.2.79 copies it in one memory copy (0b5fcacc7): 70,000 to
  13,000 instructions per request.
- plaintext went from 8,500 instructions per request (v0.2.46 to v0.2.53) to 10,900
  (master): the Host header check and the event deadlines (both v0.2.69, about +3% each)
  are hardening, not bugs. v0.2.80 takes back part of it (seven changes, -1.5% to -4.3%
  each, and the vDSO clock).
- A rerun on master after those changes (2026-11-27, 21:12 UTC) gave plaintext 312,275,
  body-16k 177,933 and json-strings-4k 165,135 requests per second.
