const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer _ = arena_state.deinit();

    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    var before: ?[]u8 = null;
    for (args[1..]) |path| {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const source = try file.readToEndAlloc(arena, std.math.maxInt(usize));
        defer before = source;
        if (before == null) continue;
        if (std.unicode.utf8ValidateSlice(before.?) and std.unicode.utf8ValidateSlice(source)) {
            try std.testing.expectEqualStrings(before.?, source);
        } else {
            try std.testing.expectEqualSlices(u8, before.?, source);
        }
    }
}
