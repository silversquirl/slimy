// Search mask; row-major; bottom-left origin
pub const mask = blk: {
    const inner = 1;
    const outer = 8;

    const dim = 2 * outer + 1;
    var bitmap: [dim][dim]bool = undefined;
    for (bitmap) |*row, y| {
        for (row) |*bit, x| {
            const rx = @intCast(i32, x) - outer;
            const ry = @intCast(i32, y) - outer;
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
