#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

// DPI-C helper: returns monotonic wall-clock time in milliseconds.
// longint in SV maps to long long in C.
long long get_wall_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

#ifdef __cplusplus
}
#endif
