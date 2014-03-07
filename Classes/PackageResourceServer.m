//
//  PackageResourceServer.m
//  SDKLauncher-iOS
//
//  Created by Shane Meyer on 2/28/13.
//  Copyright (c) 2013 The Readium Foundation. All rights reserved.
//

#import "PackageResourceServer.h"
#import "RDPackage.h"
#import "RDPackageResource.h"

#ifdef USE_MONGOOSE_HTTP_SERVER
#import "mongoose.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#ifdef PARSE_MULTI_HTTP_RANGES
#import "DDRange.h"
#import "DDNumber.h"
#else
#include <inttypes.h>
#endif
#else
#import "AQHTTPServer.h"
#import "PackageResourceConnection.h"
#endif

static dispatch_semaphore_t m_byteStreamResourceLock = NULL;

@implementation PackageResourceServer

+ (dispatch_semaphore_t) byteStreamResourceLock
{
    return m_byteStreamResourceLock;
}


#ifdef USE_MONGOOSE_HTTP_SERVER

#ifdef PARSE_MULTI_HTTP_RANGES

static NSArray * parseRangeRequest(NSString * rangeHeader, UInt64 contentLength)
{
//	HTTPLogTrace();

// Examples of byte-ranges-specifier values (assuming an entity-body of length 10000):
//
// - The first 500 bytes (byte offsets 0-499, inclusive):  bytes=0-499
//
// - The second 500 bytes (byte offsets 500-999, inclusive): bytes=500-999
//
// - The final 500 bytes (byte offsets 9500-9999, inclusive): bytes=-500
//
// - Or bytes=9500-
//
// - The first and last bytes only (bytes 0 and 9999):  bytes=0-0,-1
//
// - Several legal but not canonical specifications of the second 500 bytes (byte offsets 500-999, inclusive):
// bytes=500-600,601-999
// bytes=500-700,601-999
//

NSRange eqsignRange = [rangeHeader rangeOfString:@"="];

if(eqsignRange.location == NSNotFound) return nil;

NSUInteger tIndex = eqsignRange.location;
NSUInteger fIndex = eqsignRange.location + eqsignRange.length;

NSMutableString *rangeType  = [[rangeHeader substringToIndex:tIndex] mutableCopy];
NSMutableString *rangeValue = [[rangeHeader substringFromIndex:fIndex] mutableCopy];
#if USING_MRR
    [rangeType autorelease];
    [rangeValue autorelease];
#endif

CFStringTrimWhitespace((__bridge CFMutableStringRef)rangeType);
CFStringTrimWhitespace((__bridge CFMutableStringRef)rangeValue);

if([rangeType caseInsensitiveCompare:@"bytes"] != NSOrderedSame) return nil;

NSArray *rangeComponents = [rangeValue componentsSeparatedByString:@","];

if([rangeComponents count] == 0) return nil;

NSMutableArray * ranges = [[NSMutableArray alloc] initWithCapacity:[rangeComponents count]];
#if USING_MRR
    [ranges autorelease];
#endif

// Note: We store all range values in the form of DDRange structs, wrapped in NSValue objects.
// Since DDRange consists of UInt64 values, the range extends up to 16 exabytes.

NSUInteger i;
for (i = 0; i < [rangeComponents count]; i++)
{
NSString *rangeComponent = [rangeComponents objectAtIndex:i];

NSRange dashRange = [rangeComponent rangeOfString:@"-"];

if (dashRange.location == NSNotFound)
{
// We're dealing with an individual byte number

UInt64 byteIndex;
if(![NSNumber parseString:rangeComponent intoUInt64:&byteIndex]) return nil;

if(byteIndex >= contentLength) return nil;

[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(byteIndex, 1)]];
}
else
{
// We're dealing with a range of bytes

tIndex = dashRange.location;
fIndex = dashRange.location + dashRange.length;

NSString *r1str = [rangeComponent substringToIndex:tIndex];
NSString *r2str = [rangeComponent substringFromIndex:fIndex];

UInt64 r1, r2;

BOOL hasR1 = [NSNumber parseString:r1str intoUInt64:&r1];
BOOL hasR2 = [NSNumber parseString:r2str intoUInt64:&r2];

if (!hasR1)
{
// We're dealing with a "-[#]" range
//
// r2 is the number of ending bytes to include in the range

if(!hasR2) return nil;
if(r2 > contentLength) return nil;

UInt64 startIndex = contentLength - r2;

[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(startIndex, r2)]];
}
else if (!hasR2)
{
// We're dealing with a "[#]-" range
//
// r1 is the starting index of the range, which goes all the way to the end

if(r1 >= contentLength) return nil;

[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, contentLength - r1)]];
}
else
{
// We're dealing with a normal "[#]-[#]" range
//
// Note: The range is inclusive. So 0-1 has a length of 2 bytes.

if(r1 > r2) return nil;
if(r2 >= contentLength) return nil;

[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, r2 - r1 + 1)]];
}
}
}

