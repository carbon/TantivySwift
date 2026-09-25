//! What JavaScript needs on top of the C ABI: a way to allocate the buffers it
//! passes in. Swift hands the library pointers to its own memory; JavaScript
//! can only write into the module's linear memory, so it allocates there first.

use std::alloc::{alloc, dealloc, Layout};

/// Allocate `len` bytes (at least one) for the caller to fill. Returns null if
/// the allocation fails. Release with `tantivy_dealloc` and the same `len`.
#[no_mangle]
pub extern "C" fn tantivy_alloc(len: usize) -> *mut u8 {
    match Layout::from_size_align(len.max(1), 1) {
        Ok(layout) => unsafe { alloc(layout) },
        Err(_) => std::ptr::null_mut(),
    }
}

/// Release a buffer from `tantivy_alloc`. `len` must be the length it was
/// allocated with.
#[no_mangle]
pub extern "C" fn tantivy_dealloc(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    if let Ok(layout) = Layout::from_size_align(len.max(1), 1) {
        unsafe { dealloc(ptr, layout) };
    }
}
