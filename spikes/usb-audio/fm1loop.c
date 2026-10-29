// fm1loop: plays a quiet sine to the FM-1's USB audio output and records the FM-1's USB audio input (its master
// output, which includes what the host plays: chip/usb.c uac_play then uac_tap) at the same time, to a WAV file.
// CoreAudio AUHAL, both sides on the device whose name contains --device (default "FM-1").
//
//   fm1loop --list
//   fm1loop --seconds 30 --out run.wav [--freq 997] [--db -24] [--buffer FRAMES] [--busy-us N] [--device FM-1]
//           [--in NAME]   (record another input device instead of the FM-1s)
//
// --buffer sets the output device's IO buffer (kAudioDevicePropertyBufferFrameSize, this process only; default:
// leave it). --busy-us spins that long in each output render callback (a busy render thread). The sample rate is
// set to 44100 on the device when it is not (the rate before is put back at exit).
// Prints the output's IO buffer, callbacks, and the frames played / recorded.
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static double g_freq = 997.0, g_amp = 0.063, g_phase = 0.0, g_busy_us = 0.0;
static volatile uint64_t g_played, g_out_cb, g_in_cb, g_in_frames;
static float *g_rec;                                    // interleaved stereo
static uint64_t g_rec_cap;                              // frames
static AudioUnit g_in_au;
static AudioBufferList *g_abl;
static volatile int g_stop;
static mach_timebase_info_data_t g_tb;

static void die(const char *what, OSStatus e)
{
    fprintf(stderr, "fm1loop: %s failed (%d)\n", what, (int)e);
    exit(1);
}

static int dev_name(AudioDeviceID d, char *buf, size_t n)
{
    CFStringRef s = NULL;
    UInt32 sz = sizeof s;
    AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &s) || !s)
        return -1;
    CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
    CFRelease(s);
    return 0;
}

static UInt32 dev_channels(AudioDeviceID d, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
    UInt32 sz = 0, ch = 0;
    if (AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz) || !sz)
        return 0;
    AudioBufferList *l = malloc(sz);
    if (!AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, l))
        for (UInt32 i = 0; i < l->mNumberBuffers; i++)
            ch += l->mBuffers[i].mNumberChannels;
    free(l);
    return ch;
}

static Float64 dev_rate(AudioDeviceID d)
{
    Float64 r = 0;
    UInt32 sz = sizeof r;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &r);
    return r;
}

static void dev_set_rate(AudioDeviceID d, Float64 r)
{
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    OSStatus e = AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof r, &r);
    if (e)
        die("set the sample rate", e);
    for (int i = 0; i < 100 && dev_rate(d) != r; i++)
        usleep(10000);
}

static UInt32 dev_buffer(AudioDeviceID d, AudioObjectPropertyScope scope)
{
    UInt32 f = 0, sz = sizeof f;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyBufferFrameSize, scope, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &f);
    return f;
}

static AudioDeviceID *devices(UInt32 *n)
{
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioDeviceID *ids = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    *n = sz / sizeof *ids;
    return ids;
}

static OSStatus out_cb(void *ref, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n,
                       AudioBufferList *io)
{
    (void)ref, (void)fl, (void)ts, (void)bus;
    float *p = (float *)io->mBuffers[0].mData;
    const double w = 2.0 * M_PI * g_freq / 44100.0;
    for (UInt32 i = 0; i < n; i++) {
        float v = (float)(g_amp * sin(g_phase));
        p[2 * i] = v;
        p[2 * i + 1] = v;
        g_phase += w;
        if (g_phase > 2.0 * M_PI)
            g_phase -= 2.0 * M_PI;
    }
    g_played += n;
    g_out_cb++;
    if (g_busy_us > 0) {
        const uint64_t t0 = mach_absolute_time(), dt = (uint64_t)(g_busy_us * 1000.0 * g_tb.denom / g_tb.numer);
        while (mach_absolute_time() - t0 < dt) {
        }
    }
    return noErr;
}

