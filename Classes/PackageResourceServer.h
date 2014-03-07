//
//  PackageResourceServer.h
//  SDKLauncher-iOS
//
//  Created by Shane Meyer on 2/28/13.
//  Copyright (c) 2013 The Readium Foundation. All rights reserved.
//

#import <Foundation/Foundation.h>

#define LOCK_BYTESTREAM(block) do {\
        dispatch_semaphore_wait(PackageResourceServer.byteStreamResourceLock, DISPATCH_TIME_FOREVER);\
        @try {\
            block();\
        } @finally {\
            dispatch_semaphore_signal(PackageResourceServer.byteStreamResourceLock);\
        }\
    } while (0);

#ifdef USE_MONGOOSE_HTTP_SERVER
#import "mongoose.h"
#else
@class AQHTTPServer;
#endif

@class RDPackage;

@interface PackageResourceServer : NSObject {

#ifdef USE_MONGOOSE_HTTP_SERVER
@private int m_kSDKLauncherPackageResourceServerPort;
    pthread_t m_threadId;
    struct mg_server * m_server;
@private bool m_doPollServer;
    pthread_mutex_t m_mutex; //PTHREAD_MUTEX_INITIALIZER
#else
@private AQHTTPServer *m_httpServer;
#endif

	@private RDPackage *m_package;
}

#if defined(USE_MONGOOSE_HTTP_SERVER)
- (int) doPollServer;
- (RDPackage *) package;
- (pthread_mutex_t*) mutex;
#endif

@property (nonatomic, readonly) int port;

- (id)initWithPackage:(RDPackage *)package;

+ (dispatch_semaphore_t) byteStreamResourceLock;

@end
