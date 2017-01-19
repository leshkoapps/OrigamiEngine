//
// ORGMOutputUnit.m
//
// Copyright (c) 2012 ap4y (lod@pisem.net)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ORGMOutputUnit.h"
#import "ORGMInputUnit.h"

@interface ORGMOutputUnit () {
    AudioUnit _outputUnit;
    AURenderCallbackStruct _renderCallback;
    AudioStreamBasicDescription _format;
    unsigned long long _amountPlayed;
    BOOL _processing;
    ORGMEngineOutputFormat _outputFormat;
}

@property (strong, nonatomic) ORGMConverter *converter;

@property (nonatomic,assign,getter=isReadyToPlay)BOOL readyToPlay;

- (int)readData:(void *)ptr amount:(int)amount;

@end

@implementation ORGMOutputUnit

- (instancetype)initWithConverter:(ORGMConverter *)converter outputFormat:(ORGMEngineOutputFormat)outputFormat{
    self = [super init];
    if (self) {
        _outputFormat = outputFormat;
        _outputUnit = NULL;
        self.converter = converter;
        _amountPlayed = 0;
        _processing = NO;
        [self setup];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - public

- (ORGMEngineOutputFormat)outputFormat{
    return _outputFormat;
}

- (AudioStreamBasicDescription)format {
    return _format;
}

- (BOOL)isProcessing{
    return _processing;
}

- (void)process {
    
    if(self.isCancelled){
        return;
    }
    
    NSParameterAssert(_outputUnit!=NULL);
    if(_outputUnit!=NULL){
        AudioOutputUnitStart(_outputUnit);
        _processing = YES;
    }
}

- (void)pause {
    NSParameterAssert(_outputUnit!=NULL);
    if(_outputUnit!=NULL){
        AudioOutputUnitStop(_outputUnit);
    }
}

- (void)resume {
    NSParameterAssert(_outputUnit!=NULL);
    if(_outputUnit!=NULL){
        AudioOutputUnitStart(_outputUnit);
    }
}

- (void)stop {
    self.converter = nil;
    if (_outputUnit!=NULL) {
        if(_processing){
            AudioOutputUnitStop(_outputUnit);
        }
        AudioUnitUninitialize(_outputUnit);
        _outputUnit = NULL;
    }
    _processing = NO;
}

- (double)framesToSeconds:(double)framesCount {
    return (framesCount/_format.mSampleRate);
}

- (double)amountPlayed {
    return (_amountPlayed/_format.mBytesPerFrame)/(_format.mSampleRate);
}

- (void)seek:(double)time {
    _amountPlayed = time*_format.mBytesPerFrame*(_format.mSampleRate);
}

- (void)setVolume:(float)volume {
    NSParameterAssert(_outputUnit!=NULL);
    if (_outputUnit!=NULL) {
        AudioUnitSetParameter(_outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, volume * 0.01f, 0);
    }
}

- (void)setReadyToPlay:(BOOL)readyToPlay{
    if(_readyToPlay!=readyToPlay){
        _readyToPlay = readyToPlay;
        if(self.outputUnitDelegate && _processing){
            if([self.outputUnitDelegate respondsToSelector:@selector(outputUnit:didChangeReadyToPlay:)]){
                [self.outputUnitDelegate outputUnit:self didChangeReadyToPlay:readyToPlay];
            }
        }
    }
}

- (void)setSampleRate:(double)sampleRate {
    UInt32 size = sizeof(AudioStreamBasicDescription);
    _format.mSampleRate = sampleRate;
    NSParameterAssert(_outputUnit!=NULL);
    if(_outputUnit!=NULL){
        AudioUnitSetProperty(_outputUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             0,
                             &_format,
                             size);

        AudioUnitSetProperty(_outputUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &_format,
                             size);
    }
    [self setFormat:&_format];
    if(self.didChangeSampleRateBlock){
        self.didChangeSampleRateBlock(sampleRate);
    }
}

#pragma mark - callbacks

static OSStatus Sound_Renderer(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp  *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList  *ioData) {
    
    ORGMOutputUnit *output = (__bridge ORGMOutputUnit *)inRefCon;
    
    if(output.isCancelled){
        return errSecUserCanceled;
    }
    
    OSStatus err = noErr;

    void *readPointer = ioData->mBuffers[0].mData;

    int amountToRead, amountRead;

    amountToRead = inNumberFrames * (output->_format.mBytesPerPacket);
    amountRead = [output readData:(readPointer) amount:amountToRead];

    if (amountRead < amountToRead) {
        int amountRead2;
        amountRead2 = [output readData:(readPointer+amountRead) amount:amountToRead-amountRead];
        amountRead += amountRead2;
    }

    output.readyToPlay = (amountRead>0);
    
    ioData->mBuffers[0].mDataByteSize = amountRead;
    ioData->mBuffers[0].mNumberChannels = output->_format.mChannelsPerFrame;
    ioData->mNumberBuffers = 1;
    
    if(output.didRenderSoundBlock){
        output.didRenderSoundBlock(output,ioActionFlags,inTimeStamp,inBusNumber,inNumberFrames,ioData);
    }

    return err;
}

- (BOOL)setup {
    
    if (_outputUnit!=NULL) {
        [self stop];
    }

    AudioComponentDescription desc;
    OSStatus err = 1;

    desc.componentType = kAudioUnitType_Output;
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent comp;
    if ((comp = AudioComponentFindNext(NULL, &desc)) == NULL) {
        return NO;
    }

    if (AudioComponentInstanceNew(comp, &_outputUnit) != noErr) {
        _outputUnit = NULL;
        return NO;
    }

    if (AudioUnitInitialize(_outputUnit) != noErr){
        _outputUnit = NULL;
        return NO;
    }

    AudioStreamBasicDescription deviceFormat;
    UInt32 size = sizeof(AudioStreamBasicDescription);
    Boolean outWritable;
    
    if(_outputUnit!=NULL){
        AudioUnitGetPropertyInfo(_outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                0,
                &size,
                &outWritable);

        err = AudioUnitGetProperty (_outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                0,
                &deviceFormat,
                &size);
    }

    if (err != noErr){
        return NO;
    }

    deviceFormat.mChannelsPerFrame = 2;
    
    deviceFormat.mFormatFlags &= ~kLinearPCMFormatFlagIsNonInterleaved;
    deviceFormat.mFormatFlags &= ~kLinearPCMFormatFlagIsFloat;
    deviceFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
    
    deviceFormat.mBytesPerFrame = deviceFormat.mChannelsPerFrame*(deviceFormat.mBitsPerChannel/8);
    deviceFormat.mBytesPerPacket = deviceFormat.mBytesPerFrame * deviceFormat.mFramesPerPacket;
    
    if (_outputFormat == ORGMOutputFormat24bit) {
        deviceFormat.mBytesPerFrame = 6;
        deviceFormat.mBytesPerPacket = 6;
        deviceFormat.mBitsPerChannel = 24;
    }

    if(_outputUnit!=NULL){
        AudioUnitSetProperty(_outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                0,
                &deviceFormat,
                size);
        AudioUnitSetProperty(_outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &deviceFormat,
                size);
    }

    _renderCallback.inputProc = Sound_Renderer;
    _renderCallback.inputProcRefCon = (__bridge void * _Nullable)(self);

    if(_outputUnit!=NULL){
        AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0, &_renderCallback,
                sizeof(AURenderCallbackStruct));
    }

    [self setFormat:&deviceFormat];
    
    
    uint32_t format4cc = CFSwapInt32HostToBig(deviceFormat.mFormatID);
    
    NSLog(@"Sample Rate: %f", deviceFormat.mSampleRate);
    NSLog(@"Channels: %u", (unsigned int)deviceFormat.mChannelsPerFrame);
    NSLog(@"Bits: %u", (unsigned int)deviceFormat.mBitsPerChannel);
    NSLog(@"BytesPerFrame: %u", (unsigned int)deviceFormat.mBytesPerFrame);
    NSLog(@"BytesPerPacket: %u", (unsigned int)deviceFormat.mBytesPerPacket);
    NSLog(@"FramesPerPacket: %u", (unsigned int)deviceFormat.mFramesPerPacket);
    NSLog(@"Format Flags: %d", (unsigned int)deviceFormat.mFormatFlags);
    NSLog(@"Format Flags: %4.4s", (char *)&format4cc);
    NSLog(@"kAudioFormatFlagIsFloat: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsFloat)==kAudioFormatFlagIsFloat));
    NSLog(@"kAudioFormatFlagIsBigEndian: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsBigEndian)==kAudioFormatFlagIsBigEndian));
    NSLog(@"kAudioFormatFlagIsSignedInteger: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsSignedInteger)==kAudioFormatFlagIsSignedInteger));
    NSLog(@"kAudioFormatFlagIsPacked: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsPacked)==kAudioFormatFlagIsPacked));
    NSLog(@"kAudioFormatFlagIsAlignedHigh: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsAlignedHigh)==kAudioFormatFlagIsAlignedHigh));
    NSLog(@"kAudioFormatFlagIsNonInterleaved: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsNonInterleaved)==kAudioFormatFlagIsNonInterleaved));
    NSLog(@"kAudioFormatFlagIsNonMixable: %@", @((deviceFormat.mFormatFlags&kAudioFormatFlagIsNonMixable)==kAudioFormatFlagIsNonMixable));
    NSLog(@"kAppleLosslessFormatFlag_16BitSourceData: %@", @((deviceFormat.mFormatFlags&kAppleLosslessFormatFlag_16BitSourceData)==kAppleLosslessFormatFlag_16BitSourceData));
    NSLog(@"kAppleLosslessFormatFlag_20BitSourceData: %@", @((deviceFormat.mFormatFlags&kAppleLosslessFormatFlag_20BitSourceData)==kAppleLosslessFormatFlag_20BitSourceData));
    NSLog(@"kAppleLosslessFormatFlag_24BitSourceData: %@", @((deviceFormat.mFormatFlags&kAppleLosslessFormatFlag_24BitSourceData)==kAppleLosslessFormatFlag_24BitSourceData));
    NSLog(@"kAppleLosslessFormatFlag_32BitSourceData: %@", @((deviceFormat.mFormatFlags&kAppleLosslessFormatFlag_32BitSourceData)==kAppleLosslessFormatFlag_32BitSourceData));
    
    
    return YES;
}

- (int)readData:(void *)ptr amount:(int)amount {
    if(self.isCancelled){
        return 0;
    }
    if (self.converter) {
        int bytesRead = [self.converter shiftBytes:amount buffer:ptr];
        _amountPlayed += bytesRead;
        if ([self.converter isReadyForBuffering]) {
            dispatch_source_merge_data(self.converter.buffering_source, 1);
        }
        return bytesRead;
    }
    return 0;
}

- (void)setFormat:(AudioStreamBasicDescription *)f {
    _format = *f;
}

@end