static OSStatus in_cb(void *ref, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n,
                      AudioBufferList *io)
{
    (void)ref, (void)io;
    g_abl->mBuffers[0].mDataByteSize = n * 8;
    OSStatus e = AudioUnitRender(g_in_au, fl, ts, bus, n, g_abl);
    if (e)
        return e;
    const float *p = (const float *)g_abl->mBuffers[0].mData;
    uint64_t w = g_in_frames, k = n;
    if (w + k > g_rec_cap)
        k = g_rec_cap > w ? g_rec_cap - w : 0;
    memcpy(g_rec + 2 * w, p, (size_t)k * 8);
    g_in_frames = w + k;
    g_in_cb++;
    return noErr;
}

static void set_format(AudioUnit au, AudioUnitScope scope, AudioUnitElement el)
{
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = 44100;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 2;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = 8;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 8;
    OSStatus e = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, scope, el, &f, sizeof f);
    if (e)
        die("stream format", e);
}

static AudioUnit make_au(AudioDeviceID d, int input)
{
    AudioComponentDescription cd = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple,
                                    0, 0};
    AudioComponent c = AudioComponentFindNext(NULL, &cd);
    AudioUnit au;
    OSStatus e = AudioComponentInstanceNew(c, &au);
    if (e)
        die("AUHAL", e);
    UInt32 on = 1, off = 0;
    if (input) {
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof on);
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof off);
    }
    e = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, sizeof d);
    if (e)
        die("set device", e);
    if (input) {
        set_format(au, kAudioUnitScope_Output, 1);
        AURenderCallbackStruct cb = {in_cb, NULL};
        e = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                 sizeof cb);
    } else {
        set_format(au, kAudioUnitScope_Input, 0);
        AURenderCallbackStruct cb = {out_cb, NULL};
        e = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    }
    if (e)
        die("callback", e);
    e = AudioUnitInitialize(au);
    if (e)
        die("AudioUnitInitialize", e);
    return au;
}

static void wr32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void wr16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void write_wav(const char *path, const float *s, uint64_t frames)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(1);
    }
    const uint32_t bytes = (uint32_t)(frames * 8);
    fwrite("RIFF", 1, 4, f);
    wr32(f, 36 + bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    wr32(f, 16);
    wr16(f, 3);                                         // IEEE float
    wr16(f, 2);
    wr32(f, 44100);
    wr32(f, 44100 * 8);
    wr16(f, 8);
    wr16(f, 32);
    fwrite("data", 1, 4, f);
    wr32(f, bytes);
    fwrite(s, 8, (size_t)frames, f);
    fclose(f);
}

static void on_sig(int s) { (void)s; g_stop = 1; }