if([ranges count] == 0) return nil;

// NB: no sorting or combining-- that's being done later

return [NSArray arrayWithArray: ranges];
}

#else

static int parse_range_header(const char *header, int64_t *a, int64_t *b) {
    return sscanf(header, "bytes=%" PRId64 "-%" PRId64, a, b);
}

#endif


static void gmt_time_string(char *buf, size_t buf_len, time_t *t) {
    strftime(buf, buf_len, "%a, %d %b %Y %H:%M:%S GMT", gmtime(t));
}


struct server_info_t {
    struct mg_server * server;
    PackageResourceServer * packServer;
};


struct connection_param_t {
    RDPackageResource *resource;
};

static int mg_ev_handler(struct mg_connection *conn, enum mg_event ev)
{
//    enum mg_event {
//        MG_POLL = 100,  // Callback return value is ignored
//        MG_CONNECT,     // If callback returns MG_FALSE, connect fails
//        MG_AUTH,        // If callback returns MG_FALSE, authentication fails
//        MG_REQUEST,     // If callback returns MG_FALSE, Mongoose continues with req
//        MG_REPLY,       // If callback returns MG_FALSE, Mongoose closes connection
//        MG_CLOSE,       // Connection is closed
//        MG_HTTP_ERROR   // If callback returns MG_FALSE, Mongoose continues with err
//    };
    @autoreleasepool {
        struct server_info_t* serverInfo = (struct server_info_t*)conn->server_param;


        if (ev == MG_CONNECT)
        {
            printf("MG_CONNECT\n");
            return serverInfo->packServer.doPollServer ? MG_TRUE : MG_FALSE;
        }
        else if (ev == MG_AUTH)
        {
            printf("MG_AUTH\n");
            return serverInfo->packServer.doPollServer ? MG_TRUE : MG_FALSE;
        }
        else if (ev == MG_REPLY)
        {
            printf("MG_REPLY\n");
            return serverInfo->packServer.doPollServer ? MG_TRUE : MG_FALSE;
        }
        else if (ev == MG_POLL)
        {
            printf("MG_POLL\n");
            return MG_TRUE;
        }
        else if (ev == MG_REQUEST)
        {
            if (!serverInfo->packServer.doPollServer) return MG_TRUE;

            RDPackage * package = serverInfo->packServer.package;
            NSString * pack_id = [package packageUUID];

            printf("======================\n");
            if (conn->content_len > 0)
            {
                //char * content = new char[conn->content_len];
                char content[conn->content_len+1];
                strncpy(content, conn->content, conn->content_len);
                content[conn->content_len] = '\0';
                printf("mg_connection->content %s\n", content);
                //delete content;
            }
            printf("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n");

            printf("mg_connection->connection_param %d\n", conn->connection_param);

            printf("mg_connection->request_method %s\n", conn->request_method);

            printf("mg_connection->status_code %d\n", conn->status_code);

            printf("mg_connection->local_ip %s\n", conn->local_ip);
            printf("mg_connection->local_ip %d\n", conn->local_port);

            printf("mg_connection->http_version %s\n", conn->http_version);
            printf("mg_connection->query_string %s\n", conn->query_string);

            for (int i = 0; i < conn->num_headers; i++)
            {
                printf("******\n");
                printf("mg_connection->http_headers[%d]->name  ||| %s\n", i, conn->http_headers[i].name);
                printf("mg_connection->http_headers[%d]->value ||| %s\n", i, conn->http_headers[i].value);
                printf("******\n");
            }

            printf("mg_connection->uri %s\n", conn->uri);

            const char * packId = [pack_id UTF8String];
            printf("mg_connection->server_param (RDPackage.packageUUID) %s\n", packId);
            printf("----------------------\n");


            if (strcmp(conn->request_method, "GET") != 0)
            {
                printf("NOT GET REQUEST??\n");
                return MG_TRUE;
            }

            time_t curtime = time(NULL);
            char date[64];
            gmt_time_string(date, sizeof(date), &curtime);

            size_t uriLen = strlen(conn->uri);
            size_t packIdLen = strlen(packId);
            if (uriLen < packIdLen || strncmp(conn->uri+1, packId, packIdLen) != 0)
            {
                NSString *fileSystemPath = [[NSBundle mainBundle].resourcePath
                        stringByAppendingPathComponent: [NSString stringWithUTF8String:conn->uri]];

                // TODO: Costly I/O operation! (invoked frequently for partial HTTP range requests, e.g. audio / video media)
                if ([[NSFileManager defaultManager] fileExistsAtPath:fileSystemPath]) {

                    //NSLog(@"FS Path: %@\n", fileSystemPath);
                    printf("FS Path: %s\n", [fileSystemPath UTF8String]);

                    //NSInputStream * fileSystemStream = [NSInputStream inputStreamWithURL:[NSURL fileURLWithPath:fileSystemPath]];
                    //NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fileSystemPath error:nil];
                    //unsigned long long int fSize = (attrs == nil) ? 0 : attrs.fileSize;

                    NSData *data = [NSData dataWithContentsOfFile:fileSystemPath];
                    if (data != nil)
                    {
                        int nBytes = [data length];

                    conn->status_code = 200;

                    mg_printf(conn,
                            "%s%s%s%d%s",
                            "HTTP/1.1 200 OK\r\nDate: ",
                            date,
                            "\r\nServer: ReadiumPackageResourceServer\r\nAccept-Ranges: bytes\r\nConnection: close\r\nContent-Length: ",
                            nBytes,
                            "\r\n\r\n");

                        if (nBytes > 0)
                        {
                            mg_write(conn, [data bytes], nBytes);
                            mg_write(conn, "\r\n", 2);
                        }

                        //[data release];
                    }

                    return MG_FALSE;
                }

//
//                printf("BAD PACKAGE UUI?!\n");
//                conn->status_code = 404;
//                return MG_TRUE;
            }

            bool includePackageID = false;

            int excludeLeadingSlash = 1; // 0 TRUE, 1 FALSE
            size_t len = uriLen - (includePackageID ? packIdLen - 1 : 0) - excludeLeadingSlash;
            //char * path = new char[len];
            char path[len+1];
            strncpy(path, conn->uri + (includePackageID ? packIdLen  + 1 : 0) + excludeLeadingSlash, len);
            path[len] = '\0';
            printf("REL PATH (from conn->uri) %s\n", path);
            NSString * relPath = [NSString stringWithUTF8String: path];
            //delete path;

            __block RDPackageResource *resource =nil;

            if (conn->connection_param == NULL)
            {
                printf("NEW (conn->connection_param)\n");

                LOCK_BYTESTREAM(^{
                    resource = [package resourceAtRelativePath:relPath];
                });

                if (resource == nil)
                {
                    printf("BAD RDPackageResource path?!\n");
                    return MG_TRUE;
                }

                [resource retain]; // because it is in the autorelease pool, and we want to manually release on MG_CLOSE

                struct connection_param_t * connection_param;
                connection_param = (struct connection_param_t *) malloc(sizeof(*connection_param));
                conn->connection_param = connection_param;
                connection_param->resource = resource;
            }
            else
            {
                printf("OLD (conn->connection_param)\n");

                resource = ((struct connection_param_t *)conn->connection_param)->resource;

                if (resource == nil)
                {
                    printf("ERROR !!! ((struct connection_param_t *)conn->connection_param)->resource\n");

                    free(conn->connection_param);
                    conn->connection_param = NULL;

                    return MG_TRUE;
                }
            }



            printf("RDPackageResource path: %s\n", [[resource relativePath] UTF8String]);

            int contentLength = resource.bytesCount;

            if (contentLength == 0)
            {
                NSLog(@"WHAT? contentLength 0");
                return MG_TRUE;
            }

            printf("RDPackageResource bytes: %d\n", contentLength);

            const char * mime = mg_get_mime_type(conn->uri, "text/plain");
            printf("RDPackageResource mime: %s\n", mime);

            const char * connex = mg_get_header(conn, "Connection");
            bool keepAlive = false;
            if (strcmp(connex, "keep-alive") == 0) keepAlive = true;

            const char * hdr = mg_get_header(conn, "Range");

#ifdef PARSE_MULTI_HTTP_RANGES
        NSArray * ranges = nil;
        if (hdr != NULL)
        {
            conn->status_code = 206;
            ranges = parseRangeRequest([NSString stringWithUTF8String:hdr], contentLength);
        }
#else
            int n;
            int64_t r1 = 0;
            int64_t r2 = 0;
            if (hdr != NULL
                    && (n = parse_range_header(hdr, &r1, &r2)) > 0
                    && r1 >= 0 && r2 >= 0)
            {
                conn->status_code = 206;

                int64_t rangeLength = n == 2 ? (r2 > contentLength ? contentLength : r2) - r1 + 1: contentLength - r1;

                printf("********* RANGE: %d - %d (%d) / %d\n", (int)r1, (int)r2, (int)rangeLength, (int)contentLength);

                mg_printf(conn, "%s%s%s%s%s%d%s%d%s%d%s%d%s",
                        "HTTP/1.1 206 Partial Content\r\nDate: ",
                        date,
                        "\r\nServer: ReadiumPackageResourceServer\r\nAccept-Ranges: bytes\r\nConnection: ",
                        (keepAlive ? "keep-alive" : "close"),
                        "\r\nContent-Length: ",
                        (int)rangeLength,
                        "\r\nContent-Range: bytes ",
                        (int)r1,
                        "-",
                        (int)r2,
                        "/",
                        (int)contentLength,
                        "\r\n\r\n");
                printf("%s%s%s%s%s%d%s%d%s%d%s%d%s",
                        "HTTP/1.1 206 Partial Content\r\nDate: ",
                        date,
                        "\r\nServer: ReadiumPackageResourceServer\r\nAccept-Ranges: bytes\r\nConnection: ",
                        (keepAlive ? "keep-alive" : "close"),
                        "\r\nContent-Length: ",
                        (int)rangeLength,
                        "\r\nContent-Range: bytes ",
                        (int)r1,
                        "-",
                        (int)r2,
                        "/",
                        (int)contentLength,
                        "\r\n\r\n");

                NSRange range = {.location = (uint)r1, .length = (uint)rangeLength};

                NSData *data = [resource createChunkByReadingRange:range package:package];
                if (data != nil)
                {
                    int nBytes = [data length];
                    if (nBytes > 0)
                    {
                        printf("++++++ BYTES: %d\n", nBytes);

                        mg_write(conn, [data bytes], nBytes);
                        mg_write(conn, "\r\n", 2);
                    }

                    //[data release];
                }
            }
            else
            {
                printf("????? PackageResource FULL!\n");

                conn->status_code = 200;

                mg_printf(conn, "%s%s%s%d%s",
                        "HTTP/1.1 200 OK\r\nDate: ",
                        date,
                        "\r\nServer: ReadiumPackageResourceServer\r\nAccept-Ranges: bytes\r\nConnection: close\r\nContent-Length: ",
                        contentLength,
                        "\r\n\r\n");
                printf("%s%s%s%d%s",
                        "HTTP/1.1 200 OK\r\nDate: ",
                        date,
                        "\r\nServer: ReadiumPackageResourceServer\r\nAccept-Ranges: bytes\r\nConnection: close\r\nContent-Length: ",
                        contentLength,
                        "\r\n\r\n");



                NSData *data = [resource readAllDataChunks];
                if (data != nil)
                {
                    int nBytes = [data length];
                    if (nBytes > 0)
                    {
                        mg_write(conn, [data bytes], nBytes);
                        mg_write(conn, "\r\n", 2);
                    }

                    //[data release];
                }
            }
#endif

            return MG_FALSE;
        }
        else if (ev == MG_CLOSE)
        {
            printf("{{{{{{{{{{{{{{{{{{{{{{{{{ CLOSE\n");

            if (conn->connection_param != NULL)
            {
                printf("free(conn->connection_param)\n");

                [((struct connection_param_t *)conn->connection_param)->resource release];

                free(conn->connection_param);
                conn->connection_param = NULL;
            }

            return MG_FALSE;
        }
    }
    return MG_FALSE;
}
//
//void pthread_cleanup(void * arg)
//{
//    printf("pthread_cleanup mg_destroy_server\n");
//    mg_destroy_server((struct mg_server **)&arg);
//}

