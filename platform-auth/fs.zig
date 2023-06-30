const std = @import("std");
const cbor = @import("zbor");
const cks = @import("cks");

var store: ?cks.CKS = null;

pub fn load(a: std.mem.Allocator, pw: []const u8) !void {
    var dir = std.fs.cwd();

    var file = dir.openFile("passkey.cks", .{ .mode = .read_write }) catch {
        store = try cks.CKS.new(
            1,
            0,
            .ChaCha20,
            .None,
            .Argon2id,
            "PassKeyZ",
            "DB1",
            a,
            std.crypto.random,
            std.time.milliTimestamp,
        );

        var id = try a.alloc(u8, "Settings".len);
        @memcpy(id, "Settings");
        var settings = cks.Entry.new(id, std.time.milliTimestamp());
        try settings.addField(.{ .key = "Retries", .value = "\x08" }, std.time.milliTimestamp(), a);
        try store.?.addEntry(settings);
        return;
    };

    const data = try file.readToEndAlloc(a, 64000);
    defer a.free(data);

    store = try cks.CKS.open(
        data,
        pw,
        a,
        std.crypto.random,
        std.time.milliTimestamp,
    );
}

/// This function MOST NOT be called if a `load` has failed!
pub fn get() *cks.CKS {
    return &store.?;
}

pub fn writeBack(pw: []const u8) !void {
    var dir = std.fs.cwd();

    var file = dir.openFile("passkey.cks", .{ .mode = .read_write }) catch blk: {
        break :blk try dir.createFile("passkey.cks", .{});
    };

    try store.?.seal(file.writer(), pw);
}
