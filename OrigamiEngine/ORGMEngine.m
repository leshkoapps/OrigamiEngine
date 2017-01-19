 //
// ORGMEngine.m
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

#import "ORGMEngine.h"

#import "ORGMInputUnit.h"
#import "ORGMOutputUnit.h"
#import "ORGMConverter.h"
#import "ORGMCommonProtocols.h"

typedef NS_ENUM(NSUInteger, ORGMEngineBufferingSourceState) {
    ORGMEngineBufferingSourceStateUnknown = 0,
    ORGMEngineBufferingSourceStateDisabled,
    ORGMEngineBufferingSourceStateActive,
};



@interface ORGMEngine () <ORGMInputUnitDelegate,ORGMOutputUnitDelegate>{
    BOOL _cancelled;
    ORGMEngineBufferingSourceState _bufferingSourceHandlerState;
}

@property (strong, nonatomic) ORGMInputUnit *input;
@property (strong, nonatomic) ORGMOutputUnit *output;
@property (strong, nonatomic) ORGMConverter *converter;
@property (assign, nonatomic) ORGMEngineState currentState;
@property (strong, nonatomic) NSError *currentError;
@property (assign, nonatomic) float lastPreloadProgress;
@property (strong, nonatomic) NSURL *prevURL;
@property (strong, nonatomic) dispatch_queue_t callback_queue;
@property (strong, nonatomic) dispatch_queue_t processing_queue;
@property (strong, nonatomic) dispatch_source_t buffering_source;

@end

@implementation ORGMEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        self.callback_queue = dispatch_queue_create("com.origami.callback",DISPATCH_QUEUE_SERIAL);
        self.processing_queue = dispatch_queue_create("com.origami.processing",DISPATCH_QUEUE_SERIAL);
        self.buffering_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0, 0, self.processing_queue);
        dispatch_resume(self.buffering_source);
        self.volume = 100.0f;
        _bufferingSourceHandlerState = ORGMEngineBufferingSourceStateUnknown;
        [self clearBufferingSourceHandler];
        _currentState = ORGMEngineStateUnknown;
    }
    return self;
}

- (void)dealloc {
    _cancelled = YES;
    self.delegate = nil;
    [self _clearEngine];
    self.callback_queue = nil;
    self.processing_queue = nil;
    self.buffering_source = nil;
}

- (void)setCurrentState:(ORGMEngineState)currentState{
    if(_currentState!=currentState){
        _currentState = currentState;
        __weak typeof (self) weakSelf = self;
        dispatch_async(self.callback_queue, ^{
            if ([weakSelf.delegate respondsToSelector:@selector(engine:didChangeState:)]) {
                [weakSelf.delegate engine:weakSelf didChangeState:currentState];
            }
        });
    }
}

#pragma mark - public

- (void)playUrl:(NSURL *)url {
    [self playUrl:url withOutputUnitClass:[ORGMOutputUnit class]];
}

- (void)_playUrl:(NSURL *)url withOutputUnitClass:(Class)outputUnitClass {
    if(self.isCancelled){
        return;
    }
    NSAssert([outputUnitClass isSubclassOfClass:[ORGMOutputUnit class]], @"Output unit should be subclass of ORGMOutputUnit");
    [self _clearEngine];
    self.currentError = nil;
    ORGMInputUnit *input = [[ORGMInputUnit alloc] init];
    self.input = input;
    if (NO==[self.input openWithUrl:url]) {
        self.currentState = ORGMEngineStateError;
        self.currentError = [NSError errorWithDomain:kErrorDomain
                                                code:ORGMEngineErrorCodesSourceFailed
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                        NSLocalizedString(@"Couldn't open source", nil) }];
        return;
    }
    ORGMConverter *converter = [[ORGMConverter alloc] initWithInputUnit:self.input bufferingSource:self.buffering_source];
    self.converter = converter;
    ORGMOutputUnit *output = [[outputUnitClass alloc] initWithConverter:self.converter outputFormat:self.outputFormat];
    output.didChangeSampleRateBlock = self.outputUnitDidChangeSampleRateBlock;
    output.didConvertSoundBlock = self.outputUnitDidConvertSoundBlock;
    output.didRenderSoundBlock = self.outputUnitDidRenderSoundBlock;
    self.output = output;
    self.output.outputUnitDelegate = self;
    [self.output setVolume:self.volume];
    if (NO==[self.converter setupWithOutputUnit:self.output]) {
        self.currentState = ORGMEngineStateError;
        self.currentError = [NSError errorWithDomain:kErrorDomain
                                                code:ORGMEngineErrorCodesConverterFailed
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                        NSLocalizedString(@"Couldn't setup converter", nil) }];
        return;
    }
    [self didChangeCurrentURL:url prevURL:nil];
    [self setCurrentState:ORGMEngineStatePlaying];
    [self setBufferingSourceHandler];
    dispatch_source_merge_data(self.buffering_source, 1);
    self.input.inputUnitDelegate = self;
}

