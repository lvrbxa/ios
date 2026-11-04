//
//  Connection.m
//  OwnTracks
//
//  Created by Christoph Krey on 25.08.13.
//  Copyright © 2013-2026  Christoph Krey. All rights reserved.
//

#import "Connection.h"

#import "CoreData.h"
#import "Queue+CoreDataClass.h"

#import <UIKit/UIKit.h>
#import "OwnTracksLog.h"
#import "LocationManager.h"
#import "Settings.h"
#import "OwnTracksAppDelegate.h"
#import "Validation.h"

#import "OwnTracks-Swift.h"


@interface Connection() <NSURLSessionDelegate>

@property (nonatomic) NSInteger state;

@property (strong, nonatomic) NSTimer *reconnectTimer;
@property (strong, nonatomic) NSTimer *idleTimer;
@property (nonatomic) double reconnectTime;
@property (nonatomic) BOOL reconnectFlag;


@property (strong, nonatomic) NSString *url;
@property (strong, nonatomic) NSMutableArray <NSDictionary <NSString *, NSString *> *> *httpHeaders;

@property (strong, nonatomic) NSString *host;
@property (nonatomic) UInt32 port;
@property (nonatomic) BOOL ws;
@property (nonatomic) BOOL tls;
@property (nonatomic) MQTTProtocolVersion protocolVersion;
@property (nonatomic) NSInteger keepalive;
@property (nonatomic) BOOL clean;
@property (nonatomic) BOOL auth;
@property (strong, nonatomic) NSString *user;
@property (strong, nonatomic) NSString *pass;
@property (strong, nonatomic) NSString *willTopic;
@property (strong, nonatomic) NSData *will;
@property (nonatomic) NSInteger willQos;
@property (nonatomic) BOOL willRetainFlag;
@property (strong, nonatomic) NSString *clientId;
@property (strong, nonatomic) NSString *device;
@property (nonatomic) BOOL allowUntrustedCertificates;
@property (strong, nonatomic) NSArray *certificates;

@property (nonatomic, readwrite) NSError *lastErrorCode;

@property (nonatomic) NSUInteger outCount;
@property (nonatomic) NSUInteger inCount;

@property (strong, nonatomic) NSURLSession *urlSession;

@property (nonatomic) BOOL intendedDisconnect;

@end

#define RECONNECT_TIMER 1.0
#define RECONNECT_TIMER_MAX 64.0

@implementation Connection

- (instancetype)init {
    self = [super init];
    OwnTracksLogDebug("[Connection] Connection init");
    
    self.state = state_starting;
    self.subscriptions = [[NSArray alloc] init];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note){
        OwnTracksLogDebug("[Connection] UIApplicationWillTerminateNotification");
        self.terminate = true;
    }];
    return self;
}

- (void)main {
    OwnTracksLogDebug("[Connection] main");
    // if there is no timer running, runUntilDate: does return immediately!?
    self.idleTimer = [NSTimer timerWithTimeInterval:60
                                             target:self
                                           selector:@selector(idle)
                                           userInfo:nil
                                            repeats:TRUE];
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    [runLoop addTimer:self.idleTimer forMode:NSDefaultRunLoopMode];
    
    while (!self.terminate) {
        OwnTracksLogDebug("[Connection] main %@", [NSDate date]);
        if (self.url) {
            __block NSTimeInterval runUntilDate = 1.0;
            [CoreData.sharedInstance.queuedMOC performBlockAndWait:^{
                NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Queue"];
                request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:YES]];
                
                NSError *error = nil;
                NSArray *matches = [CoreData.sharedInstance.queuedMOC executeFetchRequest:request error:&error];
                if (matches) {
                    [self.delegate totalBuffered: self count:matches.count];
                    if (matches.count) {
                        Queue *queue = matches.firstObject;
                        
                        if (self.state == state_starting) {
                            [self sendHTTP:queue.topic data:queue.data];
                            runUntilDate = 0.1;
                        }

                        if (matches.count > 100 * 1024) {
                            queue = matches.lastObject;
                            [CoreData.sharedInstance.queuedMOC deleteObject:queue];
                            [CoreData.sharedInstance sync:CoreData.sharedInstance.queuedMOC];
                        }
                    }
                }
            }];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:runUntilDate]];
        } else {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        }
    }
    
    [self.idleTimer invalidate];
}

