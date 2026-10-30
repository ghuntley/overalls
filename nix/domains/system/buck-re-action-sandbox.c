/**
 * @cc [owner:ghuntley,label:security;isolation] buck-re-action-sandbox
 * The NativeLink worker's entrypoint for every remote action (ADR-0272).
 * Only the worker user MAY run it. It MUST run the action as ACTION_USER,
 * never the worker user, with no capabilities, no_new_privs and file
 * descriptors above stderr closed, in fresh mount, PID, IPC, UTS and network
 * namespaces: the action sees no network, no process outside its own PID
 * namespace, no sibling action directory, and none of HIDDEN_PATHS (the
 * worker's identity, store and this helper). When the action's PID 1 ends,
 * every process it left is killed with it. Afterwards it MUST make what the
 * action wrote group-accessible so the worker can upload and remove it.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/capability.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef WORK_ROOT
#error "WORK_ROOT must name the worker's work_directory"
#endif
#ifndef WORKER_USER
#error "WORKER_USER must name the worker user"
#endif
#ifndef ACTION_USER
#error "ACTION_USER must name the action user"
#endif
#ifndef HIDDEN_PATHS
#error "HIDDEN_PATHS must list the paths masked from actions"
#endif

static const char *const hidden_paths[] = {HIDDEN_PATHS, NULL};
static volatile sig_atomic_t child_pid = 0;

static void fail(const char *what) {
  fprintf(stderr, "buck-re-action-sandbox: %s: %s\n", what, strerror(errno));
  exit(126);
}

static void refuse(const char *what) {
  fprintf(stderr, "buck-re-action-sandbox: %s\n", what);
  exit(126);
}

/* A SIGTERM or SIGINT for the helper ends the whole action namespace. */
static void forward(int signal_number) {
  (void)signal_number;
  if (child_pid > 0) {
    kill((pid_t)child_pid, SIGKILL);
  }
}

static void mount_tmpfs(const char *target, const char *options) {
  if (mount("buck-re-action", target, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, options) != 0) {
    fail(target);
  }
}

static void mkdir_p(const char *path) {
  char buffer[PATH_MAX];
  size_t length = strlen(path);
  if (length == 0 || length >= sizeof buffer) {
    refuse("action directory path too long");
  }
  memcpy(buffer, path, length + 1);
  for (char *slash = buffer + 1; *slash != '\0'; slash++) {
    if (*slash != '/') {
      continue;
    }
    *slash = '\0';
    if (mkdir(buffer, 0755) != 0 && errno != EEXIST) {
      fail(buffer);
    }
    *slash = '/';
  }
  if (mkdir(buffer, 0755) != 0 && errno != EEXIST) {
    fail(buffer);
  }
}

/* Leaves only the action's own directory under WORK_ROOT visible. */
static void isolate_action_directory(const char *action_directory) {
  if (mount(action_directory, action_directory, NULL, MS_BIND | MS_REC, NULL) != 0) {
    fail("bind action directory");
  }
  int saved = open(action_directory, O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (saved < 0) {
    fail("open action directory");
  }
  mount_tmpfs(WORK_ROOT, "mode=0755,size=1m");
  mkdir_p(action_directory);
  char source[64];
  snprintf(source, sizeof source, "/proc/self/fd/%d", saved);
  if (mount(source, action_directory, NULL, MS_BIND | MS_REC, NULL) != 0) {
    fail("restore action directory");
  }
  close(saved);
  /* A private /tmp on the worker's disk, removed with the action. */
  char tmp[PATH_MAX];
  if ((size_t)snprintf(tmp, sizeof tmp, "%s/tmp", action_directory) >= sizeof tmp) {
    refuse("action tmp path too long");
  }
  if (mkdir(tmp, 0770) != 0 && errno != EEXIST) {
    fail("mkdir action tmp");
  }
  if (mount(tmp, "/tmp", NULL, MS_BIND, NULL) != 0) {
    fail("bind /tmp");
  }
}

static void hide_worker_paths(void) {
  for (const char *const *path = hidden_paths; *path != NULL; path++) {
    struct stat info;
    if (stat(*path, &info) != 0) {
      if (errno == ENOENT || errno == EACCES) {
        continue;
      }
      fail(*path);
    }
    mount_tmpfs(*path, "mode=0000,size=4k");
  }
}

static void drop_to(const struct passwd *action) {
  if (setgroups(0, NULL) != 0) {
    fail("setgroups");
  }
  if (setresgid(action->pw_gid, action->pw_gid, action->pw_gid) != 0) {
    fail("setresgid");
  }
  if (setresuid(action->pw_uid, action->pw_uid, action->pw_uid) != 0) {
    fail("setresuid");
  }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    fail("no_new_privs");
  }
  /* The credential change clears it, so it is set afterwards. */
  if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) {
    fail("pdeathsig");
  }
  if (getuid() != action->pw_uid || geteuid() != action->pw_uid || getgid() != action->pw_gid) {
    refuse("credentials did not change");
  }
  /* A change between two non-root ids keeps capabilities: drop them all. */
  struct __user_cap_header_struct header = {_LINUX_CAPABILITY_VERSION_3, 0};
  struct __user_cap_data_struct data[2];
  memset(data, 0, sizeof data);
  if (syscall(SYS_capset, &header, data) != 0) {
    fail("capset");
  }
}

