//
//  EPubViewController.m
//  SDKLauncher-iOS
//
//  Created by Shane Meyer on 6/5/13.
//  Copyright (c) 2013 The Readium Foundation. All rights reserved.
//

#import "EPubViewController.h"
#import "Bookmark.h"
#import "BookmarkDatabase.h"
#import "EPubSettings.h"
#import "EPubSettingsController.h"
#import "PackageResourceServer.h"
#import "RDContainer.h"
#import "RDNavigationElement.h"
#import "RDPackage.h"
#import "RDPackageResource.h"
#import "RDSpineItem.h"

#include <assert.h>
#include <stdbool.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/sysctl.h>


@interface EPubViewController ()

- (NSString *)htmlFromData:(NSData *)data;
- (void)passSettingsToJavaScript;
- (void)updateNavigationItems;
- (void)updateToolbar;

@end


@implementation EPubViewController


- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
	[m_alertAddBookmark autorelease];
	m_alertAddBookmark = nil;

	if (buttonIndex == 1) {
		UITextField *textField = [alertView textFieldAtIndex:0];

		NSString *title = [textField.text stringByTrimmingCharactersInSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		NSString *response = [m_webView stringByEvaluatingJavaScriptFromString:
			@"ReadiumSDK.reader.bookmarkCurrentPage()"];

		if (response != nil && response.length > 0) {
			NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
			NSError *error;

			NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
				options:0 error:&error];

			Bookmark *bookmark = [[[Bookmark alloc]
				initWithCFI:[dict objectForKey:@"contentCFI"]
				containerPath:m_container.path
				idref:[dict objectForKey:@"idref"]
				title:title] autorelease];

			if (bookmark == nil) {
				NSLog(@"The bookmark is nil!");
			}
			else {
				[[BookmarkDatabase shared] addBookmark:bookmark];
			}
		}
	}
}


- (void)cleanUp {
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	m_moIsPlaying = NO;
	m_webView = nil;

	if (m_alertAddBookmark != nil) {
		m_alertAddBookmark.delegate = nil;
		[m_alertAddBookmark dismissWithClickedButtonIndex:999 animated:NO];
		[m_alertAddBookmark release];
		m_alertAddBookmark = nil;
	}

	if (m_popover != nil) {
		[m_popover dismissPopoverAnimated:NO];
		[m_popover release];
		m_popover = nil;
	}
}


- (void)dealloc {
	[m_container release];
	[m_navElement release];
	[m_initialCFI release];
	[m_package release];
	[m_resourceServer release];
	[m_spineItem release];
	[super dealloc];
}


//
// Converts the given HTML data to a string.  The character set and encoding are assumed to be
// UTF-8, UTF-16BE, or UTF-16LE.
//
- (NSString *)htmlFromData:(NSData *)data {
	if (data == nil || data.length == 0) {
		return nil;
	}

	NSString *html = nil;
	UInt8 *bytes = (UInt8 *)data.bytes;

	if (data.length >= 3) {
		if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF16BigEndianStringEncoding];
		}
		else if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF16LittleEndianStringEncoding];
		}
		else if (bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF8StringEncoding];
		}
		else if (bytes[0] == 0x00) {
			// There's a very high liklihood of this being UTF-16BE, just without the BOM.
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF16BigEndianStringEncoding];
		}
		else if (bytes[1] == 0x00) {
			// There's a very high liklihood of this being UTF-16LE, just without the BOM.
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF16LittleEndianStringEncoding];
		}
		else {
			html = [[NSString alloc] initWithData:data
				encoding:NSUTF8StringEncoding];

			if (html == nil) {
				html = [[NSString alloc] initWithData:data
					encoding:NSUTF16BigEndianStringEncoding];

				if (html == nil) {
					html = [[NSString alloc] initWithData:data
						encoding:NSUTF16LittleEndianStringEncoding];
				}
			}
		}
	}

	return [html autorelease];
}


- (id)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
{
	return [self initWithContainer:container package:package spineItem:nil cfi:nil];
}


