// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The engine's AVAudioSourceNode: Objective-C++ only for the block; the block calls rfme_render (plain C++), so no
// Swift and nothing that allocates or locks runs on the render thread.
#import "RFMEngine.h"

AVAudioSourceNode *rfme_source_node(rfme_t *e, AVAudioFormat *format)
{
    const double rate = format.sampleRate;
    AVAudioSourceNodeRenderBlock block = ^OSStatus(BOOL *isSilence, const AudioTimeStamp *, AVAudioFrameCount n,
                                                   AudioBufferList *out) {
        float *L = out->mNumberBuffers > 0 ? static_cast<float *>(out->mBuffers[0].mData) : nullptr;
        float *R = out->mNumberBuffers > 1 ? static_cast<float *>(out->mBuffers[1].mData) : nullptr;
        if (!L)
            return noErr;
        rfme_render(e, L, R ? R : L, n, rate);      // (mono: both channels into the one buffer, the right last)
        for (UInt32 i = 0; i < out->mNumberBuffers; i++)
            out->mBuffers[i].mDataByteSize = n * sizeof(float);
        *isSilence = NO;
        return noErr;
    };
    AVAudioSourceNode *node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:block];
#if __has_feature(objc_arc)
    return node;
#else
    return [node autorelease];
#endif
}
