/// Client to Authenticator (CTAP) library
const std = @import("std");

pub const ctaphid = @import("ctaphid.zig");

pub const crypt = @import("crypto.zig");
pub const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Ecdsa = crypt.ecdsa.EcdsaP256Sha256;
pub const KeyPair = Ecdsa.KeyPair;
pub const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
pub const EcdhP256 = crypt.ecdh.EcdhP256;
pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Aes256 = std.crypto.core.aes.Aes256;

pub const ms_length = Hmac.mac_length;
pub const pin_len: usize = 16;
// VALID || MASTER_SECRET || PIN || CTR || RETRIES || padding
pub const data_len = 1 + ms_length + pin_len + 4 + 1 + 2;

const dobj = @import("dobj.zig");

pub const Versions = dobj.Versions;
pub const User = dobj.User;
pub const RelyingParty = dobj.RelyingParty;

const cbor = @import("zbor");
const cose = cbor.cose;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const DataItem = cbor.DataItem;
const Pair = cbor.Pair;

const commands = @import("commands.zig");
pub const Commands = commands.Commands;
const getCommand = commands.getCommand;
const MakeCredentialParam = commands.make_credential.MakeCredentialParam;
const GetAssertionParam = commands.get_assertion.GetAssertionParam;
const GetAssertionResponse = commands.get_assertion.GetAssertionResponse;
const extension = @import("extensions.zig");
pub const Extensions = extension.Extensions;
const PinProtocol = commands.client_pin.PinProtocol;
const ClientPinParam = commands.client_pin.ClientPinParam;
const ClientPinResponse = commands.client_pin.ClientPinResponse;
const PinUvAuthTokenState = commands.client_pin.PinUvAuthTokenState;
const PinConf = commands.client_pin.PinConf;

const data_module = @import("data.zig");

pub const AttType = enum {
    /// In this case, no attestation information is available.
    none,
    /// In the case of self attestation, also known as surrogate basic attestation [UAFProtocol], the
    /// Authenticator does not have any specific attestation key pair. Instead it uses the credential private key
    /// to create the attestation signature. Authenticators without meaningful protection measures for an
    /// attestation private key typically use this attestation type.
    self,
};

pub const AttestationType = struct {
    att_type: AttType = AttType.self,
};

