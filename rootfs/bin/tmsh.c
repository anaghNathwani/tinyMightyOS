/*
 * tmsh — TinyMightyOS Shell
 *
 * A POSIX-ish shell with extra unhinged features:
 *   chaos mode  — randomizes your PS1 every command
 *   time!       — nanosecond timing for any command
 *   bg!         — run command in background + notify on finish
 *   alias!      — persistent aliases saved to ~/.tmsh_aliases
 *   calc        — expression evaluator (via bc or awk fallback)
 *
 * Compile: gcc -O2 -o tmsh tmsh.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <ctype.h>
#include <signal.h>
#include <time.h>
#include <dirent.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <pwd.h>
#include <glob.h>

#define MAX_LINE    4096
#define MAX_ARGS    256
#define MAX_ALIASES 128
#define HIST_SIZE   1000
#define VERSION     "1.0.0"

/* ── Colors ───────────────────────────────────────────────────────────────── */
#define C_RED     "\033[1;31m"
#define C_GREEN   "\033[1;32m"
#define C_YELLOW  "\033[1;33m"
#define C_BLUE    "\033[1;34m"
#define C_MAGENTA "\033[1;35m"
#define C_CYAN    "\033[1;36m"
#define C_WHITE   "\033[1;37m"
#define C_ORANGE  "\033[38;5;202m"
#define C_PINK    "\033[38;5;205m"
#define C_RESET   "\033[0m"

/* ── State ────────────────────────────────────────────────────────────────── */

typedef struct {
    char name[64];
    char value[MAX_LINE];
} Alias;

static Alias   aliases[MAX_ALIASES];
static int     alias_count = 0;
static char   *history[HIST_SIZE];
static int     hist_count  = 0;
static int     chaos_mode  = 0;
static int     last_exit   = 0;
static char    alias_file[512];
static char    hist_file[512];

/* ── Chaos mode colors / symbols ──────────────────────────────────────────── */

static const char *chaos_colors[] = {
    C_RED, C_GREEN, C_YELLOW, C_BLUE, C_MAGENTA, C_CYAN, C_ORANGE, C_PINK
};
static const char *chaos_symbols[] = {
    "⚡", "🔥", "💀", "⚔️ ", "🌀", "💥", "🎯", "🦾", "👾", "🚀", "⭐", "🌪️ "
};
#define NCOLORS  (int)(sizeof(chaos_colors)  / sizeof(chaos_colors[0]))
#define NSYMBOLS (int)(sizeof(chaos_symbols) / sizeof(chaos_symbols[0]))

/* ── Utilities ────────────────────────────────────────────────────────────── */

static char *trim(char *s) {
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)*(e-1))) *--e = '\0';
    return s;
}

static char *strdup_safe(const char *s) {
    char *r = strdup(s);
    if (!r) { perror("strdup"); exit(1); }
    return r;
}

/* ── Alias management ─────────────────────────────────────────────────────── */

static const char *alias_lookup(const char *name) {
    for (int i = 0; i < alias_count; i++)
        if (strcmp(aliases[i].name, name) == 0) return aliases[i].value;
    return NULL;
}

static void alias_set(const char *name, const char *value, int persist) {
    for (int i = 0; i < alias_count; i++) {
        if (strcmp(aliases[i].name, name) == 0) {
            strncpy(aliases[i].value, value, MAX_LINE - 1);
            goto maybe_persist;
        }
    }
    if (alias_count >= MAX_ALIASES) { fprintf(stderr, "tmsh: alias table full\n"); return; }
    strncpy(aliases[alias_count].name,  name,  63);
    strncpy(aliases[alias_count].value, value, MAX_LINE - 1);
    alias_count++;

maybe_persist:
    if (!persist || !alias_file[0]) return;
    FILE *f = fopen(alias_file, "a");
    if (f) { fprintf(f, "alias %s='%s'\n", name, value); fclose(f); }
}

