//
//  GPGServices.m
//  GPGServices
//
//  Created by Robert Goldsmith on 24/06/2006.
//  Copyright 2006 __MyCompanyName__. All rights reserved.
//

#import "GPGServices.h"

#import "RecipientWindowController.h"
#import "KeyChooserWindowController.h"

#import "ZipOperation.h"
#import "ZipKit/ZKArchive.h"

@implementation GPGServices

-(void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	[NSApp setServicesProvider:self];
    //	NSUpdateDynamicServices();
	currentTerminateTimer=nil;
    
    [GrowlApplicationBridge setGrowlDelegate:self];
}


#pragma mark -
#pragma mark GPG-Helper

-(void)importKey:(NSString *)inputString
{
	NSDictionary *importedKeys = nil;
	GPGContext *aContext = [[GPGContext alloc] init];
	GPGData* inputData=[[GPGData alloc] initWithDataNoCopy:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
    
	@try {
        importedKeys = [aContext importKeyData:inputData];
	} @catch(NSException* localException) {
        [self displayMessageWindowWithTitleText:@"Import result:"
                                       bodyText:GPGErrorDescription([[[localException userInfo] 
                                                                      objectForKey:@"GPGErrorKey"] 
                                                                     intValue])];

        return;
	} @finally {
        [inputData release];
        [aContext release];
    }
    
    [[NSAlert alertWithMessageText:@"Import result:"
                     defaultButton:@"Ok"
                   alternateButton:nil
                       otherButton:nil
         informativeTextWithFormat:@"%i key(s), %i secret key(s), %i revocation(s) ",
      [[importedKeys valueForKey:@"importedKeyCount"] intValue],
      [[importedKeys valueForKey:@"importedSecretKeyCount"] intValue],
      [[importedKeys valueForKey:@"newRevocationCount"] intValue]]
     runModal];
}

+ (NSSet*)myPrivateKeys {
    GPGContext* context = [[GPGContext alloc] init];
    
    NSMutableSet* keySet = [NSMutableSet set];
    for(GPGKey* k in [NSSet setWithArray:[[context keyEnumeratorForSearchPattern:@"" secretKeysOnly:YES] allObjects]]) {
        [keySet addObject:[context refreshKey:k]];
    }
    
    [context release];
    
    return keySet;
}

+ (GPGKey*)myPrivateKey {
    GPGOptions *myOptions=[[GPGOptions alloc] init];
	NSString *keyID=[myOptions optionValueForName:@"default-key"];
	[myOptions release];
	if(keyID == nil)
        return nil;
    
	GPGContext *aContext = [[GPGContext alloc] init];
    
	@try {
        GPGKey* defaultKey=[aContext keyFromFingerprint:keyID secretKey:YES];
        return defaultKey;
    } @catch (NSException* s) {
    
    } @finally {
        [aContext release];
    }
    
    return nil;
}


#pragma mark -
#pragma mark Validators

+ (KeyValidatorT)canEncryptValidator {
    id block = ^(GPGKey* key) {
        // A subkey can be expired, without the key being, thus making key useless because it has
        // no other subkey...
        // We don't care about ownerTrust, validity
        
        for (GPGSubkey *aSubkey in [key subkeys]) {
            if ([aSubkey canEncrypt] && 
                ![aSubkey hasKeyExpired] && 
                ![aSubkey isKeyRevoked] &&
                ![aSubkey isKeyInvalid] &&
                ![aSubkey isKeyDisabled]) {
                return YES;
            }
        }
        return NO;
    };
    
    return [[block copy] autorelease];
}


+ (KeyValidatorT)canSignValidator {
    // Copied from GPGMail's GPGMailBundle.m
    KeyValidatorT block =  ^(GPGKey* key) {
        // A subkey can be expired, without the key being, thus making key useless because it has
        // no other subkey...
        // We don't care about ownerTrust, validity, subkeys
        
        // Secret keys are never marked as revoked! Use public key
        key = [key publicKey];
        
        // If primary key itself can sign, that's OK (unlike what gpgme documentation says!)
        if ([key canSign] && 
            ![key hasKeyExpired] && 
            ![key isKeyRevoked] && 
            ![key isKeyInvalid] && 
            ![key isKeyDisabled]) {
            return YES;
        }
        
        for (GPGSubkey *aSubkey in [key subkeys]) {
            if ([aSubkey canSign] && 
                ![aSubkey hasKeyExpired] && 
                ![aSubkey isKeyRevoked] && 
                ![aSubkey isKeyInvalid] && 
                ![aSubkey isKeyDisabled]) {
                return YES;
            }
        }
        return NO;
    };
    
    return [[block copy] autorelease];
}

+ (KeyValidatorT)isActiveValidator {
    // Copied from GPGMail's GPGMailBundle.m
    KeyValidatorT block =  ^(GPGKey* key) {

        // Secret keys are never marked as revoked! Use public key
        key = [key publicKey];
        
        // If primary key itself can sign, that's OK (unlike what gpgme documentation says!)
        if (![key hasKeyExpired] && 
            ![key isKeyRevoked] && 
            ![key isKeyInvalid] && 
            ![key isKeyDisabled]) {
            return YES;
        }
        
        for (GPGSubkey *aSubkey in [key subkeys]) {
            if (![aSubkey hasKeyExpired] && 
                ![aSubkey isKeyRevoked] && 
                ![aSubkey isKeyInvalid] && 
                ![aSubkey isKeyDisabled]) {
                return YES;
            }
        }
        return NO;
    };
    
    return [[block copy] autorelease];
}


#pragma mark -
#pragma mark Text Stuff

-(NSString *)myFingerprint {
    GPGKey* chosenKey = [GPGServices myPrivateKey];
    
    NSSet* availableKeys = [[GPGServices myPrivateKeys] filteredSetUsingPredicate:
                            [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [GPGServices isActiveValidator]((GPGKey*)evaluatedObject);
    }]];
    
    if(chosenKey == nil || availableKeys.count > 1) {
        KeyChooserWindowController* wc = [[KeyChooserWindowController alloc] init];
        [wc setKeyValidator:[GPGServices isActiveValidator]];
        
        if([wc runModal] == 0) 
            chosenKey = wc.selectedKey;
        else
            chosenKey = nil;
        
        [wc release];
    }
    
    if(chosenKey != nil)
        return [[[chosenKey formattedFingerprint] copy] autorelease];
    else
        return nil;
}


