#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    Exited(i32),
    Signaled(i32),
}

#[cfg(not(target_os = "ios"))]
mod desktop;
#[cfg(not(target_os = "ios"))]
pub use desktop::*;
