//
// FileSource.m
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

#import "FileSource.h"

@interface FileSource () {
    FILE *_fd;
}

@property (strong, nonatomic) NSURL *url;
@property (strong, nonatomic) dispatch_queue_t callback_queue;

@end

@implementation FileSource

@synthesize sourceDelegate;


- (instancetype)init{
    self = [super init];
    if(self){
       self.callback_queue = dispatch_queue_create("com.origami.file.source.callback",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
	[self close];
}

#pragma mark - ORGMSource
+ (NSString *)scheme {
    return @"file";
}

- (NSURL *)url {
	return _url;
}

- (NSString *)pathExtension{
    return self.url.pathExtension;
}

- (long)size {
    @synchronized(self){
        if(_fd!=NULL){
            long curpos = ftell(_fd);
            fseek (_fd, 0, SEEK_END);
            long size = ftell(_fd);
            fseek(_fd, curpos, SEEK_SET);
            return size;
        }
    }
    return 0;
}

- (BOOL)open:(NSURL *)url {
    @synchronized(self){
        [self setUrl:url];
        _fd = fopen([[url path] UTF8String], "r");
        BOOL success = (_fd != NULL);
        __weak typeof (self) weakSelf = self;
        dispatch_async(self.callback_queue, ^{
            if(success){
                if([weakSelf.sourceDelegate respondsToSelector:@selector(sourceDidReceiveData:)]){
                    [weakSelf.sourceDelegate sourceDidReceiveData:weakSelf];
                }
            }
            else{
                NSError *error = [[NSError alloc] initWithDomain:@"FileSourceErrorDomain" code:-1 userInfo:nil];
                if([weakSelf.sourceDelegate respondsToSelector:@selector(source:didFailWithError:)]){
                    [weakSelf.sourceDelegate source:weakSelf didFailWithError:error];
                }
            }
        });
        return success;
    }
}

- (BOOL)seekable {
	return YES;
}

- (BOOL)isRemoteSource {
    return NO;
}

- (BOOL)seek:(long)position whence:(int)whence {
    @synchronized(self){
        if(_fd!=NULL){
            return (fseek(_fd, position, whence) == 0);
        }
        return NO;
    }
}

- (long)tell {
    @synchronized(self){
        if(_fd!=NULL){
            return ftell(_fd);
        }
        return 0;
    }
}

- (long)preloadSize{
    return [self size];
}

- (int)read:(void *)buffer amount:(int)amount {
    @synchronized(self){
        if(_fd!=NULL){
            return (int)fread(buffer, 1, amount, _fd);
        }
        return 0;
    }
}

- (void)close {
    @synchronized(self){
        if (_fd) {
            fclose(_fd);
            _fd = NULL;
        }
    }
}

#pragma mark - private

@end