static void load_aliases(void) {
    if (!alias_file[0]) return;
    FILE *f = fopen(alias_file, "r");
    if (!f) return;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        char *s = trim(line);
        if (strncmp(s, "alias ", 6) != 0) continue;
        s += 6;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *name = trim(s);
        char *val  = trim(eq + 1);
        /* strip surrounding quotes */
        size_t vl = strlen(val);
        if (vl >= 2 && val[0] == '\'' && val[vl-1] == '\'') {
            val[vl-1] = '\0'; val++;
        }
        alias_set(name, val, 0);
    }
    fclose(f);
}

/* ── History ──────────────────────────────────────────────────────────────── */

static void hist_add(const char *line) {
    if (!line || !line[0]) return;
    /* avoid duplicates */
    if (hist_count > 0 && strcmp(history[(hist_count-1) % HIST_SIZE], line) == 0) return;
    free(history[hist_count % HIST_SIZE]);
    history[hist_count % HIST_SIZE] = strdup_safe(line);
    hist_count++;
}

static void hist_save(void) {
    if (!hist_file[0]) return;
    FILE *f = fopen(hist_file, "a");
    if (!f) return;
    int start = hist_count > HIST_SIZE ? hist_count - HIST_SIZE : 0;
    for (int i = start; i < hist_count; i++)
        if (history[i % HIST_SIZE])
            fprintf(f, "%s\n", history[i % HIST_SIZE]);
    fclose(f);
}

static void hist_load(void) {
    if (!hist_file[0]) return;
    FILE *f = fopen(hist_file, "r");
    if (!f) return;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = '\0';
        hist_add(line);
    }
    fclose(f);
}

/* ── PS1 prompt ───────────────────────────────────────────────────────────── */

static void print_prompt(void) {
    char cwd[512];
    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "?");

    /* shorten home dir */
    const char *home = getenv("HOME");
    char *display_cwd = cwd;
    char short_cwd[512];
    if (home && strncmp(cwd, home, strlen(home)) == 0) {
        snprintf(short_cwd, sizeof(short_cwd), "~%s", cwd + strlen(home));
        display_cwd = short_cwd;
    }

    const char *user = getenv("USER");
    if (!user) user = "user";
    char host[64];
    gethostname(host, sizeof(host));
    host[strcspn(host, ".")] = '\0';

    if (chaos_mode) {
        srand((unsigned)time(NULL) ^ (unsigned)getpid());
        const char *col = chaos_colors[rand() % NCOLORS];
        const char *sym = chaos_symbols[rand() % NSYMBOLS];
        fprintf(stdout, "%s%s %s@%s %s%s %s$%s ",
                col, sym, user, host, display_cwd, C_RESET, col, C_RESET);
    } else {
        const char *status_col = last_exit ? C_RED : C_GREEN;
        fprintf(stdout,
                C_CYAN "%s" C_RESET "@" C_BLUE "%s" C_RESET ":"
                C_YELLOW "%s" C_RESET " %s$" C_RESET " ",
                user, host, display_cwd, status_col);
    }
    fflush(stdout);
}

/* ── Tokenizer ────────────────────────────────────────────────────────────── */

static int tokenize(char *line, char **argv, int max_argv) {
    int argc = 0;
    char *p  = line;

    while (*p && argc < max_argv - 1) {
        while (isspace((unsigned char)*p)) p++;
        if (!*p) break;

        char *start;
        if (*p == '"') {
            p++;
            start = p;
            while (*p && *p != '"') p++;
            if (*p == '"') *p++ = '\0';
        } else if (*p == '\'') {
            p++;
            start = p;
            while (*p && *p != '\'') p++;
            if (*p == '\'') *p++ = '\0';
        } else {
            start = p;
            while (*p && !isspace((unsigned char)*p)) p++;
            if (*p) *p++ = '\0';
        }

        /* env var expansion ($VAR) */
        if (start[0] == '$') {
            const char *expanded = getenv(start + 1);
            argv[argc++] = (char *)(expanded ? expanded : "");
        } else {
            argv[argc++] = start;
        }
    }
    argv[argc] = NULL;
    return argc;
}

