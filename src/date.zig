const std = @import("std");

pub fn formatDate(timestamp: std.Io.Timestamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // 1970-01-01T00:00:00Z

    var seconds: f64 = @floatFromInt(timestamp.toSeconds());
    const seconds_per_day = 24.0 * 3600.0;
    const seconds_per_year_lp = 365.25 * 24.0 * 3600.0;
    const seconds_per_year = 365.25 * 24.0 * 3600.0;

    var years: f64 = 2.0;
    seconds -= 2.0 * seconds_per_year;

    years += @floor(seconds / seconds_per_year_lp);
    seconds -= (years - 2) * seconds_per_year_lp;
    const year: u16 = @intFromFloat(years + 1970);

    var days: u9 = @floor(seconds / seconds_per_day);
    seconds = @rem(seconds, seconds_per_day);
    const feb_max: u8 = if (year % 4 == 0) 29 else 28;
    var month_a: u9 = 31;
    const month: u8 = month: {
        if (days < month_a) break :month 0;
        days -= month_a;
        month_a = feb_max;
        if (days < month_a) break :month 1;
        days -= month_a;
        month_a = 31;
        if (days < month_a) break :month 2;
        days -= month_a;
        month_a = 30;
        if (days < month_a) break :month 3;
        days -= month_a;
        month_a = 31;
        if (days < month_a) break :month 4;
        days -= month_a;
        month_a = 30;
        if (days < month_a) break :month 5;
        days -= month_a;
        month_a = 31;
        if (days < month_a) break :month 6;
        days -= month_a;
        month_a = 31;
        if (days < month_a) break :month 7;
        days -= month_a;
        month_a = 30;
        if (days < month_a) break :month 8;
        days -= month_a;
        month_a = 31;
        if (days < month_a) break :month 9;
        days -= month_a;
        month_a = 30;
        if (days < month_a) break :month 10;
        days -= month_a;
        break :month 11;
    };

    const hour: u8 = @floor(seconds / 3600);
    seconds = @rem(seconds, 3600);
    const minute: u8 = @floor(seconds / 60);
    seconds = @rem(seconds, 60);

    try writer.print("{d:04}-{d:02}-{d:02}T{d:02}:{d:02}:{d:02}Z", .{ year, month + 1, days + 1, hour, minute, seconds });
}
