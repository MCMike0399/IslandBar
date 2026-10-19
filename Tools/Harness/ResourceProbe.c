// Per-process CPU time and physical footprint, without Activity Monitor's smoothing.
// Usage: resource-probe <pid> <seconds>; JSON on stdout. One CPU core is 100%.
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static struct rusage_info_v4 usage(pid_t pid) {
    struct rusage_info_v4 value = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&value) != 0) {
        perror("proc_pid_rusage");
        exit(1);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc != 3 || atoi(argv[1]) <= 0 || atoi(argv[2]) <= 0) return 2;
    pid_t pid = (pid_t)atoi(argv[1]);
    int seconds = atoi(argv[2]);
    struct rusage_info_v4 first = usage(pid), last = first;
    struct timespec start, end, delay = {.tv_sec = 1};
    clock_gettime(CLOCK_MONOTONIC, &start);
    double footprint = 0;
    for (int i = 0; i < seconds; ++i) {
        struct timespec remaining = delay;
        while (nanosleep(&remaining, &remaining) != 0) {}
        last = usage(pid);
        footprint += last.ri_phys_footprint;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
    // rusage reports Mach absolute time, which is not nanoseconds on Apple Silicon.
    // Calibrate with a CPU-bound process before using this to compare app builds.
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double cpu = ((last.ri_user_time - first.ri_user_time)
        + (last.ri_system_time - first.ri_system_time))
        * (double)timebase.numer / timebase.denom / 1e9;
    printf("{\"pid\":%d,\"seconds\":%.3f,\"cpu_percent\":%.4f,"
        "\"footprint_mib\":%.3f,\"idle_wakeups_per_second\":%.3f}\n",
        pid, elapsed, 100 * cpu / elapsed, footprint / seconds / (1024 * 1024),
        (last.ri_pkg_idle_wkups - first.ri_pkg_idle_wkups) / elapsed);
}