- (void)playUrl:(NSURL *)url withOutputUnitClass:(Class)outputUnitClass {
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _playUrl:url withOutputUnitClass:outputUnitClass];
    });
}

- (void)didChangeCurrentURL:(NSURL *)currentURL prevURL:(NSURL *)prevURL{
    __weak typeof (self) weakSelf = self;
    self.prevURL = prevURL;
    dispatch_async(self.callback_queue, ^{
        if([weakSelf.delegate respondsToSelector:@selector(engine:didChangeCurrentURL:prevItemURL:)]) {
            [weakSelf.delegate engine:weakSelf didChangeCurrentURL:currentURL prevItemURL:prevURL];
        }
    });
}

- (NSURL *)currentURL{
    return self.input.currentURL;
}

- (float)preloadProgress{
    return self.input.preloadProgress;
}

- (BOOL)isReadyToPlay{
    return self.output.isReadyToPlay;
}

- (void)_pause {
    if (self.currentState != ORGMEngineStatePlaying){
        return;
    }
    [self.output pause];
    [self setCurrentState:ORGMEngineStatePaused];
}

- (void)pause {
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _pause];
    });
}

- (void)_resume {
    if (self.currentState != ORGMEngineStatePaused){
        return;
    }
    [self.output resume];
    [self setCurrentState:ORGMEngineStatePlaying];
}

- (void)resume {
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _resume];
    });
}

- (void)_clearEngine{
    [self clearBufferingSourceHandler];
    self.input.inputUnitDelegate = nil;
    self.output.outputUnitDelegate = nil;
    [self.output stop];
    [self.output cancel];
    self.output.didRenderSoundBlock = nil;
    self.output.didConvertSoundBlock = nil;
    self.output.didChangeSampleRateBlock = nil;
    [self.converter cancel];
    [self.input cancel];
    self.input = nil;
    self.converter = nil;
    self.output = nil;
}

- (void)cancelAllAndClearEngine{
    _cancelled = YES;
    [self _clearEngine];
}

- (BOOL)isCancelled{
    return _cancelled;
}

- (void)stop {
    [self clearBufferingSourceHandler];
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _clearEngine];
        [weakSelf setCurrentState:ORGMEngineStateStopped];
    });
}

- (double)trackTime {
    return [self.output framesToSeconds:self.input.framesCount];
}

- (double)amountPlayed {
    return [self.output amountPlayed];
}

- (NSDictionary *)metadata {
    return [self.input metadata];
}

- (void)_seekToTime:(double)time withDataFlush:(BOOL)flush {
    [self.output seek:time];
    [self.input seek:time withDataFlush:flush];
    if (flush) {
        [self.converter flushBuffer];
    }
}

- (void)seekToTime:(double)time withDataFlush:(BOOL)flush completion:(void(^)(void))completion{
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _seekToTime:time withDataFlush:flush];
        if(completion){
            completion();
        }
    });
}

- (void)seekToTime:(double)time {
    [self seekToTime:time withDataFlush:NO completion:nil];
}