pub fn Auth(comptime impl: type) type {
    return struct {
        const Self = @This();

        /// General properties of the given authenticator.
        info: dobj.Info,
        /// Attestation type to be used for attestation.
        attestation_type: AttestationType,

        /// Default initialization without extensions.
        pub fn initDefault(aaguid: [16]u8) Self {
            return @This(){
                .info = dobj.Info{
                    .@"1" = &[_]Versions{Versions.FIDO_2_1},
                    .@"2" = null,
                    .@"3" = aaguid,
                    .@"4" = dobj.Options{
                        .clientPin = true,
                        .pinUvAuthToken = true,
                    }, // default options
                    .@"5" = null,
                    .@"#6" = &[_]PinProtocol{.v2},
                },
                .attestation_type = AttestationType{},
            };
        }

        // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        // Interface
        // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        pub fn loadData(allocator: std.mem.Allocator) !data_module.PublicData {
            var d = impl.load(allocator);
            defer allocator.free(d);
            return try cbor.parse(data_module.PublicData, try cbor.DataItem.new(d), .{ .allocator = allocator });
        }

        pub fn storeData(data: *const data_module.PublicData) void {
            // Lets allocate the required memory on the stack for data
            // serialization.
            var raw: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&raw);
            const allocator = fba.allocator();
            var arr = std.ArrayList(u8).init(allocator);
            defer arr.deinit();
            var writer = arr.writer();

            // reserve bytes for cbor size
            writer.writeAll("\x00\x00\x00\x00") catch unreachable;

            // Serialize PublicData to cbor
            cbor.stringify(data, .{}, writer) catch unreachable;

            // Prepend size. This might help reading back the data if no
            // underlying file system is available.
            const len = @intCast(u32, arr.items.len - 4);
            std.mem.writeIntSliceLittle(u32, arr.items[0..4], len);

            // Now store `SIZE || CBOR`
            impl.store(arr.items[0..]);
        }

        pub fn millis(self: *const Self) u32 {
            _ = self;
            return impl.millis();
        }

        /// This function asks the user in some way for permission,
        /// e.g. button press, touch, key press.
        ///
        /// It returns `true` if permission has been granted, `false`
        /// otherwise (e.g. timeout).
        pub fn requestPermission(user: ?*const dobj.User, rp: ?*const dobj.RelyingParty) bool {
            return impl.requestPermission(user, rp);
        }

        /// Fill the given slice with random data.
        pub fn getBlock(buffer: []u8) void {
            var r: u32 = undefined;

            var i: usize = 0;
            while (i < buffer.len) : (i += 1) {
                if (i % 4 == 0) {
                    // Get a fresh 32 bit integer every 4th iteration.
                    r = impl.rand();
                }

                // The shift value is always between 0 and 24, i.e. int cast will always succeed.
                buffer[i] = @intCast(u8, (r >> @intCast(u5, (8 * (i % 4)))) & 0xff);
            }
        }

        pub fn reset(allocator: std.mem.Allocator, ctr: [12]u8) void {
            const default_pin = "candystick";

            // Prepare secret data
            var secret_data: data_module.SecretData = undefined;
            secret_data.master_secret = crypt.createMasterSecret(getBlock);
            secret_data.pin_hash = crypt.pinHash(default_pin);
            secret_data.pin_length = default_pin.len;
            secret_data.sign_ctr = 0;

            // Prepare public data
            var public_data: data_module.PublicData = undefined;
            defer public_data.deinit(allocator);
            public_data.meta.valid = 0xF1;
            getBlock(public_data.meta.salt[0..]);
            //public_data.meta.salt = "\xcd\xb1\xa6\x1b\xc0\x54\x7a\x3e\x4c\xa7\x61\x88\x4a\xad\x3d\x9f\xfd\x1d\xb1\x16\x77\x71\xf3\x22\x51\x1c\x5a\x42\x16\x2c\x27\xc0".*;
            public_data.meta.nonce_ctr = ctr;
            public_data.meta.pin_retries = 8;

            // Derive key from pin
            const key = Hkdf.extract(public_data.meta.salt[0..], secret_data.pin_hash[0..]);

            // Encrypt secret data
            public_data.c = data_module.encryptSecretData(
                allocator,
                &public_data.tag,
                &secret_data,
                key,
                public_data.meta.nonce_ctr,
            ) catch unreachable;

            storeData(&public_data);
        }

        // TODO: is this function redundant after the last change?
        pub fn initData(self: *const Self) void {
            _ = self;
            var raw: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&raw);
            const allocator = fba.allocator();

            _ = loadData(allocator) catch {
                reset(allocator, [_]u8{0} ** 12);
                return;
            };
        }

        // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        // CTAP Handler
        // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        /// Main handler function, that takes a command and returns a response.
        pub fn handle(self: *const Self, allocator: Allocator, command: []const u8) ![]u8 {
            // The response message.
            // For encodings see: https://fidoalliance.org/specs/fido-v2.0-ps-20190130/fido-client-to-authenticator-protocol-v2.0-ps-20190130.html#responses
            var res = std.ArrayList(u8).init(allocator);
            var response = res.writer();
            try response.writeByte(0x00); // just overwrite if neccessary

            const cmdnr = getCommand(command) catch |err| {
                // On error, respond with a error code and return.
                try response.writeByte(@enumToInt(dobj.StatusCodes.fromError(err)));
                return res.toOwnedSlice();
            };

            const S = struct {
                var initialized: bool = false;
                var state: PinUvAuthTokenState = .{};
            };

            // At power-up, the authenticator calls initialize for each
            // pinUvAuthProtocol that it supports.
            if (!S.initialized) {
                S.state.initialize(getBlock);
                S.initialized = true;
            }

            S.state.pinUvAuthTokenUsageTimerObserver(self.millis());

            // Load authenticator data
            var write_back = true; // This gets overwritten by authReset
            var reset_token = false; // This gets overwirtten by changePin
            var data = loadData(allocator) catch {
                reset(allocator, [_]u8{0} ** 12);

                res.items[0] = @enumToInt(dobj.StatusCodes.ctap1_err_other);
                return res.toOwnedSlice(); // TODO: handle properly
            };
            var secret_data: ?data_module.SecretData = null;
            if (S.state.pin_key) |key| {
                secret_data = data_module.decryptSecretData(
                    allocator,
                    data.c,
                    data.tag[0..],
                    key,
                    data.meta.nonce_ctr,
                ) catch null;
            }
            defer {
                if (write_back) {
                    if (secret_data) |*sd| {
                        // Update nonce counter
                        var nctr: u96 = std.mem.readIntSliceLittle(u96, data.meta.nonce_ctr[0..]);
                        nctr += 1;
                        var nctr_raw: [12]u8 = undefined;
                        std.mem.writeIntSliceLittle(u96, nctr_raw[0..], nctr);

                        // Encrypt data
                        var tmp_tag: [16]u8 = undefined;
                        const tmp_c = data_module.encryptSecretData(
                            allocator,
                            &tmp_tag,
                            sd,
                            S.state.pin_key.?,
                            nctr_raw,
                        ) catch unreachable;

                        allocator.free(data.c);
                        data.c = tmp_c;
                        std.mem.copy(u8, data.tag[0..], tmp_tag[0..]);
                        data.meta.nonce_ctr = nctr_raw;
                    }

                    // Write data back into long term storage
                    storeData(&data);
                }
                // Free dynamically allocated memory. data must
                // not be used after this.
                data.deinit(allocator);

                if (reset_token) {
                    S.state.resetPinUvAuthToken(getBlock);
                }
            }

            switch (cmdnr) {
                .authenticator_make_credential => {
                    const mcp_raw = cbor.DataItem.new(command[1..]) catch {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_invalid_cbor);
                        return res.toOwnedSlice();
                    };
                    const mcp = cbor.parse(MakeCredentialParam, mcp_raw, .{ .allocator = allocator }) catch |err| {
                        const x = switch (err) {
                            error.MissingField => dobj.StatusCodes.ctap2_err_missing_parameter,
                            else => dobj.StatusCodes.ctap2_err_invalid_cbor,
                        };
                        res.items[0] = @enumToInt(x);
                        return res.toOwnedSlice();
                    };
                    defer mcp.deinit(allocator);

                    // Return error if a zero length pinUvAuthParam is receieved
                    if (mcp.@"8" == null) {
                        if (!requestPermission(&mcp.@"3", &mcp.@"2")) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                            return res.toOwnedSlice();
                        } else {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                            return res.toOwnedSlice();
                        }
                    }

                    // Check for supported pinUvAuthProtocol version
                    if (mcp.@"9" == null) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_missing_parameter);
                        return res.toOwnedSlice();
                    } else if (mcp.@"9".? != 2) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                        return res.toOwnedSlice();
                    }

                    // Check for a valid COSEAlgorithmIdentifier value
                    var valid_param: bool = false;
                    for (mcp.@"4") |param| {
                        if (crypt.isValidAlgorithm(param.alg)) {
                            valid_param = true;
                            break;
                        }
                    }
                    if (!valid_param) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_unsupported_algorithm);
                        return res.toOwnedSlice();
                    }

                    // Process all given options
                    if (mcp.@"7") |options| {
                        if (options.rk or options.uv) {
                            // we let the RP store the context for each credential.
                            // we also don't support built in user verification
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_unsupported_option);
                            return res.toOwnedSlice();
                        }
                    }

                    // Enforce user verification
                    if (!S.state.in_use) { // TODO: maybe just switch with getUserVerifiedFlagValue() call
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_token_expired);
                        return res.toOwnedSlice();
                    }
                    
                    if (!PinUvAuthTokenState.verify(S.state.state.?.pin_token, mcp.@"1", mcp.@"8".?)) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    if (S.state.permissions & 0x01 == 0) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    if (S.state.rp_id) |rpId| {
                        const rpId2 = mcp.@"2".id;
                        if (!std.mem.eql(u8, rpId, rpId2)) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                            return res.toOwnedSlice();
                        }
                    }

                    if (!S.state.getUserVerifiedFlagValue()) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    // TODO: If the pinUvAuthToken does not have a permissions RP ID associated:
                    // Associate the request’s rp.id parameter value with the pinUvAuthToken as its permissions RP ID.

                    // TODO: check exclude list

                    // Request permission from the user
                    if (!S.state.user_present and !requestPermission(&mcp.@"3", &mcp.@"2")) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                        return res.toOwnedSlice();
                    }

                    // Generate a new credential key pair for the algorithm specified.
                    const context = crypt.newContext(getBlock);
                    const key_pair = crypt.deriveKeyPair(secret_data.?.master_secret, context) catch unreachable;

                    // Create a new credential id
                    const cred_id = crypt.makeCredId(secret_data.?.master_secret, &context, mcp.@"2".id);

                    // Generate an attestation statement for the newly-created
                    // key using clientDataHash.
                    const acd = dobj.AttestedCredentialData{
                        .aaguid = self.info.@"3",
                        .credential_length = crypt.cred_id_len,
                        // context is used as id to later retrieve actual key using
                        // the master secret.
                        .credential_id = &cred_id,
                        .credential_public_key = crypt.getCoseKey(key_pair),
                    };

                    var ad = dobj.AuthData{
                        .rp_id_hash = undefined,
                        .flags = dobj.Flags{
                            .up = 1,
                            .rfu1 = 0,
                            .uv = 1,
                            .rfu2 = 0,
                            .at = 1,
                            .ed = 0,
                        },
                        .sign_count = secret_data.?.sign_ctr,
                        .attested_credential_data = acd,
                    };
                    secret_data.?.sign_ctr += 1;

                    // Calculate the SHA-256 hash of the rpId (base url).
                    std.crypto.hash.sha2.Sha256.hash(mcp.@"2".id, &ad.rp_id_hash, .{});
                    var authData = std.ArrayList(u8).init(allocator);
                    defer authData.deinit();
                    try ad.encode(authData.writer());

                    // Create attestation statement
                    var stmt: ?dobj.AttStmt = null;
                    if (self.attestation_type.att_type == .self) {
                        const sig = crypt.sign(key_pair, authData.items, mcp.@"1") catch {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap1_err_other);
                            return res.toOwnedSlice();
                        };

                        var x: [crypt.der_len]u8 = undefined;
                        stmt = dobj.AttStmt{ .@"packed" = .{
                            .@"#alg" = cose.Algorithm.Es256,
                            .sig = sig.toDer(&x),
                        } };
                    } else {
                        stmt = dobj.AttStmt{ .none = .{} };
                    }

                    const ao = dobj.AttestationObject{
                        .@"1" = dobj.Fmt.@"packed",
                        .@"2" = authData.items,
                        .@"3" = stmt.?,
                    };

                    cbor.stringify(ao, .{}, response) catch |err| {
                        res.items[0] = @enumToInt(dobj.StatusCodes.fromError(err));
                        return res.toOwnedSlice();
                    };
                },
                .authenticator_get_assertion => {
                    const gap = cbor.parse(GetAssertionParam, try cbor.DataItem.new(command[1..]), .{ .allocator = allocator }) catch |err| {
                        const x = switch (err) {
                            error.MissingField => dobj.StatusCodes.ctap2_err_missing_parameter,
                            else => dobj.StatusCodes.ctap2_err_invalid_cbor,
                        };
                        res.items[0] = @enumToInt(x);
                        return res.toOwnedSlice();
                    };
                    defer gap.deinit(allocator);

                    // Return error if a zero length pinUvAuthParam is receieved
                    if (gap.@"6" == null) {
                        if (!requestPermission(null, null)) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                            return res.toOwnedSlice();
                        } else {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                            return res.toOwnedSlice();
                        }
                    }

                    // Check for supported pinUvAuthProtocol version
                    if (gap.@"7" == null) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_missing_parameter);
                        return res.toOwnedSlice();
                    } else if (gap.@"7".? != 2) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                        return res.toOwnedSlice();
                    }

                    if (gap.@"5") |opt| {
                        // pinUvAuthParam takes precedence over uv, so uv can be true as long
                        // as pinUvAuthParam is present.
                        if ((opt.uv and gap.@"6" == null) or !opt.up) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_invalid_option);
                            return res.toOwnedSlice();
                        } else if (opt.rk) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_unsupported_option);
                            return res.toOwnedSlice();
                        }
                    }

                    // Enforce user verification
                    if (!S.state.in_use) { // TODO: maybe just switch with getUserVerifiedFlagValue() call
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_token_expired);
                        return res.toOwnedSlice();
                    }
                    
                    if (!PinUvAuthTokenState.verify(S.state.state.?.pin_token, gap.@"2", gap.@"6".?)) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    if (S.state.permissions & 0x02 == 0) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    if (S.state.rp_id) |rpId| {
                        const rpId2 = gap.@"1";
                        if (!std.mem.eql(u8, rpId, rpId2)) {
                            res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                            return res.toOwnedSlice();
                        }
                    }

                    if (!S.state.getUserVerifiedFlagValue()) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                        return res.toOwnedSlice();
                    }

                    // TODO: If the pinUvAuthToken does not have a permissions RP ID associated:
                    // Associate the request’s rp.id parameter value with the pinUvAuthToken as its permissions RP ID.

                    // locate all denoted credentials present on this
                    // authenticator and bound to the specified rpId.
                    var ctx_and_mac: ?[]const u8 = null;
                    if (gap.@"3") |creds| {
                        for (creds) |cred| {
                            if (cred.id.len < crypt.cred_id_len) continue;

                            if (crypt.verifyCredId(secret_data.?.master_secret, cred.id, gap.@"1")) {
                                ctx_and_mac = cred.id[0..];
                                break;
                            }
                        }
                    }

                    if (ctx_and_mac == null) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_no_credentials);
                        return res.toOwnedSlice();
                    }

                    // Check user presence
                    var up: bool = S.state.user_present;
                    if (!up) {
                        up = requestPermission(null, null);
                    }
                    if (!up) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                        return res.toOwnedSlice();
                    }

                    // clear permissions
                    S.state.user_present = false;
                    S.state.user_verified = false;
                    S.state.permissions = 0x10;

                    // Return signature
                    var ad = dobj.AuthData{
                        .rp_id_hash = undefined,
                        .flags = dobj.Flags{
                            .up = 1,
                            .rfu1 = 0,
                            .uv = 1,
                            .rfu2 = 0,
                            .at = 0,
                            .ed = 0,
                        },
                        .sign_count = secret_data.?.sign_ctr,
                        // attestedCredentialData are excluded
                    };
                    secret_data.?.sign_ctr += 1;
                    std.crypto.hash.sha2.Sha256.hash(gap.@"1", &ad.rp_id_hash, .{});
                    var authData = std.ArrayList(u8).init(allocator);
                    defer authData.deinit();
                    try ad.encode(authData.writer());

                    // 12. Sign the clientDataHash along with authData with the
                    // selected credential.
                    const kp = crypt.deriveKeyPair(secret_data.?.master_secret, ctx_and_mac.?[0..32].*) catch unreachable;

                    const sig = crypt.sign(kp, authData.items, gap.@"2") catch {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap1_err_other);
                        return res.toOwnedSlice();
                    };

                    var x: [crypt.der_len]u8 = undefined;
                    const gar = GetAssertionResponse{
                        .@"1" = dobj.PublicKeyCredentialDescriptor{
                            .type = "public-key",
                            .id = ctx_and_mac.?,
                        },
                        .@"2" = authData.items,
                        .@"3" = sig.toDer(&x),
                    };

                    cbor.stringify(gar, .{}, response) catch |err| {
                        res.items[0] = @enumToInt(dobj.StatusCodes.fromError(err));
                        return res.toOwnedSlice();
                    };
                },
                .authenticator_get_info => {
                    var i = self.info;
                    if (data.forcePINChange) |fpc| {
                        i.@"12" = fpc;
                    }

                    cbor.stringify(i, .{}, response) catch |err| {
                        res.items[0] = @enumToInt(dobj.StatusCodes.fromError(err));
                        return res.toOwnedSlice();
                    };
                },
                .authenticator_client_pin => {
                    const cpp = cbor.parse(ClientPinParam, try cbor.DataItem.new(command[1..]), .{ .allocator = allocator }) catch |err| {
                        const x = switch (err) {
                            error.MissingField => dobj.StatusCodes.ctap2_err_missing_parameter,
                            else => dobj.StatusCodes.ctap2_err_invalid_cbor,
                        };
                        res.items[0] = @enumToInt(x);
                        return res.toOwnedSlice();
                    };
                    defer cpp.deinit(allocator);

                    // Handle one of the subcommands.
                    var cpr: ?ClientPinResponse = null;
                    switch (cpp.@"2") {
                        .getRetries => {
                            cpr = .{
                                .@"3" = data.meta.pin_retries,
                                .@"4" = false,
                            };
                        },
                        .getKeyAgreement => {
                            // Validate arguments
                            // +++++++++++++++++++
                            // return error if required parameter is not provided.
                            const protocol = if (cpp.@"1") |prot| prot else {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_missing_parameter);
                                return res.toOwnedSlice();
                            };
                            // return error if authenticator doesn't support the selected protocol.
                            if (protocol != .v2) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                                return res.toOwnedSlice();
                            }

                            // Create response
                            // +++++++++++++++++
                            cpr = .{
                                .@"#1" = S.state.getPublicKey(),
                            };
                        },
                        .setPIN => {},
                        .changePIN => {
                            // Return error if the authenticator does not receive the
                            // mandatory parameters for this command.
                            if (cpp.@"1" == null or cpp.@"3" == null or cpp.@"5" == null or
                                cpp.@"6" == null or cpp.@"4" == null)
                            {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_missing_parameter);
                                return res.toOwnedSlice();
                            }

                            // If pinUvAuthProtocol is not supported, return error.
                            if (cpp.@"1".? != .v2) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                                return res.toOwnedSlice();
                            }

                            // If the pinRetries counter is 0, return error.
                            const retries = data.meta.pin_retries;
                            if (retries <= 0) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_blocked);
                                return res.toOwnedSlice();
                            }

                            // Obtain the shared secret
                            const shared_secret = S.state.ecdh(cpp.@"3".?) catch {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                                return res.toOwnedSlice();
                            };

                            // Verify the data (newPinEnc || pinHashEnc)
                            const new_pin_len = cpp.@"5".?.len;
                            var msg = try allocator.alloc(u8, new_pin_len + 32);
                            defer allocator.free(msg);
                            std.mem.copy(u8, msg[0..new_pin_len], cpp.@"5".?[0..]);
                            std.mem.copy(u8, msg[new_pin_len..], cpp.@"6".?[0..]);

                            const verified = PinUvAuthTokenState.verify(
                                shared_secret[0..32].*,
                                msg, // newPinEnc || pinHashEnc
                                cpp.@"4".?, // pinUvAuthParam
                            );
                            if (!verified) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_auth_invalid);
                                return res.toOwnedSlice();
                            }

                            // decrement pin retries
                            data.meta.pin_retries = retries - 1;

                            // Decrypt pinHashEnc and match against stored pinHash
                            var pinHash1: [16]u8 = undefined;
                            PinUvAuthTokenState.decrypt(
                                shared_secret,
                                pinHash1[0..],
                                cpp.@"6".?[0..],
                            );

                            const key = Hkdf.extract(data.meta.salt[0..], pinHash1[0..]);
                            secret_data = data_module.decryptSecretData(
                                allocator,
                                data.c,
                                data.tag[0..],
                                key,
                                data.meta.nonce_ctr,
                            ) catch {
                                res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                                return res.toOwnedSlice();
                            };

                            if (!std.mem.eql(u8, pinHash1[0..], secret_data.?.pin_hash[0..])) {
                                // The pin hashes don't match
                                S.state.regenerate(getBlock);

                                res.items[0] = if (data.meta.pin_retries == 0)
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_blocked)
                                    // TODO: reset authenticator -> DOOMSDAY
                                else
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                                return res.toOwnedSlice();
                            }

                            // Set the pinRetries to maximum
                            data.meta.pin_retries = 8;

                            // Decrypt new pin
                            var paddedNewPin: [64]u8 = undefined;
                            PinUvAuthTokenState.decrypt(
                                shared_secret,
                                paddedNewPin[0..],
                                cpp.@"5".?[0..],
                            );
                            var pnp_end: usize = 0;
                            while (paddedNewPin[pnp_end] != 0 and pnp_end < 64) : (pnp_end += 1) {}
                            const newPin = paddedNewPin[0..pnp_end];
                            if (newPin.len < commands.client_pin.minimum_pin_length) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_policy_violation);
                                return res.toOwnedSlice();
                            }

                            // TODO: support forcePINChange
                            // TODO: support 15.
                            // TODO: support 16.

                            // Store new pin
                            secret_data.?.pin_hash = crypt.pinHash(newPin);
                            secret_data.?.pin_length = @intCast(u8, newPin.len);
                            S.state.pin_key = Hkdf.extract(data.meta.salt[0..], &secret_data.?.pin_hash);

                            // Invalidate pinUvAuthTokens
                            reset_token = true;
                        },
                        .getPinUvAuthTokenUsingPin => {
                            // Return error if the authenticator does not receive the
                            // mandatory parameters for this command.
                            if (cpp.@"1" == null or cpp.@"3" == null or cpp.@"6" == null or cpp.@"9" == null)
                            {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_missing_parameter);
                                return res.toOwnedSlice();
                            }

                            // If pinUvAuthProtocol is not supported or the permissions are 0, 
                            // return error.
                            if (cpp.@"1".? != .v2 or cpp.@"9".? == 0) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                                return res.toOwnedSlice();
                            }

                            // Check if all requested premissions are valid
                            const options = self.info.@"4".?;
                            const cm = cpp.cmPermissionSet() and (options.credMgmt == null or options.credMgmt.? == false);
                            const be = cpp.bePermissionSet() and (options.bioEnroll == null);
                            const lbw = cpp.lbwPermissionSet() and (options.largeBlobs == null or options.largeBlobs.? == false);
                            const acfg = cpp.acfgPermissionSet() and (options.authnrCfg == null or options.authnrCfg.? == false);
                            const mc = cpp.mcPermissionSet() and (options.noMcGaPermissionsWithClientPin == true);
                            const ga = cpp.gaPermissionSet() and (options.noMcGaPermissionsWithClientPin == true);
                            if (cm or be or lbw or acfg or mc or ga) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_unauthorized_permission);
                                return res.toOwnedSlice();
                            }

                            // Check if the pin is blocked
                            if (data.meta.pin_retries == 0) {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_blocked);
                                return res.toOwnedSlice();
                            }

                            // Obtain the shared secret
                            const shared_secret = S.state.ecdh(cpp.@"3".?) catch {
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap1_err_invalid_parameter);
                                return res.toOwnedSlice();
                            };

                            // decrement pin retries
                            data.meta.pin_retries -= 1;

                            // Decrypt pinHashEnc and match against stored pinHash
                            var pinHash: [16]u8 = undefined;
                            PinUvAuthTokenState.decrypt(
                                shared_secret,
                                pinHash[0..],
                                cpp.@"6".?[0..],
                            );

                            // Derive the key from pinHash and then decrypt secret data
                            const key = Hkdf.extract(data.meta.salt[0..], pinHash[0..]);
                            secret_data = data_module.decryptSecretData(
                                allocator,
                                data.c,
                                data.tag[0..],
                                key,
                                data.meta.nonce_ctr,
                            ) catch {
                                // without valid pin/ pinHash we derive the wrong key, i.e.,
                                // the encryption will fail.
                                res.items[0] =
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                                return res.toOwnedSlice();
                            };
                            S.state.pin_key = key;

                            if (!std.mem.eql(u8, pinHash[0..], secret_data.?.pin_hash[0..])) {
                                // The pin hashes don't match
                                S.state.regenerate(getBlock);

                                res.items[0] = if (data.meta.pin_retries == 0)
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_blocked)
                                    // TODO: reset authenticator -> DOOMSDAY
                                else
                                    @enumToInt(dobj.StatusCodes.ctap2_err_pin_invalid);
                                return res.toOwnedSlice();
                            }

                            // Set retry counter to maximum
                            data.meta.pin_retries = 8;

                            // Check if user is forced to change the pin
                            if (data.forcePINChange) |change| {
                                if (change) {
                                    res.items[0] =
                                        @enumToInt(dobj.StatusCodes.ctap2_err_pin_policy_violation);
                                    return res.toOwnedSlice();
                                }
                            }

                            // Create a new pinUvAuthToken
                            S.state.resetPinUvAuthToken(getBlock);

                            // Begin using the pin uv auth token
                            S.state.beginUsingPinUvAuthToken(false, self.millis());

                            // Set permissions
                            S.state.permissions = cpp.@"9".?;

                            // If the rpId parameter is present, associate the permissions RP ID 
                            // with the pinUvAuthToken.
                            if (cpp.@"10") |rpId| {
                                const l = if (rpId.len > 64) 64 else rpId.len;
                                std.mem.copy(u8, S.state.rp_id_raw[0..l], rpId[0..l]);
                                S.state.rp_id = S.state.rp_id_raw[0..l];
                            }

                            // The authenticator returns the encrypted pinUvAuthToken for the 
                            // specified pinUvAuthProtocol, i.e. encrypt(shared secret, pinUvAuthToken).
                            var enc_shared_secret = allocator.alloc(u8, 48) catch unreachable;
                            var iv: [16]u8 = undefined;
                            getBlock(iv[0..]);
                            PinUvAuthTokenState.encrypt(
                                iv,
                                shared_secret,
                                enc_shared_secret[0..],
                                S.state.state.?.pin_token[0..],
                            );

                            // Response
                            cpr = .{
                                .@"2" = enc_shared_secret,
                            };
                        },
                        else => {},
                    }

                    if (cpr) |resp| {
                        cbor.stringify(resp, .{}, response) catch |err| {
                            res.items[0] = @enumToInt(dobj.StatusCodes.fromError(err));
                            return res.toOwnedSlice();
                        };
                        resp.deinit(allocator);
                    }
                },
                .authenticator_reset => {
                    // Resetting an authenticator is a destructive operation!

                    // Request permission from the user
                    if (!requestPermission(null, null)) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                        return res.toOwnedSlice();
                    }

                    reset(allocator, data.meta.nonce_ctr);
                    write_back = false;
                },
                .authenticator_selection => {
                    // Request permission from the user
                    if (!requestPermission(null, null)) {
                        res.items[0] = @enumToInt(dobj.StatusCodes.ctap2_err_operation_denied);
                        return res.toOwnedSlice();
                    }
                },
                else => {}
            }

            return res.toOwnedSlice();
        }
    };
}

const tests = @import("tests.zig");

test "main" {
    _ = tests;
    _ = dobj;
    _ = crypt;
    _ = commands;
    _ = ctaphid;
    _ = data_module;
}