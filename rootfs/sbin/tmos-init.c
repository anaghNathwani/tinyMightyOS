/*
 * tmos-init — TinyMightyOS PID 1
 *
 * A hand-rolled init system for people who think systemd is too comfortable.
 * Starts services in parallel, reaps zombies, handles signals, and boots fast.
 *
 * Compile: gcc -O2 -static -o tmos-init tmos-init.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <dirent.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/reboot.h>
#include <sys/prctl.h>
#include <linux/reboot.h>

#define MAX_SERVICES    64
#define MAX_LINE        512
#define SVC_DIR         "/etc/tmos/services"
#define LOG_FILE        "/var/log/tmos-init.log"
#define REBOOT_CMD      "/sbin/tmos-init reboot"

typedef enum {
    SVC_STOPPED,
    SVC_STARTING,
    SVC_RUNNING,
    SVC_FAILED,
    SVC_DISABLED,
} SvcState;

typedef struct {
    char     name[64];
    char     command[256];
    char     after[64];          /* single dep for simplicity */
    int      restart;
    int      restart_delay;
    SvcState state;
    pid_t    pid;
} Service;

static Service services[MAX_SERVICES];
static int     svc_count = 0;
static int     shutting_down = 0;
static FILE   *logfp = NULL;

/* ── Logging ──────────────────────────────────────────────────────────────── */

static void tmos_log(const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    char buf[MAX_LINE];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    /* always write to stderr (kernel console) */
    fprintf(stderr, "[tmos-init %4ld.%03ld] %s\n",
            ts.tv_sec, ts.tv_nsec / 1000000, buf);

    if (logfp) {
        fprintf(logfp, "[%4ld.%03ld] %s\n",
                ts.tv_sec, ts.tv_nsec / 1000000, buf);
        fflush(logfp);
    }
}

/* ── Essential mounts ─────────────────────────────────────────────────────── */

static void mount_essential(void) {
    struct {
        const char *src, *tgt, *type, *opts;
        unsigned long flags;
    } mounts[] = {
        { "proc",     "/proc",     "proc",     NULL,       MS_NODEV | MS_NOSUID | MS_NOEXEC },
        { "sysfs",    "/sys",      "sysfs",    NULL,       MS_NODEV | MS_NOSUID | MS_NOEXEC },
        { "devtmpfs", "/dev",      "devtmpfs", "mode=755", MS_NOSUID | MS_STRICTATIME },
        { "devpts",   "/dev/pts",  "devpts",   "mode=620,gid=5", MS_NOSUID | MS_NOEXEC },
        { "tmpfs",    "/dev/shm",  "tmpfs",    "mode=1777", MS_NOSUID | MS_NODEV },
        { "tmpfs",    "/run",      "tmpfs",    "mode=755,size=10%", MS_NOSUID | MS_NODEV },
        { "tmpfs",    "/tmp",      "tmpfs",    "mode=1777,size=20%", MS_NOSUID | MS_NODEV },
        { "cgroup2",  "/sys/fs/cgroup", "cgroup2", NULL,  MS_NOSUID | MS_NODEV | MS_NOEXEC },
        { NULL }
    };

    for (int i = 0; mounts[i].src; i++) {
        /* create mountpoint if missing */
        mkdir(mounts[i].tgt, 0755);
        if (mount(mounts[i].src, mounts[i].tgt, mounts[i].type,
                  mounts[i].flags, mounts[i].opts) < 0) {
            tmos_log("WARN: mount %s -> %s failed: %s",
                     mounts[i].src, mounts[i].tgt, strerror(errno));
        } else {
            tmos_log("mounted %s", mounts[i].tgt);
        }
    }
}

/* ── Service file parser ──────────────────────────────────────────────────── */

static void parse_service(const char *path, Service *svc) {
    FILE *f = fopen(path, "r");
    if (!f) return;

    memset(svc, 0, sizeof(*svc));
    svc->restart_delay = 1;

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        /* strip newline */
        line[strcspn(line, "\n")] = '\0';

        if (line[0] == '#' || line[0] == '[' || line[0] == '\0') continue;

        char key[64], val[256];
        if (sscanf(line, "%63[^=]=%255[^\n]", key, val) != 2) continue;

        /* trim leading space from val */
        char *v = val;
        while (*v == ' ' || *v == '\t') v++;

        if      (strcmp(key, "Name")         == 0) strncpy(svc->name, v, 63);
        else if (strcmp(key, "Command")      == 0) strncpy(svc->command, v, 255);
        else if (strcmp(key, "After")        == 0) strncpy(svc->after, v, 63);
        else if (strcmp(key, "Restart")      == 0) svc->restart = (strcmp(v, "always") == 0);
        else if (strcmp(key, "RestartDelay") == 0) svc->restart_delay = atoi(v);
        else if (strcmp(key, "Disabled")     == 0) svc->state = SVC_DISABLED;
    }
    fclose(f);
}

