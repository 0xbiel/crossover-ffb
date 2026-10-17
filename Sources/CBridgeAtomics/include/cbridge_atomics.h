// Acquire/release accessors for the shared-memory seqlocks (see bridge/shm.h).
#pragma once
#include <stdint.h>
static inline uint32_t cfb_load32_acquire(const void *p) { return __atomic_load_n((const volatile uint32_t *)p, __ATOMIC_ACQUIRE); }
static inline void cfb_store32_release(void *p, uint32_t v) { __atomic_store_n((volatile uint32_t *)p, v, __ATOMIC_RELEASE); }
static inline void cfb_store32_relaxed(void *p, uint32_t v) { __atomic_store_n((volatile uint32_t *)p, v, __ATOMIC_RELAXED); }
static inline void cfb_store64_relaxed(void *p, uint64_t v) { __atomic_store_n((volatile uint64_t *)p, v, __ATOMIC_RELAXED); }
static inline uint64_t cfb_load64_acquire(const void *p) { return __atomic_load_n((const volatile uint64_t *)p, __ATOMIC_ACQUIRE); }
static inline void cfb_fence(void) { __atomic_thread_fence(__ATOMIC_SEQ_CST); }
