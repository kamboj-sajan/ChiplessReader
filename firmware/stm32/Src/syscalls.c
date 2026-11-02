/* syscalls.c - minimal newlib stubs (nothing here uses files; _write is in platform_stm32.c). */
#include <sys/stat.h>
#include <errno.h>

int _close(int f) { (void)f; return -1; }
int _fstat(int f, struct stat *st) { (void)f; st->st_mode = S_IFCHR; return 0; }
int _isatty(int f) { (void)f; return 1; }
int _lseek(int f, int p, int d) { (void)f; (void)p; (void)d; return 0; }
int _read(int f, char *p, int n) { (void)f; (void)p; (void)n; return 0; }
int _getpid(void) { return 1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
void _exit(int status) { (void)status; while (1) { } }
