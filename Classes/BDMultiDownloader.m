//
//  BDMutliDownloader.m
//
//
//  Created by Norsez Orankijanan on 5/19/12.
//
//  Copyright (c) 2012, Norsez Orankijanan (Bluedot) All Rights Reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice, 
//  this list of conditions and the following disclaimer.
//
//  2. Redistributions in binary form must reproduce the above copyright notice, 
//  this list of conditions and the following disclaimer in the documentation 
//  and/or other materials provided with the distribution.
//
//  3. Neither the name of Bluedot nor the names of its contributors may be used 
//  to endorse or promote products derived from this software without specific
//  prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
//  POSSIBILITY OF SUCH DAMAGE.

#import "BDMultiDownloader.h"

#define kIntervalDefaultTimeout 60
#define kMaxNumberOfThreads 25
#define kMaxCache 10 * 1024 * 1000
NSString* const BDMultiDownloaderMethodPOST = @"POST";

@interface BDURLConnection : NSURLConnection{
    void(^_completion)(NSData*);
}
@property (nonatomic, copy) void(^completionWithDownloadedData)(NSData*);
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) long long expectedLength;
@property (nonatomic, strong) NSString *MIMEType;
@property (nonatomic, strong) NSString *suggestedFilename;
- (id)copyWithZone:(NSZone*)zone;
@end

@implementation BDURLConnection
- (id)copyWithZone:(NSZone *)zone
{
    return self;
}
@synthesize completionWithDownloadedData;
@synthesize MIMEType;
@synthesize expectedLength;
@synthesize progress;
@synthesize suggestedFilename;
@end


@interface BDMultiDownloader ()
{
    NSMutableArray *_currentConnections;
    NSMutableDictionary *_currentConnectionsData;
    NSMutableArray *_loadingQueue;
    NSMutableDictionary *_requestCompletions;
    NSCache *_dataCache;
}

- (void) launchNextConnection;
- (NSUInteger) numberOfItemsInQueue;
- (NSString*) keyForRequest:(NSURLRequest*)request;
@end

@implementation BDMultiDownloader


- (void)queueRequest:(NSString *)urlPath completion:(void (^)(NSData *))completionWithDownloadedData
{
    if(!urlPath){
        ////DLog(@"url is nil. Abort.");
        return;
    }
    
    NSURL *url = [NSURL URLWithString:urlPath];
    NSURLRequest *request = nil;
    NSURLRequestCachePolicy cachePolicy = self.urlCacheStoragePolicy;
    NSTimeInterval timeout = self.connectionTimeout;
    if (self.httpHeaders) {
        NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:cachePolicy timeoutInterval:timeout];
        for (NSString *key in self.httpHeaders) {
            [r addValue:[self.httpHeaders valueForKey:key] forHTTPHeaderField:key];
        }
        request = r;
    }else{
        request = [NSURLRequest requestWithURL:url cachePolicy:cachePolicy timeoutInterval:timeout];
    }
    
    if (request){
        [_loadingQueue addObject:request];
        [_requestCompletions setObject:[completionWithDownloadedData copy] forKey:[self keyForRequest:request]];
        [self launchNextConnection];        
    }
}

- (void)queueURLRequest:(NSURLRequest *)urlRequest completion:(void (^)(NSData *))completionWithDownloadedData
{
    [_loadingQueue addObject:[urlRequest copy] ];
    [_requestCompletions setObject:[completionWithDownloadedData copy] forKey:[self keyForRequest:urlRequest]];
    [self launchNextConnection];
}

- (void)jsonWithRequest:(NSURLRequest *)jsonRequest options:(NSJSONWritingOptions)options 
             completion:(void (^)(id))completionWithJSONObject
{
    [self queueURLRequest:jsonRequest
               completion:^(NSData *data) {
                   if (data == nil) {
                       completionWithJSONObject(nil);
                       return;
                   }
                   
                   NSError *error = nil;
                   id jsonObject  = [NSJSONSerialization JSONObjectWithData:data
                                                                    options:options error:&error];
                   if (error) {
                       if (onNetworkError) {
                           onNetworkError(error);
                           completionWithJSONObject(nil);
                           return;
                       }
                   }
                   
                   completionWithJSONObject(jsonObject);
                   
               }];
}

