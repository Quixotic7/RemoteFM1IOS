// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AUInternalRenderBlock: Objective-C++ only for the block itself; everything it calls is plain C++.
#import "RFMKernelImpl.h"

#include <atomic>
#include <cstring>
#include <memory>

// a MIDI 1.0 status byte's message length (0: not a channel or system message we pass)
static uint32_t midi1Len(uint8_t st)
{
    switch (st & 0xF0) {
    case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 3;
    case 0xC0: case 0xD0: return 2;
    default: break;
    }
    if (st == 0xF2) return 3;
    if (st == 0xF1 || st == 0xF3) return 2;
    return st >= 0xF6 ? 1 : 0;
}

// the event's frame in this render
static uint32_t offsetOf(AUEventSampleTime t, const AudioTimeStamp *ts, uint32_t n)
{
    if (t >= (AUEventSampleTime)AUEventSampleTimeImmediate && t < (AUEventSampleTime)AUEventSampleTimeImmediate + (1 << 24))
        t = (AUEventSampleTime)(ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) ? ts->mSampleTime : 0) +
            (t - (AUEventSampleTime)AUEventSampleTimeImmediate);
    const double t0 = ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) ? ts->mSampleTime : 0;
    const double d = (double)t - t0;
    if (!(d > 0))
        return 0;
    return d >= (double)n ? (n ? n - 1 : 0) : (uint32_t)d;
}

// MIDI 2.0 UMP (AURenderEventMIDIEventList): a MIDI 1.0 channel voice word (type 2) as its bytes; system words
// (type 1) too; MIDI 2.0 channel voice (type 4) counted only
static void umpWords(rfmk *k, const MIDIEventList *list, uint32_t offset)
{
    const MIDIEventPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        for (UInt32 w = 0; w < p->wordCount; w++) {
            const UInt32 word = p->words[w];
            const uint32_t type = word >> 28;
            if (type == 0x2 || type == 0x1) {
                const uint8_t b[3] = {(uint8_t)(word >> 16), (uint8_t)(word >> 8), (uint8_t)word};
                const uint32_t n = midi1Len(b[0]);
                if (n)
                    k->midi(b, n, offset);
            } else if (type == 0x4) {
                const uint8_t b[1] = {(uint8_t)(word >> 16)};
                k->midiEvents.fetch_add(1, std::memory_order_relaxed);
                (void)b;
                w++;                            // (a 64-bit message)
            }
        }
        p = MIDIEventPacketNext(p);
    }
}

namespace {
struct OutCtx {
    rfmk *k;
    AUEventSampleTime t;
};
}

static void emitOut(void *ctx, const uint8_t *msg, uint32_t len, uint32_t offset)
{
    OutCtx *o = static_cast<OutCtx *>(ctx);
#if __has_feature(objc_arc)
    AUMIDIOutputEventBlock b = (__bridge AUMIDIOutputEventBlock)o->k->midiOut;
#else
    AUMIDIOutputEventBlock b = (AUMIDIOutputEventBlock)o->k->midiOut;
#endif
    if (b)
        b(o->t + (AUEventSampleTime)offset, 0, (NSInteger)len, msg);
}

// the host's tempo, beat and transport for this buffer (RFMHostClock.h); what it doesn't answer stays 0
static void hostInput(rfmk *k, rfmhc_input_t *in, uint32_t frames)
{
#if __has_feature(objc_arc)
    AUHostMusicalContextBlock mc = (__bridge AUHostMusicalContextBlock)k->musical;
    AUHostTransportStateBlock tr = (__bridge AUHostTransportStateBlock)k->transport;
#else
    AUHostMusicalContextBlock mc = (AUHostMusicalContextBlock)k->musical;
    AUHostTransportStateBlock tr = (AUHostTransportStateBlock)k->transport;
#endif
    *in = rfmhc_input_t{};
    in->sample_rate = k->sampleRate;
    in->frames = frames;
    if (mc)
        in->has_context = mc(&in->tempo, nullptr, nullptr, &in->beat, nullptr, nullptr) ? 1 : 0;
    AUHostTransportStateFlags f = 0;
    double pos = 0;
    if (tr)
        in->has_transport = tr(&f, &pos, &in->cycle_start, &in->cycle_end) ? 1 : 0;
    in->moving = (f & AUHostTransportStateMoving) ? 1 : 0;
    in->cycling = (f & AUHostTransportStateCycling) ? 1 : 0;
}

