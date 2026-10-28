// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AUInternalRenderBlock: Objective-C++ only for the block itself; everything it calls is plain C++.
#import "RFMKernelImpl.h"

#include <cstring>

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

static void emitOut(void *ctx, const uint8_t *msg, uint32_t len)
{
    OutCtx *o = static_cast<OutCtx *>(ctx);
#if __has_feature(objc_arc)
    AUMIDIOutputEventBlock b = (__bridge AUMIDIOutputEventBlock)o->k->midiOut;
#else
    AUMIDIOutputEventBlock b = (AUMIDIOutputEventBlock)o->k->midiOut;
#endif
    if (b)
        b(o->t, 0, (NSInteger)len, msg);
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
        for (const AURenderEvent *e = events; e; e = e->head.next) {
            if (e->head.eventType == AURenderEventMIDI || e->head.eventType == AURenderEventMIDISysEx)
                k->midi(e->MIDI.data, e->MIDI.length, offsetOf(e->head.eventSampleTime, ts, frameCount));
            else if (e->head.eventType == AURenderEventMIDIEventList)
                umpWords(k, &e->MIDIEventsList.eventList, offsetOf(e->head.eventSampleTime, ts, frameCount));
        }
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