static void load_services(void) {
    DIR *d = opendir(SVC_DIR);
    if (!d) {
        tmos_log("no services dir %s, continuing", SVC_DIR);
        return;
    }

    struct dirent *ent;
    while ((ent = readdir(d)) && svc_count < MAX_SERVICES) {
        size_t nl = strlen(ent->d_name);
        if (nl < 5 || strcmp(ent->d_name + nl - 4, ".svc") != 0) continue;

        char path[512];
        snprintf(path, sizeof(path), "%s/%s", SVC_DIR, ent->d_name);
        parse_service(path, &services[svc_count]);

        if (services[svc_count].name[0] && services[svc_count].command[0]) {
            tmos_log("loaded service: %s", services[svc_count].name);
            svc_count++;
        }
    }
    closedir(d);
    tmos_log("loaded %d services", svc_count);
}

/* ── Service lifecycle ────────────────────────────────────────────────────── */

static Service *find_service(const char *name) {
    for (int i = 0; i < svc_count; i++)
        if (strcmp(services[i].name, name) == 0) return &services[i];
    return NULL;
}

static void start_service(Service *svc) {
    if (svc->state == SVC_DISABLED || svc->state == SVC_RUNNING ||
        svc->state == SVC_STARTING) return;

    /* check dependency */
    if (svc->after[0]) {
        Service *dep = find_service(svc->after);
        if (dep && dep->state != SVC_RUNNING) {
            tmos_log("service %s waiting for %s", svc->name, svc->after);
            return;
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        tmos_log("FATAL: fork failed for %s: %s", svc->name, strerror(errno));
        svc->state = SVC_FAILED;
        return;
    }

    if (pid == 0) {
        /* child: exec the service */
        setsid();
        int null = open("/dev/null", O_RDONLY);
        if (null >= 0) { dup2(null, STDIN_FILENO); close(null); }

        /* build log path */
        char logpath[256];
        snprintf(logpath, sizeof(logpath), "/var/log/%s.log", svc->name);
        int lfd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (lfd >= 0) {
            dup2(lfd, STDOUT_FILENO);
            dup2(lfd, STDERR_FILENO);
            close(lfd);
        }

        /* tokenize command */
        char cmd[256];
        strncpy(cmd, svc->command, sizeof(cmd) - 1);
        char *argv[32];
        int argc = 0;
        char *tok = strtok(cmd, " \t");
        while (tok && argc < 31) { argv[argc++] = tok; tok = strtok(NULL, " \t"); }
        argv[argc] = NULL;

        execv(argv[0], argv);
        fprintf(stderr, "execv(%s) failed: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    svc->pid   = pid;
    svc->state = SVC_RUNNING;
    tmos_log("started %s (pid %d)", svc->name, pid);
}

static void start_all_services(void) {
    /* multiple passes to resolve ordering */
    for (int pass = 0; pass < 8; pass++) {
        int started = 0;
        for (int i = 0; i < svc_count; i++) {
            if (services[i].state == SVC_STOPPED) {
                start_service(&services[i]);
                if (services[i].state != SVC_STOPPED) started++;
            }
        }
        if (!started) break;
        usleep(50000); /* 50ms between waves */
    }
}

/* ── Zombie reaper ────────────────────────────────────────────────────────── */

static void reap_children(void) {
    int status;
    pid_t pid;

    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < svc_count; i++) {
            if (services[i].pid != pid) continue;

            int exit_code = WIFEXITED(status)   ? WEXITSTATUS(status) :
                            WIFSIGNALED(status)  ? -WTERMSIG(status)   : -1;

            tmos_log("service %s (pid %d) exited: %d",
                     services[i].name, pid, exit_code);
            services[i].pid   = 0;
            services[i].state = exit_code == 0 ? SVC_STOPPED : SVC_FAILED;

            if (services[i].restart && !shutting_down) {
                tmos_log("restarting %s in %ds", services[i].name,
                         services[i].restart_delay);
                /* mark stopped so next pass restarts it */
                services[i].state = SVC_STOPPED;
            }
            break;
        }
    }
}

/* ── Signal handling ──────────────────────────────────────────────────────── */

static volatile sig_atomic_t sig_reboot   = 0;
static volatile sig_atomic_t sig_poweroff = 0;
static volatile sig_atomic_t sig_hup      = 0;

static void sig_handler(int s) {
    if (s == SIGTERM || s == SIGUSR2) sig_poweroff = 1;
    if (s == SIGINT  || s == SIGUSR1) sig_reboot   = 1;
    if (s == SIGHUP)                  sig_hup      = 1;
}

static void setup_signals(void) {
    struct sigaction sa = { .sa_handler = sig_handler, .sa_flags = SA_RESTART };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    /* ignore SIGPIPE — services die, not us */
    signal(SIGPIPE, SIG_IGN);
}

/* ── Shutdown ─────────────────────────────────────────────────────────────── */

static void shutdown_system(int do_reboot) {
    shutting_down = 1;
    tmos_log("shutting down (reboot=%d)", do_reboot);

    /* signal all services */
    for (int i = 0; i < svc_count; i++) {
        if (services[i].pid > 0) {
            kill(services[i].pid, SIGTERM);
        }
    }

    /* give them 5 seconds */
    struct timespec deadline;
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += 5;

    while (1) {
        reap_children();

        int alive = 0;
        for (int i = 0; i < svc_count; i++)
            if (services[i].pid > 0) alive++;
        if (!alive) break;

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec >= deadline.tv_sec) {
            tmos_log("SIGKILL time");
            for (int i = 0; i < svc_count; i++)
                if (services[i].pid > 0) kill(services[i].pid, SIGKILL);
            break;
        }
        usleep(100000);
    }

    sync();
    tmos_log("sync complete, %s", do_reboot ? "rebooting" : "powering off");

    if (do_reboot) reboot(RB_AUTOBOOT);
    else           reboot(RB_POWER_OFF);
}

