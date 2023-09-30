// Search mask; row-major; bottom-left origin
pub const mask = blk: {
    const inner = 1;
    const outer = 8;

    const dim = 2 * outer + 1;
    var bitmap: [dim][dim]bool = undefined;
    for (&bitmap, 0..) |*row, y| {
        for (row, 0..) |*bit, x| {
            const rx = @as(i32, @intCast(x)) - outer;
            const ry = @as(i32, @intCast(y)) - outer;
            const d2 = rx * rx + ry * ry;
            bit.* =
                // Outside inner circle
                inner * inner < d2 and
                // Inside outer circle
                d2 <= outer * outer;
        }
    }

    break :blk bitmap;
};
pub const mask_width = mask[0].len;
pub const mask_height = mask.len;