-(NSString *)myKey {
    GPGKey* selectedPrivateKey = [GPGServices myPrivateKey];
    
    NSSet* availableKeys = [[GPGServices myPrivateKeys] filteredSetUsingPredicate:
                            [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [GPGServices isActiveValidator]((GPGKey*)evaluatedObject);
    }]];
    
    if(selectedPrivateKey == nil || availableKeys.count > 1) {
        KeyChooserWindowController* wc = [[KeyChooserWindowController alloc] init];
        [wc setKeyValidator:[GPGServices isActiveValidator]];
        
        if([wc runModal] == 0) 
            selectedPrivateKey = wc.selectedKey;
        else
            selectedPrivateKey = nil;
        
        [wc release];
    }
    
    if(selectedPrivateKey == nil)
        return nil;
    
    GPGContext* ctx = [[GPGContext alloc] init];
    [ctx setUsesArmor:YES];
    [ctx setUsesTextMode:YES];
    
    NSData* keyData = nil;
    @try {
        keyData = [[ctx exportedKeys:[NSArray arrayWithObject:selectedPrivateKey]] data];
        
        if(keyData == nil) {
            [[NSAlert alertWithMessageText:@"Exporting key failed." 
                             defaultButton:@"Ok"
                           alternateButton:nil
                               otherButton:nil
                 informativeTextWithFormat:@"Could not export key %@", [selectedPrivateKey shortKeyID]] 
             runModal];
            
            return nil;
        }
	} @catch(NSException* localException) {
        GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
        [self displayMessageWindowWithTitleText:@"Exporting key failed."
                                       bodyText:GPGErrorDescription(error)];
        return nil;
	} @finally {
        [ctx release];
    }
    
	return [[[NSString alloc] initWithData:keyData 
                                  encoding:NSUTF8StringEncoding] autorelease];
}

