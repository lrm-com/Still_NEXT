#ifndef STILL_AUDIO_H
#define STILL_AUDIO_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define STILL_API __declspec(dllexport)
#else
  #define STILL_API __attribute__((visibility("default")))
#endif

/* ── Opaque handles ─────────────────────────────────────────────────── */

typedef struct StillPlayer StillPlayer;

/* ── Enums ──────────────────────────────────────────────────────────── */

typedef enum {
  STILL_STOPPED  = 0,
  STILL_LOADING  = 1,
  STILL_PLAYING  = 2,
  STILL_PAUSED   = 3,
  STILL_SEEKING  = 4,
  STILL_END_OF_LIST = 5,
} StillPlaybackStatus;

typedef enum {
  STILL_LOOP_OFF        = 0,
  STILL_LOOP_ALL        = 1,
  STILL_LOOP_ONE        = 2,
} StillLoopMode;

/* ── Callbacks ──────────────────────────────────────────────────────── */

/* Position / duration updates – called from audio thread, keep fast. */
typedef void (*StillPositionCallback)(double positionSec, double durationSec, void* userData);

/* State changes (status, track index). */
typedef void (*StillStateCallback)(StillPlaybackStatus status, int32_t currentIndex, void* userData);

/* Spectrum magnitudes – called from audio thread.
   magnitudes: dB values, length = fftSize/2. */
typedef void (*StillSpectrumCallback)(const float* magnitudes, int32_t length, void* userData);

/* ── Lifecycle ──────────────────────────────────────────────────────── */

STILL_API StillPlayer* still_create(void);
STILL_API void         still_destroy(StillPlayer* player);

/* ── Callbacks registration ─────────────────────────────────────────── */

STILL_API void still_set_position_callback(StillPlayer* p, StillPositionCallback cb, void* userData);
STILL_API void still_set_state_callback(StillPlayer* p, StillStateCallback cb, void* userData);
STILL_API void still_set_spectrum_callback(StillPlayer* p, StillSpectrumCallback cb, void* userData);

/* ── Queue management ───────────────────────────────────────────────── */

/* Replace the entire queue. Files are decoded on demand. */
STILL_API int32_t still_set_queue(StillPlayer* p,
                                  const char* const* filePaths,
                                  int32_t count);

STILL_API int32_t still_get_current_index(StillPlayer* p);
STILL_API int32_t still_get_queue_length(StillPlayer* p);

/* ── Playback control ───────────────────────────────────────────────── */

STILL_API int  still_play(StillPlayer* p);
STILL_API int  still_pause(StillPlayer* p);
STILL_API int  still_stop(StillPlayer* p);
STILL_API int  still_seek(StillPlayer* p, double positionSec);
STILL_API int  still_seek_to_track(StillPlayer* p, int32_t index);

/* ── Properties ─────────────────────────────────────────────────────── */

STILL_API int  still_set_volume(StillPlayer* p, float volume);
STILL_API int  still_set_speed(StillPlayer* p, float speed);
STILL_API int  still_set_loop_mode(StillPlayer* p, StillLoopMode mode);
STILL_API int  still_set_muted(StillPlayer* p, bool muted);

STILL_API float still_get_volume(StillPlayer* p);
STILL_API float still_get_speed(StillPlayer* p);
STILL_API double still_get_position(StillPlayer* p);
STILL_API double still_get_duration(StillPlayer* p);
STILL_API StillPlaybackStatus still_get_status(StillPlayer* p);

/* ── Equalizer (10-band) ───────────────────────────────────────────── */

/* Gains: array of 10 floats in dB, range [-12, +12].
   Band order: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz. */
STILL_API int  still_set_equalizer_bands(StillPlayer* p, const float* gainsDb, int32_t count);

/* Bass boost: enabled flag + gain in dB. */
STILL_API int  still_set_bass_boost(StillPlayer* p, bool enabled, float gainDb);

/* Treble boost: enabled flag + gain in dB. */
STILL_API int  still_set_treble_boost(StillPlayer* p, bool enabled, float gainDb);

/* ── ReplayGain ─────────────────────────────────────────────────────── */

STILL_API int  still_set_replay_gain(StillPlayer* p, float gainDb);

/* ── Fade ───────────────────────────────────────────────────────────── */

STILL_API int  still_fade_in(StillPlayer* p, float durationSec);
STILL_API int  still_fade_out(StillPlayer* p, float durationSec);

/* ── Spectrum analysis ──────────────────────────────────────────────── */

STILL_API int  still_set_fft_size(StillPlayer* p, int32_t size);

/* ── Error info ─────────────────────────────────────────────────────── */

STILL_API const char* still_last_error(StillPlayer* p);

#ifdef __cplusplus
}
#endif

#endif /* STILL_AUDIO_H */
