// MiniTerm Mosh embedding API. GPL-3.0-or-later; see ../COPYING.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MTMosh MTMosh;
typedef void (*MTMoshOutput)(void *, const uint8_t *, size_t);
typedef void (*MTMoshStatus)(void *, int); // 1 first frame, 2 stalled, 3 resumed
// All inputs copied. run() must execute exactly once on a dedicated thread.
MTMosh *mt_mosh_create(const char *numeric_ip, uint16_t port, const char *key, uint16_t columns, uint16_t rows);
// 0 clean, 1 engine failure, 2 cancelled, 3 UDP startup timeout, 4 UTF-8 locale unavailable
int mt_mosh_run(MTMosh *, void *, MTMoshOutput, MTMoshStatus);
// Thread-safe. Send rejects the entire chunk when its bounded queue is full.
int mt_mosh_send(MTMosh *, const uint8_t *, size_t);
void mt_mosh_resize(MTMosh *, uint16_t, uint16_t);
void mt_mosh_pause(MTMosh *, int);
void mt_mosh_stop(MTMosh *);
// Only after run() has returned (or if never run).
void mt_mosh_destroy(MTMosh *);
#ifdef __cplusplus
}
#endif