int main(int argc, char **argv)
{
    const char *want = "FM-1", *want_in = NULL, *out = "loop.wav";
    double seconds = 10, db = -24;
    int list = 0;
    UInt32 buffer = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--list")) list = 1;
        else if (!strcmp(argv[i], "--set-rate") && i + 2 < argc) {       // --set-rate NAME HZ (put a rate back)
            UInt32 nn;
            AudioDeviceID *dd = devices(&nn);
            for (UInt32 k = 0; k < nn; k++) {
                char nm[256] = "";
                dev_name(dd[k], nm, sizeof nm);
                if (strstr(nm, argv[i + 1]))
                    dev_set_rate(dd[k], atof(argv[i + 2])), printf("%s: %.0f Hz\n", nm, dev_rate(dd[k]));
            }
            return 0;
        }
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--freq") && i + 1 < argc) g_freq = atof(argv[++i]);
        else if (!strcmp(argv[i], "--db") && i + 1 < argc) db = atof(argv[++i]);
        else if (!strcmp(argv[i], "--buffer") && i + 1 < argc) buffer = (UInt32)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--busy-us") && i + 1 < argc) g_busy_us = atof(argv[++i]);
        else if (!strcmp(argv[i], "--device") && i + 1 < argc) want = argv[++i];
        else if (!strcmp(argv[i], "--in") && i + 1 < argc) want_in = argv[++i];
        else {
            fprintf(stderr, "usage: fm1loop [--list] [--seconds S] [--out F.wav] [--freq HZ] [--db DBFS] "
                            "[--buffer FRAMES] [--busy-us US] [--device NAME] [--in NAME]\n");
            return 2;
        }
    }
    mach_timebase_info(&g_tb);
    g_amp = pow(10.0, db / 20.0);
    UInt32 n;
    AudioDeviceID *ids = devices(&n), dev_in = 0, dev_out = 0;
    int matches_in = 0, matches_out = 0;
    for (UInt32 i = 0; i < n; i++) {
        char nm[256] = "";
        dev_name(ids[i], nm, sizeof nm);
        const UInt32 ci = dev_channels(ids[i], kAudioObjectPropertyScopeInput),
                     co = dev_channels(ids[i], kAudioObjectPropertyScopeOutput);
        if (list)
            printf("%u  %-40s in %u  out %u  %.0f Hz\n", (unsigned)ids[i], nm, (unsigned)ci, (unsigned)co,
                   dev_rate(ids[i]));
        if (strstr(nm, want_in ? want_in : want) && ci)
            dev_in = ids[i], matches_in++;
        if (strstr(nm, want) && co)
            dev_out = ids[i], matches_out++;
    }
    if (list)
        return 0;
    if (matches_in != 1 || matches_out != 1) {
        fprintf(stderr, "fm1loop: %d input and %d output devices named like \"%s\": want exactly one each\n",
                matches_in, matches_out, want);
        return 1;
    }
    const Float64 rate_in0 = dev_rate(dev_in), rate_out0 = dev_rate(dev_out);
    if (rate_out0 != 44100) dev_set_rate(dev_out, 44100);
    if (dev_in != dev_out && rate_in0 != 44100) dev_set_rate(dev_in, 44100);
    g_rec_cap = (uint64_t)((seconds + 3) * 44100);
    g_rec = calloc((size_t)g_rec_cap * 2, sizeof(float));
    g_abl = malloc(sizeof(AudioBufferList));
    g_abl->mNumberBuffers = 1;
    g_abl->mBuffers[0].mNumberChannels = 2;
    g_abl->mBuffers[0].mDataByteSize = 8192 * 8;
    g_abl->mBuffers[0].mData = malloc(8192 * 8);

    AudioUnit ao = make_au(dev_out, 0);
    g_in_au = make_au(dev_in, 1);
    if (buffer) {
        OSStatus e = AudioUnitSetProperty(ao, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                          &buffer, sizeof buffer);
        if (e)
            die("set the IO buffer", e);
    }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    OSStatus e = AudioOutputUnitStart(g_in_au);
    if (e)
        die("start input", e);
    e = AudioOutputUnitStart(ao);
    if (e)
        die("start output", e);
    fprintf(stderr, "fm1loop: device %u, %.0f Hz (was %.0f/%.0f), IO buffer out %u in %u frames, %.1f Hz at %.1f dBFS, "
                    "busy %.0f us, %.0f s -> %s\n",
            (unsigned)dev_out, dev_rate(dev_out), rate_out0, rate_in0, (unsigned)dev_buffer(dev_out,
            kAudioObjectPropertyScopeOutput), (unsigned)dev_buffer(dev_in, kAudioObjectPropertyScopeInput), g_freq, db,
            g_busy_us, seconds, out);
    const uint64_t want_frames = (uint64_t)(seconds * 44100);
    for (int t = 0; !g_stop && g_in_frames < want_frames && t < (int)(seconds * 100) + 500; t++)
        usleep(10000);
    AudioOutputUnitStop(ao);
    AudioOutputUnitStop(g_in_au);
    AudioUnitUninitialize(ao);
    AudioUnitUninitialize(g_in_au);
    AudioComponentInstanceDispose(ao);
    AudioComponentInstanceDispose(g_in_au);
    if (dev_rate(dev_out) != rate_out0 && rate_out0 > 0) dev_set_rate(dev_out, rate_out0);
    if (dev_in != dev_out && dev_rate(dev_in) != rate_in0 && rate_in0 > 0) dev_set_rate(dev_in, rate_in0);
    fprintf(stderr, "fm1loop: played %llu frames (%llu callbacks), recorded %llu frames (%llu callbacks)\n",
            (unsigned long long)g_played, (unsigned long long)g_out_cb, (unsigned long long)g_in_frames,
            (unsigned long long)g_in_cb);
    write_wav(out, g_rec, g_in_frames);
    return 0;
}