- (void)imageWithPath:(NSString *)urlPath completion:(void (^)(UIImage *, BOOL))completionWithImageYesIfFromCache
{
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlPath]];
    NSData *data = [_dataCache objectForKey:[self keyForRequest:request]];
    if  (data.length > 0){
        UIImage *image = [UIImage imageWithData:data];
        completionWithImageYesIfFromCache(image, YES);
    }else {
        [self queueRequest:urlPath completion:^(NSData *data) {
            UIImage *image = [UIImage imageWithData:data];
            completionWithImageYesIfFromCache(image, NO);
        }];
    }
}

- (void)dequeueWithPath:(NSString *)path
{
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:path]];
    NSString *key = [self keyForRequest:request];
    NSArray * searchResults = [_currentConnections filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        BDURLConnection *aConn = evaluatedObject;
        return [[self keyForRequest:aConn.originalRequest] isEqualToString:key];
    }]];
    
    if (searchResults.count > 0) {
        BDURLConnection *connection = [searchResults objectAtIndex:0];    
        [connection cancel];
        [_loadingQueue removeObject:connection.originalRequest];
        [_currentConnectionsData removeObjectForKey:connection];
        [_requestCompletions removeObjectForKey:connection];
    }    
}

- (void)clearQueue
{
    
    //DLog(@"clear queue.");
    for (NSURLConnection *conn in _currentConnections) {
        
        if (self.onNetworkActivity) {
            self.onNetworkActivity(NO);
        }
        
        [conn cancel];
    }
    [_currentConnections removeAllObjects];
    [_loadingQueue removeAllObjects];
    [_requestCompletions removeAllObjects];
    [_currentConnectionsData removeAllObjects];
}

- (NSUInteger)numberOfItemsInQueue
{
    return _loadingQueue.count;
}

- (NSString*) keyForRequest:(NSURLRequest*)request
{
    if ([[request.HTTPMethod uppercaseString] isEqualToString:BDMultiDownloaderMethodPOST]) {
        return [NSString stringWithFormat:@"%@%@%@",request.URL.absoluteString, request.HTTPMethod, request.HTTPBody];
    }
    return request.URL.absoluteString;
}

- (void)launchNextConnection
{
    if (_currentConnections.count >= self.maximumNumberOfThreads) {
        ////DLog(@"Threads at Max. Abort.");
        return;
    }
    
    if (self.numberOfItemsInQueue==0) {
        ////DLog(@"Nothing in queue.");
        return;
    }
    
    NSURLRequest *request = [_loadingQueue objectAtIndex:0];
    [_loadingQueue removeObjectAtIndex:0];
    
    NSString *requestKey = [self keyForRequest:request];
    NSData *dataInCache = [_dataCache objectForKey:requestKey];
    if (dataInCache) {
        void (^completion)(NSData*) = [_requestCompletions objectForKey:requestKey];
        [_requestCompletions removeObjectForKey:requestKey];
        if (completion) {
            completion(dataInCache);
        }
        return;
    }
    
    BDURLConnection *conn = [[BDURLConnection alloc] initWithRequest:request delegate:self];
    conn.suggestedFilename = request.URL.lastPathComponent;
    [_currentConnections addObject:conn];
    
    void (^completion)(NSData*) = [_requestCompletions objectForKey:[self keyForRequest:request]];
    [conn setCompletionWithDownloadedData:completion];
    [conn start];
    if (self.onNetworkActivity) {
        self.onNetworkActivity(YES);
    }
}

- (NSUInteger)cacheSizeLimit{
    return _dataCache.totalCostLimit;
}