/* ── Pipeline execution ───────────────────────────────────────────────────── */

static int exec_simple(char **argv, int argc, int bg) {
    (void)argc;

    /* alias expansion */
    const char *alias_val = alias_lookup(argv[0]);
    char expanded[MAX_LINE];
    char *real_argv[MAX_ARGS];
    int real_argc = 0;

    if (alias_val) {
        strncpy(expanded, alias_val, MAX_LINE - 1);
        real_argc = tokenize(expanded, real_argv, MAX_ARGS);
        /* append remaining args */
        for (int i = 1; argv[i] && real_argc < MAX_ARGS - 1; i++)
            real_argv[real_argc++] = argv[i];
        real_argv[real_argc] = NULL;
        argv = real_argv;
    }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }

    if (pid == 0) {
        if (bg) {
            setsid();
            int null = open("/dev/null", O_RDWR);
            if (null >= 0) { dup2(null, STDIN_FILENO); close(null); }
        }
        execvp(argv[0], argv);
        fprintf(stderr, "tmsh: %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    if (bg) {
        fprintf(stdout, "[bg] pid %d\n", pid);
        return 0;
    }

    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

/* ── Built-ins ────────────────────────────────────────────────────────────── */

static int builtin_cd(char **argv) {
    const char *dir = argv[1];
    if (!dir) dir = getenv("HOME");
    if (!dir) dir = "/";
    if (chdir(dir) < 0) { perror("cd"); return 1; }
    return 0;
}

static int builtin_export(char **argv) {
    if (!argv[1]) { fprintf(stderr, "export: missing argument\n"); return 1; }
    char *eq = strchr(argv[1], '=');
    if (eq) {
        *eq = '\0';
        setenv(argv[1], eq + 1, 1);
        *eq = '=';
    } else {
        /* export existing variable */
    }
    return 0;
}

static int builtin_alias(char **argv, int persist) {
    if (!argv[1]) {
        for (int i = 0; i < alias_count; i++)
            printf("alias %s='%s'\n", aliases[i].name, aliases[i].value);
        return 0;
    }
    char *eq = strchr(argv[1], '=');
    if (!eq) { fprintf(stderr, "alias: expected name=value\n"); return 1; }
    *eq = '\0';
    alias_set(argv[1], eq + 1, persist);
    *eq = '=';
    return 0;
}

static int builtin_chaos(char **argv) {
    if (!argv[1] || strcmp(argv[1], "on") == 0) {
        chaos_mode = 1;
        printf("%sChaos mode ENGAGED. Your prompt will never be the same.%s\n", C_ORANGE, C_RESET);
    } else if (strcmp(argv[1], "off") == 0) {
        chaos_mode = 0;
        printf("%sChaos mode disengaged. Boring.%s\n", C_BLUE, C_RESET);
    } else {
        fprintf(stderr, "chaos: on|off\n");
        return 1;
    }
    return 0;
}

static int builtin_calc(char **argv) {
    if (!argv[1]) { fprintf(stderr, "calc: expression required\n"); return 1; }

    /* join all args */
    char expr[MAX_LINE] = "";
    for (int i = 1; argv[i]; i++) {
        strncat(expr, argv[i], MAX_LINE - strlen(expr) - 2);
        strncat(expr, " ",    MAX_LINE - strlen(expr) - 1);
    }

    /* try bc first */
    char cmd[MAX_LINE + 64];
    snprintf(cmd, sizeof(cmd), "echo '%s' | bc -l 2>/dev/null", expr);
    int ret = system(cmd);
    if (ret != 0) {
        /* fallback: awk */
        snprintf(cmd, sizeof(cmd), "awk 'BEGIN{print (%s)}'", expr);
        ret = system(cmd);
    }
    return ret;
}

static int builtin_history(void) {
    int start = hist_count > 20 ? hist_count - 20 : 0;
    for (int i = start; i < hist_count; i++) {
        const char *h = history[i % HIST_SIZE];
        if (h) printf("  %4d  %s\n", i + 1, h);
    }
    return 0;
}

static int builtin_fetch(void) {
    /* tmos-fetch: print system info */
    char host[64]; gethostname(host, sizeof(host));
    const char *user = getenv("USER");
    char cwd[512];  getcwd(cwd, sizeof(cwd));

    printf(C_RED
           "  ████████╗███╗   ███╗ ██████╗ ███████╗\n"
           "     ██╔══╝████╗ ████║██╔═══██╗██╔════╝\n"
           "     ██║   ██╔████╔██║██║   ██║███████╗\n"
           "     ██║   ██║╚██╔╝██║██║   ██║╚════██║\n"
           "     ██║   ██║ ╚═╝ ██║╚██████╔╝███████║\n"
           "     ╚═╝   ╚═╝     ╚═╝ ╚═════╝ ╚══════╝\n"
           C_RESET);

    printf(C_CYAN "  OS" C_RESET "         TinyMightyOS 1.0.0 \"Unhinged Ungulate\"\n");
    printf(C_CYAN "  Host" C_RESET "       %s\n", host);
    printf(C_CYAN "  User" C_RESET "       %s\n", user ? user : "unknown");
    printf(C_CYAN "  Shell" C_RESET "      tmsh %s\n", VERSION);
    printf(C_CYAN "  CWD" C_RESET "        %s\n", cwd);

    /* read uptime */
    FILE *f = fopen("/proc/uptime", "r");
    if (f) {
        double up;
        fscanf(f, "%lf", &up);
        fclose(f);
        int h = (int)up / 3600;
        int m = ((int)up % 3600) / 60;
        int s = (int)up % 60;
        printf(C_CYAN "  Uptime" C_RESET "     %dh %dm %ds\n", h, m, s);
    }

    /* read /proc/meminfo */
    f = fopen("/proc/meminfo", "r");
    if (f) {
        char key[64]; long val;
        long total = 0, avail = 0;
        char line[128];
        while (fgets(line, sizeof(line), f)) {
            if (sscanf(line, "%63s %ld", key, &val) == 2) {
                if (strcmp(key, "MemTotal:") == 0) total = val;
                if (strcmp(key, "MemAvailable:") == 0) avail = val;
            }
        }
        fclose(f);
        printf(C_CYAN "  Memory" C_RESET "     %ld MiB / %ld MiB\n",
               (total - avail) / 1024, total / 1024);
    }

    /* cpu model */
    f = fopen("/proc/cpuinfo", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "model name", 10) == 0) {
                char *colon = strchr(line, ':');
                if (colon) printf(C_CYAN "  CPU" C_RESET "        %s", trim(colon + 1));
                break;
            }
        }
        fclose(f);
    }

    printf("\n" C_ORANGE "  BE UNGOVERNABLE" C_RESET "\n\n");
    return 0;
}

