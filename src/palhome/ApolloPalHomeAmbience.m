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

// Target levels for each layer (0 = off). Written on the main thread, read
// by the render thread; plain floats are fine (a torn read is inaudible).
typedef struct {
    float fire, rain, wind, clock, music, hum, crickets, bubbles, room;
} APAmbienceLevels;

typedef struct {
    double sampleRate;
    uint32_t rng;
    APAmbienceLevels target, level;
    float master, masterTarget;
    // Fire.
    float brown, rumbleLP, crackleEnv, crackleAmp, crackleLP, popPhase, popFreq, popEnv;
    // Rain / wind.
    float rainLP, rainHP, dropEnv, windLP1, windLP2, windLFO, windGust;
    // Clock.
    double clockPhase; int tick; float clickEnv, clickPhase, clickFreq;
    // Music box.
    double noteTimer; float notePhase, noteFreq, noteEnv; int noteIndex;
    // Hum / beeps.
    double humPhase1, humPhase2; float beepEnv, beepPhase, beepFreq; double beepTimer;
    // Crickets.
    double chirpTimer; int chirpPulses; float chirpEnv, chirpPhase, chirpGate;
    // Bubbles.
    float bubbleEnv, bubblePhase, bubbleFreq, bubbleSweep;
    // Room tone.
    float roomLP;
} APAmbienceState;

static inline float APWhite(APAmbienceState *s) {
    uint32_t x = s->rng; x ^= x << 13; x ^= x >> 17; x ^= x << 5; s->rng = x;
    return (x & 0xFFFFFF) / (float)0x800000 - 1.0f;
}
static inline float APUnit(APAmbienceState *s) { return (APWhite(s) + 1) * 0.5f; }

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

    // Fire: a low rumble, a fizz of crackles, and the odd pop.
    if (L.fire > 0.001f) {
        s->brown = s->brown * 0.997f + w * 0.03f;
        s->rumbleLP += (s->brown - s->rumbleLP) * 0.02f;
        if (APUnit(s) < 9.0f / sr) { s->crackleEnv = 1; s->crackleAmp = powf(APUnit(s), 2.2f); }
        s->crackleEnv *= 1.0f - 600.0f / sr;
        float crackle = w * s->crackleEnv * s->crackleAmp;
        s->crackleLP += (crackle - s->crackleLP) * 0.35f;
        float fizz = (crackle - s->crackleLP) * 0.9f + s->crackleLP * 0.4f;
        if (APUnit(s) < 0.35f / sr) { s->popEnv = 1; s->popFreq = 90 + APUnit(s) * 140; }
        s->popEnv *= 1.0f - 40.0f / sr;
        s->popPhase += s->popFreq * dt;
        float pop = sinf(s->popPhase * 2 * M_PI) * s->popEnv * s->popEnv * 0.5f;
        out += L.fire * (s->rumbleLP * 0.35f + fizz * 0.5f + pop * 0.6f);
    }
    // Rain: soft hiss plus droplets.
    if (L.rain > 0.001f) {
        s->rainLP += (w - s->rainLP) * 0.3f;
        s->rainHP += (s->rainLP - s->rainHP) * 0.02f;
        if (APUnit(s) < 22.0f / sr) s->dropEnv = 0.3f + APUnit(s) * 0.7f;
        s->dropEnv *= 1.0f - 900.0f / sr;
        out += L.rain * ((s->rainLP - s->rainHP) * 0.25f + w * s->dropEnv * 0.25f);
    }
    // Wind: band of noise whose pitch and loudness drift in gusts.
    if (L.wind > 0.001f) {
        s->windLFO += dt * 0.11f;
        float gust = 0.55f + 0.45f * sinf(s->windLFO * 2 * M_PI) * sinf(s->windLFO * 0.37f * 2 * M_PI);
        float cutoff = 0.004f + 0.01f * gust;
        s->windLP1 += (w - s->windLP1) * cutoff;
        s->windLP2 += (s->windLP1 - s->windLP2) * cutoff;
        out += L.wind * (s->windLP1 - s->windLP2) * 4.0f * gust;
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
    // Music box: a wandering pentatonic lullaby.
    if (L.music > 0.001f) {
        s->noteTimer -= dt;
        if (s->noteTimer <= 0) {
            static const float scale[] = {523.25f, 587.33f, 659.25f, 783.99f, 880.0f, 1046.5f, 1174.7f, 1318.5f};
            int step = (int)(APUnit(s) * 5) - 2;
            s->noteIndex = MAX(0, MIN(7, s->noteIndex + (step == 0 ? 1 : step)));
            s->noteFreq = scale[s->noteIndex];
            s->noteEnv = 1;
            s->noteTimer = APUnit(s) < 0.2f ? 0.9 : 0.45;
        }
        s->noteEnv *= 1.0f - 2.4f / sr;
        s->notePhase += s->noteFreq * dt;
        float tone = sinf(s->notePhase * 2 * M_PI) + 0.25f * sinf(s->notePhase * 6 * M_PI);
        out += L.music * tone * s->noteEnv * 0.11f;
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
    // Room tone: a breath of warm noise under everything.
    if (L.room > 0.001f) {
        s->roomLP += (w - s->roomLP) * 0.01f;
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

+ (BOOL)isEnabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kSoundKey];
    return value ? [value boolValue] : YES;
}

+ (void)setEnabled:(BOOL)enabled { [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSoundKey]; }

- (instancetype)init {
    if ((self = [super init])) {
        _state = calloc(1, sizeof(APAmbienceState));
        _state->rng = 0xA5A5A5A5u;
        _state->sampleRate = 48000;
        _state->clockPhase = 0.5;
        _state->noteIndex = 3;
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
                case APAnimNotes: levels.music = 1.0f; break;
                case APAnimBubbles: levels.bubbles = MAX(levels.bubbles, 0.6f); break;
                default: break;
            }
        }
    }
    NSString *style = layout.style.identifier;
    if ([style isEqual:@"space"]) levels.hum = 1;
    if ([style isEqual:@"underwater"]) { levels.bubbles = MAX(levels.bubbles, 0.8f); levels.room = 0.9f; }
    if ([style isEqual:@"castle"]) levels.wind = MAX(levels.wind, 0.45f);
    if (([style isEqual:@"treehouse"] || [style isEqual:@"saloon"]) && night) levels.crickets = 1;
    if ([style isEqual:@"treehouse"] && !night) levels.wind = MAX(levels.wind, 0.25f);
    if (levels.room == 0) levels.room = 0.35f;
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
    [session setCategory:AVAudioSessionCategoryAmbient withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
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
    ApolloLog(@"[PalHome] ambience started %.0fHz fire=%.2f rain=%.2f wind=%.2f clock=%.2f music=%.2f hum=%.2f crickets=%.2f bubbles=%.2f",
              self.state->sampleRate, t.fire, t.rain, t.wind, t.clock, t.music, t.hum, t.crickets, t.bubbles);
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
