const std = @import("std");
const builtin = @import("builtin");
const build_consts = @import("build_consts");
const epoch = std.time.epoch;

pub const version = build_consts.version;

pub const desc = std.fmt.comptimePrint("slimy ({s}) v{f}", .{
    @tagName(builtin.mode),
    version,
});
pub const full_desc = if (timestamp) |ts|
    desc ++ ", built at " ++ ts
else
    desc;

pub const timestamp: ?[]const u8 = if (build_consts.timestamp) |ts|
    stringTimestamp(ts)
else
    null;

fn stringTimestamp(comptime ts: u64) []const u8 {
    const esec = epoch.EpochSeconds{ .secs = ts };
    const day_sec = esec.getDaySeconds();
    const year_day = esec.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.comptimePrint("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}+00:00", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index,

        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}