- (void)idle {
    OwnTracksLogDebug("[Connection] idle");
}

- (void)connectTo:(NSString *)host
             port:(UInt32)port
               ws:(BOOL)ws
              tls:(BOOL)tls
  protocolVersion:(MQTTProtocolVersion)protocolVersion
        keepalive:(NSInteger)keepalive
            clean:(BOOL)clean
            force:(BOOL)force
             auth:(BOOL)auth
             user:(NSString *)user
             pass:(NSString *)pass
        willTopic:(NSString *)willTopic
             will:(NSData *)will
          willQos:(NSInteger)willQos
   willRetainFlag:(BOOL)willRetainFlag
     withClientId:(NSString *)clientId
allowUntrustedCertificates:(BOOL)allowUntrustedCertificates
     certificates:(NSArray *)certificates {
    // 改造版: MQTTは外した。HTTPだけで送る
    OwnTracksLogDefault("[Connection] connectTo ignored (MQTT removed)");
    self.url = nil;
    self.port = 0;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)redirectResponse
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSMutableURLRequest *newRequest = request.mutableCopy;
    if (redirectResponse) {
        newRequest = nil;
    }

    completionHandler(newRequest);
}


- (void)connectHTTP:(NSString *)url
               auth:(BOOL)auth
               user:(NSString *)user
               pass:(NSString *)pass
             device:(NSString *)device
        httpHeaders:(NSString * _Nullable)httpHeaders{
    self.url = url;
    self.auth = auth;
    self.user = user;
    self.pass = pass;
    self.device = device;
    self.httpHeaders = [[NSMutableArray alloc] init];
    NSArray <NSString *> *httpHeaderLines = [httpHeaders componentsSeparatedByString:@"\\n"];
    for (NSString *httpHeaderLine in httpHeaderLines) {
        NSRange range = [httpHeaderLine rangeOfString:@":"];
        if (range.location != NSNotFound) {
            NSString *key = [[httpHeaderLine substringToIndex:range.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString * value = [[httpHeaderLine substringFromIndex:range.location + range.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [self.httpHeaders addObject:@{@"key": key, @"value": value}];
        }
    }
    self.reconnectTime = RECONNECT_TIMER;
    self.reconnectFlag = FALSE;
    self.state = state_starting;
    [self connectToInternal];

#if 1
    NSURLSessionConfiguration *usc = NSURLSessionConfiguration.defaultSessionConfiguration;
    self.urlSession = [NSURLSession sessionWithConfiguration:usc
                                                    delegate:self
                                               delegateQueue:nil];
#else
    self.urlSession = NSURLSession.sharedSession;
#endif
}

- (UInt16)sendData:(NSData *)data
             topic:(NSString *)topic
        topicAlias:(NSNumber *)topicAlias
               qos:(MQTTQosLevel)qos
            retain:(BOOL)retainFlag {
    OwnTracksLogDefault("[Connection] sendData(%ld):%@ %@ q%d r%d",
              data.length,
              topic,
              [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding],
              qos,
              retainFlag);

    if (self.url) {
        [CoreData.sharedInstance.queuedMOC performBlock:^{
            Queue *queue = [NSEntityDescription insertNewObjectForEntityForName:@"Queue"
                                                         inManagedObjectContext:CoreData.sharedInstance.queuedMOC];

            NSData *outgoingData = data;
            if (outgoingData) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:outgoingData options:0 error:nil];
                if (json && [json isKindOfClass:[NSDictionary class]] && self.url) {
                    NSMutableDictionary *mutableJson = [json mutableCopy];
                    mutableJson[@"topic"] = topic;
                    outgoingData = [NSJSONSerialization dataWithJSONObject:mutableJson options:0 error:nil];
                }
            }
            if (self.key && self.key.length) {
                outgoingData = [self encrypt:outgoingData];
            }

            queue.timestamp = [NSDate date];
            queue.topic = topic;
            queue.data = outgoingData;
            
            [CoreData.sharedInstance sync:CoreData.sharedInstance.queuedMOC];
        }];
        
        return 0;
    } else {
        return 0;
    }
}

- (void)HTTPerror:(NSString *)message {
    [NavigationController alertWithTitle:@"HTTP" message:message];
}

- (void)sendHTTP:(NSString *)topic data:(NSData *)data {
    NSString *postLength = [NSString stringWithFormat:@"%ld",(unsigned long)data.length];
    OwnTracksLogDebug("[Connection] sendtHTTP %@(%@):%@",
                 topic, postLength, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    
    // auth
    if (self.auth) {
        NSString *authString = [NSString stringWithFormat:@"%@:%@",
                                self.user ? self.user : @"",
                                self.pass ? self.pass : @""];
        NSData *authData = [authString dataUsingEncoding:NSASCIIStringEncoding];
        NSString *authValue = [authData base64EncodedStringWithOptions:0];
        [request setValue:[NSString stringWithFormat:@"Basic %@", authValue] forHTTPHeaderField:@"Authorization"];
    }
    NSString *user = @"user";
    if (self.user && self.user.length > 0) {
        user = self.user;
    }
    [request setValue:user forHTTPHeaderField:@"X-Limit-U"];

    NSString *device = @"device";
    if (self.device && self.device.length > 0) {
        device = self.device;
    }
    [request setValue:device forHTTPHeaderField:@"X-Limit-D"];
    
    for (NSDictionary *httpHeader in self.httpHeaders) {
        NSString *key = [httpHeader objectForKey:@"key"];
        NSString *value = [httpHeader objectForKey:@"value"];
        if (key && [key isKindOfClass:[NSString class]] &&
            value && [value isKindOfClass:[NSString class]]) {
            [request setValue:value forHTTPHeaderField:key];
        }
    }

    request.URL = [NSURL URLWithString:self.url];
    request.HTTPMethod = @"POST";
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    request.HTTPBody = data;
    
    NSString *contentType = [NSString stringWithFormat:@"application/json"];
    [request setValue:contentType forHTTPHeaderField: @"Content-Type"];
    
    OwnTracksLogDebug("[Connection] NSMutableURLRequest %@://%@%@%@%@ (%@)",
              request.URL.scheme,
              request.URL.user ? request.URL.password ?
              [NSString stringWithFormat:@"%@:<password>@", request.URL.user] :
              [NSString stringWithFormat:@"%@@", request.URL.user] :
              @"",
              request.URL.host,
              request.URL.port ? [NSString stringWithFormat:@":%@", request.URL.port] : @"",
              request.URL.path,
              request.allHTTPHeaderFields
              );
    
    self.state = state_connecting;
    self.lastErrorCode = nil;

    __block NSRunLoop *myRunLoop = [NSRunLoop currentRunLoop];

    NSURLSessionDataTask *dataTask =
    [self.urlSession dataTaskWithRequest:request completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {

        OwnTracksLogDebug("[Connection] dataTaskWithRequest %@ %@ %@", data, response, error);
         if (!error) {
             
             if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                 NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                 OwnTracksLogDebug("[Connection] NSHTTPURLResponse %@", httpResponse);
                 if (httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299) {
                     self.state = state_connected;
                     
                     [CoreData.sharedInstance.queuedMOC performBlock:^{
                         NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Queue"];
                         request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:YES]];
                         
                         NSArray *matches = [CoreData.sharedInstance.queuedMOC executeFetchRequest:request error:nil];
                         if (matches) {
                             [self.delegate totalBuffered: self count:matches.count];
                             if (matches.count) {
                                 Queue *queue = matches.firstObject;
                                 [CoreData.sharedInstance.queuedMOC deleteObject:queue];
                                 [CoreData.sharedInstance sync:CoreData.sharedInstance.queuedMOC];
                             }
                         }
                         
                         NSData *incomingData = data;
                         OwnTracksLogDebug("[Connection] HTTP %ld incomingData(%lu): %@",
                                           (long)httpResponse.statusCode,
                                           (unsigned long)incomingData.length,
                                           [[NSString alloc] initWithData:incomingData encoding:NSUTF8StringEncoding]);
                         if (self.key && self.key.length) {
                             incomingData = [self decrypt:incomingData];
                         }

                         if (incomingData) {
                             id json = [[Validation sharedInstance] validateMessagesData:incomingData];
                             if (json && [json isKindOfClass:[NSArray class]]) {
                                 for (id element in json) {
                                     if ([element isKindOfClass:[NSDictionary class]]) {
                                         [self oneMessage:element];
                                     }
                                 }
                             } else if ([json isKindOfClass:[NSDictionary class]]) {
                                 [self oneMessage:json];
                             } else {
                                 //
                             }
                         } else {
                             //
                         }
                         
                         self.state = state_starting;
                         return;
                     }];
                 } else {
                     self.lastErrorCode = [NSError errorWithDomain:@"HTTP Response"
                                                              code:httpResponse.statusCode userInfo:nil];
                     self.state = state_error;
                     OwnTracksLogDefault("[Connection] %@", self.lastErrorCode);

                     if (httpResponse.statusCode >= 400 && httpResponse.statusCode <= 499) {
                         NSString *message = [NSString stringWithFormat:@"Status Code %ld\n%@",
                                              (long)httpResponse.statusCode,
                                              [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding]
                                              ];

                         [self performSelectorOnMainThread:@selector(HTTPerror:)
                                                withObject:message
                                             waitUntilDone:FALSE];
                         [CoreData.sharedInstance.queuedMOC performBlock:^{
                             NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Queue"];
                             request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:YES]];

                             NSArray *matches = [CoreData.sharedInstance.queuedMOC executeFetchRequest:request error:nil];
                             if (matches) {
                                 [self.delegate totalBuffered: self count:matches.count];
                                 if (matches.count) {
                                     Queue *queue = matches.firstObject;
                                     [CoreData.sharedInstance.queuedMOC deleteObject:queue];
                                     [CoreData.sharedInstance sync:CoreData.sharedInstance.queuedMOC];
                                 }
                             }

                             return;
                         }];
                     }
                     [self startReconnectTimer:myRunLoop];
                 }
             } else {
                 self.lastErrorCode = [NSError errorWithDomain:@"HTTP Response"
                                                          code:0 userInfo:nil];
                 self.state = state_error;
                 [self startReconnectTimer:myRunLoop];
             }
         } else {
             self.lastErrorCode = error;
             self.state = state_error;
             [self startReconnectTimer:myRunLoop];
         }
     }];
    [dataTask resume];
}

