#import "ApolloPalHomeChiptune.h"
#import <math.h>

// A tiny tracker. Each voice is a string of steps, one character per step:
//   notes  "C4" style pairs are too wide, so a step is a semitone offset
//          from the voice's root, written as a letter: 'a'..'z' = 0..25,
//          '.' = rest, '-' = hold the previous note.
// Drums: 'k' kick, 's' snare, 'h' hat, '.' rest.

typedef struct {
    const char *lead;  // pulse wave, 25% duty
    const char *bass;  // triangle
    const char *drums; // noise
    int leadRoot, bassRoot; // MIDI note for 'a'
    double step;       // seconds per step
} APTune;

static double APMidiHz(int note) { return 440.0 * pow(2.0, (note - 69) / 12.0); }

// Steps are semitones from the root: a=0 b=1 … so in C major from C:
// C=a D=c E=e F=f G=h A=j B=l C'=m D'=o E'=q F'=r G'=t A'=v C''=y
static const APTune kTunes[] = {
    [APJingleMovingDay] = {
        // C E G C' | A - G E F G - | C' (held)
        "aehmj-hefh-m-----",
        "a-a-h-h-f-f-h-h-a",
        "k.h.s.h.k.h.s.hks",
        72, 36, 0.105,
    },
    [APJingleUnpack] = {
        "a.hmqty",
        "a---h--",
        "s..h.hs",
        64, 40, 0.06,
    },
    [APJingleYum] = {
        "h.m-",
        "....",
        "h.h.",
        72, 40, 0.08,
    },
    [APJingleHeart] = {
        "aehmqty-",
        "........",
        "h.h.h.h.",
        72, 40, 0.05,
    },
    [APJingleAdopt] = {
        "mjhjm-t-y---",
        "a-h-f-h-a---",
        "k.h.s.h.k.s.",
        60, 36, 0.11,
    },
};

float *APJingleRender(APJingle jingle, double rate, NSUInteger *frames) {
    if (jingle < 0 || jingle >= (APJingle)(sizeof(kTunes) / sizeof(kTunes[0])) || rate <= 0) return NULL;
    APTune tune = kTunes[jingle];
    size_t steps = MAX(strlen(tune.lead), MAX(strlen(tune.bass), strlen(tune.drums)));
    double tail = 0.35; // let the last note ring
    NSUInteger total = (NSUInteger)((steps * tune.step + tail) * rate);
    float *out = calloc(total, sizeof(float));
    if (!out) return NULL;
    uint32_t noise = 0x12345u;
    // Voices.
    for (int voice = 0; voice < 3; voice++) {
        const char *line = voice == 0 ? tune.lead : voice == 1 ? tune.bass : tune.drums;
        size_t n = strlen(line);
        double phase = 0, hz = 0;
        double noteStart = 0;
        for (size_t i = 0; i < n; i++) {
            char ch = line[i];
            NSUInteger s0 = (NSUInteger)(i * tune.step * rate), s1 = (NSUInteger)((i + 1) * tune.step * rate);
            if (i == n - 1) s1 = MIN(total, s1 + (NSUInteger)(tail * rate));
            if (voice < 2) {
                if (ch >= 'a' && ch <= 'z') {
                    hz = APMidiHz((voice == 0 ? tune.leadRoot : tune.bassRoot) + (ch - 'a'));
                    noteStart = i * tune.step;
                } else if (ch == '.') {
                    hz = 0;
                }
                for (NSUInteger s = s0; s < s1 && s < total; s++) {
                    if (hz <= 0) continue;
                    double t = s / rate - noteStart;
                    phase += hz / rate;
                    phase -= floor(phase);
                    float sample;
                    if (voice == 0) {
                        // Pulse with a soft decay and a touch of vibrato on long notes.
                        double vib = t > 0.25 ? sin(t * 32) * 0.004 : 0;
                        double p = fmod(phase + vib + 1, 1);
                        sample = (p < 0.25 ? 1.0f : -1.0f) * 0.16f * (float)(0.55 + 0.45 * exp(-t * 5));
                    } else {
                        // Triangle.
                        sample = (float)(phase < 0.5 ? phase * 4 - 1 : 3 - phase * 4) * 0.22f;
                    }
                    out[s] += sample;
                }
            } else if (ch != '.') {
                double length = ch == 'k' ? 0.12 : ch == 's' ? 0.1 : 0.03;
                for (NSUInteger s = s0; s < s1 && s < total; s++) {
                    double t = (s - s0) / rate;
                    if (t > length) break;
                    float env = (float)(1 - t / length);
                    float sample;
                    if (ch == 'k') {
                        // A thumpy pitch drop.
                        double f = 120 * exp(-t * 30) + 45;
                        sample = (float)sin(2 * M_PI * f * t) * 0.5f * env;
                    } else {
                        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5;
                        float white = (noise & 0xFFFF) / 32768.0f - 1;
                        sample = white * (ch == 's' ? 0.18f : 0.07f) * env;
                    }
                    out[s] += sample;
                }
            }
        }
    }
    // Gentle fade at the very end; soft clip.
    NSUInteger fade = (NSUInteger)(0.08 * rate);
    for (NSUInteger s = 0; s < total; s++) {
        float g = s + fade > total ? (float)(total - s) / fade : 1;
        out[s] = tanhf(out[s] * 1.4f) * 0.7f * g;
    }
    if (frames) *frames = total;
    return out;
}