- (id)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
	bookmark:(Bookmark *)bookmark
{
	RDSpineItem *spineItem = nil;

	for (RDSpineItem *currSpineItem in package.spineItems) {
		if ([currSpineItem.idref isEqualToString:bookmark.idref]) {
			spineItem = currSpineItem;
			break;
		}
	}

	return [self
		initWithContainer:container
		package:package
		spineItem:spineItem
		cfi:bookmark.cfi];
}


- (id)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
	navElement:(RDNavigationElement *)navElement
{
	if (container == nil || package == nil) {
		[self release];
		return nil;
	}

	RDSpineItem *spineItem = nil;

	if (package.spineItems.count > 0) {
		spineItem = [package.spineItems objectAtIndex:0];
	}

	if (spineItem == nil) {
		[self release];
		return nil;
	}

	if (self = [super initWithTitle:package.title navBarHidden:NO]) {
		m_container = [container retain];
		m_navElement = [navElement retain];
		m_package = [package retain];
		m_spineItem = [spineItem retain];
		m_resourceServer = [[PackageResourceServer alloc] initWithPackage:package];
		[self updateNavigationItems];
	}

	return self;
}


- (id)
	initWithContainer:(RDContainer *)container
	package:(RDPackage *)package
	spineItem:(RDSpineItem *)spineItem
	cfi:(NSString *)cfi
{
	if (container == nil || package == nil) {
		[self release];
		return nil;
	}

	if (spineItem == nil && package.spineItems.count > 0) {
		spineItem = [package.spineItems objectAtIndex:0];
	}

	if (spineItem == nil) {
		[self release];
		return nil;
	}

	if (self = [super initWithTitle:package.title navBarHidden:NO]) {
		m_container = [container retain];
		m_initialCFI = [cfi retain];
		m_package = [package retain];
		m_resourceServer = [[PackageResourceServer alloc] initWithPackage:package];
		m_spineItem = [spineItem retain];
		[self updateNavigationItems];
	}

	return self;
}


- (void)loadView {
	self.view = [[[UIView alloc] init] autorelease];
	self.view.backgroundColor = [UIColor whiteColor];

	// Notifications

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

	[nc addObserver:self selector:@selector(onEPubSettingsDidChange:)
		name:kSDKLauncherEPubSettingsDidChange object:nil];

	// Web view

	m_webView = [[[UIWebView alloc] init] autorelease];
	m_webView.delegate = self;
	m_webView.hidden = YES;
	m_webView.scalesPageToFit = YES;
	m_webView.scrollView.bounces = NO;
	[self.view addSubview:m_webView];

	NSString *url = [NSString stringWithFormat:
		@"http://localhost:%d/reader.html", m_resourceServer.port];
	[m_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}


- (void)onClickAddBookmark {
	if (m_alertAddBookmark == nil) {
		m_alertAddBookmark = [[UIAlertView alloc]
			initWithTitle:LocStr(@"ADD_BOOKMARK_PROMPT_TITLE")
			message:nil
			delegate:self
			cancelButtonTitle:LocStr(@"GENERIC_CANCEL")
			otherButtonTitles:LocStr(@"GENERIC_OK"), nil];
		m_alertAddBookmark.alertViewStyle = UIAlertViewStylePlainTextInput;
		UITextField *textField = [m_alertAddBookmark textFieldAtIndex:0];
		textField.placeholder = LocStr(@"ADD_BOOKMARK_PROMPT_PLACEHOLDER");
		[m_alertAddBookmark show];
	}
}


- (void)onClickMOPause {
	[m_webView stringByEvaluatingJavaScriptFromString:@"ReadiumSDK.reader.toggleMediaOverlay()"];
}


- (void)onClickMOPlay {
	[m_webView stringByEvaluatingJavaScriptFromString:@"ReadiumSDK.reader.toggleMediaOverlay()"];
}


- (void)onClickNext {
	[m_webView stringByEvaluatingJavaScriptFromString:@"ReadiumSDK.reader.openPageNext()"];
}


- (void)onClickPrev {
	[m_webView stringByEvaluatingJavaScriptFromString:@"ReadiumSDK.reader.openPagePrev()"];
}


- (void)onClickSettings {
	EPubSettingsController *c = [[[EPubSettingsController alloc] init] autorelease];

	UINavigationController *nav = [[[UINavigationController alloc]
		initWithRootViewController:c] autorelease];

	if (IS_IPAD) {
		if (m_popover == nil) {
			m_popover = [[UIPopoverController alloc] initWithContentViewController:nav];
			m_popover.delegate = self;
			[m_popover presentPopoverFromBarButtonItem:self.navigationItem.rightBarButtonItem
				permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
		}
	}
	else {
		[self presentViewController:nav animated:YES completion:nil];
	}
}


- (void)onEPubSettingsDidChange:(NSNotification *)notification {
	[self passSettingsToJavaScript];
}


- (void)passSettingsToJavaScript {
	NSData *data = [NSJSONSerialization dataWithJSONObject:[EPubSettings shared].dictionary
		options:0 error:nil];

	if (data == nil) {
		return;
	}

	NSString *s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];

	if (s == nil || s.length == 0) {
		return;
	}

	[m_webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:
		@"ReadiumSDK.reader.updateSettings(%@)", s]];
}


- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
	[m_popover release];
	m_popover = nil;
}


- (void)updateNavigationItems {
	self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemAction
		target:self
		action:@selector(onClickSettings)] autorelease];
}


- (void)updateToolbar {
	if (m_webView.hidden) {
		self.toolbarItems = nil;
		return;
	}

	NSMutableArray *items = [NSMutableArray arrayWithCapacity:8];

	UIBarButtonItem *itemFixed = [[[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
		target:nil
		action:nil] autorelease];
	itemFixed.width = 12;

	static NSString *arrowL = @"\u2190";
	static NSString *arrowR = @"\u2192";

	UIBarButtonItem *itemNext = [[[UIBarButtonItem alloc]
		initWithTitle:m_currentPageProgressionIsLTR ? arrowR : arrowL
		style:UIBarButtonItemStylePlain
		target:self
		action:@selector(onClickNext)] autorelease];

	UIBarButtonItem *itemPrev = [[[UIBarButtonItem alloc]
		initWithTitle:m_currentPageProgressionIsLTR ? arrowL : arrowR
		style:UIBarButtonItemStylePlain
		target:self
		action:@selector(onClickPrev)] autorelease];

	if (m_currentPageProgressionIsLTR) {
		[items addObject:itemPrev];
		[items addObject:itemFixed];
		[items addObject:itemNext];
	}
	else {
		[items addObject:itemNext];
		[items addObject:itemFixed];
		[items addObject:itemPrev];
	}

	[items addObject:itemFixed];

	UILabel *label = [[[UILabel alloc] init] autorelease];
	label.backgroundColor = [UIColor clearColor];
	label.font = [UIFont systemFontOfSize:16];
	label.textColor = [UIColor blackColor];

	if (m_currentPageCount == 0) {
		label.text = @"";
		itemNext.enabled = NO;
		itemPrev.enabled = NO;
	}
	else {
		label.text = LocStr(@"PAGE_X_OF_Y", m_currentPageIndex + 1, m_currentPageCount);

		itemNext.enabled = !(
			(m_currentSpineItemIndex + 1 == m_package.spineItems.count) &&
			(m_currentPageIndex + m_currentOpenPageCount + 1 >= m_currentPageCount)
		);

		itemPrev.enabled = !(m_currentSpineItemIndex == 0 && m_currentPageIndex == 0);
	}

	[label sizeToFit];

	[items addObject:[[[UIBarButtonItem alloc] initWithCustomView:label] autorelease]];

	[items addObject:[[[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
		target:nil
		action:nil] autorelease]
	];

	NSString *response = [m_webView stringByEvaluatingJavaScriptFromString:
		@"ReadiumSDK.reader.isMediaOverlayAvailable()"];

	if (response != nil && [response isEqualToString:@"true"]) {
		if (m_moIsPlaying) {
			[items addObject:[[[UIBarButtonItem alloc]
				initWithBarButtonSystemItem:UIBarButtonSystemItemPause
				target:self
				action:@selector(onClickMOPause)] autorelease]
			];
		}
		else {
			[items addObject:[[[UIBarButtonItem alloc]
				initWithBarButtonSystemItem:UIBarButtonSystemItemPlay
				target:self
				action:@selector(onClickMOPlay)] autorelease]
			];
		}

		[items addObject:itemFixed];
	}

	[items addObject:[[[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		target:self
		action:@selector(onClickAddBookmark)] autorelease]
	];

	self.toolbarItems = items;
}


- (void)viewDidLayoutSubviews {
	m_webView.frame = self.view.bounds;
}


- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];

	if (self.navigationController != nil) {
		[self.navigationController setToolbarHidden:NO animated:YES];
	}
}


- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];

	if (self.navigationController != nil) {
		[self.navigationController setToolbarHidden:YES animated:YES];
	}
}