static int make_group_accessible(const char *path, const struct stat *info, int type, struct FTW *walk) {
  (void)walk;
  if (type == FTW_SL || type == FTW_SLN || info->st_uid != getuid()) {
    return 0;
  }
  /* Permission bits only: the unit refuses setuid and setgid modes. */
  mode_t wanted = info->st_mode & 0777;
  wanted |= S_IRGRP | S_IWGRP | S_IRUSR | S_IWUSR;
  if (S_ISDIR(info->st_mode) || (info->st_mode & S_IXUSR) != 0) {
    wanted |= S_IXGRP | S_IXUSR;
  }
  (void)chmod(path, wanted);
  return 0;
}

/* PID 1 of the action's namespaces, already the action user: runs the
 * action, reaps whatever it orphans, then hands its files to the worker's
 * group. Returning ends the namespace and every process left in it. */
static int run_action(char **argv, const char *action_directory) {
  pid_t pid = fork();
  if (pid < 0) {
    fail("fork action");
  }
  if (pid == 0) {
    if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) {
      fail("close_range");
    }
    execvp(argv[0], argv);
    fail(argv[0]);
  }
  int status = 0;
  for (;;) {
    int reaped_status;
    pid_t reaped = waitpid(-1, &reaped_status, 0);
    if (reaped == pid) {
      status = reaped_status;
      break;
    }
    if (reaped < 0 && errno != EINTR) {
      fail("waitpid action");
    }
  }
  (void)nftw(action_directory, make_group_accessible, 64, FTW_PHYS);
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    refuse("usage: buck-re-action-sandbox COMMAND [ARG]...");
  }
  const struct passwd *worker = getpwnam(WORKER_USER);
  if (worker == NULL || getuid() != worker->pw_uid) {
    refuse("only the worker user may run actions");
  }
  const uid_t worker_uid = worker->pw_uid;
  const struct passwd *found = getpwnam(ACTION_USER);
  if (found == NULL || found->pw_uid == 0 || found->pw_uid == worker_uid) {
    refuse("the action user is missing or unsafe");
  }
  const struct passwd action_entry = *found;

  char cwd[PATH_MAX];
  if (getcwd(cwd, sizeof cwd) == NULL) {
    fail("getcwd");
  }
  const size_t root_length = strlen(WORK_ROOT);
  if (strncmp(cwd, WORK_ROOT "/", root_length + 1) != 0) {
    refuse("the action does not run under the work directory");
  }
  char action_directory[PATH_MAX];
  const char *operation = cwd + root_length + 1;
  const char *end = strchr(operation, '/');
  size_t length = end == NULL ? strlen(cwd) : (size_t)(end - cwd);
  if (operation[0] == '\0' || operation[0] == '.' || length >= sizeof action_directory) {
    refuse("the action directory is invalid");
  }
  memcpy(action_directory, cwd, length);
  action_directory[length] = '\0';

  if (unshare(CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWUTS | CLONE_NEWNET) != 0) {
    fail("unshare");
  }
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    fail("private mounts");
  }
  isolate_action_directory(action_directory);
  hide_worker_paths();

  struct sigaction handler = {0};
  handler.sa_handler = forward;
  sigemptyset(&handler.sa_mask);
  sigaction(SIGTERM, &handler, NULL);
  sigaction(SIGINT, &handler, NULL);

  pid_t pid = fork();
  if (pid < 0) {
    fail("fork");
  }
  if (pid == 0) {
    /* PID 1 of the action's namespace: its /proc shows only the action. */
    if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
      fail("mount /proc");
    }
    drop_to(&action_entry);
    if (chdir(cwd) != 0) {
      fail("chdir");
    }
    _exit(run_action(argv + 1, action_directory));
  }
  child_pid = pid;
  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      fail("waitpid");
    }
  }
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}
