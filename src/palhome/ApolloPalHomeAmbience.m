#import "ApolloPalHomeAmbience.h"
#import "ApolloPalHomeRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#if __has_include("ApolloCommon.h")
#import "ApolloCommon.h"
#else
#define ApolloLog(...) do {} while (0)
#endif

static NSString *const kSoundKey = @"ApolloRebornPalHomeSound";
static NSString *const kSoundAlwaysKey = @"ApolloRebornPalHomeSoundAlways";

// Target levels for each layer (0 = off). Written on the main thread, read
// by the render thread; plain floats are fine (a torn read is inaudible).
typedef struct {
    float fire, rain, wind, clock, music, hum, crickets, bubbles, owl, room;
} APAmbienceLevels;

// Record player songs. Each is a melody and a bass line of (MIDI note, beats)
// pairs (note 0 = rest) that loop, with a tempo and a timbre per voice.
// The record player's variants are these songs, in this order.
typedef struct { uint8_t note; float beats; } APSongNote;
typedef enum {
    APTimbreMusicBox, // bell-like pluck
    APTimbreKeys,     // electric piano: warm, with a slow tremolo
    APTimbreVibes,    // vibraphone: round, shimmering
    APTimbreChip,     // soft square, filtered so it never buzzes
    APTimbreTriangle, // chiptune bass
    APTimbrePluck,    // upright/plucked bass
    APTimbreTheremin, // slow swell with vibrato
    APTimbreOrgan,    // sustained, hollow
} APTimbre;
typedef struct {
    const APSongNote *melody; int melodyCount;
    const APSongNote *bass; int bassCount;
    float bpm; APTimbre melodyTimbre, bassTimbre;
} APSong;

// Brahms' Lullaby (public domain), as a music box.
static const APSongNote kLullaby[] = {
    {64,.75},{64,.25},{67,2}, {64,.75},{64,.25},{67,2}, {64,.5},{67,.5},{72,1},{71,1.5},{69,.5},{69,1},{67,1},
    {62,.5},{64,.5},{65,1},{62,1},{62,.5},{64,.5},{65,2}, {62,.5},{65,.5},{71,.5},{69,.5},{67,1},{71,1},{72,2},
    {60,.5},{60,.5},{72,2},{69,.5},{65,.5},{67,2}, {64,.5},{60,.5},{65,1},{67,1},{69,1},{67,2},{0,2},
};
// Lo-fi: lazy major-seventh arpeggios over a soft bass.
static const APSongNote kLofi[] = {
    {65,.75},{69,.75},{72,.5},{76,2}, {64,.75},{67,.75},{71,.5},{74,2},
    {62,.75},{65,.75},{69,.5},{72,2}, {60,.75},{64,.75},{67,.5},{71,1},{0,1},
};
static const APSongNote kLofiBass[] = { {53,4},{52,4},{50,4},{48,3},{55,1} };
// A little waltz in G.
static const APSongNote kWaltz[] = {
    {71,2},{72,1}, {74,2},{79,1}, {78,2},{76,1}, {74,3}, {72,2},{69,1}, {71,2},{67,1}, {69,2},{66,1}, {67,3},
    {71,1},{74,1},{79,1}, {78,2},{76,1}, {74,1},{72,1},{71,1}, {69,3}, {72,1},{76,1},{81,1}, {79,2},{78,1}, {76,1},{74,1},{66,1}, {67,3},
};
static const APSongNote kWaltzBass[] = {
    {55,3},{55,3},{50,3},{55,3},{57,3},{55,3},{50,3},{55,3},
    {55,3},{50,3},{55,3},{50,3},{57,3},{55,3},{50,3},{55,3},
};
// Jazz: vibes over a walking bass (ii-V-I-VI in C).
static const APSongNote kJazz[] = {
    {0,1},{69,.67},{72,.33},{74,1},{72,1}, {71,1.5},{67,.5},{65,2}, {64,2},{0,.67},{67,.33},{71,1}, {69,3},{0,1},
};
static const APSongNote kJazzBass[] = {
    {50,1},{53,1},{57,1},{60,1}, {55,1},{59,1},{62,1},{59,1}, {48,1},{52,1},{55,1},{59,1}, {57,1},{55,1},{52,1},{49,1},
};
// Chiptune: a bouncy 8-bit tune.
static const APSongNote kChip[] = {
    {72,.5},{76,.5},{79,.5},{84,.5},{83,.5},{79,.5},{76,1}, {77,.5},{81,.5},{84,.5},{81,.5},{79,2},
    {76,.5},{79,.5},{84,.5},{88,.5},{86,.5},{83,.5},{79,1}, {81,.5},{79,.5},{77,.5},{74,.5},{72,2},
};
static const APSongNote kChipBass[] = { {48,2},{48,2},{53,2},{55,2},{48,2},{52,2},{53,1},{55,1},{48,2} };
// Spooky: a minor theremin line over a slow organ.
static const APSongNote kSpooky[] = {
    {69,1},{72,1},{76,1},{75,1}, {74,2},{71,2}, {72,1},{69,1},{68,1},{71,1}, {69,3},{0,1},
    {76,1},{77,1},{76,1},{75,1}, {76,2},{72,2}, {71,1},{68,1},{64,1},{68,1}, {69,4},
};
static const APSongNote kSpookyBass[] = { {45,4},{50,4},{52,4},{45,4},{53,4},{45,4},{52,4},{45,4} };