- (BOOL)
	webView:(UIWebView *)webView
	shouldStartLoadWithRequest:(NSURLRequest *)request
	navigationType:(UIWebViewNavigationType)navigationType
{
	BOOL shouldLoad = YES;
	NSString *url = request.URL.absoluteString;
	NSString *s = @"epubobjc:";

	if ([url hasPrefix:s]) {
		url = [url substringFromIndex:s.length];
		shouldLoad = NO;

		if ([url isEqualToString:@"readerDidInitialize"]) {
			NSMutableDictionary *dict = [NSMutableDictionary dictionary];
			[dict setObject:m_package.dictionary forKey:@"package"];
			[dict setObject:[EPubSettings shared].dictionary forKey:@"settings"];

			NSDictionary *pageDict = nil;

			if (m_spineItem == nil) {
			}
			else if (m_initialCFI != nil && m_initialCFI.length > 0) {
				pageDict = @{
					@"idref" : m_spineItem.idref,
					@"elementCfi" : m_initialCFI
				};
			}
			else if (m_navElement.content != nil && m_navElement.content.length > 0) {
				pageDict = @{
					@"contentRefUrl" : m_navElement.content,
					@"sourceFileHref" : (m_navElement.sourceHref == nil ?
						@"" : m_navElement.sourceHref)
				};
			}
			else {
				pageDict = @{
					@"idref" : m_spineItem.idref
				};
			}

			if (pageDict != nil) {
				[dict setObject:pageDict forKey:@"openPageRequest"];
			}

			NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];

			if (data != nil) {
				NSString *arg = [[[NSString alloc] initWithData:data
					encoding:NSUTF8StringEncoding] autorelease];
				[m_webView stringByEvaluatingJavaScriptFromString:[NSString
					stringWithFormat:@"ReadiumSDK.reader.openBook(%@)", arg]];
			}

			return shouldLoad;
		}

		s = @"pageDidChange?q=";

		if ([url hasPrefix:s]) {
			s = [url substringFromIndex:s.length];
			s = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

			NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
			NSError *error;

			NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
				options:0 error:&error];

			NSString *direction = [dict objectForKey:@"pageProgressionDirection"];

			if ([direction isKindOfClass:[NSString class]]) {
				m_currentPageProgressionIsLTR = ![direction isEqualToString:@"rtl"];
			}
			else {
				m_currentPageProgressionIsLTR = YES;
			}

			m_currentOpenPageCount = 0;

			for (NSDictionary *pageDict in [dict objectForKey:@"openPages"]) {
				m_currentOpenPageCount++;

				NSNumber *number = [pageDict objectForKey:@"spineItemPageCount"];
				m_currentPageCount = number.intValue;

				number = [pageDict objectForKey:@"spineItemPageIndex"];
				m_currentPageIndex = number.intValue;

				number = [pageDict objectForKey:@"spineItemIndex"];
				m_currentSpineItemIndex = number.intValue;

				break;
			}

			m_webView.hidden = NO;
			[self updateToolbar];
			return shouldLoad;
		}

		s = @"mediaOverlayStatusDidChange?q=";

		if ([url hasPrefix:s]) {
			s = [url substringFromIndex:s.length];
			s = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

			NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
			NSError *error;

			NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
				options:0 error:&error];

			NSNumber *number = [dict objectForKey:@"isPlaying"];

			if (number != nil) {
				m_moIsPlaying = number.boolValue;
			}

			[self updateToolbar];
			return shouldLoad;
		}
	}

	return shouldLoad;
}


@end
