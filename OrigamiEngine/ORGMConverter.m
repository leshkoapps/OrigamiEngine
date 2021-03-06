//
// ORGMConverter.m
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

#import "ORGMConverter.h"

#import "ORGMInputUnit.h"
#import "ORGMOutputUnit.h"

@interface ORGMConverter () {
    AudioStreamBasicDescription _inputFormat;
    AudioStreamBasicDescription _outputFormat;
    AudioConverterRef _converter;
}

@property (strong, nonatomic) ORGMInputUnit *inputUnit;
@property (weak,   nonatomic) ORGMOutputUnit *outputUnit;
@property (strong, nonatomic) NSMutableData *convertedData;
@property (strong, nonatomic) dispatch_source_t buffering_source;
@property (assign, nonatomic) void *callbackBuffer;
@property (assign, nonatomic) void *writeBuf;

@end

@implementation ORGMConverter

- (instancetype)initWithInputUnit:(ORGMInputUnit *)inputUnit bufferingSource:(dispatch_source_t)bufferingSource{
    self = [super init];
    if (self) {
        self.convertedData = [NSMutableData data];
        self.inputUnit = inputUnit;
        self.buffering_source = bufferingSource;
        _inputFormat = inputUnit.format;
        self.writeBuf = malloc(CHUNK_SIZE);
    }
    return self;
}

- (void)dealloc {
    if(self.callbackBuffer!=NULL){
        free(self.callbackBuffer);
        self.callbackBuffer=NULL;
    }
    if(self.writeBuf!=NULL){
        free(self.writeBuf);
        self.writeBuf=NULL;
    }
    @try {
        [self.inputUnit close];
        self.inputUnit = nil;
    } @catch (NSException *exception) {}
}

#pragma mark - public

- (BOOL)setupWithOutputUnit:(ORGMOutputUnit *)outputUnit {
    self.outputUnit = outputUnit;
    [self.outputUnit setSampleRate:_inputFormat.mSampleRate];

    _outputFormat = outputUnit.format;
    self.callbackBuffer = malloc((CHUNK_SIZE/_outputFormat.mBytesPerFrame) * _inputFormat.mBytesPerPacket);

    OSStatus stat = AudioConverterNew(&_inputFormat, &_outputFormat, &_converter);
    if (stat != noErr) {
        NSLog(NSLocalizedString(@"Error creating converter", nil));
        return NO;
    }

    if (_inputFormat.mChannelsPerFrame == 1) {
        SInt32 channelMap[2] = { 0, 0 };

        stat = AudioConverterSetProperty(_converter,
                                         kAudioConverterChannelMap,
                                         sizeof(channelMap),
                                         channelMap);
        if (stat != noErr) {
            NSLog(NSLocalizedString(@"Error mapping channels", nil));
            return NO;
        }
    }

    return YES;
}

- (void)process {
    
    if(self.isCancelled){
        return;
    }
    
    int amountConverted = 0;
    do {
        if(self.isCancelled){
            break;
        }
        if (self.convertedData.length >= BUFFER_SIZE) {
            break;
        }
        amountConverted = [self convert:self.writeBuf amount:CHUNK_SIZE];
        __weak typeof (self) weakSelf = self;
        dispatch_sync(self.inputUnit.lock_queue, ^{
            [weakSelf.convertedData appendBytes:weakSelf.writeBuf length:amountConverted];
        });
    } while (amountConverted > 0 && self.isCancelled==NO);

    if(self.isCancelled){
        return;
    }
    
    if (!self.outputUnit.isProcessing) {
        if (_convertedData.length < BUFFER_SIZE) {
            dispatch_source_merge_data(self.buffering_source, 1);
            return;
        }
        [_outputUnit process];
    }
}

- (void)reinitWithNewInput:(ORGMInputUnit *)inputUnit withDataFlush:(BOOL)flush {
    if (flush) {
        [self flushBuffer];
    }
    self.inputUnit = inputUnit;
    _inputFormat = inputUnit.format;
    [self setupWithOutputUnit:_outputUnit];
}

- (int)shiftBytes:(NSUInteger)amount buffer:(void *)buffer {
    if(self.isCancelled){
        return 0;
    }
    int bytesToRead = (int)MIN(_convertedData.length, amount);
    __weak typeof (self) weakSelf = self;
    dispatch_sync(self.inputUnit.lock_queue, ^{
        memcpy(buffer, weakSelf.convertedData.bytes, bytesToRead);
        [weakSelf.convertedData replaceBytesInRange:NSMakeRange(0, bytesToRead) withBytes:NULL length:0];
    });

    return bytesToRead;
}

- (BOOL)isReadyForBuffering {
    if(self.isCancelled){
        return NO;
    }
    return (_convertedData.length <= 0.5*BUFFER_SIZE && !_inputUnit.isProcessing);
}

- (void)flushBuffer {
     __weak typeof (self) weakSelf = self;
    dispatch_sync(self.inputUnit.lock_queue, ^{
        weakSelf.convertedData = [NSMutableData data];
    });
}

#pragma mark - private

- (int)convert:(void *)dest amount:(int)amount {
    
    if(self.isCancelled){
        return 0;
    }
    
    AudioBufferList ioData;
    UInt32 ioNumberFrames;
    OSStatus err;

    ioNumberFrames = amount/_outputFormat.mBytesPerFrame;
    ioData.mBuffers[0].mData = dest;
    ioData.mBuffers[0].mDataByteSize = amount;
    ioData.mBuffers[0].mNumberChannels = _outputFormat.mChannelsPerFrame;
    ioData.mNumberBuffers = 1;

    err = AudioConverterFillComplexBuffer(_converter, ACInputProc, (__bridge void * _Nullable)(self), &ioNumberFrames, &ioData, NULL);
    int amountRead = ioData.mBuffers[0].mDataByteSize;
    if (err == kAudioConverterErr_InvalidInputSize)	{
        amountRead += [self convert:dest + amountRead amount:amount - amountRead];
    }
    if(self.outputUnit.didConvertSoundBlock){
        self.outputUnit.didConvertSoundBlock(self.outputUnit,ioNumberFrames,&ioData);
    }
    return amountRead;
}

static OSStatus ACInputProc(AudioConverterRef inAudioConverter,
                            UInt32* ioNumberDataPackets, AudioBufferList* ioData,
                            AudioStreamPacketDescription** outDataPacketDescription,
                            void* inUserData) {
    
    ORGMConverter *converter = (__bridge ORGMConverter *)inUserData;
    OSStatus err = noErr;
    
    if(converter.isCancelled){
        return errSecUserCanceled;
    }
    
    int amountToWrite;

    amountToWrite = [converter.inputUnit shiftBytes:(*ioNumberDataPackets)*(converter->_inputFormat.mBytesPerPacket)
                                             buffer:converter->_callbackBuffer];

    if (amountToWrite == 0) {
        ioData->mBuffers[0].mDataByteSize = 0;
        *ioNumberDataPackets = 0;

        return 100;
    }

    ioData->mBuffers[0].mData = converter->_callbackBuffer;
    ioData->mBuffers[0].mDataByteSize = amountToWrite;
    ioData->mBuffers[0].mNumberChannels = (converter->_inputFormat.mChannelsPerFrame);
    ioData->mNumberBuffers = 1;

    return err;
}

@end