- (void)_setNextUrl:(NSURL *)url withDataFlush:(BOOL)flush {
    NSURL *prevURL = self.currentURL;
    if (!url) {
        [self stop];
    } else {
        if ([self.input openWithUrl:url]==NO) {
            self.currentState = ORGMEngineStateError;
            self.currentError = [NSError errorWithDomain:kErrorDomain
                                                    code:ORGMEngineErrorCodesSourceFailed
                                                userInfo:@{ NSLocalizedDescriptionKey:
                                                                NSLocalizedString(@"Couldn't open source", nil) }];
            [self stop];
        }
        else{
            [self.converter reinitWithNewInput:self.input withDataFlush:flush];
            [self.output seek:0.0]; //to reset amount played
            [self didChangeCurrentURL:url prevURL:prevURL];
            [self setCurrentState:ORGMEngineStatePlaying]; //trigger delegate method
            self.input.inputUnitDelegate = self;
        }
    }
}

- (void)setNextUrl:(NSURL *)url withDataFlush:(BOOL)flush {
    __weak typeof (self) weakSelf = self;
    dispatch_async(self.processing_queue, ^{
        [weakSelf _setNextUrl:url withDataFlush:flush];
    });
}

#pragma mark - private

- (void)clearBufferingSourceHandler{
    if(_bufferingSourceHandlerState!=ORGMEngineBufferingSourceStateDisabled){
        if(self.buffering_source!=NULL){
            dispatch_source_set_event_handler(self.buffering_source, ^{});
        }
        _bufferingSourceHandlerState=ORGMEngineBufferingSourceStateDisabled;
    }
}

- (ORGMEngineBufferingSourceState)bufferingSourceHandlerState{
    return _bufferingSourceHandlerState;
}

- (void)setBufferingSourceHandler{
    if(_bufferingSourceHandlerState!=ORGMEngineBufferingSourceStateActive){
        __weak typeof (self) weakSelf = self;
        dispatch_source_set_event_handler(self.buffering_source, ^{
            if(weakSelf==nil || weakSelf.isCancelled || weakSelf.bufferingSourceHandlerState!=ORGMEngineBufferingSourceStateActive){
                return;
            }
            if(weakSelf.input.isCancelled==NO){
                [weakSelf.input process];
            }
            if(weakSelf.converter.isCancelled==NO){
                [weakSelf.converter process];
            }
        });
        _bufferingSourceHandlerState=ORGMEngineBufferingSourceStateActive;
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    [self.output setVolume:volume];
}

- (void)inputUnit:(ORGMInputUnit *)unit didChangePreloadProgress:(float)progress{
    if(unit==self.input && (ABS(_lastPreloadProgress-progress)>0.05 || (fabs(progress - 1.0) < FLT_EPSILON) || (fabs(progress) < FLT_EPSILON))){
        _lastPreloadProgress = progress;
        __weak typeof (self) weakSelf = self;
        dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didChangePreloadProgress:)]){
                [weakSelf.delegate engine:weakSelf didChangePreloadProgress:progress];
            }
        });
    }
}

- (void)inputUnit:(ORGMInputUnit *)unit didFailWithError:(NSError *)error{
    if(unit==self.input){
        __weak typeof (self) weakSelf = self;
        dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didFailCurrentItemWithError:)]){
                [weakSelf.delegate engine:weakSelf didFailCurrentItemWithError:error];
            }
        });
    }
}

- (void)outputUnit:(ORGMOutputUnit *)unit didChangeReadyToPlay:(BOOL)readyToPlay{
    if(unit==self.output){
        __weak typeof (self) weakSelf = self;
        dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didChangeReadyToPlay:)]){
                [weakSelf.delegate engine:weakSelf didChangeReadyToPlay:readyToPlay];
            }
        });
        if(unit.converter.inputUnit.endOfInput){
            NSURL *currentURL = self.currentURL;
            [self didChangeCurrentURL:nil prevURL:currentURL];
            [self stop];
        }
    }
}

- (void)inputUnitDidEndOfInput:(ORGMInputUnit *)unit{
    unit.inputUnitDelegate = nil;
    if(self.isCancelled || _bufferingSourceHandlerState!=ORGMEngineBufferingSourceStateActive){
        return;
    }
    if (unit!=nil && self.input!=nil && unit==self.input) {
        NSURL *nextUrl = nil;
        if([self.delegate respondsToSelector:@selector(engineExpectsNextUrl:)]){
            nextUrl = [self.delegate engineExpectsNextUrl:self];
        }
        if (nextUrl!=nil) {
            [self setNextUrl:nextUrl withDataFlush:NO];
        }
    }
}

@end
