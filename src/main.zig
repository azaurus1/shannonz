const std = @import("std");
const Io = std.Io;
const chilli = @import("chilli");

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root_options = chilli.CommandOptions{
        .name = "shannonz",
        .description = "A tool for finding strings and shannon entropy.",
        .version = "v1.0.0",
        .exec = rootExec,
    };
    var root_command = try chilli.Command.init(allocator, root_options);
    defer root_command.deinit();

    try root_command.addPositional(.{
        .name = "file",
        .description = "The path of the file to read.",
        .is_required = true,
        .type = .String,
    });

    try root_command.run(init.args, null);
}

fn rootExec(ctx: chilli.CommandContext) anyerror!void {
    std.log.info("Reading file...", .{});

    const file_str = try ctx.getArg("file", []const u8);

    var threaded: std.Io.Threaded = .init(ctx.app_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, file_str, .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var r = &reader.interface;

    // stat file for file size to allocate to heap
    const file_stat = try file.stat(io);
    const size: usize = @intCast(file_stat.size);

    const read_buf = try ctx.app_allocator.alloc(u8, size);
    defer ctx.app_allocator.free(read_buf);

    const bytes_read = try r.readSliceShort(read_buf);
    std.log.info("{d} bytes read", .{bytes_read});

    // entropy
    // sliding window of 1024 bytes
    const window_size = 1024;
    var offset: usize = 0;
    var entropy_map = std.AutoHashMap(u32, f64).init(ctx.app_allocator);
    defer entropy_map.deinit();
    var window_count: u32 = 0;

    while (offset < bytes_read) {
        const end = @min(offset + window_size, bytes_read);
        const window = read_buf[offset..end];

        // build 256 bucket histogram
        // frequency table
        var frequency_table = std.AutoHashMap(u8, i32).init(ctx.app_allocator);
        defer frequency_table.deinit();

        // loop items in window, add each value as a key and increment v for count
        for (window) |value| {
            // std.log.info("{d}", .{i});
            if (frequency_table.contains(value)) {
                var freq = frequency_table.get(value);

                if (freq) |*freq_val| {
                    freq_val.* += 1;
                }
                try frequency_table.put(value, freq.?);
            } else {
                try frequency_table.put(value, 1);
            }
        }

        var iterator = frequency_table.keyIterator();

        var self_information_sum: f64 = undefined;
        while (iterator.next()) |entry| {
            const freq = frequency_table.get(entry.*);
            // std.log.info("{d}: {d}", .{ entry.*, freq.? });

            // divide each count by 1024
            const probability = (@as(f64, freq.?) / 1024);
            // std.log.info("Probability: {d}", .{probability});

            // non-zero probabilities: compute p x log2(p)
            const prob_by_log = probability * std.math.log2(probability);
            // std.log.info("p x log2(p): {d}", .{prob_by_log});

            self_information_sum = self_information_sum + prob_by_log;
        }

        // std.log.info("self information sum: {d}", .{self_information_sum});

        // compute entropy
        const entropy = self_information_sum * -1;

        try entropy_map.put(window_count, entropy);

        std.log.info("{d} to {d}", .{ offset, end });
        offset += window_size;

        // increment window count
        std.log.info("window count {d}", .{window_count});
        window_count += 1;
    }

    var entropy_iterator = entropy_map.iterator();

    var entropy_keys: std.ArrayList(u32) = .empty;
    defer entropy_keys.deinit(ctx.app_allocator);

    while (entropy_iterator.next()) |entry| {
        try entropy_keys.append(ctx.app_allocator, entry.key_ptr.*);
    }

    std.mem.sort(u32, entropy_keys.items, {}, std.sort.asc(u32));

    for (entropy_keys.items) |k| {
        const v = entropy_map.get(k).?;
        std.log.info("Byte {d} entropy = {d}", .{ k, v });
    }
}
