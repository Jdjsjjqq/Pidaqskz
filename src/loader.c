/*
 * libkernelua_loader.so — Linux port of wsock32.dll (KerneLUA loader)
 *
 * Loaded into the Steam client via LD_PRELOAD (steam.sh hook installed by
 * install.sh). Two jobs, mirroring the Windows proxy DLL:
 *
 *   1. spawn kernelua/backend.py once per client session (the CreateProcessW
 *      + OpenMutexW part of the original), guarded by an abstract unix
 *      socket that the backend owns;
 *   2. intercept the exec family used by the client to launch
 *      steamwebhelper and append CEF remote-debugging flags so the backend
 *      can attach over CDP and inject the UI script.
 *
 * The original wsock32.dll is a pure export-forwarder proxy (ws2_32 +
 * MSWSOCK) plus the two behaviors above. On Linux there is no wsock32 to
 * hijack, and no forwarding layer is needed — the preload replaces the
 * proxy role entirely.
 *
 * Build: gcc -O2 -fPIC -shared -ldl src/loader.c -o build/libkernelua_loader.so
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define CDP_PORT "9222"
#define BACKEND_SOCK "\0kernelua_backend" /* abstract namespace = OpenMutexW */

static const char *kCdPortArg = "--remote-debugging-port=" CDP_PORT;
static const char *kCdOriginsArg = "--remote-allow-origins=*";

/* breadcrumb log: ~/.kernelua/loader.log — proves the .so was loaded
 * even when the backend never gets spawned */
static void klog(const char *fmt, ...)
{
    const char *home = getenv("HOME");
    if (!home || !*home)
        return;

    char dir[PATH_MAX], path[PATH_MAX];
    if (snprintf(dir, sizeof(dir), "%s/.kernelua", home) >= (int)sizeof(dir))
        return;
    mkdir(dir, 0755);
    if (snprintf(path, sizeof(path), "%s/loader.log", dir) >= (int)sizeof(path))
        return;

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;

    va_list ap;
    va_start(ap, fmt);
    vdprintf(fd, fmt, ap);
    va_end(ap);
    close(fd);
}

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static const char *base_name(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int is_webhelper(const char *path)
{
    const char *b = base_name(path);
    /* steamwebhelper, steamwebhelper.exe (proton), nothing else */
    return strncmp(b, "steamwebhelper", 14) == 0;
}

static int is_steam_client(const char *path)
{
    const char *b = base_name(path);
    return strcmp(b, "steam") == 0 || strcmp(b, "steam.sh") == 0;
}

/*
 * Build an augmented argv for steamwebhelper:
 *   - any existing --remote-debugging-port=... is replaced with ours
 *   - any existing --remote-allow-origins=... is replaced with ours
 *   - missing flags are appended
 * Returns a freshly allocated NULL-terminated array (strings point into
 * either the original argv or our statics). Caller frees the array only.
 */
static char **augment_argv(char *const argv[], size_t *count_out)
{
    size_t n = 0;
    while (argv[n])
        n++;

    /* worst case: original + 2 appended + NULL */
    char **na = calloc(n + 3, sizeof(char *));
    if (!na)
        return NULL;

    int have_port = 0, have_origins = 0;
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        const char *a = argv[i];
        if (strncmp(a, "--remote-debugging-port=", 24) == 0) {
            na[j++] = (char *)kCdPortArg;
            have_port = 1;
        } else if (strncmp(a, "--remote-allow-origins=", 23) == 0) {
            na[j++] = (char *)kCdOriginsArg;
            have_origins = 1;
        } else {
            na[j++] = argv[i];
        }
    }
    if (!have_port)
        na[j++] = (char *)kCdPortArg;
    if (!have_origins)
        na[j++] = (char *)kCdOriginsArg;
    na[j] = NULL;
    if (count_out)
        *count_out = j;
    klog("webhelper argv rewritten (cdp %s)\n", CDP_PORT);
    return na;
}

/* ------------------------------------------------------------------ */
/* backend single-instance + spawn                                    */
/* ------------------------------------------------------------------ */