static const APSong kSongs[] = {
    { kLullaby, (int)(sizeof(kLullaby) / sizeof(APSongNote)), NULL, 0, 84, APTimbreMusicBox, APTimbrePluck },
    { kLofi, (int)(sizeof(kLofi) / sizeof(APSongNote)), kLofiBass, (int)(sizeof(kLofiBass) / sizeof(APSongNote)), 70, APTimbreKeys, APTimbrePluck },
    { kWaltz, (int)(sizeof(kWaltz) / sizeof(APSongNote)), kWaltzBass, (int)(sizeof(kWaltzBass) / sizeof(APSongNote)), 150, APTimbreMusicBox, APTimbrePluck },
    { kJazz, (int)(sizeof(kJazz) / sizeof(APSongNote)), kJazzBass, (int)(sizeof(kJazzBass) / sizeof(APSongNote)), 108, APTimbreVibes, APTimbrePluck },
    { kChip, (int)(sizeof(kChip) / sizeof(APSongNote)), kChipBass, (int)(sizeof(kChipBass) / sizeof(APSongNote)), 132, APTimbreChip, APTimbreTriangle },
    { kSpooky, (int)(sizeof(kSpooky) / sizeof(APSongNote)), kSpookyBass, (int)(sizeof(kSpookyBass) / sizeof(APSongNote)), 66, APTimbreTheremin, APTimbreOrgan },
};
static const int kSongCount = (int)(sizeof(kSongs) / sizeof(APSong));

typedef struct {
    int index; double timer, held; // note in the line, time left in it, time since it began
    float phase, freq, env, amp, lfo, lp;
    BOOL sounding;
} APSongVoice;

typedef struct {
    double sampleRate;
    uint32_t rng;
    APAmbienceLevels target, level;
    float master, masterTarget;
    // Fire.
    float brown, rumbleLP, crackleEnv, crackleAmp, crackleLP, popPhase, popFreq, popEnv;
    // Rain / wind.
    float rainLP, rainLP2, rainHP, dropEnv, dropPhase, dropFreq, windLP1, windLP2, windLFO, windGust;
    // Clock.
    double clockPhase; int tick; float clickEnv, clickPhase, clickFreq;
    // Record player: the song on it (set from the main thread) and its two voices.
    int songTarget, song;
    APSongVoice voices[2];
    // Hum / beeps.
    double humPhase1, humPhase2; float beepEnv, beepPhase, beepFreq; double beepTimer;
    // Crickets.
    double chirpTimer; int chirpPulses; float chirpEnv, chirpPhase, chirpGate;
    // Bubbles.
    float bubbleEnv, bubblePhase, bubbleFreq, bubbleSweep;
    // Owl.
    double owlTimer; int owlHoots; float owlEnv, owlGate, owlPhase, owlFreq, owlBreathLP;
    // Room tone.
    float roomLP;
} APAmbienceState;

static inline float APWhite(APAmbienceState *s) {
    uint32_t x = s->rng; x ^= x << 13; x ^= x >> 17; x ^= x << 5; s->rng = x;
    return (x & 0xFFFFFF) / (float)0x800000 - 1.0f;
}
static inline float APUnit(APAmbienceState *s) { return (APWhite(s) + 1) * 0.5f; }

