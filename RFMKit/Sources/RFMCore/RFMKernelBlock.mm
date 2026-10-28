// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AUInternalRenderBlock: Objective-C++ only for the block itself; everything it calls is plain C++.
#import "RFMKernelImpl.h"

#include <cstring>

// MIDI 2.0 UMP (AURenderEventMIDIEventList): a MIDI 1.0 channel voice word (type 2) as its three bytes
static void umpWords(rfmk *k, const MIDIEventList *list)
{
    const MIDIEventPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        for (UInt32 w = 0; w < p->wordCount; w++) {
            const UInt32 word = p->words[w];
            if ((word >> 28) == 0x2) {
                const uint8_t b[3] = {(uint8_t)(word >> 16), (uint8_t)(word >> 8), (uint8_t)word};
                k->midi(b, 3);
            } else if ((word >> 28) == 0x4) {   // MIDI 2.0 channel voice: counted, status byte only
                const uint8_t b[1] = {(uint8_t)(word >> 16)};
                k->midi(b, 1);
            }
        }
        p = MIDIEventPacketNext(p);
    }
}

AUInternalRenderBlock rfmk_render_block(rfmk_t *k)
{
    AUInternalRenderBlock block = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                                                     const AudioTimeStamp *, AUAudioFrameCount frameCount,
                                                     NSInteger, AudioBufferList *outputData,
                                                     const AURenderEvent *events, AURenderPullInputBlock) {
        if (frameCount > k->maxFrames)
            return kAudioUnitErr_TooManyFramesToProcess;
        for (const AURenderEvent *e = events; e; e = e->head.next) {
            if (e->head.eventType == AURenderEventMIDI || e->head.eventType == AURenderEventMIDISysEx)
                k->midi(e->MIDI.data, e->MIDI.length);
            else if (e->head.eventType == AURenderEventMIDIEventList)
                umpWords(k, &e->MIDIEventsList.eventList);
        }
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            AudioBuffer &b = outputData->mBuffers[i];
            if (!b.mData)                           // the host wants our buffers
                b.mData = k->bufs[i < k->channels ? i : k->channels - 1];
            b.mDataByteSize = frameCount * sizeof(float);
            std::memset(b.mData, 0, b.mDataByteSize);
        }
        *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        k->counted(frameCount);
        return noErr;
    };
#if __has_feature(objc_arc)
    return block;
#else
    return [[block copy] autorelease];
#endif
}
