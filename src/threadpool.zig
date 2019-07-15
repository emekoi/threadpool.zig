//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");
const deque = @import("deque");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;

pub const TaskFn = fn () anyerror!void;

pub fn Future(comptime T: type) type {
    return union(enum) {
        const Self = @This();

        Error: anyerror,
        Ok: T,

        pub async fn resolve(self: Self) !T {
            return switch (self) {
                Self.Error => |err| err,
                Self.Ok => |ok| ok,
            };
        }

        pub async fn get(self: Self) !T {
            return switch (self) {
                Self.Error => |err| err,
                Self.Ok => |ok| ok,
            };
        }
    };
}

pub const ThreadPool = struct {
    const Deque = deque.Deque(Task, 32);
    const Stealer = deque.Stealer(Task, 32);

    const Task = struct {
        task_fn: TaskFn,
    };

    const Worker = struct {
        stealer: Stealer,
        terminate: bool,
        thread: ?*Thread,

        fn run(self: *Worker) u8 {
            while (!self.terminate) {
                while (self.stealer.steal()) |task| {
                    task.task_fn() catch |err| {
                        std.debug.warn("error: {}\n", @errorName(err));
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                        return 1;
                    };
                }
            }
            return 0;
        }

        fn shutdown(self: *Worker) void {
            // this race condition is okay (i think)
            self.terminate = true;
            if (self.thread) |thread|
                thread.wait();
        }
    };

    allocator: *Allocator,
    worker_pool: []Worker,
    thread_count: usize,
    work_pool: Deque,

    pub fn init(allocator: *Allocator, thread_count: ?usize) !ThreadPool {
        if (builtin.single_threaded) {
            @compileError("cannot use ThreadPool in signgle threaded build mode");
        }

        const count = thread_count orelse try Thread.cpuCount();
        var result = ThreadPool{
            .allocator = allocator,
            .worker_pool = try allocator.alloc(Worker, count),
            .thread_count = count,
            .work_pool = try Deque.new(allocator),
        };
        for (result.worker_pool) |*worker| {
            worker.thread = null;
        }
        return result;
    }

    pub fn deinit(self: *ThreadPool) void {
        for (self.worker_pool) |*worker| {
            worker.shutdown();
        }
    }

    pub fn start(self: *ThreadPool) !void {
        for (self.worker_pool) |*worker| {
            worker.terminate = false;
            worker.stealer = self.work_pool.stealer();
            @fence(.SeqCst);
            worker.thread = try Thread.spawn(worker, Worker.run);
        }
    }

    pub fn push(self: *ThreadPool, task: TaskFn) !void {
        try self.work_pool.push(Task{
            .task_fn = task,
        });
    }
};

test "simple" {
    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    defer std.heap.direct_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var allocator = &fba.allocator;

    const Test = struct {
        var static: usize = 0;

        fn hello() anyerror!void {
            try std.io.null_out_stream.print("hello {}: {}\n", Thread.getCurrentId(), static);
            static += 1;
        }
    };

    var pool = try ThreadPool.init(allocator, null);
    defer pool.deinit();
    const AMOUNT = 1000000;
    {
        var i: usize = AMOUNT;
        while (i > 0) : (i -= 1) {
            try pool.push(Test.hello);
        }

        var timer = try std.time.Timer.start();
        try pool.start();
        std.debug.warn("\n time-multi: {}\n", timer.lap());
        timer.reset();
        Test.static = 0;
    }

    {
        var timer = try std.time.Timer.start();

        var i: usize = AMOUNT;
        while (i > 0) : (i -= 1) {
            try Test.hello();
        }
        std.debug.warn("time-single: {}\n", timer.lap());
    }
}