static BOOL APTimbreSustains(APTimbre t) { return t == APTimbreTheremin || t == APTimbreOrgan; }

// One voice of the record player: steps through its line and renders it.
static float APSongVoiceSample(APSongVoice *v, const APSongNote *line, int count, float bpm, APTimbre t, float dt) {
    if (!line || count == 0) return 0;
    double beat = 60.0 / bpm;
    v->timer -= dt; v->held += dt;
    if (v->timer <= 0) {
        v->index = (v->index + 1) % count;
        APSongNote n = line[v->index];
        v->timer += n.beats * beat;
        v->held = 0;
        v->sounding = n.note != 0;
        if (v->sounding) {
            v->freq = 440.0f * powf(2.0f, (n.note - 69) / 12.0f);
            if (!APTimbreSustains(t)) v->env = 1;
        }
    }
    // Envelope: plucked timbres strike and ring down; sustained ones swell in
    // while the note is held and let go just before the next.
    float decay;
    switch (t) {
        case APTimbreMusicBox: decay = 2.2f; break;
        case APTimbreKeys: decay = 0.9f; break;
        case APTimbreVibes: decay = 1.1f; break;
        case APTimbreChip: decay = 2.6f; break;
        case APTimbreTriangle: decay = 3.0f; break;
        case APTimbrePluck: decay = 2.4f; break;
        default: decay = 0; break;
    }
    if (APTimbreSustains(t)) {
        BOOL hold = v->sounding && v->timer > 0.06;
        v->env += ((hold ? 1.0f : 0.0f) - v->env) * dt * (hold ? 6.0f : 10.0f);
    } else {
        v->env *= 1.0f - decay * dt;
    }
    v->amp += (v->env - v->amp) * fminf(1.0f, dt * 300.0f); // a few ms, so nothing clicks
    if (v->amp < 0.0005f) return 0;
    v->lfo += dt;
    float f = v->freq;
    if (t == APTimbreTheremin) f *= 1.0f + 0.006f * sinf(v->lfo * 5.2f * 2 * M_PI) * fminf(1.0f, (float)v->held * 2);
    v->phase += f * dt;
    if (v->phase > 1.0f) v->phase -= floorf(v->phase);
    float x = v->phase * 2 * M_PI, out = 0;
    switch (t) {
        case APTimbreMusicBox: out = 1.3f * (sinf(x) + 0.22f * sinf(3 * x) * v->amp); break;
        case APTimbreKeys: out = (sinf(x) + 0.3f * sinf(2 * x) * v->amp) * (1.0f - 0.15f * (0.5f + 0.5f * sinf(v->lfo * 4.5f * 2 * M_PI))); break;
        case APTimbreVibes: out = (sinf(x) + 0.08f * sinf(4 * x)) * (1.0f - 0.25f * (0.5f + 0.5f * sinf(v->lfo * 6 * 2 * M_PI))); break;
        case APTimbreChip: {
            float sq = v->phase < 0.5f ? 0.6f : -0.6f;
            v->lp += (sq - v->lp) * 0.12f; // rounds the corners off
            out = v->lp;
            break;
        }
        case APTimbreTriangle: out = 4.0f * fabsf(v->phase - 0.5f) - 1.0f; break;
        case APTimbrePluck: out = sinf(x) + 0.35f * sinf(2 * x) * v->amp; break;
        // Sustained notes sound louder than struck ones, so they sit lower.
        case APTimbreTheremin: out = 0.75f * (sinf(x) + 0.12f * sinf(2 * x)); break;
        case APTimbreOrgan: out = 0.6f * (0.7f * sinf(x) + 0.3f * sinf(2 * x) + 0.15f * sinf(3 * x)); break;
    }
    return out * v->amp;
}

