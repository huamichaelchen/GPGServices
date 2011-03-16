//
//  KeyChooserWindowController.m
//  GPGServices
//
//  Created by Moritz Ulrich on 16.03.11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "KeyChooserWindowController.h"


@implementation KeyChooserWindowController

@synthesize availableKeys, chosenKey;

- (id)init {
    self = [super initWithWindowNibName:@"PrivateKeyChooserWindow"];
 
    NSLog(@"private keys: %@", [self getPrivateKeys]);
    NSLog(@"default key: %@", [self getDefaultKey]);
    
    self.availableKeys = [self getPrivateKeys];
    self.chosenKey = [self getDefaultKey];
    
    return self;
}

- (void)dealloc {
    self.availableKeys = nil;
    self.chosenKey = nil;
    
    [super dealloc];
}

- (void)windowDidLoad {
    [super windowDidLoad];
    
    [popupButton removeAllItems];
    for(GPGKey* key in self.availableKeys) {
        NSMutableString* description = [NSMutableString string];
        [description appendFormat:@"%@ - %@ (%@) <%@>",
         [key shortKeyID], [key name], [key comment], [key email]];
        [popupButton addItemWithTitle:description];
    } 
    
    NSUInteger idx = [self.availableKeys indexOfObject:self.chosenKey];
    [popupButton selectItemAtIndex:idx];
}

- (IBAction)chooseButtonClicked:(id)sender {
    NSUInteger idx = popupButton.indexOfSelectedItem;
    if(idx >= self.availableKeys.count)
        self.chosenKey = nil;
    else
        self.chosenKey = [self.availableKeys objectAtIndex:idx];
    
    [NSApp stopModalWithCode:0];
}

- (IBAction)cancelButtonClicked:(id)sender {
    self.chosenKey = nil;
    
    [NSApp stopModalWithCode:1];
}

- (void)windowWillClose:(NSNotification *)notification {
    if(notification.object == self.window && 
       [NSApp modalWindow] == self.window) {
        [NSApp stopModalWithCode:1];
    }
}

- (NSInteger)runModal {
    [self.window center];
    [self.window display];
    return [NSApp runModalForWindow:self.window];
}

#pragma mark -
#pragma mark GPG Helpers

- (NSArray*)getPrivateKeys {
    GPGContext* context = [[GPGContext alloc] init];
    NSArray* keys = [[context keyEnumeratorForSearchPattern:@"" secretKeysOnly:YES] allObjects];
    [context release];
    
    return keys;
}

- (GPGKey*)getDefaultKey {
    GPGOptions *myOptions=[[GPGOptions alloc] init];
	NSString *keyID=[myOptions optionValueForName:@"default-key"];
	[myOptions release];
	if(keyID == nil)
        return nil;
    
	GPGContext *aContext = [[GPGContext alloc] init];
    
	NS_DURING
    GPGKey* defaultKey=[aContext keyFromFingerprint:keyID secretKey:YES];
    [aContext release];
    return defaultKey;
    NS_HANDLER
    [aContext release];
    return nil;
	NS_ENDHANDLER
    
    return nil;
}


@end