static int builtin_version(void) {
    printf("tmsh %s — TinyMightyOS shell\n", VERSION);
    printf("chaos mode: %s\n", chaos_mode ? "ON 🔥" : "off");
    return 0;
}

/* ── Command dispatch ─────────────────────────────────────────────────────── */

static int dispatch(char *line) {
    if (!line || !line[0]) return 0;

    /* strip leading whitespace */
    line = trim(line);
    if (line[0] == '#') return 0;

    hist_add(line);

    /* detect special prefixes */
    int timed  = (strncmp(line, "time! ", 6) == 0);
    int bg     = (strncmp(line, "bg! ",   4) == 0);

    char *cmd_line = line;
    if (timed)  cmd_line = line + 6;
    if (bg)     cmd_line = line + 4;

    char buf[MAX_LINE];
    strncpy(buf, cmd_line, MAX_LINE - 1);

    char *argv[MAX_ARGS];
    int argc = tokenize(buf, argv, MAX_ARGS);
    if (!argc) return 0;

    struct timespec t0, t1;
    if (timed) clock_gettime(CLOCK_MONOTONIC, &t0);

    int ret = 0;

    /* built-ins */
    if (strcmp(argv[0], "exit") == 0 || strcmp(argv[0], "quit") == 0) {
        hist_save();
        exit(argv[1] ? atoi(argv[1]) : last_exit);
    }
    else if (strcmp(argv[0], "cd")       == 0) ret = builtin_cd(argv);
    else if (strcmp(argv[0], "export")   == 0) ret = builtin_export(argv);
    else if (strcmp(argv[0], "alias")    == 0) ret = builtin_alias(argv, 0);
    else if (strcmp(argv[0], "alias!")   == 0) ret = builtin_alias(argv, 1);
    else if (strcmp(argv[0], "unalias")  == 0) {
        if (argv[1]) {
            for (int i = 0; i < alias_count; i++) {
                if (strcmp(aliases[i].name, argv[1]) == 0) {
                    memmove(&aliases[i], &aliases[i+1], (alias_count-i-1)*sizeof(Alias));
                    alias_count--;
                    break;
                }
            }
        }
    }
    else if (strcmp(argv[0], "chaos")    == 0) ret = builtin_chaos(argv);
    else if (strcmp(argv[0], "calc")     == 0) ret = builtin_calc(argv);
    else if (strcmp(argv[0], "history")  == 0) ret = builtin_history();
    else if (strcmp(argv[0], "fetch")    == 0) ret = builtin_fetch();
    else if (strcmp(argv[0], "version")  == 0) ret = builtin_version();
    else if (strcmp(argv[0], "pwd")      == 0) {
        char cwd[512]; getcwd(cwd, sizeof(cwd)); puts(cwd);
    }
    else if (strcmp(argv[0], "true")     == 0) ret = 0;
    else if (strcmp(argv[0], "false")    == 0) ret = 1;
    else if (strcmp(argv[0], ":")        == 0) ret = 0;
    else ret = exec_simple(argv, argc, bg);

    if (timed) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) +
                         (t1.tv_nsec - t0.tv_nsec) / 1e9;
        printf(C_CYAN "[time!] %.9f seconds" C_RESET "\n", elapsed);
    }

    last_exit = ret;
    return ret;
}