-(NSString *)encryptTextString:(NSString *)inputString
{
    GPGContext *aContext = [[GPGContext alloc] init];
    [aContext setUsesArmor:YES];
    
	BOOL trustsAllKeys = YES;
    GPGData *outputData = nil;
    
	RecipientWindowController* rcp = [[RecipientWindowController alloc] init];
	int ret = [rcp runModal];
    [rcp release];
	if(ret != 0) {
		[aContext release];
		return nil;
	} else {
		GPGData *inputData=[[GPGData alloc] initWithDataNoCopy:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
		
		BOOL sign = rcp.sign;
        NSArray* validRecipients = rcp.selectedKeys;
        GPGKey* privateKey = rcp.selectedPrivateKey;

        if(rcp.encryptForOwnKeyToo && privateKey) {
            validRecipients = [[[NSSet setWithArray:validRecipients] 
                                setByAddingObject:[privateKey publicKey]] 
                               allObjects];
        } else {
            validRecipients = [[NSSet setWithArray:validRecipients] allObjects];
        }
            
        if(privateKey == nil) {
            [self displayMessageWindowWithTitleText:@"Encryption failed." 
                                           bodyText:@"No usable private key found"];
            [inputData release];
            [aContext release];
            return nil;
        }
        
        if(validRecipients.count == 0) {
            [self displayMessageWindowWithTitleText:@"Encryption failed."
                                           bodyText:@"No valid recipients found"];

            [inputData release];
            [aContext release];
            return nil;
        }
        
		@try {
            if(sign) {
                [aContext addSignerKey:privateKey];
                outputData=[aContext encryptedSignedData:inputData withKeys:validRecipients trustAllKeys:trustsAllKeys];
            } else {
                outputData=[aContext encryptedData:inputData withKeys:validRecipients trustAllKeys:trustsAllKeys];
            }
		} @catch(NSException* localException) {
            outputData = nil;
            switch(GPGErrorCodeFromError([[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue]))
            {
                case GPGErrorNoData:
                    [self displayMessageWindowWithTitleText:@"Encryption failed."  
                                                   bodyText:@"No encryptable text was found within the selection."];
                    break;
                case GPGErrorCancelled:
                    break;
                default: {
                    GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
                    [self displayMessageWindowWithTitleText:@"Encryption failed."  
                                                   bodyText:GPGErrorDescription(error)];
                }
            }
            return nil;
		} @finally {
            [inputData release];
            [aContext release];
        }
	}
	    
	return [[[NSString alloc] initWithData:[outputData data] encoding:NSUTF8StringEncoding] autorelease];
}

-(NSString *)decryptTextString:(NSString *)inputString
{
    GPGData *outputData = nil;
	GPGContext *aContext = [[GPGContext alloc] init];

	GPGData *inputData=[[GPGData alloc] initWithDataNoCopy:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
    
	@try {
     	[aContext setPassphraseDelegate:self];
        outputData = [aContext decryptedData:inputData];
	} @catch (NSException* localException) {
        outputData = nil;
        switch(GPGErrorCodeFromError([[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue]))
        {
            case GPGErrorNoData:
                [self displayMessageWindowWithTitleText:@"Decryption failed."
                                               bodyText:@"No decryptable text was found within the selection."];
                break;
            case GPGErrorCancelled:
                break;
            default: {
                GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
                [self displayMessageWindowWithTitleText:@"Decryption failed." 
                                               bodyText:GPGErrorDescription(error)];
            }
        }
        return nil;
	} @finally {
        [inputData release];
        [aContext release];
    }
    
	return [[[NSString alloc] initWithData:[outputData data] encoding:NSUTF8StringEncoding] autorelease];
}


-(NSString *)signTextString:(NSString *)inputString
{
	GPGContext *aContext = [[GPGContext alloc] init];
	[aContext setPassphraseDelegate:self];
    
	GPGData *inputData=[[GPGData alloc] initWithDataNoCopy:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
    GPGKey* chosenKey = [GPGServices myPrivateKey];
    
    NSSet* availableKeys = [[GPGServices myPrivateKeys] filteredSetUsingPredicate:
                            [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [GPGServices canSignValidator]((GPGKey*)evaluatedObject);
    }]];
                            
    if(chosenKey == nil || availableKeys.count > 1) {
        KeyChooserWindowController* wc = [[KeyChooserWindowController alloc] init];
        [wc setKeyValidator:[GPGServices canSignValidator]];
             
        if([wc runModal] == 0) 
            chosenKey = wc.selectedKey;
        else
            chosenKey = nil;
        
        [wc release];
    } else if(availableKeys.count == 1) {
        chosenKey = [availableKeys anyObject];
    }
    
    if(chosenKey != nil) {
        [aContext clearSignerKeys];
        [aContext addSignerKey:chosenKey];
    } else {
        [inputData release];
        [aContext release];
        
        return nil;
    }
    
    GPGData *outputData = nil;
	@try {
        outputData = [aContext signedData:inputData signatureMode:GPGSignatureModeClear];
	} @catch(NSException* localException) {
        outputData = nil;
        switch(GPGErrorCodeFromError([[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue]))
        {
            case GPGErrorNoData:
                [self displayMessageWindowWithTitleText:@"Signing failed."
                                               bodyText:@"No signable text was found within the selection."];
                break;
            case GPGErrorBadPassphrase:
                [self displayMessageWindowWithTitleText:@"Signing failed."
                                               bodyText:@"The passphrase is incorrect."];
                break;
            case GPGErrorUnusableSecretKey:
                [self displayMessageWindowWithTitleText:@"Signing failed."
                                               bodyText:@"The default secret key is unusable."];
                break;
            case GPGErrorCancelled:
                break;
            default: {
                GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
                [self displayMessageWindowWithTitleText:@"Signing failed."
                                               bodyText:GPGErrorDescription(error)];
            }
        }
        return nil;
	} @finally {
        [inputData release];
        [aContext release];
    }
    
	return [[[NSString alloc] initWithData:[outputData data] encoding:NSUTF8StringEncoding] autorelease];
}


-(void)verifyTextString:(NSString *)inputString
{
	GPGContext *aContext = [[GPGContext alloc] init];
	GPGData* inputData=[[GPGData alloc] initWithDataNoCopy:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
    
	@try {
        NSArray* sigs = [aContext verifySignedData:inputData originalData:nil];
        
        if([sigs count]>0)
        {
            GPGSignature* sig=[sigs objectAtIndex:0];
            if(GPGErrorCodeFromError([sig status])==GPGErrorNoError)
            {
                NSString* userID = [[aContext keyFromFingerprint:[sig fingerprint] secretKey:NO] userID];
                NSString* validity = [sig validityDescription];
                
                [[NSAlert alertWithMessageText:@"Verification successful."
                                 defaultButton:@"Ok"
                               alternateButton:nil
                                   otherButton:nil
                     informativeTextWithFormat:@"Good signature (%@ trust):\n\"%@\"",validity,userID]
                 runModal];
            }
            else {
                [self displayMessageWindowWithTitleText:@"Verification FAILED."
                                               bodyText:GPGErrorDescription([sig status])];
            }
        }
        else {
            //Looks like sigs.count == 0 when we have encrypted text but no signature
            //[self displayMessageWindowWithTitleText:@"Verification error."
            //                               bodyText:@"Unable to verify due to an internal error"];
            
            [self displayMessageWindowWithTitleText:@"Verification failed." 
                                           bodyText:@"No signatures found within the selection."];
        }
        
	} @catch(NSException* localException) {
        if(GPGErrorCodeFromError([[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue])==GPGErrorNoData)
            [self displayMessageWindowWithTitleText:@"Verification failed." 
                                           bodyText:@"No verifiable text was found within the selection"];
        else {
            GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
            [self displayMessageWindowWithTitleText:@"Verification failed." 
                                           bodyText:GPGErrorDescription(error)];
        }
        return;
	} @finally {
        [inputData release];
        [aContext release];
    }
}

#pragma mark -
#pragma mark File Stuff

- (NSString*)normalizedAndUniquifiedPathFromPath:(NSString*)path {
    NSFileManager* fmgr = [[[NSFileManager alloc] init] autorelease];
    if([fmgr isWritableFileAtPath:[path stringByDeletingLastPathComponent]]) {
        return [ZKArchive uniquify:path];
    } else {
        NSString* desktop = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory,
                                                                 NSUserDomainMask, YES) objectAtIndex:0];
        return [ZKArchive uniquify:[desktop stringByAppendingPathComponent:[path lastPathComponent]]];
    }
}

- (void)detachedSignFile:(NSString*)file withKeys:(NSArray*)keys {
    @try {
        //Generate .sig file
        GPGContext* signContext = [[[GPGContext alloc] init] autorelease];
        [signContext setUsesArmor:YES];
        for(GPGKey* k in keys)
            [signContext addSignerKey:k];
        
        GPGData* dataToSign = [[[GPGData alloc] initWithContentsOfFile:file] autorelease];
        GPGData* signData = [signContext signedData:dataToSign signatureMode:GPGSignatureModeDetach];
        
        NSString* sigFile = [file stringByAppendingPathExtension:@"sig"];
        [[signData data] writeToFile:sigFile atomically:YES];
    } @catch (NSException* e) {
        [GrowlApplicationBridge notifyWithTitle:@"Signing failed"
                                    description:[file lastPathComponent]
                               notificationName:@"SigningFileFailed"
                                       iconData:[NSData data]
                                       priority:0
                                       isSticky:NO
                                   clickContext:file];
        
    }
}

- (void)signFiles:(NSArray*)files {     
    GPGKey* chosenKey = [GPGServices myPrivateKey];
    
    NSSet* availableKeys = [[GPGServices myPrivateKeys] filteredSetUsingPredicate:
                            [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [GPGServices canSignValidator]((GPGKey*)evaluatedObject);
    }]];
    
    if(chosenKey == nil || availableKeys.count > 1) {
        KeyChooserWindowController* wc = [[KeyChooserWindowController alloc] init];
        [wc setKeyValidator:[GPGServices canSignValidator]];
        
        if([wc runModal] == 0) 
            chosenKey = wc.selectedKey;
        else
            chosenKey = nil;
        
        [wc release];
    } else if(availableKeys.count == 1) {
        chosenKey = [availableKeys anyObject];
    }
    
    //For now, don't sign directories
    NSFileManager* fmgr = [[[NSFileManager alloc] init] autorelease];
    files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id file, NSDictionary *bindings) {
        BOOL isDir = YES;
        BOOL exists = [fmgr fileExistsAtPath:(NSString*)file isDirectory:&isDir];
        
        if(isDir) {
            [GrowlApplicationBridge notifyWithTitle:@"Can't sign file"
                                        description:[NSString stringWithFormat:@"%@ is a directory.", [file lastPathComponent]]
                                   notificationName:@"FileToSignIsDirectory"
                                           iconData:[NSData data]
                                           priority:0
                                           isSticky:NO
                                       clickContext:file];
        }
        
        return exists && !isDir;
    }]];
    
    if(files.count == 0)
        return;
    
    if(chosenKey != nil)
        for(NSString* file in files) 
            [self detachedSignFile:file withKeys:[NSArray arrayWithObject:chosenKey]];
    
    [GrowlApplicationBridge notifyWithTitle:@"Signing finished"
                                description:[NSString stringWithFormat:@"Finished signing %i file(s)", files.count]
                           notificationName:@"SigningSucceeded"
                                   iconData:[NSData data]
                                   priority:0
                                   isSticky:NO
                               clickContext:files];
}

- (GPGData*)signedGPGDataForGPGData:(GPGData*)dataToSign withKeys:(NSArray*)keys {
    @try {
        GPGContext* signContext = [[[GPGContext alloc] init] autorelease];
        for(GPGKey* k in keys)
            [signContext addSignerKey:k];
        
        return [signContext signedData:dataToSign signatureMode:GPGSignatureModeNormal];
    } @catch (NSException* e) {
        NSLog(@"error in signedGPGDataForGPGData: %@", [e description]);
    }
    
    return nil;
}

- (void)encryptFiles:(NSArray*)files {
    BOOL trustAllKeys = YES;
    
    NSLog(@"encrypting file(s): %@...", [files componentsJoinedByString:@","]);
    
    if(files.count == 0)
        return;

    RecipientWindowController* rcp = [[RecipientWindowController alloc] init];
	int ret = [rcp runModal];
    [rcp release];
	if(ret != 0) {
        //User pressed 'cancel'
		return;
	} else {
    	BOOL sign = rcp.sign;
        NSArray* validRecipients = rcp.selectedKeys;
        GPGKey* privateKey = rcp.selectedPrivateKey;
        
        if(rcp.encryptForOwnKeyToo && privateKey) {
            validRecipients = [[[NSSet setWithArray:validRecipients] 
                                setByAddingObject:[privateKey publicKey]] 
                               allObjects];
        } else {
            validRecipients = [[NSSet setWithArray:validRecipients] allObjects];
        }

        GPGData* gpgData = nil;
        double megabytes = 0;
        NSString* destination = nil;
        
        NSFileManager* fmgr = [[[NSFileManager alloc] init] autorelease];
        
        if(files.count == 1) {
            NSString* file = [files objectAtIndex:0];
            BOOL isDirectory = YES;
            BOOL exists = [fmgr fileExistsAtPath:file isDirectory:&isDirectory];
            
            if(exists && isDirectory) {
                ZipOperation* operation = [[ZipOperation alloc] init];
                operation.filePath = file;
                operation.delegate = self;
                [operation start];

                NSString* filename = [NSString stringWithFormat:@"%@.zip.gpg", [file lastPathComponent]];
                megabytes = [operation.zipData length] / 1048576.0;
                destination = [[file stringByDeletingLastPathComponent] stringByAppendingPathComponent:filename];
                gpgData = [[[GPGData alloc] initWithData:operation.zipData] autorelease];
                
                [operation release];
            } else if(exists) {
                NSError* error = nil;
                NSNumber* fileSize = [[fmgr attributesOfItemAtPath:file error:&error] valueForKey:NSFileSize];
                megabytes = [fileSize doubleValue] / 1048576;
                destination = [file stringByAppendingString:@".gpg"];
                gpgData = [[[GPGData alloc] initWithContentsOfFile:file] autorelease];
            } else {    
                [self displayMessageWindowWithTitleText:@"File doesn't exist"
                                               bodyText:@"Please try again"];
                return;
            }
        } else if(files.count > 1) {
            ZipOperation* operation = [[ZipOperation alloc] init];
            operation.files = files;
            operation.delegate = self;
            [operation start];
            
            
            megabytes = [operation.zipData length] / 1048576.0;
            destination = [[[files objectAtIndex:0] stringByDeletingLastPathComponent] 
                           stringByAppendingPathComponent:@"Archive.zip.gpg"];
            gpgData = [[[GPGData alloc] initWithData:operation.zipData] autorelease];
            
            [operation release];
        }
        
        //Check if directory is writable and append i+1 if file already exists at destination
        destination = [self normalizedAndUniquifiedPathFromPath:destination];
        
        NSLog(@"destination: %@", destination);
        NSLog(@"fileSize: %@Mb", [NSNumberFormatter localizedStringFromNumber:[NSNumber numberWithDouble:megabytes]
                                                                  numberStyle:NSNumberFormatterDecimalStyle]);        
        NSLog(@"gpgData.length: %lld", [gpgData length]);
        
        if(megabytes > 10) {
            int ret = [[NSAlert alertWithMessageText:@"Large File"
                                       defaultButton:@"Continue"
                                     alternateButton:@"Cancel"
                                         otherButton:nil
                           informativeTextWithFormat:@"Encryption will take a long time.\nPress 'Cancel' to abort."] 
                       runModal];
            
            if(ret == NSAlertAlternateReturn)
                return;
        }

        GPGContext* ctx = [[[GPGContext alloc] init] autorelease];

        GPGData* encrypted = nil;
        if(sign == YES && privateKey != nil) 
            encrypted = [ctx encryptedSignedData:gpgData
                                        withKeys:validRecipients 
                                    trustAllKeys:trustAllKeys];
        else
            encrypted = [ctx encryptedData:gpgData 
                                  withKeys:validRecipients
                              trustAllKeys:trustAllKeys];
        
        if(encrypted == nil) {
            [GrowlApplicationBridge notifyWithTitle:@"Signing failed"
                                        description:destination
                                   notificationName:@"SigningFileFailed"
                                           iconData:[NSData data]
                                           priority:0
                                           isSticky:NO
                                       clickContext:destination];
        } else {
            [encrypted.data writeToFile:destination atomically:YES];
            
            [GrowlApplicationBridge notifyWithTitle:@"Encryption finished"
                                        description:[destination lastPathComponent]
                                   notificationName:@"EncryptionSucceeded"
                                           iconData:[NSData data]
                                           priority:0
                                           isSticky:NO
                                       clickContext:destination];
        }
    }
}


- (void)decryptFiles:(NSArray*)files {
	GPGContext *aContext = [[[GPGContext alloc] init] autorelease];

    //For now, don't sign directories
    NSFileManager* fmgr = [[[NSFileManager alloc] init] autorelease];
    if(files.count == 0)
        return;
    
    [aContext setPassphraseDelegate:self];
    
    for(NSString* file in files) {
        BOOL isDirectory = NO;
        @try {
            if([fmgr fileExistsAtPath:file isDirectory:&isDirectory] &&
               isDirectory == NO) {
                NSLog(@"file: %@", file);
                
                GPGData* inputData = [[[GPGData alloc] initWithContentsOfFile:file] autorelease];
                NSLog(@"inputData.size: %lld", [inputData length]);
                
                GPGData* outputData = [aContext decryptedData:inputData];
            
                NSString* outputFile = [self normalizedAndUniquifiedPathFromPath:[file stringByDeletingPathExtension]];
                NSLog(@"writing decrypted data to file: %@", outputFile);
                
                NSError* error = nil;
                [outputData.data writeToFile:outputFile options:NSDataWritingAtomic error:&error];
                
                if(error != nil) 
                    NSLog(@"error!: %@", error);
            }
        } @catch (NSException* localException) {
            switch(GPGErrorCodeFromError([[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue])) {
                case GPGErrorNoData:
                    [self displayMessageWindowWithTitleText:@"Decryption failed."
                                                   bodyText:@"No decryptable data was found."];
                    break;
                case GPGErrorCancelled:
                    break;
                default: {
                    GPGError error = [[[localException userInfo] objectForKey:@"GPGErrorKey"] intValue];
                    [self displayMessageWindowWithTitleText:@"Decryption failed." 
                                                   bodyText:GPGErrorDescription(error)];
                }
            }
        } 
    }
    
    [GrowlApplicationBridge notifyWithTitle:@"Decryption finished"
                                description:[NSString stringWithFormat:@"Finished decrypting %i file(s)", files.count]
                           notificationName:@"DecryptionSucceeded"
                                   iconData:[NSData data]
                                   priority:0
                                   isSticky:NO
                               clickContext:files];

}

#pragma mark -
#pragma mark Service handling routines

-(void)dealWithPasteboard:(NSPasteboard *)pboard
                 userData:(NSString *)userData
                     mode:(ServiceModeEnum)mode
                    error:(NSString **)error {
	[self cancelTerminateTimer];
	[NSApp activateIgnoringOtherApps:YES];
    
    NSString *pboardString = nil;
	if(mode!=MyKeyService && mode!=MyFingerprintService)
	{
		NSString* type = [pboard availableTypeFromArray:[NSArray arrayWithObjects:
                                                         NSStringPboardType, 
                                                         NSRTFPboardType,
                                                         NSFilenamesPboardType, 
                                                         nil]];
        
        if([type isEqualToString:NSStringPboardType])
		{
			if(!(pboardString = [pboard stringForType:NSStringPboardType]))
			{
				*error=[NSString stringWithFormat:@"Error: Could not perform GPG operation. Pasteboard could not supply text string."];
				[self exitServiceRequest];
				return;
			}
		}
		else if([type isEqualToString:NSRTFPboardType])
		{
			if(!(pboardString = [pboard stringForType:NSStringPboardType]))
			{
				*error=[NSString stringWithFormat:@"Error: Could not perform GPG operation. Pasteboard could not supply text string."];
				[self exitServiceRequest];
				return;
			}
		}
		else
		{
			*error = NSLocalizedString(@"Error: Could not perform GPG operation.", @"Pasteboard could not supply the string in an acceptible format.");
			[self exitServiceRequest];
			return;
		}
	}
    
    NSString *newString=nil;
	switch(mode)
	{
		case SignService:
			newString=[self signTextString:pboardString];
			break;
	    case EncryptService:
	        newString=[self encryptTextString:pboardString];
			break;
	    case DecryptService:
	        newString=[self decryptTextString:pboardString];
			break;
		case VerifyService:
			[self verifyTextString:pboardString];
			break;
		case MyKeyService:
			newString=[self myKey];
			break;
		case MyFingerprintService:
			newString=[self myFingerprint];
			break;
		case ImportKeyService:
			[self importKey:pboardString];
			break;
        default:
            break;
	}
    
	if(newString!=nil)
	{
		[pboard declareTypes:[NSArray arrayWithObjects:NSStringPboardType,NSRTFPboardType,nil] owner:nil];
		[pboard setString:newString forType:NSStringPboardType];
   		[pboard setString:newString forType:NSRTFPboardType];
	}
	[self exitServiceRequest];
}

-(void)dealWithFilesPasteboard:(NSPasteboard *)pboard
                      userData:(NSString *)userData
                          mode:(FileServiceModeEnum)mode
                         error:(NSString **)error {
    [self cancelTerminateTimer];
	[NSApp activateIgnoringOtherApps:YES];
    
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    NSData *data = [pboard dataForType:NSFilenamesPboardType];
    
    NSString* fileErrorStr = nil;
    NSArray *filenames = [NSPropertyListSerialization
                          propertyListFromData:data
                          mutabilityOption:kCFPropertyListImmutable
                          format:nil
                          errorDescription:&fileErrorStr];
    if(fileErrorStr) {
        NSLog(@"error while getting files form pboard: %@", fileErrorStr);
        *error = fileErrorStr;
    } else {
        switch(mode) {
            case SignFileService:
                [self signFiles:filenames];
                break;
            case EncryptFileService:
                [self encryptFiles:filenames];
                break;
            case DecryptFileService:
                [self decryptFiles:filenames];
                break;
            default:
                break;
        }
    }
    
    [pool release];
    
    [self exitServiceRequest];
}

-(void)exitServiceRequest
{
	[NSApp hide:self];
	[self goneIn60Seconds];
}

-(void)sign:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:SignService error:error];}

