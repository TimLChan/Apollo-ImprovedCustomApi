#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "fishhook.h"

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

%hook RDKOAuthCredential

- (NSString *)clientIdentifier {
    return sRedditClientId;
}

%end

@interface __NSCFLocalSessionTask : NSObject <NSCopying, NSProgressReporting>
@end

%hook __NSCFLocalSessionTask

- (void)_onqueue_resume {
    // Grab the request url
    NSURLRequest *request =  [self valueForKey:@"_originalRequest"];
    NSString *requestURL = request.URL.absoluteString;

    // Drop requests to analytics/apns services
    if ([requestURL containsString:@"https://apollopushserver.xyz"] || [requestURL containsString:@"telemetrydeck.com"]) {
        return;
    }

    if ([requestURL containsString:@"https://api.imgur.com/"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        // Insert the api credential and update the request on this session task
        [mutableRequest setValue:[NSString stringWithFormat:@"Client-ID %@", sImgurClientId] forHTTPHeaderField:@"Authorization"];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    }

    %orig;
}

%end

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
- (void)useDummyDataWithCompletionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

%hook NSURLSession
// Imgur Upload
- (NSURLSessionUploadTask*)uploadTaskWithRequest:(NSURLRequest*)request fromData:(NSData*)bodyData completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    NSString *urlString = [[request URL] absoluteString];
    NSString *oldPrefix = @"https://imgur-apiv3.p.rapidapi.com/3/image";
    NSString *newPrefix = @"https://api.imgur.com/3/image";

    if ([urlString isEqualToString:oldPrefix]) {
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newPrefix]];
        return %orig(modifiedRequest,bodyData,completionHandler);
    }
    return %orig();
}
// Imgur Delete
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    NSString *urlString = [[request URL] absoluteString];
    NSString *oldPrefix = @"https://imgur-apiv3.p.rapidapi.com/3/image/";
    NSString *newPrefix = @"https://api.imgur.com/3/image/";

    if ([urlString hasPrefix:oldPrefix]) {
        NSString *suffix = [urlString substringFromIndex:oldPrefix.length];
        NSString *newUrlString = [newPrefix stringByAppendingString:suffix];
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
        return %orig(modifiedRequest,completionHandler);
    }
    return %orig();
}

// Fix Imgur loading issue
static NSString *imageID;
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    imageID = [url.lastPathComponent stringByDeletingPathExtension];
    // Remove unwanted messages on app startup
    if ([url.absoluteString containsString:@"https://apollogur.download/api/apollonouncement"] ||
        [url.absoluteString containsString:@"https://apollogur.download/api/easter_sale"] ||
        [url.absoluteString containsString:@"https://apollogur.download/api/html_codes"] ||
        [url.absoluteString containsString:@"https://apollogur.download/api/refund_screen_config"]) {
        return nil;
    } else if ([url.absoluteString containsString:@"https://apollogur.download/api/image/"]) {
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/image/%@.json", imageID];
        NSURL *modifiedURL = [NSURL URLWithString:modifiedURLString];
        // Access the modified URL to get the actual data
        NSURLSessionDataTask *dataTask = [self dataTaskWithURL:modifiedURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || ![self isJSONResponse:response]) {
                // If an error occurs or the response is not a JSON response, dummy data is used
                [self useDummyDataWithCompletionHandler:completionHandler];
            } else {
                // If normal data is returned, the callback is executed
                completionHandler(data, response, error);
            }
        }];

        [dataTask resume];
        return dataTask;
    } else if ([url.absoluteString containsString:@"https://apollogur.download/api/album/"]) {
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/album/%@.json", imageID];
        NSURL *modifiedURL = [NSURL URLWithString:modifiedURLString];
        return %orig(modifiedURL, completionHandler);
    }
    return %orig;
}
%new
- (BOOL)isJSONResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
        if (contentType && [contentType rangeOfString:@"application/json" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}
%new
- (void)useDummyDataWithCompletionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    // Create dummy data
    NSDictionary *dummyData = @{
        @"data": @{
            @"id": @"example_id",
            @"title": @"Example Image",
            @"description": @"This is an example image",
            @"datetime": @(1234567890),
            @"type": @"image/gif",
            @"animated": @(YES),
            @"width": @(640),
            @"height": @(480),
            @"size": @(1024),
            @"views": @(100),
            @"bandwidth": @(512),
            @"vote": @(0),
            @"favorite": @(NO),
            @"nsfw": @(NO),
            @"section": @"example",
            @"account_url": @"example_user",
            @"account_id": @"example_account_id",
            @"is_ad": @(NO),
            @"in_most_viral": @(NO),
            @"has_sound": @(NO),
            @"tags": @[@"example", @"image"],
            @"ad_type": @"image",
            @"ad_url": @"https://example.com",
            @"edited": @(0),
            @"in_gallery": @(NO),
            @"deletehash": @"abc123deletehash",
            @"name": @"example_image",
            @"link": [NSString stringWithFormat:@"https://i.imgur.com/%@.gif", imageID],
            @"success": @(YES)
        }
    };

    NSError *error;
    NSData *dummyDataJSON = [NSJSONSerialization dataWithJSONObject:dummyData options:0 error:&error];

    if (error) {
        NSLog(@"JSON conversion error for dummy data: %@", error);
        return;
    }

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://apollogur.download/api/image/"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    completionHandler(dummyDataJSON, response, nil);
}
%end


@interface SettingsGeneralViewController : UIViewController
@end

%hook SettingsGeneralViewController

- (void)viewDidLoad {
    %orig;
    ((SettingsGeneralViewController *)self).navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Custom API" style: UIBarButtonItemStylePlain target:self action:@selector(showAPICredentialViewController)];
}

%new - (void)showAPICredentialViewController {
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:[[CustomAPIViewController alloc] init]];
    [self presentViewController:navController animated:YES completion:nil];
}

%end

@interface _TtGC7SwiftUI19UIHostingControllerV6Apollo18WallpaperAlertView_ : UIViewController
@end

%hook _TtGC7SwiftUI19UIHostingControllerV6Apollo18WallpaperAlertView_

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    UITabBarController *tabBarController = (UITabBarController *) [self presentingViewController];
    if ([tabBarController selectedIndex] == 0) {
        [tabBarController dismissViewControllerAnimated:YES completion:nil];
    }
}

%end

%ctor {
    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];

    %init(SettingsGeneralViewController=objc_getClass("Apollo.SettingsGeneralViewController"));

    rebind_symbols((struct rebinding[3]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig}
    }, 3);

    if ([sRedditClientId length] == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;
            UITabBarController *tabBarController = (UITabBarController *)mainWindow.rootViewController;
            // Navigate to Settings tab
            tabBarController.selectedViewController = [tabBarController.viewControllers lastObject];
            UINavigationController *settingsNavController = (UINavigationController *) tabBarController.selectedViewController;
            
            // Navigate to General Settings
            UIViewController *settingsGeneralViewController = [[objc_getClass("Apollo.SettingsGeneralViewController") alloc] init];

            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // Invoke Custom API bar button item
                    UIBarButtonItem *rightBarButtonItem = settingsGeneralViewController.navigationItem.rightBarButtonItem;
                    [UIApplication.sharedApplication sendAction:rightBarButtonItem.action to:rightBarButtonItem.target from:settingsGeneralViewController forEvent:nil];
                });
            }];
            [settingsNavController pushViewController:settingsGeneralViewController animated:YES];
            [CATransaction commit];
        });
    }
}