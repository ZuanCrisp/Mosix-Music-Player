use cap_std::fs::Dir;
use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Storage::FileSystem::MoveFileExW;

/// Publish within the opened parent without requiring hard-link support from
/// the destination filesystem. A concurrent publisher must never be replaced.
#[allow(unsafe_code)] // One Windows call with owned, NUL-terminated paths.
pub(super) fn publish_new(parent: &Dir, name: &str, target: &OsStr) -> io::Result<()> {
    fn wide(path: &Path) -> io::Result<Vec<u16>> {
        let mut units: Vec<_> = path.as_os_str().encode_wide().collect();
        if units.contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "NUL in file path",
            ));
        }
        units.push(0);
        Ok(units)
    }

    // Use the directory handle's current path, as cap-std does for rename.
    // Retain the verbatim prefix for UNC shares and paths beyond MAX_PATH.
    let directory = parent.try_clone()?.into_std_file();
    let path = winx::file::get_file_path(&directory)?;
    let source = wide(&path.join(name))?;
    let destination = wide(&path.join(target))?;
    // SAFETY: Both buffers are NUL-terminated and live throughout the call.
    // Omitting REPLACE_EXISTING makes the existence check part of the rename;
    // omitting COPY_ALLOWED keeps publication on the destination filesystem.
    if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 0) } == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