-(void)encrypt:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:EncryptService error:error];}

-(void)decrypt:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:DecryptService error:error];}

-(void)verify:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:VerifyService error:error];}

-(void)myKey:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:MyKeyService error:error];}

-(void)myFingerprint:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:MyFingerprintService error:error];}

-(void)importKey:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithPasteboard:pboard userData:userData mode:ImportKeyService error:error];}

-(void)signFile:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error 
{[self dealWithFilesPasteboard:pboard userData:userData mode:SignFileService error:error];}

-(void)encryptFile:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{[self dealWithFilesPasteboard:pboard userData:userData mode:EncryptService error:error];}

-(void)decryptFile:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error 
{[self dealWithFilesPasteboard:pboard userData:userData mode:DecryptFileService error:error];}


#pragma mark -
#pragma mark UI Helpher

- (NSURL*)getFilenameForSavingWithSuggestedPath:(NSString*)path 
                         withSuggestedExtension:(NSString*)ext {    
    NSSavePanel* savePanel = [NSSavePanel savePanel];
    savePanel.title = @"Choose Destination";
    savePanel.directory = [path stringByDeletingLastPathComponent];
    
    if(ext == nil)
        ext = @".gpg";
    [savePanel setNameFieldStringValue:[[path lastPathComponent] 
                                        stringByAppendingString:ext]];
    
    if([savePanel runModal] == NSFileHandlingPanelOKButton)
        return savePanel.URL;
    else
        return nil;
}


