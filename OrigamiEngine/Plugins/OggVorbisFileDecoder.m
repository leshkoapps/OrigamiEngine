//
//  OggVorbisFileDecoder.m
//  OrigamiEngine
//
//  Created by Artem Meleshko on 8/23/17.
//
//

#import "OggVorbisFileDecoder.h"
#import <Vorbis/vorbisfile.h>

#define OGG_BITS_PER_BYTE 8
#define OGG_BYTES_TO_BITS(bytes) ((bytes) * OGG_BITS_PER_BYTE)
#define OGG_VORBIS_WORDSIZE 2

@interface OggVorbisFileDecoder (){
   OggVorbis_File mOggVorbisFile;
   Float64 mRate;
   UInt32 mChannels;
   UInt32 mBitsPerSample;
   int64_t mTotalFrames;
   BOOL mSeekable;
}

@property (strong, atomic) NSMutableDictionary *decoderMetadata;
@property (strong, nonatomic) id<ORGMSource> source;

@end

@implementation OggVorbisFileDecoder


- (BOOL)open:(id<ORGMSource>)s {
    [self setSource:s];
    self.decoderMetadata = [NSMutableDictionary dictionary];
    
    ov_callbacks callbacks = {
        ReadCallback,
        SeekCallback,
        NULL,
        TellCallback
    };

    int result = ov_open_callbacks((__bridge void *)(self.source), &mOggVorbisFile, NULL, 0, callbacks);
    @try {NSAssert(result >= 0, @"ov_open_callbacks succeeded.");} @catch (NSException *exception) {}
    if (result<0) {
        return NO;
    }
    
    vorbis_info* pInfo = ov_info(&mOggVorbisFile, -1);
    @try { NSAssert(pInfo!=NULL, @"ov_info succeeded.");} @catch (NSException *exception) {}
    if (pInfo==NULL) {
        return NO;
    }
    
    int bytesPerChannel = OGG_VORBIS_WORDSIZE;
    
    mSeekable = (ov_seekable(&mOggVorbisFile)>0);
    mTotalFrames = ov_raw_total(&mOggVorbisFile, -1);
    mRate = (Float64)pInfo->rate; // sample rate (fps)
    mChannels = (UInt32)pInfo->channels;// channels per frame
    mBitsPerSample = (UInt32)OGG_BYTES_TO_BITS(bytesPerChannel);// bits per channel
    
    [self parseMetadata];
    
    return YES;
}

- (void)dealloc {
    [self close];
}

+ (NSArray *)fileTypes {
    return [NSArray arrayWithObjects:@"ogg", nil];
}

- (NSDictionary *)properties {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:mChannels], @"channels",
            [NSNumber numberWithInt:mBitsPerSample], @"bitsPerSample",
            [NSNumber numberWithFloat:mRate], @"sampleRate",
            [NSNumber numberWithDouble:mTotalFrames], @"totalFrames",
            [NSNumber numberWithBool:mSeekable], @"seekable",
            @"little", @"endian",
            nil];
}

- (NSDictionary *)metadata {
    return self.decoderMetadata;
}

- (int)readAudio:(void *)buffer frames:(UInt32)frames {

    UInt32 mDataByteSize = frames * mChannels * (mBitsPerSample/8);
    
    int bigEndian = 0;
    int wordSize = OGG_VORBIS_WORDSIZE;
    int signedSamples = 1;
    int currentSection = -1;
    
    //See: http://xiph.org/vorbis/doc/vorbisfile/ov_read.html
    UInt32 nTotalBytesRead = 0;
    long nBytesRead = 0;
    const UInt32 kMaxChunkSize = 4096;
    while(nTotalBytesRead < mDataByteSize){
        nBytesRead = ov_read(&mOggVorbisFile,
                             buffer+nTotalBytesRead,
                             MIN(kMaxChunkSize,mDataByteSize-nTotalBytesRead),
                             bigEndian, wordSize,
                             signedSamples, &currentSection);
        if(nBytesRead  <= 0)
            break;
        nTotalBytesRead += nBytesRead;
    }
    int samples = nTotalBytesRead/(mChannels*(mBitsPerSample/8));
    if (samples < 0){
        samples = 0;
    }
    return samples;
}

- (long)seek:(long)sample {
    //Possible errors are OV_ENOSEEK, OV_EINVAL, OV_EREAD, OV_EFAULT, OV_EBADLINK
    //http://xiph.org/vorbis/doc/vorbisfile/ov_time_seek.html
    long result = ov_raw_seek(&mOggVorbisFile, sample);
    return result;
}

- (void)close {
    [self.source close];
    ov_clear(&mOggVorbisFile);
}

#pragma mark - private

- (void)parseMetadata {
    @try {
        char **ptr=ov_comment(&mOggVorbisFile,-1)->user_comments;
        while(*ptr){
            const char *comment = *ptr;
            NSString *commentValue = [NSString stringWithUTF8String:comment];
            if(commentValue!=nil){
                NSRange range = [commentValue rangeOfString:@"="];
                if(range.location!=NSNotFound){
                    NSString *key = [commentValue substringWithRange:NSMakeRange(0, range.location)];
                    NSString *value = [commentValue substringWithRange:
                                       NSMakeRange(range.location + 1, commentValue.length - range.location - 1)];
                    if (value!=nil && key!=nil){
                        [self.decoderMetadata setObject:value forKey:[key lowercaseString]];
                    }
                }
            }
            ++ptr;
        }
    } @catch (NSException *exception) {}
}

#pragma mark - callback

static size_t ReadCallback(void *ptr, size_t size, size_t nmemb, void *datasource) {
    id<ORGMSource> source = (__bridge id<ORGMSource>)(datasource);
    int result = [source read:ptr amount:(int)nmemb];
    return result;
}

static int SeekCallback(void *datasource, ogg_int64_t offset, int whence) {
    id<ORGMSource> source = (__bridge id<ORGMSource>)(datasource);
    return [source seek:(long)offset whence:whence] ? 0 : -1;
}

static long TellCallback(void *datasource) {
    id<ORGMSource> source = (__bridge id<ORGMSource>)(datasource);
    return [source tell];
}

@end
