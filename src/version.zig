const std = @import("std");
const build_consts = @import("build_consts");
const epoch = std.time.epoch;

pub const desc = std.fmt.comptimePrint("slimy v{}", .{build_consts.version});
pub const full_desc = if (timestamp) |ts|
    desc ++ ", built at " ++ ts
else
    desc;

pub const timestamp: ?[]const u8 = if (build_consts.timestamp) |ts|
blk: {
    const esec = epoch.EpochSeconds{ .secs = @intCast(i63, ts) };
    const day_sec = esec.getDaySeconds();
    const year_day = esec.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    break :blk std.fmt.comptimePrint("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}+00:00", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index,

        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
} else null;