/* dladdr on our constructor function -> path of this .so -> sibling backend.py */
static int backend_already_running(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return 0;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, BACKEND_SOCK, sizeof(BACKEND_SOCK));

    int ok = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    int saved = errno;
    close(fd);
    if (!ok && saved != ECONNREFUSED && saved != ENOENT)
        return 1; /* sockd exists but busy/permission -> assume running */
    return ok ? 1 : 0;
}

static void spawn_backend(void)
{
    Dl_info info;
    if (!dladdr((void *)spawn_backend, &info) || !info.dli_fname)
        return;

    char so_path[PATH_MAX];
    if (!realpath(info.dli_fname, so_path))
        return;

    char *slash = strrchr(so_path, '/');
    if (!slash)
        return;
    *slash = '\0';

    char backend[PATH_MAX];
    if (strlen(so_path) + 12 >= sizeof(backend))
        return;
    snprintf(backend, sizeof(backend), "%s/backend.py", so_path);

    if (access(backend, X_OK) != 0) {
        /* lib64/ + lib32/ layout: the .so sits one level below the payload,
           e.g. .../kernelua/lib32/libkernelua_loader.so -> ../backend.py */
        char *s2 = strrchr(so_path, '/');
        if (s2) {
            *s2 = '\0'; /* parent of the .so's dir */
            snprintf(backend, sizeof(backend), "%s/backend.py", so_path);
        }
    }

    if (access(backend, X_OK) != 0) {
        klog("backend.py missing or not executable: %s\n", backend);
        return;
    }

    /* detach: fork -> setsid -> fork -> exec */
    pid_t pid = fork();
    if (pid < 0) {
        klog("fork failed: %d\n", errno);
        return;
    }
    if (pid > 0) {
        waitpid(pid, NULL, 0); /* reap intermediate */
        return;
    }
    setsid();
    if (fork() < 0)
        _exit(1);

    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        dup2(devnull, 1);
        dup2(devnull, 2);
        if (devnull > 2)
            close(devnull);
    }

    char *const child_argv[] = { (char *)backend, NULL };
    execv(backend, child_argv);
    _exit(1);
}

/* ------------------------------------------------------------------ */
/* constructor                                                        */
/* ------------------------------------------------------------------ */

static void init_loader(void) __attribute__((constructor));
static void init_loader(void)
{
    char cmdline[4096] = { 0 };
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, cmdline, sizeof(cmdline) - 1);
        (void)r;
        close(fd);
    }
    /* cmdline is NUL-separated; argv[0] is first */
    if (cmdline[0] == '\0')
        return;

    {
        const char *b = base_name(cmdline);
        int client = is_steam_client(cmdline);
        int helper = is_webhelper(cmdline);

        /* breadcrumb for every process we actually care about */
        if (client || helper)
            klog("loader loaded pid=%d comm=%s\n", (int)getpid(), b);

        if (client) {
            /* belt-and-braces: the wrapper normally starts the backend;
               this ctor path covers launches that skip the wrapper */
            if (backend_already_running()) {
                klog("backend already running\n");
            } else {
                klog("spawning backend (ctor fallback)\n");
                spawn_backend();
            }
        }
        /* webhelper needs no init work here: the exec hook in the client
         * process is what rewrites its command line */
    }
}

/* ------------------------------------------------------------------ */
/* exec family hooks                                                  */
/* ------------------------------------------------------------------ */

/*
 * glibc routes execv/execvp/execl* to execve *inside* libc, bypassing the
 * PLT — interposing execve alone silently misses those callers. Hook the
 * whole public family; every entry point forwards to its real counterpart
 * with an augmented argv.
 */

static int (*real_execve)(const char *, char *const[], char *const[]) = NULL;
static int (*real_execv)(const char *, char *const[]) = NULL;
static int (*real_execvp)(const char *, char *const[]) = NULL;
static int (*real_execvpe)(const char *, char *const[], char *const[]) = NULL;
static int (*real_posix_spawn)(pid_t *, const char *,
                               const posix_spawn_file_actions_t *,
                               const posix_spawnattr_t *,
                               char *const[], char *const[]) = NULL;
static int (*real_posix_spawnp)(pid_t *, const char *,
                                const posix_spawn_file_actions_t *,
                                const posix_spawnattr_t *,
                                char *const[], char *const[]) = NULL;