static float APAmbienceSample(APAmbienceState *s) {
    double sr = s->sampleRate;
    float dt = 1.0f / sr;
    // Glide every layer toward its target (~1.5s fades).
    float glide = dt / 1.5f;
    float *lv = (float *)&s->level, *tg = (float *)&s->target;
    for (int i = 0; i < (int)(sizeof(APAmbienceLevels) / sizeof(float)); i++) lv[i] += (tg[i] - lv[i]) * glide * 4;
    s->master += (s->masterTarget - s->master) * glide * 3;
    APAmbienceLevels L = s->level;
    float w = APWhite(s), out = 0;

    // Fire: a soft low rumble, a few muffled crackles, and the odd woody pop.
    // (No bright fizz: on a phone speaker that just reads as static.)
    if (L.fire > 0.001f) {
        s->brown = s->brown * 0.997f + w * 0.03f;
        s->rumbleLP += (s->brown - s->rumbleLP) * 0.01f;
        if (APUnit(s) < 4.0f / sr) { s->crackleEnv = 1; s->crackleAmp = powf(APUnit(s), 2.2f); }
        s->crackleEnv *= 1.0f - 500.0f / sr;
        s->crackleLP += (w * s->crackleEnv * s->crackleAmp - s->crackleLP) * 0.06f;
        if (APUnit(s) < 0.3f / sr) { s->popEnv = 1; s->popFreq = 90 + APUnit(s) * 140; }
        s->popEnv *= 1.0f - 40.0f / sr;
        s->popPhase += s->popFreq * dt;
        float pop = sinf(s->popPhase * 2 * M_PI) * s->popEnv * s->popEnv * 0.5f;
        out += L.fire * (s->rumbleLP * 0.25f + s->crackleLP * 0.9f + pop * 0.6f);
    }
    // Rain: a faint, dark patter plus little tonal drips on the glass.
    if (L.rain > 0.001f) {
        s->rainLP += (w - s->rainLP) * 0.06f;
        s->rainLP2 += (s->rainLP - s->rainLP2) * 0.06f;
        s->rainHP += (s->rainLP2 - s->rainHP) * 0.004f;
        if (APUnit(s) < 3.0f / sr) { s->dropEnv = 0.3f + APUnit(s) * 0.7f; s->dropFreq = 1400 + APUnit(s) * 1600; }
        s->dropEnv *= 1.0f - 60.0f / sr;
        s->dropFreq *= 1.0f - 2.0f * dt; // each drip bends down a touch
        s->dropPhase += s->dropFreq * dt;
        float drip = sinf(s->dropPhase * 2 * M_PI) * s->dropEnv * s->dropEnv;
        out += L.rain * ((s->rainLP2 - s->rainHP) * 0.18f + drip * 0.05f);
    }
    // Wind: band of noise whose pitch and loudness drift in gusts.
    if (L.wind > 0.001f) {
        s->windLFO += dt * 0.11f;
        float gust = 0.55f + 0.45f * sinf(s->windLFO * 2 * M_PI) * sinf(s->windLFO * 0.37f * 2 * M_PI);
        float cutoff = 0.004f + 0.01f * gust;
        s->windLP1 += (w - s->windLP1) * cutoff;
        s->windLP2 += (s->windLP1 - s->windLP2) * cutoff;
        out += L.wind * (s->windLP1 - s->windLP2) * 2.2f * gust;
    }
    // Clock: tick, tock.
    if (L.clock > 0.001f) {
        s->clockPhase += dt;
        if (s->clockPhase >= 1.0) {
            s->clockPhase -= 1.0;
            s->tick = !s->tick;
            s->clickEnv = 1;
            s->clickFreq = s->tick ? 2300 : 1750;
        }
        s->clickEnv *= 1.0f - 700.0f / sr;
        s->clickPhase += s->clickFreq * dt;
        out += L.clock * sinf(s->clickPhase * 2 * M_PI) * s->clickEnv * s->clickEnv * 0.18f;
    }
    // Record player: whichever song is on it. A new record starts from the top.
    if (s->song != s->songTarget) {
        s->song = s->songTarget;
        memset(s->voices, 0, sizeof(s->voices));
        s->voices[0].index = s->voices[1].index = -1;
    }
    if (L.music > 0.001f) {
        const APSong *song = &kSongs[MAX(0, MIN(kSongCount - 1, s->song))];
        float melody = APSongVoiceSample(&s->voices[0], song->melody, song->melodyCount, song->bpm, song->melodyTimbre, dt);
        float bass = APSongVoiceSample(&s->voices[1], song->bass, song->bassCount, song->bpm, song->bassTimbre, dt);
        out += L.music * (melody * 0.1f + bass * 0.075f);
    }
    // Station hum, with the occasional soft console beep.
    if (L.hum > 0.001f) {
        s->humPhase1 += 55.0 * dt;
        s->humPhase2 += 110.6 * dt;
        float hum = sinf(s->humPhase1 * 2 * M_PI) * 0.6f + sinf(s->humPhase2 * 2 * M_PI) * 0.35f;
        s->beepTimer -= dt;
        if (s->beepTimer <= 0) { s->beepEnv = 1; s->beepFreq = APUnit(s) < 0.5f ? 1318.5f : 987.8f; s->beepTimer = 6 + APUnit(s) * 10; }
        s->beepEnv *= 1.0f - 12.0f / sr;
        s->beepPhase += s->beepFreq * dt;
        out += L.hum * (hum * 0.09f + sinf(s->beepPhase * 2 * M_PI) * s->beepEnv * 0.05f);
    }
    // Crickets: trills of three quick chirps.
    if (L.crickets > 0.001f) {
        s->chirpTimer -= dt;
        if (s->chirpTimer <= 0) {
            if (s->chirpPulses > 0) { s->chirpPulses--; s->chirpGate = 1; s->chirpTimer = 0.06; }
            else { s->chirpPulses = 3; s->chirpTimer = 0.5 + APUnit(s) * 1.4; s->chirpGate = 0; }
        }
        if (s->chirpTimer < 0.025 && s->chirpPulses >= 0) s->chirpGate = 0;
        s->chirpEnv += ((s->chirpGate > 0 ? 1.0f : 0.0f) - s->chirpEnv) * 0.01f;
        s->chirpPhase += 4700 * dt;
        out += L.crickets * sinf(s->chirpPhase * 2 * M_PI) * s->chirpEnv * 0.035f;
    }
    // Bubbles: little rising blips.
    if (L.bubbles > 0.001f) {
        if (APUnit(s) < 1.1f / sr) { s->bubbleEnv = 1; s->bubbleFreq = 350 + APUnit(s) * 500; s->bubbleSweep = 1; }
        s->bubbleEnv *= 1.0f - 45.0f / sr;
        s->bubbleSweep += dt * 18;
        s->bubblePhase += s->bubbleFreq * s->bubbleSweep * dt;
        out += L.bubbles * sinf(s->bubblePhase * 2 * M_PI) * s->bubbleEnv * 0.12f;
    }
    // Owl: now and then a soft, breathy "hoo… hoo-hoo", falling slightly.
    if (L.owl > 0.001f) {
        s->owlTimer -= dt;
        if (s->owlTimer <= 0) {
            if (s->owlHoots > 0) {
                s->owlHoots--; s->owlGate = 1; s->owlFreq = 400 - s->owlHoots * 18;
                s->owlTimer = s->owlHoots == 2 ? 0.7 : 0.36; // a long first hoo, then a quick pair
            } else {
                s->owlHoots = 3; s->owlGate = 0; s->owlTimer = 12 + APUnit(s) * 18;
            }
        }
        if (s->owlTimer < 0.12) s->owlGate = 0;
        s->owlEnv += ((s->owlGate > 0 ? 1.0f : 0.0f) - s->owlEnv) * (s->owlGate > 0 ? 0.0009f : 0.0004f);
        s->owlFreq *= 1.0f - 0.08f * dt; // a little droop through each hoo
        s->owlPhase += s->owlFreq * dt;
        s->owlBreathLP += (w - s->owlBreathLP) * 0.05f;
        float tone = sinf(s->owlPhase * 2 * M_PI) + 0.15f * sinf(s->owlPhase * 4 * M_PI);
        out += L.owl * s->owlEnv * (tone * 0.06f + s->owlBreathLP * 0.015f);
    }
    // Room tone: only underwater, a slow deep swell (never a hiss).
    if (L.room > 0.001f) {
        s->roomLP += (w - s->roomLP) * 0.0025f;
        out += L.room * s->roomLP * 0.5f;
    }
    out *= s->master;
    return tanhf(out * 1.2f) * 0.85f; // soft clip
}