- (void)oneMessage:(NSDictionary *)message {
    OwnTracksLogDebug("[Connection] oneMessage %@", message.description);

    if (message && [message isKindOfClass:[NSDictionary class]]) {
        NSString *topic = @"owntracks/http/??";
        NSString *type = message[@"_type"];
        if (type && [type isEqualToString:@"cmd"]) {
            topic = [Settings theGeneralTopicInMOC:CoreData.sharedInstance.queuedMOC];
        } else {
            if (message[@"tid"]) {
                topic = [NSString stringWithFormat:@"owntracks/http/%@", message[@"tid"]];
            }
        }
        OwnTracksLogDebug("[Connection] oneMessage topic %@", topic);
        
        [self.delegate handleMessage:self
                                data:[NSJSONSerialization dataWithJSONObject:message options:0 error:nil]
                             onTopic:topic
                            retained:FALSE];
    }
}

- (void)disconnect {
    OwnTracksLogDefault("[Connection] disconnect");
    if (!self.url) {
        self.intendedDisconnect = TRUE;
        self.state = state_closing;
        if (self.reconnectTimer) {
            if (self.reconnectTimer.isValid) {
                [self.reconnectTimer invalidate];
            }
            self.reconnectTimer = nil;
        }
    }
}

- (void)reset {
    OwnTracksLogDefault("[Connection] reset");
    [self performSelectorOnMainThread:@selector(resetQueue)
                           withObject:nil
                        waitUntilDone:TRUE];
}