static void *mg_serve(void *serverInformation)
{
    printf("NSThread.isMultiThreaded %d\n", NSThread.isMultiThreaded);


//    pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
//    pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED, NULL);

    struct server_info_t* serverInfo = (struct server_info_t*)serverInformation;

    unsigned int num_active_connections = 0;

    pthread_mutex_t * mutex = serverInfo->packServer.mutex;

    pthread_mutex_lock(mutex);

    // uses pthread_self()
    //pthread_cleanup_push(&pthread_cleanup, (struct mg_server *)server); // MACRO: opens lexical scope {
    printf("THREAD (before loop) \n");

    while (serverInfo->packServer.doPollServer || num_active_connections > 0)
    {
        printf("THREAD %d (poll) %p\n", num_active_connections, serverInfo->server);

        num_active_connections = mg_poll_server(serverInfo->server, 1000); // ms

        //pthread_testcancel();
    }

    printf("THREAD (after loop) %d\n", num_active_connections);
    //pthread_cleanup_pop(1); // MACRO: closes lexical scope }

    mg_destroy_server(&serverInfo->server);
    serverInfo->server = NULL;

    //[serverInfo->packServer release];
    serverInfo->packServer = nil;

    printf("free(serverInfo);\n");

    free(serverInfo);
    serverInfo = NULL;

    printf("pthread_mutex_unlock\n");

    pthread_mutex_unlock(mutex);

    printf("pthread_exit\n");

    //pthread_exit((void*)'z');
    //pthread_exit(NULL);
    return NULL;
}
#else
#endif