@interface ApolloPalHomeAmbience ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioSourceNode *source;
@property (nonatomic, strong) AVAudioPlayerNode *jinglePlayer;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, AVAudioPCMBuffer *> *jingles;
@property (nonatomic) APAmbienceState *state;
@property (nonatomic, copy, nullable) NSString *previousCategory;
@property (nonatomic) AVAudioSessionCategoryOptions previousOptions;
@property (nonatomic) BOOL running;
// Whether Pal Home wants sound at all (start until stop). Separate from
// `running` (is the engine going right now): interruptions and route changes
// stop the engine, and only a still-wanted engine may come back.
@property (nonatomic) BOOL wanted;
@property (nonatomic) BOOL resumeAfterInterruption;
@end

@implementation ApolloPalHomeAmbience

+ (APSoundMode)mode {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:kSoundKey];
    if (value && ![value boolValue]) return APSoundOff;
    return [defaults boolForKey:kSoundAlwaysKey] ? APSoundAlways : APSoundOn;
}

+ (void)setMode:(APSoundMode)mode {
    [NSUserDefaults.standardUserDefaults setBool:mode != APSoundOff forKey:kSoundKey];
    [NSUserDefaults.standardUserDefaults setBool:mode == APSoundAlways forKey:kSoundAlwaysKey];
}