/* ── Line reader (simple, no readline dep) ────────────────────────────────── */

static char *read_line(void) {
    static char buf[MAX_LINE];
    if (!fgets(buf, sizeof(buf), stdin)) return NULL;
    buf[strcspn(buf, "\n")] = '\0';
    return buf;
}

/* ── Source a file ────────────────────────────────────────────────────────── */

static void source_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = '\0';
        dispatch(line);
    }
    fclose(f);
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    /* set up paths */
    const char *home = getenv("HOME");
    if (!home) home = "/root";
    snprintf(alias_file, sizeof(alias_file), "%s/.tmsh_aliases", home);
    snprintf(hist_file,  sizeof(hist_file),  "%s/.tmsh_history",  home);

    /* default env */
    if (!getenv("PATH"))
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    if (!getenv("TERM"))
        setenv("TERM", "xterm-256color", 1);

    /* load config */
    load_aliases();
    hist_load();

    /* source rc file */
    char rc[512];
    snprintf(rc, sizeof(rc), "%s/.tmshrc", home);
    source_file(rc);
    source_file("/etc/tmos/tmshrc");

    /* non-interactive: run a command or script */
    if (argc > 1) {
        if (strcmp(argv[1], "-c") == 0) {
            if (!argv[2]) { fprintf(stderr, "tmsh: -c requires argument\n"); return 1; }
            return dispatch(argv[2]);
        }
        /* run script file */
        source_file(argv[1]);
        return last_exit;
    }

    /* interactive mode */
    int interactive = isatty(STDIN_FILENO);
    if (interactive) {
        printf(C_RED "tmsh %s" C_RESET " — type 'fetch' for system info, 'chaos on' for fun\n\n",
               VERSION);
    }

    while (1) {
        if (interactive) print_prompt();
        char *line = read_line();
        if (!line) {
            if (interactive) printf("\nexit\n");
            break;
        }
        dispatch(line);
    }

    hist_save();
    return last_exit;
}