- (void)setCacheSizeLimit:(NSUInteger)cacheSizeLimit
{
    [_dataCache setCountLimit:cacheSizeLimit];
}

#pragma mark - connection delegate
-(void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response{
    NSMutableData *data = [[NSMutableData alloc] init];
    [_currentConnectionsData setObject:data forKey:connection];
    
    BDURLConnection *conn = (BDURLConnection*) connection;
    [conn setMIMEType:response.MIMEType];
    [conn setExpectedLength:response.expectedContentLength];
    [conn setProgress:0.0];
    
    if (self.onDownloadProgressWithProgressAndSuggestedFilename) {
        self.onDownloadProgressWithProgressAndSuggestedFilename(conn.progress, conn.suggestedFilename);
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSMutableData *_data = (NSMutableData*)[_currentConnectionsData objectForKey:connection];
    [_data appendData:data];
    BDURLConnection *conn = (BDURLConnection*) connection;
    [conn setProgress:_data.length/(double) conn.expectedLength ];
    if (self.onDownloadProgressWithProgressAndSuggestedFilename) {
        self.onDownloadProgressWithProgressAndSuggestedFilename(conn.progress, conn.suggestedFilename);
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    if (self.onNetworkActivity) {
        self.onNetworkActivity(NO);
    }
    
    [_currentConnections removeObject:connection];
    NSData *data = [_currentConnectionsData objectForKey:connection];
    BDURLConnection *conn = (BDURLConnection*) connection;
    if (data.length > 0){
        [_dataCache setObject:data forKey:[self keyForRequest:conn.originalRequest] cost:data.length];
    }
    [_currentConnectionsData removeObjectForKey:connection];
    [_loadingQueue removeObject:[self keyForRequest:connection.originalRequest]];
    void(^completion)(NSData*) = [(BDURLConnection*)connection completionWithDownloadedData];

    if (completion) {
        if (self.completionQueue) {
            dispatch_async(self.completionQueue, ^{
                completion(data);
            });
        }else {
            completion(data);
        }

    }    
    
    [self launchNextConnection];
}

-(void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error{
    
    if (self.onNetworkActivity){
        self.onNetworkActivity(NO);
    }
    
    [_currentConnections removeObject:connection];
    [_currentConnectionsData removeObjectForKey:connection];
    [_loadingQueue removeObject:connection.originalRequest];
    
    if ([error.domain isEqualToString:NSURLErrorDomain] ) {
        [self clearQueue];
        if (self.onNetworkError) {
            self.onNetworkError(error);
        }
    }
    
    [self launchNextConnection];
    
}

- (id)init
{
    self = [super init];
    if (self) {
        self.maximumNumberOfThreads = kMaxNumberOfThreads;
        self.urlCacheStoragePolicy = NSURLCacheStorageAllowedInMemoryOnly;
        _currentConnections = [[NSMutableArray alloc] init];
        _currentConnectionsData = [[NSMutableDictionary alloc] init];
        _loadingQueue = [[NSMutableArray alloc] init];
        _requestCompletions = [[NSMutableDictionary alloc] init];
        _dataCache = [[NSCache alloc] init];
        self.completionQueue = NULL;
        [_dataCache setName:@"data cache"];
        [_dataCache setCountLimit:kMaxCache];
        self.connectionTimeout = kIntervalDefaultTimeout;
    }
    return self;
}


+ (BDMultiDownloader *)shared
{
    static dispatch_once_t once;
    static BDMultiDownloader * singleton;
    dispatch_once(&once, ^ { singleton = [[BDMultiDownloader alloc] init]; });
    return singleton;
}

@synthesize onNetworkActivity;
@synthesize onDownloadProgressWithProgressAndSuggestedFilename;
@synthesize onNetworkError;

@synthesize maximumNumberOfThreads;
@synthesize httpHeaders;
@synthesize cacheSizeLimit=_cacheSizeLimit;
@synthesize connectionTimeout;

@synthesize completionQueue;
@synthesize urlCacheStoragePolicy;
@end