+ (BOOL)isEnabled { return self.mode != APSoundOff; }

- (instancetype)init {
    if ((self = [super init])) {
        _state = calloc(1, sizeof(APAmbienceState));
        _state->rng = 0xA5A5A5A5u;
        _state->sampleRate = 48000;
        _state->clockPhase = 0.5;
        _state->voices[0].index = _state->voices[1].index = -1;
        _state->beepTimer = 5;
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_engine stop];
    free(_state);
}

// The engine stops itself on a route change (headphones) or an interruption
// (a call); forget we were running and start again if we still should.
- (void)engineStopped:(NSNotification *)note {
    self.jingles = nil; // rendered for the old format
    self.running = NO;
    if (!self.wanted) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf.wanted) [weakSelf start]; });
}

#if TARGET_OS_IPHONE
- (void)interrupted:(NSNotification *)note {
    AVAudioSessionInterruptionType type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.resumeAfterInterruption = self.running;
        self.running = NO;
    } else if (self.resumeAfterInterruption) {
        self.resumeAfterInterruption = NO;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf.wanted) [weakSelf start]; });
    }
}
#endif

- (void)updateForLayout:(APRoomLayout *)layout minuteOfDay:(int)minute {
    APAmbienceLevels levels = {0};
    int hour = (minute / 60) % 24;
    BOOL night = hour >= 20 || hour < 6;
    for (APPlacedItem *item in layout.items) {
        for (APAnim *anim in item.art.anims) {
            switch (anim.kind) {
                case APAnimFire: levels.fire = MAX(levels.fire, anim.w > 10 ? 1.0f : 0.55f); break;
                case APAnimWindow:
                    if (anim.variant == 2) levels.rain = 0.8f;
                    if (anim.variant == 0) levels.wind = MAX(levels.wind, night ? 0.6f : 0.35f);
                    if (anim.variant == 5) levels.bubbles = MAX(levels.bubbles, 0.5f);
                    break;
                case APAnimClockHands: levels.clock = 0.7f; break;
                case APAnimNotes:
                    // The first record player's song plays.
                    if (levels.music == 0) self.state->songTarget = MAX(0, anim.variant);
                    levels.music = 1.0f;
                    break;
                case APAnimBubbles: levels.bubbles = MAX(levels.bubbles, 0.6f); break;
                default: break;
            }
        }
    }
    NSString *style = layout.style.identifier;
    if ([style isEqual:@"space"]) levels.hum = 1;
    if ([style isEqual:@"underwater"]) { levels.bubbles = MAX(levels.bubbles, 0.8f); levels.room = 0.5f; }
    if ([style isEqual:@"castle"]) levels.wind = MAX(levels.wind, 0.45f);
    if ([style isEqual:@"manor"]) { levels.wind = MAX(levels.wind, 0.4f); levels.owl = night ? 1.0f : 0.5f; }
    if (([style isEqual:@"treehouse"] || [style isEqual:@"saloon"]) && night) levels.crickets = 1;
    if ([style isEqual:@"treehouse"] && !night) levels.wind = MAX(levels.wind, 0.25f);
    self.state->target = levels;
}

