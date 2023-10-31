const std = @import("std");
const client = @import("client");
const authenticatorGetInfo = client.cbor_commands.authenticatorGetInfo;
const client_pin = client.cbor_commands.client_pin;
const cred_management = client.cbor_commands.cred_management;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

pub fn main() !void {
    {
        var transports = try client.Transports.enumerate(allocator, .{});
        defer transports.deinit();

        for (transports.devices) |*device| {
            var x = try device.allocPrint(allocator);
            defer allocator.free(x);
            std.log.info("{s}", .{x});
        }

        if (transports.devices.len > 0) {
            try transports.devices[0].open();
            defer transports.devices[0].close();
            const info = try authenticatorGetInfo(&transports.devices[0], allocator);
            defer info.deinit(allocator);
            std.log.info("info: {any}", .{info});

            var enc = try client_pin.getKeyAgreement(&transports.devices[0], .V2, allocator);
            defer enc.deinit();
            std.log.info("shared secret: {any}", .{enc});

            var token = try client_pin.getPinToken(&transports.devices[0], &enc, "password", allocator);
            defer allocator.free(token);
            std.log.info("token: {s}", .{std.fmt.fmtSliceHexLower(token)});

            var rp = try cred_management.enumerateRPsBegin(&transports.devices[0], .V2, token, allocator, true);
            if (rp) |_rp| {
                defer _rp.deinit();
                std.log.info("id: {s}", .{_rp.rp.id});
            } else {
                std.log.info("no RPs", .{});
            }
        }
    }

    //if (gpa.detectLeaks()) {
    //    std.log.info("leak", .{});
    //}
}