/* ── Welcome banner ───────────────────────────────────────────────────────── */

static void print_banner(void) {
    const char *banner =
        "\033[1;31m"
        " _____ _             __  __ _       _     _         ___  ____  \n"
        "|_   _(_)_ __  _   _|  \\/  (_) __ _| |__ | |_ _   _/ _ \\/ ___| \n"
        "  | | | | '_ \\| | | | |\\/| | |/ _` | '_ \\| __| | | | | |\\___ \\ \n"
        "  | | | | | | | |_| | |  | | | (_| | | | | |_| |_| | |_| |___) |\n"
        "  |_| |_|_| |_|\\__, |_|  |_|_|\\__, |_| |_|\\__|\\__, |\\___/|____/ \n"
        "               |___/           |___/            |___/             \n"
        "\033[0;33m"
        "                    BE UNGOVERNABLE\n"
        "\033[0m\n";
    fputs(banner, stderr);
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    /* handle reboot/poweroff subcommands */
    if (argc > 1) {
        if (strcmp(argv[1], "reboot")   == 0) { sync(); reboot(RB_AUTOBOOT);   }
        if (strcmp(argv[1], "poweroff") == 0) { sync(); reboot(RB_POWER_OFF);  }
        if (strcmp(argv[1], "halt")     == 0) { sync(); reboot(RB_HALT_SYSTEM);}
        fprintf(stderr, "usage: tmos-init [reboot|poweroff|halt]\n");
        return 1;
    }

    if (getpid() != 1) {
        fprintf(stderr, "tmos-init: not running as PID 1, aborting\n");
        return 1;
    }

    /* become a subreaper so we inherit orphaned processes */
    prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);

    print_banner();
    tmos_log("tmos-init starting (pid 1)");

    mount_essential();

    /* open log file after /var is mounted */
    mkdir("/var/log", 0755);
    logfp = fopen(LOG_FILE, "a");

    setup_signals();
    load_services();
    start_all_services();

    tmos_log("init loop running");

    /* main loop */
    while (1) {
        reap_children();

        if (sig_hup) {
            sig_hup = 0;
            tmos_log("SIGHUP: reloading services");
            load_services();
            start_all_services();
        }

        if (sig_poweroff) { shutdown_system(0); }
        if (sig_reboot)   { shutdown_system(1); }

        /* restart any stopped-and-restart services */
        if (!shutting_down) {
            for (int i = 0; i < svc_count; i++) {
                if (services[i].restart && services[i].state == SVC_STOPPED)
                    start_service(&services[i]);
            }
        }

        usleep(200000); /* poll at 5 Hz — low CPU, fast enough */
    }

    return 0; /* unreachable */
}