- (void)start {
    if (!ApolloPalHomeAmbience.isEnabled) return;
    self.wanted = YES;
    if (self.running) return;
    NSError *error = nil;
#if TARGET_OS_IPHONE
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // Don't fight something that's actually playing (a video, music).
    if (session.secondaryAudioShouldBeSilencedHint) {
        ApolloLog(@"[PalHome] ambience deferred: other audio is playing");
        return;
    }
    self.previousCategory = session.category;
    self.previousOptions = session.categoryOptions;
    // Always: playback (heard in Silent Mode); On: ambient (follows it). Both mix.
    AVAudioSessionCategory category = ApolloPalHomeAmbience.mode == APSoundAlways ? AVAudioSessionCategoryPlayback : AVAudioSessionCategoryAmbient;
    [session setCategory:category withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    [session setActive:YES error:nil];
#endif
    if (!self.engine) {
        self.engine = [AVAudioEngine new];
        AVAudioFormat *hardware = [self.engine.outputNode inputFormatForBus:0];
        double rate = hardware.sampleRate > 0 ? hardware.sampleRate : 48000;
        self.state->sampleRate = rate;
        AVAudioFormat *mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
        APAmbienceState *state = self.state;
        self.source = [[AVAudioSourceNode alloc] initWithFormat:mono renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                                                                          AVAudioFrameCount frames, AudioBufferList *output) {
            float *buffer = (float *)output->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < frames; i++) buffer[i] = APAmbienceSample(state);
            return noErr;
        }];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(engineStopped:)
                                                   name:AVAudioEngineConfigurationChangeNotification object:self.engine];
#if TARGET_OS_IPHONE
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interrupted:)
                                                   name:AVAudioSessionInterruptionNotification object:nil];
#endif
        [self.engine attachNode:self.source];
        [self.engine connect:self.source to:self.engine.mainMixerNode format:mono];
        self.jinglePlayer = [AVAudioPlayerNode new];
        [self.engine attachNode:self.jinglePlayer];
        [self.engine connect:self.jinglePlayer to:self.engine.mainMixerNode format:mono];
        self.engine.mainMixerNode.outputVolume = 0.8f;
    }
    self.state->masterTarget = 1;
    if (![self.engine startAndReturnError:&error]) {
        ApolloLog(@"[PalHome] ambience failed to start: %@", error);
        return;
    }
    self.running = YES;
    APAmbienceLevels t = self.state->target;
    ApolloLog(@"[PalHome] ambience started %.0fHz fire=%.2f rain=%.2f wind=%.2f clock=%.2f music=%.2f hum=%.2f crickets=%.2f bubbles=%.2f owl=%.2f",
              self.state->sampleRate, t.fire, t.rain, t.wind, t.clock, t.music, t.hum, t.crickets, t.bubbles, t.owl);
}

- (void)playJingle:(APJingle)jingle {
    if (!ApolloPalHomeAmbience.isEnabled || !self.running || !self.jinglePlayer) return;
    if (!self.jingles) self.jingles = [NSMutableDictionary dictionary];
    AVAudioPCMBuffer *buffer = self.jingles[@(jingle)];
    if (!buffer) {
        double rate = self.state->sampleRate;
        NSUInteger frames = 0;
        float *samples = APJingleRender(jingle, rate, &frames);
        if (!samples || !frames) { free(samples); return; }
        AVAudioFormat *mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
        buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:mono frameCapacity:(AVAudioFrameCount)frames];
        memcpy(buffer.floatChannelData[0], samples, frames * sizeof(float));
        buffer.frameLength = (AVAudioFrameCount)frames;
        free(samples);
        self.jingles[@(jingle)] = buffer;
    }
    // A new sting interrupts the last rather than piling up.
    [self.jinglePlayer stop];
    [self.jinglePlayer scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    self.jinglePlayer.volume = 0.9f;
    [self.jinglePlayer play];
    ApolloLog(@"[PalHome] jingle %ld (%.2fs)", (long)jingle, buffer.frameLength / self.state->sampleRate);
}

- (void)stop {
    // Not wanted any more: cancels any pending restart too.
    self.wanted = NO;
    self.resumeAfterInterruption = NO;
    if (!self.running) return;
    self.running = NO;
    self.state->masterTarget = 0;
    self.state->master = 0;
    [self.engine pause];
#if TARGET_OS_IPHONE
    if (self.previousCategory) {
        [AVAudioSession.sharedInstance setCategory:self.previousCategory withOptions:self.previousOptions error:nil];
    }
#endif
}

@end
