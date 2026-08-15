const r4os = @import("r4os");

var boot_log_buffer: [r4os.abi.boot_log_buffer_size]u8 = .{0xA5} ** r4os.abi.boot_log_buffer_size;

const App = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }

    fn run(self: *App) i32 {
        self.sys.println("BOOTDIAG");
        var ok = true;
        ok = self.testApiHeader() and ok;
        ok = self.testBootInfoSnapshot() and ok;
        ok = self.testBootPhasePerformance() and ok;
        ok = self.testBootLogBridge() and ok;
        ok = self.testMemorySnapshot() and ok;
        ok = self.testMemoryPressure() and ok;
        ok = self.testAppHeapRetired() and ok;
        ok = self.testMemoryProfiles() and ok;
        ok = self.testLargeVirtualReserve() and ok;
        ok = self.testVmApiPath() and ok;
        ok = self.testSdkAllocatorV2() and ok;
        ok = self.testSchedulerPath() and ok;

        self.sys.write("BOOTDIAG result: ");
        self.sys.println(if (ok) "OK" else "FAILED");
        return if (ok) 0 else 1;
    }

    fn testApiHeader(self: *App) bool {
        const ok = self.sys.contractValid() and
            self.dev.hasFn("memory_summary") and
            self.dev.hasFn("memory_pressure_snapshot") and
            self.dev.hasFn("memory_vm_reserve_probe") and
            self.dev.hasFn("performance_summary") and
            self.sys.base.hasDevFn("memory_summary") and
            self.sys.hasFn("vm_reserve") and
            self.dev.hasFn("boot_info_summary") and
            self.sys.hasFn("boot_log_info");
        self.printCheck("R4SYS runtime core groups", ok);
        if (!ok) return false;
        self.sys.write("  R4SYS runtime version=");
        self.sys.printU64(self.sys.tableAbiVersion());
        self.sys.write(" size=");
        self.sys.printU64(self.sys.tableSize());
        self.sys.println("");
        return true;
    }

    fn testBootPhasePerformance(self: *App) bool {
        const summary = self.dev.performanceSummary() orelse return self.failBool("Boot performance summary unavailable");
        var saw_loader = false;
        var saw_runtime = false;
        var saw_shell = false;
        var checked: u32 = 0;
        var i: u32 = 0;
        while (i < summary.boot_phase_count) : (i += 1) {
            const phase = self.dev.performanceBootPhase(i) orelse return self.failBool("Boot phase performance entry unavailable");
            checked += 1;
            if (phase.phase == 10) saw_loader = true;
            if (phase.phase == 13) saw_runtime = true;
            if (phase.phase == 18) saw_shell = true;
        }
        const ok = (summary.flags & r4os.abi.performance_flag_boot_perf_ready) != 0 and
            summary.boot_phase_count > 0 and
            summary.boot_transition_count >= summary.boot_phase_count and
            checked == summary.boot_phase_count and
            saw_loader and saw_runtime and saw_shell;
        self.printCheck("Boot phase performance", ok);
        if (!ok) return false;
        self.sys.write("  Boot phases=");
        self.sys.printU64(summary.boot_phase_count);
        self.sys.write(" transitions=");
        self.sys.printU64(summary.boot_transition_count);
        self.sys.write(" ticks=");
        self.sys.printU64(summary.boot_total_ticks);
        self.sys.println("");
        return true;
    }

    fn testBootLogBridge(self: *App) bool {
        const info = self.sys.bootLogInfo() orelse return self.failBool("BootLog info unavailable");
        const info_ok = info.capacity == r4os.abi.boot_log_buffer_size and
            info.length > 0 and
            info.length <= info.capacity and
            info.total_written >= info.length;
        self.printCheck("BootLog info", info_ok);
        if (!info_ok) return false;

        const read_len: usize = @intCast(info.length);
        const got = self.sys.bootLogRead(0, boot_log_buffer[0..read_len]);
        if (got <= 0) return self.failBool("BootLog read failed");
        const got_len: usize = @intCast(got);
        const text = boot_log_buffer[0..got_len];
        const driver_ok = contains(text, "[LOG1] source=Driver severity=");
        const protocol_ok = contains(text, "[LOG1] source=Protocol severity=");
        const event_ok = driver_ok and protocol_ok;
        self.printCheck("R4D/R4P log events", event_ok);
        if (!event_ok) return false;

        self.sys.write("  BootLog bytes=");
        self.sys.printU64(info.length);
        self.sys.write(" total=");
        self.sys.printU64(info.total_written);
        self.sys.write(" dropped=");
        self.sys.printU64(info.dropped_bytes);
        self.sys.println("");
        return true;
    }

    fn testBootInfoSnapshot(self: *App) bool {
        const summary = self.dev.bootInfoSummary() orelse return self.failBool("BootInfo summary unavailable");
        const count = self.dev.bootInfoMemoryCount();
        const core_ok =
            (summary.flags & r4os.abi.boot_info_flag_initialized) != 0 and
            (summary.flags & r4os.abi.boot_info_flag_has_hhdm) != 0 and
            (summary.flags & r4os.abi.boot_info_flag_has_framebuffer) != 0 and
            summary.hhdm_offset != 0 and
            summary.framebuffer_address != 0 and
            summary.framebuffer_width > 0 and
            summary.framebuffer_height > 0 and
            count > 0 and
            count == summary.memory_map_count;
        self.printCheck("BootInfo summary", core_ok);
        if (!core_ok) return false;

        var usable_regions: u32 = 0;
        var usable_bytes: u64 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry = self.dev.bootInfoMemoryEntry(i) orelse return self.failBool("BootInfo memory entry unavailable");
            if (entry.length == 0) return self.failBool("BootInfo zero-length memory entry");
            if (entry.kind == r4os.abi.boot_memory_kind_usable) {
                usable_regions += 1;
                usable_bytes += entry.length;
            }
        }
        const map_ok = usable_regions > 0 and usable_bytes >= 1024 * 1024;
        self.printCheck("BootInfo memory map", map_ok);
        if (!map_ok) return false;
        self.sys.write("  BootInfo usable MB=");
        self.sys.printU64(usable_bytes / 1024 / 1024);
        self.sys.write(" entries=");
        self.sys.printU64(count);
        self.sys.println("");
        return true;
    }

    fn testMemorySnapshot(self: *App) bool {
        const summary = self.dev.memorySummary() orelse return self.failBool("memory summary unavailable");
        const ok = summary.active_blocks > 0 and
            summary.committed_bytes > 0 and
            summary.free_physical_bytes > 0 and
            summary.by_kind[r4os.abi.memory_kind_kernel_heap] > 0 and
            summary.by_kind[r4os.abi.memory_kind_page_table] > 0;
        self.printCheck("Memory snapshot", ok);
        if (!ok) return false;
        self.sys.write("  Memory active=");
        self.sys.printU64(summary.active_blocks);
        self.sys.write(" committed=");
        self.sys.printU64(summary.committed_bytes);
        self.sys.println("");
        return true;
    }

    fn testMemoryPressure(self: *App) bool {
        const pressure = self.dev.memoryPressure() orelse return self.failBool("memory pressure unavailable");
        const reclaim_ready = (pressure.flags & r4os.abi.memory_pressure_flag_fs_cache_reclaim) != 0;
        const no_reclaim = (pressure.flags & r4os.abi.memory_pressure_flag_no_reclaim) != 0;
        const flags_ok = (pressure.flags & r4os.abi.memory_pressure_flag_no_pagefile) != 0 and
            (pressure.flags & r4os.abi.memory_pressure_flag_no_swap) != 0 and
            (pressure.flags & r4os.abi.memory_pressure_flag_commit_limited) != 0 and
            ((reclaim_ready and !no_reclaim and pressure.reclaimable_bytes > 0) or
                (no_reclaim and !reclaim_ready and pressure.reclaimable_bytes == 0));
        const ok = pressure.version == r4os.abi.memory_pressure_snapshot_version and
            pressure.size >= @sizeOf(r4os.abi.ProgramMemoryPressureSnapshot) and
            pressure.pressure_level >= r4os.abi.memory_pressure_level_normal and
            pressure.pressure_level <= r4os.abi.memory_pressure_level_critical and
            pressure.total_physical_bytes > 0 and
            pressure.virtual_committed_bytes >= pressure.virtual_resident_bytes and
            pressure.commit_budget_bytes >= pressure.virtual_resident_bytes and
            pressure.commit_headroom_bytes <= pressure.commit_budget_bytes and
            pressure.dirty_bytes <= pressure.used_physical_bytes and
            pressure.non_reclaimable_bytes + pressure.reclaimable_bytes == pressure.used_physical_bytes and
            flags_ok;
        self.printCheck("Memory pressure snapshot", ok);
        if (!ok) return false;
        self.sys.write("  Memory pressure level=");
        self.sys.printU64(pressure.pressure_level);
        self.sys.write(" appAvailMB=");
        self.sys.printU64(pressure.app_available_bytes / 1024 / 1024);
        self.sys.write(" headroomMB=");
        self.sys.printU64(pressure.commit_headroom_bytes / 1024 / 1024);
        self.sys.println("");
        return true;
    }

    fn testAppHeapRetired(self: *App) bool {
        const summary = self.dev.memorySummary() orelse return self.failBool("memory summary for AppHeap retirement unavailable");
        const ok = summary.by_kind[r4os.abi.memory_kind_app_heap] == 0;
        self.printCheck("AppHeap V1 retired", ok);
        if (!ok) {
            self.sys.write("  AppHeap blocks=");
            self.sys.printU64(summary.by_kind[r4os.abi.memory_kind_app_heap]);
            self.sys.println("");
        }
        return ok;
    }

    fn testMemoryProfiles(self: *App) bool {
        if (!self.sys.base.hasDevFn("memory_summary")) return self.failBool("R4X memory profile API missing");
        var info: r4os.abi.ProgramInstanceInfo = .{};
        var found = false;
        var index: u32 = 0;
        while (self.sys.programInstance(index, &info) > 0) : (index += 1) {
            if (tagEquals(info.memory_tag[0..], "bootdiag")) {
                found = true;
                break;
            }
        }
        if (!found) return self.failBool("BOOTDIAG memory profile instance missing");

        const profile_ok = info.memory_profile == r4os.abi.memory_profile_normal and
            info.memory_reserved_limit >= 1024 * 1024 * 1024 and
            info.memory_committed_limit >= 256 * 1024 * 1024 and
            info.memory_resident_limit >= 256 * 1024 * 1024 and
            info.stack_reserved_bytes >= 8 * 1024 * 1024 and
            info.stack_committed_bytes > 0 and
            info.memory_reserved_bytes >= info.stack_reserved_bytes and
            info.memory_committed_bytes > 0;
        self.printCheck("R4X memory profile snapshot", profile_ok);
        if (!profile_ok) {
            self.sys.write("  profile=");
            self.sys.printU64(info.memory_profile);
            self.sys.write(" reserve-limit=");
            self.sys.printU64(info.memory_reserved_limit);
            self.sys.write(" commit-limit=");
            self.sys.printU64(info.memory_committed_limit);
            self.sys.write(" resident-limit=");
            self.sys.printU64(info.memory_resident_limit);
            self.sys.write(" stack=");
            self.sys.printU64(info.stack_reserved_bytes);
            self.sys.write("/");
            self.sys.printU64(info.stack_committed_bytes);
            self.sys.println("");
            return false;
        }

        var rejected: r4os.abi.ProgramVmRegionInfo = .{};
        const reject_rc = self.sys.vmReserveRaw(info.memory_reserved_limit + 4096, 4096, r4os.abi.vm_region_flags_default, &rejected);
        const reject_ok = reject_rc == r4os.abi.vm_error_limit_exceeded and rejected.id == 0;
        self.printCheck("R4X memory profile limit", reject_ok);
        if (!reject_ok) {
            self.sys.write("  reserve-over-limit rc=");
            self.sys.printI32(reject_rc);
            self.sys.write(" id=");
            self.sys.printU64(rejected.id);
            self.sys.println("");
            if (rejected.id != 0) _ = self.sys.vmRelease(rejected.id);
            return false;
        }

        self.sys.write("  Memory profile=");
        self.sys.printU64(info.memory_profile);
        self.sys.write(" reserveMB=");
        self.sys.printU64(info.memory_reserved_limit / 1024 / 1024);
        self.sys.write(" commitMB=");
        self.sys.printU64(info.memory_committed_limit / 1024 / 1024);
        self.sys.write(" residentMB=");
        self.sys.printU64(info.memory_resident_limit / 1024 / 1024);
        self.sys.write(" usedKB=");
        self.sys.printU64(info.memory_committed_bytes / 1024);
        self.sys.println("");
        return true;
    }

    fn testLargeVirtualReserve(self: *App) bool {
        const probe_bytes: u64 = 4 * 1024 * 1024 * 1024;
        const probe = self.dev.memoryVmReserveProbe(probe_bytes) orelse return self.failBool("VM reserve probe unavailable");
        const ok = probe.status == 0 and
            probe.len >= probe_bytes and
            probe.reserved_bytes >= probe_bytes and
            probe.committed_bytes == 0 and
            probe.phys_len == 0 and
            probe.owner == r4os.abi.memory_owner_r4x_instance and
            probe.kind == r4os.abi.memory_kind_virtual_range and
            probe.block_status == r4os.abi.memory_status_reserved and
            probe.owner_id != 0 and
            probe.active_during > probe.active_before and
            probe.active_after == probe.active_before and
            probe.committed_during == probe.committed_before and
            probe.committed_after == probe.committed_before and
            probe.released != 0;
        self.printCheck("R4X VM multi-GB reserve", ok);
        if (!ok) {
            self.sys.write("  VM probe status=");
            self.sys.printI32(probe.status);
            self.sys.write(" len=");
            self.sys.printU64(probe.len);
            self.sys.write(" reserved=");
            self.sys.printU64(probe.reserved_bytes);
            self.sys.write(" committed=");
            self.sys.printU64(probe.committed_bytes);
            self.sys.write(" phys=");
            self.sys.printU64(probe.phys_len);
            self.sys.write(" active ");
            self.sys.printU64(probe.active_before);
            self.sys.write(" -> ");
            self.sys.printU64(probe.active_during);
            self.sys.write(" -> ");
            self.sys.printU64(probe.active_after);
            self.sys.println("");
            return false;
        }
        self.sys.write("  VM reserve MB=");
        self.sys.printU64(probe.reserved_bytes / 1024 / 1024);
        self.sys.write(" committed=");
        self.sys.printU64(probe.committed_bytes);
        self.sys.write(" largest-free MB=");
        self.sys.printU64(probe.largest_free_after / 1024 / 1024);
        self.sys.println("");
        return true;
    }

    fn testVmApiPath(self: *App) bool {
        const reserve_bytes: u64 = 128 * 1024 * 1024;
        const commit_bytes: u64 = 64 * 1024 * 1024;
        const reserved = self.sys.vmReserve(reserve_bytes, 4096, r4os.abi.vm_region_flags_default) orelse return self.failBool("VM reserve unavailable");
        var release_needed = true;
        defer {
            if (release_needed) _ = self.sys.vmRelease(reserved.id);
        }

        const reserve_ok = reserved.id != 0 and
            reserved.status == r4os.abi.memory_status_reserved and
            reserved.owner == r4os.abi.memory_owner_r4x_instance and
            reserved.kind == r4os.abi.memory_kind_virtual_range and
            reserved.window == r4os.abi.memory_window_r4x_vm and
            reserved.len >= reserve_bytes and
            reserved.committed_bytes == 0 and
            (reserved.flags & r4os.abi.vm_region_flag_writable) != 0;
        self.printCheck("R4SYS VM reserve API", reserve_ok);
        if (!reserve_ok) {
            self.printVmRegion("reserved", reserved);
            return false;
        }

        const flag_rc = self.sys.vmCommitFlags(reserved.id, 0, commit_bytes, r4os.abi.vm_region_flag_executable);
        const flag_ok = flag_rc == r4os.abi.vm_error_unsupported_flags;
        self.printCheck("R4SYS VM commit flag validation", flag_ok);
        if (!flag_ok) {
            self.sys.write("  VM commit flag rc=");
            self.sys.printI32(flag_rc);
            self.sys.println("");
            return false;
        }

        const before_commit = self.dev.memorySummary() orelse return self.failBool("memory summary before VM commit unavailable");
        const commit_rc = self.sys.vmCommit(reserved.id, 0, commit_bytes);
        if (commit_rc != r4os.abi.vm_ok) {
            self.sys.write("  VM commit rc=");
            self.sys.printI32(commit_rc);
            self.sys.println("");
            return false;
        }
        const after_commit = self.dev.memorySummary() orelse return self.failBool("memory summary after VM commit unavailable");
        const commit_phys_drop = physicalDrop(before_commit.free_physical_bytes, after_commit.free_physical_bytes);
        const demand_commit_ok = commit_phys_drop < 1024 * 1024;
        self.printCheck("R4SYS VM demand commit", demand_commit_ok);
        if (!demand_commit_ok) {
            self.sys.write("  VM commit physical drop=");
            self.sys.printU64(commit_phys_drop);
            self.sys.write(" bytes");
            self.sys.println("");
            return false;
        }

        const committed = self.sys.vmQuery(reserved.id) orelse return self.failBool("VM query after commit failed");
        const committed_ok = committed.status == r4os.abi.memory_status_committed and
            committed.committed_bytes >= commit_bytes and
            committed.base == reserved.base and
            committed.len == reserved.len;
        self.printCheck("R4SYS VM commit/query", committed_ok);
        if (!committed_ok) {
            self.printVmRegion("committed", committed);
            return false;
        }

        const ptr: [*]u8 = @ptrFromInt(committed.base);
        const sparse_touch_ok = touchSparse(ptr, commit_bytes, 0x61);
        const after_touch = self.dev.memorySummary() orelse return self.failBool("memory summary after VM touch unavailable");
        const touch_phys_drop = physicalDrop(after_commit.free_physical_bytes, after_touch.free_physical_bytes);
        const sparse_phys_ok = sparse_touch_ok and
            after_touch.free_physical_bytes < after_commit.free_physical_bytes and
            touch_phys_drop < commit_bytes / 8;
        self.printCheck("R4SYS VM sparse resident", sparse_phys_ok);
        if (!sparse_phys_ok) {
            self.sys.write("  VM touch physical drop=");
            self.sys.printU64(touch_phys_drop);
            self.sys.write(" commit=");
            self.sys.printU64(commit_bytes);
            self.sys.println("");
            return false;
        }

        const decommit_rc = self.sys.vmDecommit(reserved.id, 0, commit_bytes);
        if (decommit_rc != r4os.abi.vm_ok) {
            self.sys.write("  VM decommit rc=");
            self.sys.printI32(decommit_rc);
            self.sys.println("");
            return false;
        }

        const decommitted = self.sys.vmQuery(reserved.id) orelse return self.failBool("VM query after decommit failed");
        const decommit_ok = decommitted.status == r4os.abi.memory_status_reserved and decommitted.committed_bytes == 0;
        self.printCheck("R4SYS VM decommit", decommit_ok);
        if (!decommit_ok) {
            self.printVmRegion("decommitted", decommitted);
            return false;
        }

        const release_rc = self.sys.vmRelease(reserved.id);
        release_needed = false;
        const released_ok = release_rc == r4os.abi.vm_ok and self.sys.vmQuery(reserved.id) == null;
        self.printCheck("R4SYS VM release", released_ok);
        if (!released_ok) {
            self.sys.write("  VM release rc=");
            self.sys.printI32(release_rc);
            self.sys.println("");
            return false;
        }

        self.sys.write("  VM API region=");
        self.sys.printU64(reserved.id);
        self.sys.write(" reserve MB=");
        self.sys.printU64(reserved.len / 1024 / 1024);
        self.sys.write(" committed KB=");
        self.sys.printU64(commit_bytes / 1024);
        self.sys.write(" commit-drop=");
        self.sys.printU64(commit_phys_drop);
        self.sys.write(" touch-drop=");
        self.sys.printU64(touch_phys_drop);
        self.sys.println("");
        return true;
    }

    fn testSdkAllocatorV2(self: *App) bool {
        const before_summary = self.dev.memorySummary() orelse return self.failBool("SDK allocator memory summary before unavailable");
        const before_stats = self.sys.allocatorStats();
        const allocator = self.sys.allocator();

        var bytes: @import("std").ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        bytes.appendSlice(allocator, "R4OS") catch return self.failBool("SDK allocator ArrayList bytes");
        bytes.append(allocator, '-') catch return self.failBool("SDK allocator ArrayList append");
        bytes.appendSlice(allocator, "VMV2") catch return self.failBool("SDK allocator ArrayList growth");
        if (!@import("std").mem.eql(u8, bytes.items, "R4OS-VMV2")) return self.failBool("SDK allocator ArrayList data");

        var numbers: @import("std").ArrayList(u32) = .empty;
        defer numbers.deinit(allocator);
        var i: u32 = 0;
        while (i < 96) : (i += 1) numbers.append(allocator, i * 7 + 3) catch return self.failBool("SDK allocator small blocks");
        if (numbers.items.len != 96 or numbers.items[0] != 3 or numbers.items[95] != 668) return self.failBool("SDK allocator small data");

        const large = allocator.alloc(u8, 2 * 1024 * 1024) catch return self.failBool("SDK allocator large block");
        defer allocator.free(large);
        if ((@intFromPtr(large.ptr) & 4095) != 0) return self.failBool("SDK allocator large alignment");
        if (!touchSparse(large.ptr, large.len, 0x53)) return self.failBool("SDK allocator large touch");

        const during_summary = self.dev.memorySummary() orelse return self.failBool("SDK allocator memory summary during unavailable");
        const stats = self.sys.allocatorStats();
        const app_heap_retired = before_summary.by_kind[r4os.abi.memory_kind_app_heap] == 0 and
            during_summary.by_kind[r4os.abi.memory_kind_app_heap] == 0;
        const vm_visible = during_summary.by_kind[r4os.abi.memory_kind_virtual_range] > before_summary.by_kind[r4os.abi.memory_kind_virtual_range] and
            stats.small_regions > 0 and
            stats.active_allocations > before_stats.active_allocations and
            stats.active_bytes >= large.len;
        const ok = app_heap_retired and vm_visible;
        self.printCheck("SDK allocator V2 VM path", ok);
        if (!ok) {
            self.sys.write("  SDK alloc vm-kind ");
            self.sys.printU64(before_summary.by_kind[r4os.abi.memory_kind_virtual_range]);
            self.sys.write(" -> ");
            self.sys.printU64(during_summary.by_kind[r4os.abi.memory_kind_virtual_range]);
            self.sys.write(" appheap=");
            self.sys.printU64(during_summary.by_kind[r4os.abi.memory_kind_app_heap]);
            self.sys.write(" active-bytes=");
            self.sys.printU64(stats.active_bytes);
            self.sys.println("");
            return false;
        }
        self.sys.write("  SDK allocator regions=");
        self.sys.printU64(stats.small_regions);
        self.sys.write(" active-bytes=");
        self.sys.printU64(stats.active_bytes);
        self.sys.write(" committed=");
        self.sys.printU64(stats.committed_bytes);
        self.sys.println("");
        return true;
    }

    fn testSchedulerPath(self: *App) bool {
        const start = self.sys.ticks();
        self.sys.taskYield();
        self.sys.sleepTicks(1);
        const end = self.sys.ticks();
        const ok = end > start;
        self.printCheck("Scheduler yield/sleep", ok);
        if (!ok) return false;
        self.sys.write("  Scheduler ticks ");
        self.sys.printU64(start);
        self.sys.write(" -> ");
        self.sys.printU64(end);
        self.sys.println("");
        return true;
    }

    fn printCheck(self: *App, label: []const u8, ok: bool) void {
        self.sys.write("  ");
        self.sys.write(label);
        self.sys.write(": ");
        self.sys.println(if (ok) "OK" else "FAILED");
    }

    fn failBool(self: *App, msg: []const u8) bool {
        self.sys.write("  ");
        self.sys.println(msg);
        return false;
    }

    fn printVmRegion(self: *App, label: []const u8, info: r4os.abi.ProgramVmRegionInfo) void {
        self.sys.write("  VM ");
        self.sys.write(label);
        self.sys.write(" id=");
        self.sys.printU64(info.id);
        self.sys.write(" status=");
        self.sys.printU64(info.status);
        self.sys.write(" len=");
        self.sys.printU64(info.len);
        self.sys.write(" committed=");
        self.sys.printU64(info.committed_bytes);
        self.sys.write(" flags=");
        self.sys.printU64(info.flags);
        self.sys.println("");
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    return app.run();
}

fn touchSparse(mem: [*]u8, len: u64, seed: u8) bool {
    if (len < 4096) return false;
    const first: usize = 0;
    const middle: usize = @intCast((len / 2) & ~@as(u64, 4095));
    const last: usize = @intCast(len - 1);
    const middle_value = seed +% 1;
    const last_value = seed ^ 0xA5;
    mem[first] = seed;
    mem[middle] = middle_value;
    mem[last] = last_value;
    return mem[first] == seed and mem[middle] == middle_value and mem[last] == last_value;
}

fn physicalDrop(before: u64, after: u64) u64 {
    return if (before > after) before - after else 0;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn tagEquals(raw: []const u8, expected: []const u8) bool {
    var len: usize = 0;
    while (len < raw.len and raw[len] != 0) : (len += 1) {}
    if (len != expected.len) return false;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (raw[i] != expected[i]) return false;
    }
    return true;
}