-(void)displayMessageWindowWithTitleText:(NSString *)title bodyText:(NSString *)body {
    [[NSAlert alertWithMessageText:title
                    defaultButton:@"Ok"
                  alternateButton:nil
                      otherButton:nil
         informativeTextWithFormat:[NSString stringWithFormat:@"%@", body]] runModal];
}

-(NSString *)context:(GPGContext *)context passphraseForKey:(GPGKey *)key again:(BOOL)again
{
	[passphraseText setStringValue:@""];
	int flag=[NSApp runModalForWindow:passphraseWindow];
	NSString *passphrase=[[[passphraseText stringValue] copy] autorelease];
	[passphraseWindow close];
	if(flag)
		return passphrase;
	else
		return nil;
}


-(IBAction)closeModalWindow:(id)sender{
	[NSApp stopModalWithCode:[sender tag]];
}

//
//Timer based application termination
//
-(void)cancelTerminateTimer
{
	[currentTerminateTimer invalidate];
	currentTerminateTimer=nil;
}

-(void)goneIn60Seconds
{
	if(currentTerminateTimer!=nil)
		[self cancelTerminateTimer];
	currentTerminateTimer=[NSTimer scheduledTimerWithTimeInterval:60.0 target:self selector:@selector(selfQuit:) userInfo:nil repeats:NO];
}

-(void)selfQuit:(NSTimer *)timer
{
	[NSApp terminate:self];
}

@end
