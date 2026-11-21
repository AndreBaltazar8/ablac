use std::ffi::{c_char, c_void, CStr, CString};
#[link(name = "json-c")]
unsafe extern "C" {
    fn json_tokener_parse(s: *const c_char) -> *mut c_void;
    fn json_object_to_json_string_ext(v: *mut c_void, flags: i32) -> *const c_char;
    fn json_object_put(v: *mut c_void) -> i32;
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let n: usize = args[1].parse().unwrap();
    let input = CString::new(std::fs::read(&args[2]).unwrap()).unwrap();
    for i in 0..n {
        unsafe {
            let v = json_tokener_parse(input.as_ptr());
            assert!(!v.is_null());
            let out = json_object_to_json_string_ext(v, 0);
            if i == n - 1 {
                println!("{}", CStr::from_ptr(out).to_str().unwrap());
            }
            json_object_put(v);
        }
    }
}