#define RESOLVE(fn)                                                        \
    do {                                                                   \
        if (!real_##fn)                                                    \
            real_##fn = dlsym(RTLD_NEXT, #fn);                             \
    } while (0)

#define EXEC_ARGS_MAX 256

int execve(const char *path, char *const argv[], char *const envp[])
{
    RESOLVE(execve);
    if (!is_webhelper(path))
        return real_execve(path, argv, envp);

    char **na = augment_argv(argv, NULL);
    int r = real_execve(path, na ? na : argv, envp);
    free(na);
    return r;
}

int execv(const char *path, char *const argv[])
{
    RESOLVE(execv);
    if (!is_webhelper(path))
        return real_execv(path, argv);

    char **na = augment_argv(argv, NULL);
    int r = real_execv(path, na ? na : argv);
    free(na);
    return r;
}

int execvp(const char *file, char *const argv[])
{
    RESOLVE(execvp);
    if (!is_webhelper(file))
        return real_execvp(file, argv);

    char **na = augment_argv(argv, NULL);
    int r = real_execvp(file, na ? na : argv);
    free(na);
    return r;
}

int execvpe(const char *file, char *const argv[], char *const envp[])
{
    RESOLVE(execvpe);
    if (!is_webhelper(file))
        return real_execvpe(file, argv, envp);

    char **na = augment_argv(argv, NULL);
    int r = real_execvpe(file, na ? na : argv, envp);
    free(na);
    return r;
}

static char **collect_varargs(const char *arg, va_list ap, char *const **envp_out)
{
    static char *argv[EXEC_ARGS_MAX];
    size_t i = 0;

    argv[i++] = (char *)arg;
    for (;;) {
        const char *s;
        if (i >= EXEC_ARGS_MAX - 1)
            return NULL;
        s = va_arg(ap, const char *);
        if (!s) {
            if (envp_out)
                *envp_out = va_arg(ap, char *const *);
            break;
        }
        argv[i++] = (char *)s;
    }
    argv[i] = NULL;
    return argv;
}

int execl(const char *path, const char *arg, ...)
{
    va_list ap;
    char **argv;

    va_start(ap, arg);
    argv = collect_varargs(arg, ap, NULL);
    va_end(ap);
    if (!argv) {
        errno = E2BIG;
        return -1;
    }

    RESOLVE(execv);
    if (!is_webhelper(path))
        return real_execv(path, argv);

    char **na = augment_argv(argv, NULL);
    int r = real_execv(path, na ? na : argv);
    free(na);
    return r;
}

int execlp(const char *file, const char *arg, ...)
{
    va_list ap;
    char **argv;

    va_start(ap, arg);
    argv = collect_varargs(arg, ap, NULL);
    va_end(ap);
    if (!argv) {
        errno = E2BIG;
        return -1;
    }

    RESOLVE(execvp);
    if (!is_webhelper(file))
        return real_execvp(file, argv);

    char **na = augment_argv(argv, NULL);
    int r = real_execvp(file, na ? na : argv);
    free(na);
    return r;
}

int execle(const char *path, const char *arg, ...)
{
    va_list ap;
    char *const *envp = NULL;
    char **argv;

    va_start(ap, arg);
    argv = collect_varargs(arg, ap, &envp);
    va_end(ap);
    if (!argv) {
        errno = E2BIG;
        return -1;
    }

    RESOLVE(execve);
    if (!is_webhelper(path))
        return real_execve(path, argv, envp);

    char **na = augment_argv(argv, NULL);
    int r = real_execve(path, na ? na : argv, envp);
    free(na);
    return r;
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[])
{
    RESOLVE(posix_spawn);
    if (!is_webhelper(path))
        return real_posix_spawn(pid, path, fa, attr, argv, envp);

    char **na = augment_argv(argv, NULL);
    int r = real_posix_spawn(pid, path, fa, attr, na ? na : argv, envp);
    free(na);
    return r;
}

int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[])
{
    RESOLVE(posix_spawnp);
    if (!is_webhelper(file))
        return real_posix_spawnp(pid, file, fa, attr, argv, envp);

    char **na = augment_argv(argv, NULL);
    int r = real_posix_spawnp(pid, file, fa, attr, na ? na : argv, envp);
    free(na);
    return r;
}
