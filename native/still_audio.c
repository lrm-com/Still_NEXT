/*
 * still_audio.c – miniaudio-based audio engine for Still NEXT
 *
 * Features:
 *   - Decode + output via miniaudio (no WMF dependency)
 *   - 10-band parametric equalizer
 *   - Real-time FFT spectrum analysis
 *   - ReplayGain, fade in/out
 *   - Playlist / queue management with loop modes
 *
 * Build (Windows MSVC):
 *   cl /LD /O2 /I. still_audio.c /link /OUT:still_audio.dll
 *
 * Build (MinGW):
 *   gcc -shared -o still_audio.dll still_audio.c -I. -lm -lole32 -loleaut32 -lwinmm -lws2_32
 */

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING      1
#define MA_NO_GENERATION    1

#include "miniaudio.h"
#include "still_audio.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#ifdef _WIN32
#include <windows.h>
#endif

/* ═══════════════════════════════════════════════════════════════════════
 *  Constants
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAX_QUEUE        1024
#define STILL_MAX_PATH   4096
#define DEFAULT_FFT      1024
#define EQ_BAND_COUNT    10
#define EQ_FREQS_HZ      {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}

/* ═══════════════════════════════════════════════════════════════════════
 *  FFT (simple radix-2 Cooley–Tukey, runs on audio thread – keep fast)
 * ═══════════════════════════════════════════════════════════════════════ */

