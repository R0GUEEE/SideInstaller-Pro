//! Shared C-string helpers for the FFI boundary.

use std::ffi::{c_char, CStr, CString};

/// Allocate a C string the caller frees with `si_string_free`. Escape interior
/// NUL bytes instead of silently losing the entire diagnostic at the FFI boundary.
pub fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    let bytes = s.into();
    match CString::new(bytes) {
        Ok(value) => value.into_raw(),
        Err(error) => {
            let bytes = error.into_vec();
            let mut escaped = Vec::with_capacity(bytes.len());
            for byte in bytes {
                if byte == 0 { escaped.extend_from_slice(b"\\0"); }
                else { escaped.push(byte); }
            }
            CString::new(escaped).expect("escaped bytes contain no NUL").into_raw()
        }
    }
}

/// Read a C string, falling back to `default` when null, empty or not UTF-8.
///
/// # Safety
/// `p` must be null or point to a valid NUL-terminated C string.
#[allow(dead_code)]
pub unsafe fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    match CStr::from_ptr(p).to_str() {
        Ok(s) if !s.is_empty() => s.to_string(),
        _ => default.to_string(),
    }
}

/// Read a required C string, returning `None` when null or invalid.
///
/// # Safety
/// `p` must be null or point to a valid NUL-terminated C string.
#[allow(dead_code)]
pub unsafe fn req_str(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(|s| s.to_string())
}

/// Free a heap C string previously produced by `cstr`.
///
/// # Safety
/// `p` must be null or a pointer returned by `cstr`/`into_raw`.
pub unsafe fn string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cstr_preserves_text_and_escapes_interior_nuls() {
        for (input, expected) in [
            ("ordinary", "ordinary"),
            ("", ""),
            ("\0start", "\\0start"),
            ("before\0after", "before\\0after"),
            ("end\0", "end\\0"),
            ("résumé\0✓", "résumé\\0✓"),
        ] {
            let ptr = cstr(input);
            unsafe {
                assert_eq!(CStr::from_ptr(ptr).to_str().unwrap(), expected);
                string_free(ptr);
            }
        }
    }
}