- (void)dealloc {

#if DISPATCH_USES_ARC == 0

    if ( m_byteStreamResourceLock != NULL )
    {
        //dispatch_semaphore_signal(m_byteStreamResourceLock);
        dispatch_release(m_byteStreamResourceLock);
        m_byteStreamResourceLock = NULL;
    }
#endif

#ifdef USE_MONGOOSE_HTTP_SERVER

    printf("mongoose dealloc\n");

    if (m_threadId != NULL)
    {
        printf("pthread_cancel join\n");

        //pthread_exit(m_threadId);
        //pthread_kill(m_threadId, 0);

        //pthread_cancel(m_threadId);

        m_doPollServer = false;

        printf("pthread_mutex_lock...\n");
        pthread_mutex_lock(&m_mutex);

//        char *c;
//        int ret = pthread_join(m_threadId, (void**)&c);
//        //ret == EINVAL ==> PTHREAD_CREATE_DETACHED :(

        m_threadId = NULL;

        printf("pthread_cancel join DONE\n");
    }

    m_server = NULL;

    printf("pthread_mutex_destroy\n");
    pthread_mutex_destroy(&m_mutex);

// done when thread gets cleaned-up
//    if (m_server != NULL)
//    {
//        printf("DESTROY SERVER THREAD (dealloc)\n");
//        mg_destroy_server(&m_server);
//    }
#else
	if (m_httpServer != nil) {
		if (m_httpServer.isListening) {
			[m_httpServer stop];
		}

		[m_httpServer release];
		m_httpServer = nil;
	}

	[PackageResourceConnection setPackage:nil];
#endif

	[m_package release];

	[super dealloc];
}