static void fft_radix2(float* real, float* imag, int n) {
    int j = 0;
    for (int i = 1; i < n; i++) {
        int bit = n >> 1;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            float t = real[i]; real[i] = real[j]; real[j] = t;
            t = imag[i]; imag[i] = imag[j]; imag[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        float ang = -2.0f * 3.14159265f / (float)len;
        float wr = cosf(ang), wi = sinf(ang);
        for (int i = 0; i < n; i += len) {
            float cur_r = 1.0f, cur_i = 0.0f;
            for (int k = 0; k < len / 2; k++) {
                int u = i + k, v = i + k + len / 2;
                float tr = cur_r * real[v] - cur_i * imag[v];
                float ti = cur_r * imag[v] + cur_i * real[v];
                real[v] = real[u] - tr;  imag[v] = imag[u] - ti;
                real[u] += tr;           imag[u] += ti;
                float nr = cur_r * wr - cur_i * wi;
                cur_i   = cur_r * wi + cur_i * wr;
                cur_r   = nr;
            }
        }
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Biquad filter (for bass/treble shelf, matching Dart-side EQ)
 * ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} Biquad;

static void biquad_reset(Biquad* b) {
    b->x1 = b->x2 = b->y1 = b->y2 = 0;
}

static void biquad_peaking(Biquad* b, float freq, float gainDb, float sampleRate, float Q) {
    if (fabsf(gainDb) < 0.01f) {
        b->b0 = 1; b->b1 = b->b2 = b->a1 = b->a2 = 0;
        return;
    }
    float A  = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * 3.14159265f * freq / sampleRate;
    float alpha = sinf(w0) / (2.0f * Q);
    float cosw  = cosf(w0);
    float b0 = 1.0f + alpha * A;
    float b1 = -2.0f * cosw;
    float b2 = 1.0f - alpha * A;
    float a0 = 1.0f + alpha / A;
    float a1 = -2.0f * cosw;
    float a2 = 1.0f - alpha / A;
    b->b0 = b0/a0; b->b1 = b1/a0; b->b2 = b2/a0;
    b->a1 = a1/a0; b->a2 = a2/a0;
}

static void biquad_low_shelf(Biquad* b, float freq, float gainDb, float sampleRate, float Q) {
    if (fabsf(gainDb) < 0.01f) {
        b->b0 = 1; b->b1 = b->b2 = b->a1 = b->a2 = 0;
        return;
    }
    float A  = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * 3.14159265f * freq / sampleRate;
    float alpha = sinf(w0) / (2.0f * Q);
    float cosw  = cosf(w0);
    float sqrtA = sqrtf(A);
    float beta  = 2.0f * sqrtA * alpha;
    float b0 = A*((A+1) - (A-1)*cosw + beta);
    float b1 = 2*A*((A-1) - (A+1)*cosw);
    float b2 = A*((A+1) - (A-1)*cosw - beta);
    float a0 = (A+1) + (A-1)*cosw + beta;
    float a1 = -2*((A-1) + (A+1)*cosw);
    float a2 = (A+1) + (A-1)*cosw - beta;
    b->b0 = b0/a0; b->b1 = b1/a0; b->b2 = b2/a0;
    b->a1 = a1/a0; b->a2 = a2/a0;
}

static void biquad_high_shelf(Biquad* b, float freq, float gainDb, float sampleRate, float Q) {
    if (fabsf(gainDb) < 0.01f) {
        b->b0 = 1; b->b1 = b->b2 = b->a1 = b->a2 = 0;
        return;
    }
    float A  = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * 3.14159265f * freq / sampleRate;
    float alpha = sinf(w0) / (2.0f * Q);
    float cosw  = cosf(w0);
    float sqrtA = sqrtf(A);
    float beta  = 2.0f * sqrtA * alpha;
    float b0 = A*((A+1) + (A-1)*cosw + beta);
    float b1 = -2*A*((A-1) + (A+1)*cosw);
    float b2 = A*((A+1) + (A-1)*cosw - beta);
    float a0 = (A+1) - (A-1)*cosw + beta;
    float a1 = 2*((A-1) - (A+1)*cosw);
    float a2 = (A+1) - (A-1)*cosw - beta;
    b->b0 = b0/a0; b->b1 = b1/a0; b->b2 = b2/a0;
    b->a1 = a1/a0; b->a2 = a2/a0;
}

static float biquad_process(Biquad* b, float input) {
    float output = b->b0*input + b->b1*b->x1 + b->b2*b->x2 - b->a1*b->y1 - b->a2*b->y2;
    b->x2 = b->x1; b->x1 = input;
    b->y2 = b->y1; b->y1 = output;
    return output;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  EQ band descriptor
 * ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    Biquad filter[2];   /* per-stereo-channel (L=0, R=1) */
    float  freq;
    float  gainDb;
} EqBand;

/* ═══════════════════════════════════════════════════════════════════════
 *  Track info (decoded metadata, kept per-queue slot)
 * ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    char   path[STILL_MAX_PATH];
    double durationSec;
    ma_bool32 loaded;     /* whether decoder was opened */
    ma_decoder decoder;
} TrackInfo;

/* ═══════════════════════════════════════════════════════════════════════
 *  StillPlayer – the one and only instance
 * ═══════════════════════════════════════════════════════════════════════ */

struct StillPlayer {
    /* ── miniaudio core ─────────────────────────────────── */
    ma_device          device;
    ma_device_config   deviceConfig;
    ma_engine          engine;          /* reserved for future use */
    ma_resource_manager rm;

    /* ── decoding ───────────────────────────────────────── */
    TrackInfo          queue[MAX_QUEUE];
    int32_t            queueLen;
    int32_t            currentIndex;

    /* ── playback state ─────────────────────────────────── */
    StillPlaybackStatus status;
    StillLoopMode      loopMode;
    float              volume;
    float              speed;
    bool               muted;
    float              positionSec;
    float              durationSec;

    /* ── equalizer (10-band) ────────────────────────────── */
    EqBand             eqBands[EQ_BAND_COUNT];
    Biquad             bassBoost;      /* low-shelf, L channel */
    Biquad             bassBoostR;     /* low-shelf, R channel */
    Biquad             trebleBoost;    /* high-shelf, L channel */
    Biquad             trebleBoostR;   /* high-shelf, R channel */
    bool               bassBoostOn;
    bool               trebleBoostOn;
    float              bassBoostGain;
    float              trebleBoostGain;

    /* ── replay gain ────────────────────────────────────── */
    float              replayGainDb;

    /* ── fade ───────────────────────────────────────────── */
    float              fadeVolume;    /* 0..1 */
    float              fadeTarget;    /* 0 or 1 */
    float              fadeStep;      /* +/- per sample */

    /* ── spectrum ───────────────────────────────────────── */
    int32_t            fftSize;
    float*             fftBuffer;     /* ring buffer of mono samples */
    int32_t            fftWritePos;
    int32_t            fftCount;      /* samples accumulated in current window */
    float*             fftWindow;     /* Hann window */

    /* ── callbacks ──────────────────────────────────────── */
    StillPositionCallback posCb;
    void*                posCbData;
    StillStateCallback   stateCb;
    void*                stateCbData;
    StillSpectrumCallback specCb;
    void*                specCbData;

    /* ── error ──────────────────────────────────────────── */
    char               lastError[256];
};

/* ═══════════════════════════════════════════════════════════════════════
 *  Helper – post state change to Dart
 * ═══════════════════════════════════════════════════════════════════════ */

static void post_state(StillPlayer* p, StillPlaybackStatus st, int32_t idx) {
    p->status = st;
    fprintf(stderr, "[still_audio] post_state: st=%d idx=%d stateCb=%p\n", (int)st, idx, (void*)(uintptr_t)p->stateCb);
    if (p->stateCb) p->stateCb(st, idx, p->stateCbData);
}

static void post_position(StillPlayer* p) {
    if (p->posCb)
        p->posCb(p->positionSec, p->durationSec, p->posCbData);
}

static void post_error(StillPlayer* p, const char* msg) {
    snprintf(p->lastError, sizeof(p->lastError), "%s", msg);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Helper – open decoder with proper Unicode path on Windows
 * ═══════════════════════════════════════════════════════════════════════ */

static ma_result open_decoder_utf8(ma_decoder* dec, const char* utf8Path, ma_decoder_config* dc) {
#ifdef _WIN32
    /* Convert UTF-8 → UTF-16, then use wide-char decoder init */
    int wLen = MultiByteToWideChar(CP_UTF8, 0, utf8Path, -1, NULL, 0);
    if (wLen <= 0) return MA_INVALID_FILE;
    wchar_t* wPath = (wchar_t*)malloc(wLen * sizeof(wchar_t));
    if (!wPath) return MA_OUT_OF_MEMORY;
    MultiByteToWideChar(CP_UTF8, 0, utf8Path, -1, wPath, wLen);
    ma_result r = ma_decoder_init_file_w(wPath, dc, dec);
    free(wPath);
    return r;
#else
    /* Linux / macOS – fopen() natively handles UTF-8 */
    return ma_decoder_init_file(utf8Path, dc, dec);
#endif
}

static inline float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static void process_frame(StillPlayer* p, float* L, float* R) {
    /* per-band EQ */
    for (int b = 0; b < EQ_BAND_COUNT; b++) {
        *L = biquad_process(&p->eqBands[b].filter[0], *L);
        *R = biquad_process(&p->eqBands[b].filter[1], *R);
    }
    /* bass boost – separate filter state per channel */
    if (p->bassBoostOn && p->bassBoostGain != 0) {
        *L = biquad_process(&p->bassBoost, *L);
        *R = biquad_process(&p->bassBoostR, *R);
    }
    /* treble boost – separate filter state per channel */
    if (p->trebleBoostOn && p->trebleBoostGain != 0) {
        *L = biquad_process(&p->trebleBoost, *L);
        *R = biquad_process(&p->trebleBoostR, *R);
    }
    /* replay gain */
    float gain = powf(10.0f, p->replayGainDb / 20.0f);
    /* fade */
    if (p->fadeStep != 0) {
        p->fadeVolume = clampf(p->fadeVolume + p->fadeStep, 0.0f, 1.0f);
        if ((p->fadeStep > 0 && p->fadeVolume >= p->fadeTarget) ||
            (p->fadeStep < 0 && p->fadeVolume <= p->fadeTarget)) {
            p->fadeStep = 0;
        }
    }
    float vol = p->muted ? 0.0f : p->volume;
    float master = vol * gain * p->fadeVolume;
    *L = clampf(*L * master, -1.0f, 1.0f);
    *R = clampf(*R * master, -1.0f, 1.0f);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Helper – spectrum analysis on mono-downmixed buffer
 * ═══════════════════════════════════════════════════════════════════════ */

static void feed_spectrum(StillPlayer* p, const float* samples, int32_t frameCount, int32_t channels) {
    if (!p->specCb || !p->fftBuffer) return;
    for (int32_t i = 0; i < frameCount; i++) {
        float mono = channels == 2
            ? (samples[i*2] + samples[i*2+1]) * 0.5f
            : samples[i];
        p->fftBuffer[p->fftWritePos] = mono;
        p->fftWritePos = (p->fftWritePos + 1) % p->fftSize;
        p->fftCount++;
        if (p->fftCount >= p->fftSize) {
            /* copy out windowed frame */
            float real[DEFAULT_FFT]; /* stack is fine for 1024 */
            float imag[DEFAULT_FFT];
            int32_t n = p->fftSize < DEFAULT_FFT ? p->fftSize : DEFAULT_FFT;
            for (int32_t j = 0; j < n; j++) {
                int32_t idx = (p->fftWritePos + j) % p->fftSize;
                real[j] = p->fftBuffer[idx] * p->fftWindow[j];
                imag[j] = 0;
            }
            fft_radix2(real, imag, n);
            /* magnitudes in dB */
            int32_t bins = n / 2;
            float mags[DEFAULT_FFT / 2];
            float scale = 2.0f / n;
            for (int32_t j = 0; j < bins; j++) {
                float mag = sqrtf(real[j]*real[j] + imag[j]*imag[j]) * scale;
                float dB = 20.0f * log10f(mag + 1e-9f);
                mags[j] = clampf(dB, -120.0f, 0.0f);
            }
            p->specCb(mags, bins, p->specCbData);
            p->fftCount -= p->fftSize / 2; /* hop = fftSize/2 */
        }
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  miniaudio data callback – the heart of the audio thread
 * ═══════════════════════════════════════════════════════════════════════ */

static void data_callback(ma_device* device, void* out, const void* in, ma_uint32 frameCount) {
    StillPlayer* p = (StillPlayer*)device->pUserData;
    ma_uint32 bytesPerSample = ma_get_bytes_per_sample(device->playback.format);
    ma_uint32 totalBytes = frameCount * bytesPerSample * device->playback.channels;
    if (!p || p->currentIndex < 0 || p->currentIndex >= p->queueLen) {
        memset(out, 0, totalBytes);
        return;
    }

    TrackInfo* track = &p->queue[p->currentIndex];
    if (!track->loaded) {
        memset(out, 0, totalBytes);
        return;
    }

    ma_uint32 channels = device->playback.channels;
    ma_uint32 totalRead = 0;

    while (totalRead < frameCount) {
        ma_uint32 remaining = frameCount - totalRead;
        ma_uint64 framesToRead = remaining;

        float* buf = (float*)out + totalRead * channels;
        ma_uint64 framesRead = 0;
        ma_decoder_read_pcm_frames(&track->decoder, buf, framesToRead, &framesRead);

        if (framesRead == 0) {
            /* end of track */
            if (p->loopMode == STILL_LOOP_ONE) {
                ma_decoder_seek_to_pcm_frame(&track->decoder, 0);
                continue; /* try to fill remaining frames */
            }
            /* signal end-of-track to main thread */
            if (totalRead < frameCount) {
                memset(buf, 0, (frameCount - totalRead) * channels * sizeof(float));
            }
            post_state(p, STILL_END_OF_LIST, p->currentIndex);
            return;
        }

        /* process DSP on the decoded chunk */
        float* fbuf = (float*)out + totalRead * channels;
        for (ma_uint32 i = 0; i < (ma_uint32)framesRead; i++) {
            float L = fbuf[i*channels + 0];
            float R = channels >= 2 ? fbuf[i*channels + 1] : L;
            process_frame(p, &L, &R);
            fbuf[i*channels + 0] = L;
            if (channels >= 2) fbuf[i*channels + 1] = R;
        }

        /* spectrum */
        feed_spectrum(p, fbuf, (int32_t)framesRead, (int32_t)channels);

        totalRead += (ma_uint32)framesRead;

        /* update position */
        ma_uint64 curFrame = 0;
        ma_decoder_get_cursor_in_pcm_frames(&track->decoder, &curFrame);
        p->positionSec = (float)curFrame / (float)track->decoder.outputSampleRate;
        p->durationSec = track->durationSec;
    }

    /* post position periodically (every callback is fine) */
    post_position(p);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  EQ rebuild helper
 * ═══════════════════════════════════════════════════════════════════════ */

static const float EQ_FREQS[EQ_BAND_COUNT] = EQ_FREQS_HZ;

static void eq_rebuild(StillPlayer* p) {
    float sr = (float)p->device.sampleRate;
    for (int b = 0; b < EQ_BAND_COUNT; b++) {
        p->eqBands[b].freq = EQ_FREQS[b];
        biquad_peaking(&p->eqBands[b].filter[0], EQ_FREQS[b], p->eqBands[b].gainDb, sr, 1.0f);
        biquad_peaking(&p->eqBands[b].filter[1], EQ_FREQS[b], p->eqBands[b].gainDb, sr, 1.0f);
    }
    /* bass/treble shelf – separate instances for L and R */
    biquad_low_shelf(&p->bassBoost, 120.0f, p->bassBoostOn ? p->bassBoostGain : 0, sr, 0.707f);
    biquad_low_shelf(&p->bassBoostR, 120.0f, p->bassBoostOn ? p->bassBoostGain : 0, sr, 0.707f);
    biquad_high_shelf(&p->trebleBoost, 8000.0f, p->trebleBoostOn ? p->trebleBoostGain : 0, sr, 0.707f);
    biquad_high_shelf(&p->trebleBoostR, 8000.0f, p->trebleBoostOn ? p->trebleBoostGain : 0, sr, 0.707f);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API
 * ═══════════════════════════════════════════════════════════════════════ */

StillPlayer* still_create(void) {
    StillPlayer* p = (StillPlayer*)calloc(1, sizeof(StillPlayer));
    if (!p) return NULL;

    p->volume = 1.0f;
    p->speed  = 1.0f;
    p->fadeVolume = 1.0f;
    p->currentIndex = -1;
    p->fftSize = DEFAULT_FFT;
    p->status = STILL_STOPPED;

    /* init EQ */
    for (int b = 0; b < EQ_BAND_COUNT; b++) {
        p->eqBands[b].gainDb = 0;
        biquad_reset(&p->eqBands[b].filter[0]);
        biquad_reset(&p->eqBands[b].filter[1]);
    }
    biquad_reset(&p->bassBoost);
    biquad_reset(&p->bassBoostR);
    biquad_reset(&p->trebleBoost);
    biquad_reset(&p->trebleBoostR);

    /* init miniaudio device */
    p->deviceConfig = ma_device_config_init(ma_device_type_playback);
    p->deviceConfig.playback.format   = ma_format_f32;
    p->deviceConfig.playback.channels = 2;
    p->deviceConfig.sampleRate        = 0;  /* use device default */
    p->deviceConfig.dataCallback      = data_callback;
    p->deviceConfig.pUserData         = p;

    ma_result result = ma_device_init(NULL, &p->deviceConfig, &p->device);
    fprintf(stderr, "[still_audio] still_create: ma_device_init returned %d, sampleRate=%u\n", (int)result, p->device.sampleRate);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "[still_audio] still_create: device init FAILED\n");
        post_error(p, "Failed to initialize audio device");
        free(p);
        return NULL;
    }

    /* spectrum window + buffer */
    p->fftBuffer = (float*)calloc(p->fftSize, sizeof(float));
    p->fftWindow = (float*)malloc(p->fftSize * sizeof(float));
    for (int i = 0; i < p->fftSize; i++) {
        p->fftWindow[i] = 0.5f * (1.0f - cosf(2.0f * 3.14159265f * i / (p->fftSize - 1)));
    }

    return p;
}

void still_destroy(StillPlayer* p) {
    if (!p) return;
    still_stop(p);
    ma_device_uninit(&p->device);
    for (int i = 0; i < p->queueLen; i++) {
        if (p->queue[i].loaded) ma_decoder_uninit(&p->queue[i].decoder);
    }
    free(p->fftBuffer);
    free(p->fftWindow);
    free(p);
}

/* ── Callbacks ──────────────────────────────────────────────────────── */

void still_set_position_callback(StillPlayer* p, StillPositionCallback cb, void* userData) {
    p->posCb = cb; p->posCbData = userData;
}
void still_set_state_callback(StillPlayer* p, StillStateCallback cb, void* userData) {
    fprintf(stderr, "[still_audio] still_set_state_callback: cb=%p userData=%p\n", (void*)(uintptr_t)cb, userData);
    p->stateCb = cb; p->stateCbData = userData;
}
void still_set_spectrum_callback(StillPlayer* p, StillSpectrumCallback cb, void* userData) {
    p->specCb = cb; p->specCbData = userData;
}

/* ── Queue ──────────────────────────────────────────────────────────── */

int32_t still_set_queue(StillPlayer* p, const char* const* filePaths, int32_t count) {
    if (!p) return -1;
    fprintf(stderr, "[still_audio] still_set_queue: count=%d\n", count);
    still_stop(p);

    /* uninit old decoders */
    for (int i = 0; i < p->queueLen; i++) {
        if (p->queue[i].loaded) {
            ma_decoder_uninit(&p->queue[i].decoder);
            p->queue[i].loaded = MA_FALSE;
        }
    }
    p->queueLen = 0;
    p->currentIndex = -1;

    if (!filePaths || count <= 0 || count > MAX_QUEUE) return 0;

    ma_uint32 devSampleRate = p->device.sampleRate;

    for (int32_t i = 0; i < count; i++) {
        TrackInfo* t = &p->queue[i];
        snprintf(t->path, STILL_MAX_PATH, "%s", filePaths[i]);

        ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 2, devSampleRate);
        ma_result r = open_decoder_utf8(&t->decoder, filePaths[i], &dc);
        if (r == MA_SUCCESS) {
            t->loaded = MA_TRUE;
            /* get duration */
            ma_uint64 totalFrames = 0;
            ma_decoder_get_length_in_pcm_frames(&t->decoder, &totalFrames);
            t->durationSec = (double)totalFrames / (double)t->decoder.outputSampleRate;
        } else {
            t->loaded = MA_FALSE;
            t->durationSec = 0;
            /* skip but keep slot so Dart knows it exists */
        }
    }
    p->queueLen = count;

    /* rebuild EQ for device sample rate */
    eq_rebuild(p);

    return count;
}

int32_t still_get_current_index(StillPlayer* p) { return p ? p->currentIndex : -1; }
int32_t still_get_queue_length(StillPlayer* p)  { return p ? p->queueLen : 0; }

/* ── Playback ───────────────────────────────────────────────────────── */

int still_play(StillPlayer* p) {
    if (!p) return -1;
    fprintf(stderr, "[still_audio] still_play: currentIndex=%d queueLen=%d\n", p->currentIndex, p->queueLen);
    if (p->currentIndex < 0 || p->currentIndex >= p->queueLen) {
        /* start from first track */
        if (p->queueLen > 0) {
            p->currentIndex = 0;
            p->positionSec = 0;
            ma_decoder_seek_to_pcm_frame(&p->queue[0].decoder, 0);
        } else {
            fprintf(stderr, "[still_audio] still_play: no tracks, returning\n");
            return 0;
        }
    }
    ma_result r = ma_device_start(&p->device);
    fprintf(stderr, "[still_audio] still_play: ma_device_start returned %d\n", (int)r);
    post_state(p, STILL_PLAYING, p->currentIndex);
    return 0;
}

int still_pause(StillPlayer* p) {
    if (!p) return -1;
    ma_device_stop(&p->device);
    post_state(p, STILL_PAUSED, p->currentIndex);
    return 0;
}

int still_stop(StillPlayer* p) {
    if (!p) return -1;
    ma_device_stop(&p->device);
    p->positionSec = 0;
    post_state(p, STILL_STOPPED, p->currentIndex);
    return 0;
}

int still_seek(StillPlayer* p, double positionSec) {
    if (!p || p->currentIndex < 0 || p->currentIndex >= p->queueLen) return -1;
    TrackInfo* t = &p->queue[p->currentIndex];
    if (!t->loaded) return -1;
    ma_uint64 targetFrame = (ma_uint64)(positionSec * (double)t->decoder.outputSampleRate);
    ma_decoder_seek_to_pcm_frame(&t->decoder, targetFrame);
    p->positionSec = (float)positionSec;
    post_position(p);
    return 0;
}

int still_seek_to_track(StillPlayer* p, int32_t index) {
    if (!p || index < 0 || index >= p->queueLen) return -1;
    p->currentIndex = index;
    p->positionSec = 0;
    if (p->queue[index].loaded)
        ma_decoder_seek_to_pcm_frame(&p->queue[index].decoder, 0);
    post_state(p, STILL_LOADING, index);
    return 0;
}

/* ── Properties ─────────────────────────────────────────────────────── */

int still_set_volume(StillPlayer* p, float v) {
    if (!p) return -1;
    p->volume = clampf(v, 0.0f, 1.0f);
    return 0;
}

int still_set_speed(StillPlayer* p, float s) {
    if (!p) return -1;
    p->speed = clampf(s, 0.25f, 4.0f);
    /* TODO: miniaudio 没有内置变速，需要通过 ma_data_source 音高变换
     * 或重采样器实现。当前仅存储值，实际不变速。 */
    return 0;
}

int still_set_loop_mode(StillPlayer* p, StillLoopMode m) {
    if (!p) return -1;
    p->loopMode = m;
    return 0;
}

int still_set_muted(StillPlayer* p, bool m) {
    if (!p) return -1;
    p->muted = m;
    return 0;
}

float still_get_volume(StillPlayer* p) { return p ? p->volume : 0; }
float still_get_speed(StillPlayer* p)  { return p ? p->speed : 1; }
double still_get_position(StillPlayer* p) { return p ? p->positionSec : 0; }
double still_get_duration(StillPlayer* p) { return p ? p->durationSec : 0; }
StillPlaybackStatus still_get_status(StillPlayer* p) { return p ? p->status : STILL_STOPPED; }

/* ── Equalizer ──────────────────────────────────────────────────────── */

int still_set_equalizer_bands(StillPlayer* p, const float* gainsDb, int32_t count) {
    if (!p || !gainsDb || count < EQ_BAND_COUNT) return -1;
    for (int b = 0; b < EQ_BAND_COUNT; b++) {
        p->eqBands[b].gainDb = clampf(gainsDb[b], -12.0f, 12.0f);
    }
    eq_rebuild(p);
    return 0;
}

int still_set_bass_boost(StillPlayer* p, bool enabled, float gainDb) {
    if (!p) return -1;
    p->bassBoostOn = enabled;
    p->bassBoostGain = clampf(gainDb, -12.0f, 12.0f);
    eq_rebuild(p);
    return 0;
}

int still_set_treble_boost(StillPlayer* p, bool enabled, float gainDb) {
    if (!p) return -1;
    p->trebleBoostOn = enabled;
    p->trebleBoostGain = clampf(gainDb, -12.0f, 12.0f);
    eq_rebuild(p);
    return 0;
}

/* ── ReplayGain ─────────────────────────────────────────────────────── */

int still_set_replay_gain(StillPlayer* p, float gainDb) {
    if (!p) return -1;
    p->replayGainDb = gainDb;
    return 0;
}

/* ── Fade ───────────────────────────────────────────────────────────── */

int still_fade_in(StillPlayer* p, float durationSec) {
    if (!p) return -1;
    if (durationSec <= 0) { p->fadeVolume = 1; p->fadeStep = 0; return 0; }
    p->fadeVolume = 0;
    p->fadeTarget = 1.0f;
    float sr = (float)p->device.sampleRate;
    if (sr < 1) sr = 44100.0f;
    p->fadeStep = 1.0f / (durationSec * sr);
    return 0;
}

int still_fade_out(StillPlayer* p, float durationSec) {
    if (!p) return -1;
    if (durationSec <= 0) { p->fadeVolume = 0; p->fadeStep = 0; return 0; }
    p->fadeTarget = 0.0f;
    float sr = (float)p->device.sampleRate;
    if (sr < 1) sr = 44100.0f;
    p->fadeStep = -1.0f / (durationSec * sr);
    return 0;
}

/* ── Spectrum ───────────────────────────────────────────────────────── */

int still_set_fft_size(StillPlayer* p, int32_t size) {
    if (!p || size < 64 || (size & (size-1)) != 0) return -1;
    free(p->fftBuffer);
    free(p->fftWindow);
    p->fftSize = size;
    p->fftBuffer = (float*)calloc(size, sizeof(float));
    p->fftWindow = (float*)malloc(size * sizeof(float));
    for (int i = 0; i < size; i++) {
        p->fftWindow[i] = 0.5f * (1.0f - cosf(2.0f * 3.14159265f * i / (size - 1)));
    }
    p->fftWritePos = 0;
    p->fftCount = 0;
    return 0;
}

/* ── Error ──────────────────────────────────────────────────────────── */

const char* still_last_error(StillPlayer* p) {
    return p ? p->lastError : "";
}
