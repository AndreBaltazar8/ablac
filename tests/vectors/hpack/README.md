# HPACK interoperability stories

`stories.txt` is a subset of [http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case) (commit `8a1406e7d14bfcb6c046021f13cc15cfb162726d`, MIT, see
`LICENSE`): stories 00 to 09 of each of the 14 encoder implementations in it (nghttp2 with and without table size changes, go-hpack, node-http2-hpack, python-hpack, the
Haskell http2 encoders, swift-nio-hpack), 1190 cases of header lists with the bytes an independent encoder made of them. The whole corpus is 40 MB in compact form; the
subset keeps the encoder variety (Huffman or not, indexing strategies, table size updates) at under 1 MB. `convert.mjs` makes the file from a clone:
`node convert.mjs <clone> 0 9 > stories.txt`. Fields are separated by 0x1f; see `convert.mjs` for the line format.

Used by `tests/cases/http2/hpack-corpus.ab` (tools/test-http2.sh): each story is decoded in order by one decoder (the dynamic table carries from case to case, as it does on a
connection) and every case must give back exactly the header list.