#ifdef USE_MONGOOSE_HTTP_SERVER
-(void)stub{
    NSAutoreleasePool * localPool = [[NSAutoreleasePool alloc] init];
    if([NSThread isMultiThreaded])
        NSLog(@"entering Multithreaded Mode");
    [localPool release];
}
#endif

- (id)initWithPackage:(RDPackage *)package {
	if (package == nil) {
		[self release];
		return nil;
	}

	if (self = [super init]) {


		m_package = [package retain];

        // create a critical section lock
        m_byteStreamResourceLock = dispatch_semaphore_create(1);

#ifdef USE_MONGOOSE_HTTP_SERVER

        [NSThread detachNewThreadSelector:@selector(stub) toTarget:self withObject:Nil];

        pthread_mutex_init(&m_mutex, NULL);

        //struct server_info_t * serverInfo = new (struct server_info_t)();
        struct server_info_t * serverInfo;
        serverInfo = (struct server_info_t *) malloc(sizeof(*serverInfo));

        serverInfo->packServer = self; // [self retain];  NO! (otherwise dealloc never called)

        //mg_ev_handler ===> endpoint_type == EP_USER
        m_server = mg_create_server((void *)serverInfo, mg_ev_handler);

        serverInfo->server = m_server;

//        m_kSDKLauncherPackageResourceServerPort = 8080;
//        NSString * port = [NSString stringWithFormat:@"%d", m_kSDKLauncherPackageResourceServerPort];
//        mg_set_option(server, "listening_port", [port UTF8String]);

        mg_set_option(m_server, "listening_port", "0");
        const char * portStr = mg_get_option(m_server, "listening_port");
        m_kSDKLauncherPackageResourceServerPort = strtol(portStr, NULL, 10);

        printf("Resource server port: %d\n", m_kSDKLauncherPackageResourceServerPort);

        m_doPollServer = true;


        m_threadId = (pthread_t)mg_start_thread(mg_serve, serverInfo);

#else
		m_httpServer = [[AQHTTPServer alloc] initWithAddress:@"localhost"
			root:[NSBundle mainBundle].resourceURL];

		if (m_httpServer == nil) {
			NSLog(@"The HTTP server is nil!");
			[self release];
			return nil;
		}

		[m_httpServer setConnectionClass:[PackageResourceConnection class]];

		NSError *error = nil;
		BOOL success = [m_httpServer start:&error];

		if (!success || error != nil) {
			if (error != nil) {
				NSLog(@"Could not start the HTTP server! %@", error);
			}

			[self release];
			return nil;
		}

		[PackageResourceConnection setPackage:package];
#endif
	}

	return self;
}


#if defined(USE_MONGOOSE_HTTP_SERVER)

- (RDPackage *) package
{
    return m_package;
}

- (int) doPollServer
{
    return m_doPollServer;
}

- (pthread_mutex_t*) mutex
{
    return &m_mutex;
}

#endif

- (int)port {
#ifdef USE_MONGOOSE_HTTP_SERVER
    return m_kSDKLauncherPackageResourceServerPort;
#else
	NSString *s = m_httpServer.serverAddress;
	NSRange range = [s rangeOfString:@":"];
	return range.location == NSNotFound ? 0 : [s substringFromIndex:range.location + 1].intValue;
#endif
}


@end
