const std = @import("std");
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// Stored by the authenticator and used to derive all other secrets
pub const MasterSecret = [Hkdf.prk_length]u8;

/// Create a new, random master secret using a hash based key derivation function
pub fn createMasterSecret(rand: std.rand.Random) MasterSecret {
    var ikm: [32]u8 = undefined;
    var salt: [16]u8 = undefined;
    rand.bytes(ikm[0..]);
    rand.bytes(salt[0..]);
    return Hkdf.extract(&salt, &ikm);
}