AUInternalRenderBlock rfmk_render_block(rfmk_t *k)
{
    AUInternalRenderBlock block = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                                                     const AudioTimeStamp *ts, AUAudioFrameCount frameCount,
                                                     NSInteger, AudioBufferList *outputData,
                                                     const AURenderEvent *events, AURenderPullInputBlock) {
        if (frameCount > k->maxFrames)
            return kAudioUnitErr_TooManyFramesToProcess;
        k->nev = 0;
        const bool clockOn = k->hostClockOn.load(std::memory_order_relaxed);
        rfmhc_input_t host{};
        if (clockOn)
            hostInput(k, &host, frameCount);
        k->dropClock = clockOn && host.has_context && host.has_transport;
        for (const AURenderEvent *e = events; e; e = e->head.next) {
            if (e->head.eventType == AURenderEventMIDI || e->head.eventType == AURenderEventMIDISysEx)
                k->midi(e->MIDI.data, e->MIDI.length, offsetOf(e->head.eventSampleTime, ts, frameCount));
            else if (e->head.eventType == AURenderEventMIDIEventList)
                umpWords(k, &e->MIDIEventsList.eventList, offsetOf(e->head.eventSampleTime, ts, frameCount));
        }
        k->hostClock(host, clockOn);                // (the host's clock and transport, merged by frame)
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            AudioBuffer &b = outputData->mBuffers[i];
            if (!b.mData)                           // the host wants our buffers
                b.mData = k->bufs[i < k->channels ? i : k->channels - 1];
            b.mDataByteSize = frameCount * sizeof(float);
        }
        float *L = outputData->mNumberBuffers > 0 ? (float *)outputData->mBuffers[0].mData : k->bufs[0];
        float *R = outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : k->scratch.data();
        const int played = k->process(L, R, frameCount);
        if (outputData->mNumberBuffers == 1)        // (mono: both channels)
            for (UInt32 i = 0; i < frameCount; i++)
                L[i] = 0.5f * (L[i] + R[i]);
        for (UInt32 i = 2; i < outputData->mNumberBuffers; i++)
            std::memset(outputData->mBuffers[i].mData, 0, frameCount * sizeof(float));
        if (!played)
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        if (k->midiOut) {
            OutCtx o{k, (AUEventSampleTime)(ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) ? ts->mSampleTime : 0)};
            k->drainMidiOut(emitOut, &o);
        }
        k->counted(frameCount);
        return noErr;
    };
#if __has_feature(objc_arc)
    return block;
#else
    return [[block copy] autorelease];
#endif
}

void rfmk_set_midi_out(rfmk_t *k, AUMIDIOutputEventBlock block)
{
    rfmk_drop_midi_out(k);
    if (block) {
#if __has_feature(objc_arc)
        k->midiOut = (__bridge_retained void *)[block copy];
#else
        k->midiOut = (void *)[block copy];
#endif
    }
    if (k->engine)
        rfme_midi_out_enable(k->engine, block ? 1 : 0);
}

static void *retainBlock(id b)
{
    if (!b)
        return nullptr;
#if __has_feature(objc_arc)
    return (__bridge_retained void *)[b copy];
#else
    return (void *)[b copy];
#endif
}

static void releaseBlock(void *&p)
{
    if (!p)
        return;
#if __has_feature(objc_arc)
    id b = (__bridge_transfer id)p;
    b = nil;
#else
    [(id)p release];
#endif
    p = nullptr;
}

void rfmk_set_host_blocks(rfmk_t *k, AUHostMusicalContextBlock musical, AUHostTransportStateBlock transport)
{
    rfmk_drop_host_blocks(k);
    k->musical = retainBlock(musical);
    k->transport = retainBlock(transport);
}

void rfmk_drop_host_blocks(rfmk *k)
{
    releaseBlock(k->musical);
    releaseBlock(k->transport);
}

void rfmk_drop_midi_out(rfmk *k)
{
    if (!k->midiOut)
        return;
#if __has_feature(objc_arc)
    AUMIDIOutputEventBlock b = (__bridge_transfer AUMIDIOutputEventBlock)k->midiOut;
    b = nil;
#else
    [(id)k->midiOut release];
#endif
    k->midiOut = nullptr;
}

// ---- RFMAudioUnitBase: the render context observer
@implementation RFMAudioUnitBase {
    // shared with the observer block, which the OS caches and may call after this object is gone (then: NULL)
    std::shared_ptr<std::atomic<rfme_t *>> _rcEngine;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError
{
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (self)
        _rcEngine = std::make_shared<std::atomic<rfme_t *>>(nullptr);
    return self;
}

- (void)rfmSetRenderContextEngine:(rfme_t *)engine
{
    if (_rcEngine)
        _rcEngine->store(engine, std::memory_order_release);
}

- (AURenderContextObserver)renderContextObserver
{
    std::shared_ptr<std::atomic<rfme_t *>> h = _rcEngine;
    return ^(const AudioUnitRenderContext *ctx) {
        rfme_t *e = h ? h->load(std::memory_order_acquire) : nullptr;
        if (!e)
            return;
#if __has_feature(objc_arc)
        rfme_set_workgroup(e, ctx ? (__bridge void *)ctx->workgroup : nullptr);
#else
        rfme_set_workgroup(e, ctx ? (void *)ctx->workgroup : nullptr);
#endif
    };
}

- (void)dealloc
{
    if (_rcEngine)
        _rcEngine->store(nullptr, std::memory_order_release);
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end
