// Starts a program the way another app (luoke-core) would start an accessory's job, and measures it: wall time and
// peak memory (phys_footprint, what the kernel charges it). It stops the program with SIGTERM after --timeout seconds,
// or at once when memory pressure reaches critical.
//
// --disclaim: the child answers for itself (responsibility_spawnattrs_setdisclaim, as browsers and terminals start
// helpers). Without it, macOS's privacy checks (TCC: Photos, folders) charge the child to the app that started it — for
// a job luoke-core starts, luoke-core's permissions, not luoke-search's. Used to find out which.
//
//   clang -O2 -o .dev/spawn_measured scripts/spawn_measured.c
//   .dev/spawn_measured [--disclaim] [--timeout S] [--pid-file F] -- <program> [arguments...]
//
// Prints one line to stderr: "spawn: exit N, S s, peak footprint M MB[, stopped: …]". The program's own output passes
// through untouched.
#include <dlfcn.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int pressure(void) {
    int level = 0;
    size_t size = sizeof level;
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0) != 0) return 0;
    return level;
}

int main(int argc, char **argv) {
    int disclaim = 0, index = 1;
    double timeout = 0;
    const char *pidFile = NULL;
    for (; index < argc; index++) {
        if (strcmp(argv[index], "--disclaim") == 0) disclaim = 1;
        else if (strcmp(argv[index], "--timeout") == 0 && index + 1 < argc) timeout = atof(argv[++index]);
        else if (strcmp(argv[index], "--pid-file") == 0 && index + 1 < argc) pidFile = argv[++index];
        else if (strcmp(argv[index], "--") == 0) { index++; break; }
        else break;
    }
    if (index >= argc) {
        fprintf(stderr, "usage: spawn_measured [--disclaim] [--timeout S] [--pid-file F] -- program [args...]\n");
        return 2;
    }
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    if (disclaim) {
        int (*setDisclaim)(posix_spawnattr_t *, int) =
            (int (*)(posix_spawnattr_t *, int))dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
        if (!setDisclaim || setDisclaim(&attributes, 1) != 0) {
            fprintf(stderr, "spawn: can't disclaim responsibility on this system\n");
            return 2;
        }
    }
    pid_t child;
    double started = now();
    int error = posix_spawn(&child, argv[index], NULL, &attributes, &argv[index], environ);
    posix_spawnattr_destroy(&attributes);
    if (error != 0) {
        fprintf(stderr, "spawn: can't start the program (%s)\n", strerror(error));
        return 2;
    }
    if (pidFile) {
        FILE *file = fopen(pidFile, "w");
        if (file) { fprintf(file, "%d\n", child); fclose(file); }
    }
    const char *stopped = NULL;
    siginfo_t info;
    for (;;) {
        memset(&info, 0, sizeof info);
        // WNOWAIT: once it has exited, it stays a zombie so its lifetime peak can still be read.
        if (waitid(P_PID, child, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == child) break;
        if (!stopped && timeout > 0 && now() - started > timeout) {
            stopped = "timeout";
            kill(child, SIGTERM);
        }
        if (!stopped && pressure() >= 4) {
            stopped = "memory pressure critical";
            kill(child, SIGTERM);
        }
        usleep(200 * 1000);
    }
    double seconds = now() - started;
    struct rusage_info_v4 usage;
    double peak = -1;
    if (proc_pid_rusage(child, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
        peak = usage.ri_lifetime_max_phys_footprint / 1048576.0;
    }
    int status = 0;
    waitpid(child, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    fprintf(stderr, "spawn: exit %d, %.1f s, peak footprint %.0f MB%s%s\n", code, seconds, peak,
            stopped ? ", stopped: " : "", stopped ? stopped : "");
    return code;
}
