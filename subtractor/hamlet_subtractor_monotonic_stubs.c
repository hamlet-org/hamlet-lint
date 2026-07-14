#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <time.h>

CAMLprim value hamlet_subtractor_monotonic_now(value unit) {
  CAMLparam1(unit);
#if defined(_WIN32)
  caml_failwith("Hamlet's resolver monotonic clock is POSIX-only");
#else
  struct timespec timestamp;
  if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
    caml_failwith("clock_gettime(CLOCK_MONOTONIC) failed");
  }
  double seconds = (double)timestamp.tv_sec;
  seconds += (double)timestamp.tv_nsec / 1000000000.0;
  CAMLreturn(caml_copy_double(seconds));
#endif
}
