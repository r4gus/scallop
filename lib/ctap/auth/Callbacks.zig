//! Callbacks provided by the underlying platform/ the user
//!
//! The callbacks are required to keep the library platform
//! agnostic.

const std = @import("std");
const fido = @import("../../main.zig");
const cks = @import("cks");

pub const Error = enum(i32) {
    SUCCESS = 0,
    DoesAlreadyExist = -1,
    DoesNotExist = -2,
    KeyStoreFull = -3,
    OutOfMemory = -4,
    Timeout = -5,
    Other = -6,
};

/// Result value of the `up` callback
pub const UpResult = enum(i32) {
    /// The user has denied the action
    Denied = 0,
    /// The user has accepted the action
    Accepted = 1,
    /// The user presence check has timed out
    Timeout = 2,
};

pub const DataIterator = struct {
    d: [*c][*c]u8 = 0,
    i: usize = 0,
    allocator: std.mem.Allocator,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.d == null) return null;

        if (self.d[self.i] == null) {
            return null;
        } else {
            defer self.i += 1;
            return self.d[self.i][0..strlen(self.d[self.i])];
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.d == null) return;

        var i: usize = 0;
        while (self.d[i] != null) {
            var x = self.d[i];
            // First overwrite the region with random data. This prevents sensitive information
            // from lingering in memory for longer than neccessary.
            std.crypto.random.bytes(x[0..strlen(x)]);
            // Then free the memory
            self.allocator.free(x[0 .. strlen(x) + 1]);
            i += 1;
            x = self.d[i];
        }
        self.allocator.free(self.d[0 .. i + 1]);
    }
};

inline fn strlen(s: [*c]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

// +++++++++++++++++++++++++++++++++++++++++++++++++++
// Callback Types
// +++++++++++++++++++++++++++++++++++++++++++++++++++

/// Type of the User Verification (UV) callback
///
/// This callback can be backed by ANY form of
/// user verification like a password, finger
/// print, ...
pub const UvCallback = ?*const fn () callconv(.C) UpResult;

pub const UpCallback = *const fn (
    /// Information about the context (e.g., make credential)
    info: [*c]const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: [*c]const u8,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: [*c]const u8,
) callconv(.C) UpResult;

/// Select a resident key for a user associated with the given RP ID
///
/// Returns either the index of the user (starting from 0) or `Error.Timeout`.
pub const SelectDiscoverableCredentialCallback = ?*const fn (
    rpId: [*c]const u8,
    users: [*c][*c]const u8,
) callconv(.C) i32;

/// Read the data associated with `id` and `rp` into out
///
/// The callback MUST not copy more than `out_len` bytes into `out`.
///
/// ## Argument options
///
/// * `id = null` and `rp = null` - Return all credential entries.
/// * `id != null` and `rp = null` - Return the entry with the specified `id`. This can be a credential or settings.
/// * `id = null` and `rp != null` - Return all credentials associated with the given `rp` ID.
pub const ReadCallback = *const fn (
    id: [*c]const u8,
    rp: [*c]const u8,
    out: *[*c][*c]u8,
) callconv(.C) Error;

/// Write `data` to permanent storage (e.g., database, filesystem, ...)
///
/// Returns either Error.SUCCESS on success or an error.
///
/// ## Argument options
///
/// * `id = null` and `rp = null` - Return all credential entries.
/// * `id != null` and `rp = null` - Return the entry with the specified `id`. This can be a credential or settings.
/// * `id = null` and `rp != null` - Return all credentials associated with the given `rp` ID.
pub const CreateCallback = *const fn (
    id: [*c]const u8,
    rp: [*c]const u8,
    data: [*c]const u8,
) callconv(.C) Error;

/// Delete the entry with the given `id`
///
/// Returns either Error.SUCCESS on success or an error.
pub const DeleteCallback = *const fn (
    id: [*c]const u8,
) callconv(.C) Error;

// +++++++++++++++++++++++++++++++++++++++++++++++++++
// Callbacks
// +++++++++++++++++++++++++++++++++++++++++++++++++++

pub const Callbacks = extern struct {
    /// Request user presence
    up: UpCallback,

    /// User verification callback
    ///
    /// This callback should execute a built-in user verification method.
    ///
    /// This callback is optional. Client request with the uv flag set will
    /// fail if this callback isn't provided.
    ///
    /// Possible methods are:
    /// - Password
    /// - Finger print sensor
    /// - Pattern
    uv: UvCallback,

    /// Let the user select one of the given `users` credentials
    select: SelectDiscoverableCredentialCallback = null,

    read: ReadCallback,
    write: CreateCallback,
    delete: DeleteCallback,
};
