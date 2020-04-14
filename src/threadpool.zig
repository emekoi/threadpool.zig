//  Copyright (c) 2020 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");
const deque = @import("deque");

const SegmentedList = std.SegmentedList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

pub fn Task(frame: *anyframe->anyerror!void, f: var, args: var) anyerror!void {
    defer std.debug.warn("\nthread:{} -> exit", .{Thread.getCurrentId()});
    suspend {
        std.debug.warn("\nthread:{} -> 0x{x}", .{Thread.getCurrentId(), @ptrToInt(@frame())});
        frame.* = @frame();
    }

    const Args = @TypeOf(args);

    comptime {
        const info = @typeInfo(@TypeOf(f));
        if (info.Fn.args.len > 0) {
            std.debug.assert(info.Fn.args[0].arg_type.? == Args);
        }
    }

    const args_ = if (@sizeOf(Args) == 0) .{} else args;

    switch (@typeInfo(@TypeOf(f).ReturnType)) {
        builtin.TypeId.Void => {
            @call(.{}, f, args_);
        },
        builtin.TypeId.ErrorUnion => {
            try @call(.{}, f, args_);
        },
        else => @compileError("expected return type of main to be 'void', or '!void'"),
    }
}

pub const ThreadPool = struct {
    const ThreadList = SegmentedList(WorkerThread, 8);
    const Stealer = deque.Stealer(anyframe->anyerror!void, 32);
    const Deque = deque.Deque(anyframe->anyerror!void, 32);

    allocator: *Allocator,
    threads: ThreadList,
    thread_count: usize,
    frame_pool: Deque,

    const WorkerThread = struct {
        terminate: bool = false,
        thread: ?*Thread = null,
        stealer: Stealer,

        fn run(self: *WorkerThread) anyerror!void {
            while (true) {
                while (self.stealer.steal()) |frame| {
                    try process(frame);
                }
                if (self.terminate) break;
            }
        }

        fn process(frame: anyframe->anyerror!void) anyerror!void {
            resume frame;
        }
    };

    pub fn init(allocator: *Allocator, thread_count: ?usize) !ThreadPool {
        return ThreadPool {
            .allocator = allocator,
            .threads = ThreadList.init(allocator),
            .thread_count = thread_count orelse try Thread.cpuCount(),
            .frame_pool = try Deque.new(allocator),
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        var iter = self.threads.iterator(0);
        defer self.frame_pool.deinit();

        while (iter.next()) |worker| {
            if (worker.thread) |thread| {
                worker.terminate = true;
                thread.wait();
            }
        }
    }

    pub fn start(self: *ThreadPool) !void {
        if (!builtin.single_threaded) {
            var iter = self.threads.iterator(0);
            var i: usize = 0;
            while (i < self.thread_count) : (i += 1) {
                var worker = try self.threads.addOne();
                worker.stealer = self.frame_pool.stealer();
                @fence(.SeqCst);
                worker.thread = try Thread.spawn(worker, WorkerThread.run);
            }
        }
    }
    
    pub fn sync(self: *ThreadPool) !void {
        while (!self.frame_pool.isEmpty()) {
            while (self.frame_pool.pop()) |frame| {
                // try WorkerThread.process(@intToPtr(@TypeOf(frame), @ptrToInt(frame) - 0x10).*);
                // try WorkerThread.process(frame);
                // _ = await frame;
                resume frame.*;
                std.debug.warn("\nsync:{} -> 0x{x}", .{Thread.getCurrentId(), @ptrToInt(frame)});
            }
        }
    }

    pub fn pushAsync(self: *ThreadPool, fun: var, args: var) anyerror!void {
        
    }

    pub fn push(self: *ThreadPool, f: var, args: var) anyerror!void {
        var frame = try self.frame_pool.addOne();
        _ = async Task(frame, f, args);
        // resume frame.*;
        // frame.* = @as(anyframe->anyerror!void, async Task(f, args));
        // resume f;
        // try WorkerThread.process(self.frame_pool.pop().?);
        // resume self.frame_pool.pop().?;
        // try WorkerThread.process(frame.*);
        // std.debug.warn("\nthread:{} -> 0x{x}", .{Thread.getCurrentId(), @ptrToInt(frame.*)});
        // _ = noasync await frame;
    }
};

// test "simple-single-threaded" {
//     const AMOUNT = 1000000;
//     const Test = struct {
//         var static: usize = 0;

//         fn hello() anyerror!void {
//             try std.io.null_out_stream.print("hello {}: {}\n", .{Thread.getCurrentId(), static});
//             static += 1;
//         }
//     };

//     var timer = try std.time.Timer.start();

//     var i: usize = AMOUNT;
//     while (i > 0) : (i -= 1) {
//         try Test.hello();
//     }
//     std.debug.warn(" time-single: {} ", .{timer.lap()});
// }

test "simple-multi-threaded" {
    var slice = try std.heap.page_allocator.alloc(u8, 1 << 29);
    defer std.heap.page_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var allocator = &fba.allocator;

    const Test = struct {
        var static: usize = 0;

        fn hello() anyerror!void {
            // std.debug.warn("\nhello {}", .{static});
            static += 1;
            // return error.TODO;
        }
    };

    var pool = try ThreadPool.init(allocator, 1);
    defer pool.deinit();
    
    const AMOUNT = 10;
    var i: usize = AMOUNT;
    while (i > 0) : (i -= 1) {
        try pool.push(Test.hello, {});
        // var frame  = pool.frame_pool.pop().?;
        // std.debug.warn("\n_sync -> 0x{x}", .{@ptrToInt(frame.*)});
        // resume frame.*;
        // try pool.sync();
    }

    // resume pool.frame_pool.pop().?.*;

    var timer = try std.time.Timer.start();
    // try pool.start();
    try pool.sync(); 

    std.debug.warn("\ntime-multi: {} {} ", .{timer.lap(), Test.static});
    timer.reset();
    Test.static = 0;
}
