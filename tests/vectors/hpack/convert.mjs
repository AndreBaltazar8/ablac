// Makes stories.txt from a clone of https://github.com/http2jp/hpack-test-case: node convert.mjs <clone> <first story> <last story> > stories.txt
// One line per case: story, sequence number, header table size ("" when the case sets none), the wire bytes in hex, then name and value of each header, all fields
// separated by 0x1f (US). The raw-data directory (the headers without a wire form) is left out. Names and values with 0x1f or a line break are refused.
import fs from 'node:fs'
const root = process.argv[2], first = +process.argv[3], last = +process.argv[4]
const impls = fs.readdirSync(root).filter(d => fs.existsSync(`${root}/${d}/story_00.json`) && d !== 'raw-data').sort()
const bad = /[\x1f\n\r]/
let out = '', cases = 0
for (const impl of impls) {
  for (let n = first; n <= last; n++) {
    const name = `story_${String(n).padStart(2, '0')}`
    if (!fs.existsSync(`${root}/${impl}/${name}.json`)) continue
    const story = JSON.parse(fs.readFileSync(`${root}/${impl}/${name}.json`, 'utf8'))
    for (const c of story.cases) {
      const fields = [`${impl}/${name}`, String(c.seqno), c.header_table_size === undefined ? '' : String(c.header_table_size), c.wire]
      for (const o of c.headers) {
        const k = Object.keys(o)[0]
        if (bad.test(k) || bad.test(o[k])) throw new Error(`${impl}/${name} ${c.seqno}: a separator in a header`)
        fields.push(k, o[k])
      }
      out += fields.join('\x1f') + '\n'
      cases++
    }
  }
}
process.stdout.write(out)
console.error(`${impls.length} implementations, ${cases} cases`)