- (void)resetQueue {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Queue"];
    
    NSError *error = nil;
    NSArray *matches = [CoreData.sharedInstance.mainMOC executeFetchRequest:request error:&error];
    if (matches) {
        if (matches.count) {
            for (NSManagedObject *object in matches) {
                [CoreData.sharedInstance.mainMOC deleteObject:object];
            }
            [CoreData.sharedInstance sync:CoreData.sharedInstance.mainMOC];
        }
    }
    [self.delegate totalBuffered:self count:0];
}

#pragma internal helpers

- (void)connectToInternal {
    // 改造版: HTTPだけなので接続の処理は無い
}

- (NSString *)parameters {
    if (self.url) {
        return self.url;
    } else {
        return [NSString stringWithFormat:@"%@://%@%@:%ld c%d k%ld as %@ protocol:%u",
                self.ws ? (self.tls ? @"wss" : @"ws") : (self.tls ? @"mqtts" : @"mqtt"),
                self.auth ? [NSString stringWithFormat:@"%@@", self.user] : @"",
                self.host,
                (long)self.port,
                self.clean,
                (long)self.keepalive,
                self.clientId,
                self.protocolVersion
                ];
    }
}

- (void)setState:(NSInteger)state {
    _state = state;
    OwnTracksLogDefault("[Connection] state %@ (%ld)",
                 @{@(state_starting): @"starting",
                   @(state_connecting): @"connecting",
                   @(state_error): @"error",
                   @(state_connected): @"connected",
                   @(state_closing): @"closing",
                   @(state_closed): @"closed"
                   }[@(self.state)],
                 (long)self.state);
    [self.delegate showState:self state:self.state];
}

