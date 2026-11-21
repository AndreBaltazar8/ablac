use std::ffi::{c_char, c_void, CString};
#[link(name = "pcre2-8")]
unsafe extern "C" {
    fn pcre2_compile_8(
        p: *const c_char,
        n: usize,
        flags: u32,
        error: *mut i32,
        at: *mut usize,
        ctx: *mut c_void,
    ) -> *mut c_void;
    fn pcre2_match_data_create_from_pattern_8(c: *mut c_void, ctx: *mut c_void) -> *mut c_void;
    fn pcre2_match_8(
        c: *mut c_void,
        s: *const u8,
        n: usize,
        at: usize,
        flags: u32,
        md: *mut c_void,
        ctx: *mut c_void,
    ) -> i32;
    fn pcre2_get_ovector_pointer_8(md: *mut c_void) -> *mut usize;
    fn pcre2_match_data_free_8(md: *mut c_void);
    fn pcre2_code_free_8(c: *mut c_void);
}
struct Regex {
    c: *mut c_void,
    md: *mut c_void,
}
impl Regex {
    fn new(p: &str) -> Self {
        let s = CString::new(p).unwrap();
        let (mut e, mut at) = (0, 0);
        unsafe {
            let c = pcre2_compile_8(
                s.as_ptr(),
                p.len(),
                0,
                &mut e,
                &mut at,
                std::ptr::null_mut(),
            );
            assert!(!c.is_null());
            let md = pcre2_match_data_create_from_pattern_8(c, std::ptr::null_mut());
            Self { c, md }
        }
    }
    fn find(&self, s: &[u8], at: usize) -> Option<(usize, usize)> {
        unsafe {
            let r = pcre2_match_8(
                self.c,
                s.as_ptr(),
                s.len(),
                at,
                0,
                self.md,
                std::ptr::null_mut(),
            );
            if r == -1 {
                return None;
            }
            assert!(r >= 0);
            let v = pcre2_get_ovector_pointer_8(self.md);
            Some((*v, *v.add(1)))
        }
    }
    fn replace(&self, s: &[u8], r: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut at = 0;
        while let Some((start, end)) = self.find(s, at) {
            out.extend_from_slice(&s[at..start]);
            out.extend_from_slice(r);
            at = end;
        }
        out.extend_from_slice(&s[at..]);
        out
    }
}
impl Drop for Regex {
    fn drop(&mut self) {
        unsafe {
            pcre2_match_data_free_8(self.md);
            pcre2_code_free_8(self.c);
        }
    }
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = std::fs::read(&args[2]).unwrap();
    let mut s = Regex::new(">[^\n]*\n|\n").replace(&input, b"");
    let cleaned = s.len();
    let patterns = [
        "agggtaaa|tttaccct",
        "[cgt]gggtaaa|tttaccc[acg]",
        "a[act]ggtaaa|tttacc[agt]t",
        "ag[act]gtaaa|tttac[agt]ct",
        "agg[act]taaa|ttta[agt]cct",
        "aggg[acg]aaa|ttt[cgt]ccct",
        "agggt[cgt]aa|tt[acg]accct",
        "agggta[cgt]a|t[acg]taccct",
        "agggtaa[cgt]|[acg]ttaccct",
    ];
    for p in patterns {
        let re = Regex::new(p);
        let (mut count, mut at) = (0, 0);
        while let Some((_, end)) = re.find(&s, at) {
            count += 1;
            at = end;
        }
        println!("{} {}", p, count);
    }
    let patterns = [
        "tHa[Nt]",
        "aND|caN|Ha[DS]|WaS",
        "a[NSt]|BY",
        "<[^>]*>",
        "\\|[^|][^|]*\\|",
    ];
    let replacements = ["<4>", "<3>", "<2>", "|", "-"];
    for i in 0..5 {
        s = Regex::new(patterns[i]).replace(&s, replacements[i].as_bytes());
    }
    println!("\n{}\n{}\n{}", input.len(), cleaned, s.len());
}