- (void)reconnect {
    OwnTracksLogDefault("[Connection] reconnect");

    if (self.reconnectTimer) {
        if (self.reconnectTimer.isValid) {
            [self.reconnectTimer invalidate];
        }
        self.reconnectTimer = nil;
    }

    self.state = state_starting;
    self.lastErrorCode = nil;
    
    if (self.url != nil || self.port != 0) {
        if (self.reconnectTime < RECONNECT_TIMER_MAX) {
            self.reconnectTime *= 2.0;
        }
    } else {
        self.reconnectTime = 24.0*60.0*60.0;
    }
    [self connectToInternal];
}

- (void)connectToLast {
    OwnTracksLogDefault("[Connection] connectToLast");
    
    self.reconnectTime = RECONNECT_TIMER;
    
    [self connectToInternal];
}

- (void)startReconnectTimer:(NSRunLoop *)runLoop {
    OwnTracksLogDefault("[Connection] set reconnectTimer %f", self.reconnectTime);
    self.reconnectTimer = [NSTimer timerWithTimeInterval:self.reconnectTime
                                                  target:self
                                                selector:@selector(reconnect)
                                                userInfo:Nil
                                                 repeats:FALSE];
    [runLoop addTimer:self.reconnectTimer forMode:NSDefaultRunLoopMode];
}

// 改造版: libsodiumを外した。暗号化はしない
- (NSData *)encrypt:(NSData *)message {
    return message;
}

- (NSData *)decrypt:(NSData *)data {
    return data;
}

@end
