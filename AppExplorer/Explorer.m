// Copyright (c) 2006-2015 Simon Fell
//
// Permission is hereby granted, free of charge, to any person obtaining a 
// copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the 
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included 
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
// THE SOFTWARE.
//

#import "Explorer.h"
#import "ReportDocument.h"
#import "detailsController.h"
#import "ZKLoginController.h"
#import "EditableQueryResultWrapper.h"
#import "QueryResultTable.h"
#import "QueryListController.h"
#import "ApexController.h"
#import "zkSforce.h"
#import "ResultsSaver.h"
#import "BulkDelete.h"
#import "SearchQueryResult.h"
#import "ZKDescribeThemeItem+ZKFindResource.h"
#import "Prefs.h"

static NSString *schemaTabId = @"schema";
static CGFloat MIN_PANE_SIZE = 128.0f;
static NSString *KEYPATH_WINDOW_VISIBLE = @"windowVisible";

@interface Explorer ()
- (IBAction)initUi:(id)sender;
- (IBAction)postLogin:(id)sender;
- (void)closeLoginPanelIfOpen:(id)sender;

- (void)setSoqlString:(NSString *)soql;
- (NSString *)soqlString;

- (void)colorize;

- (void)describeFinished:(NSNotification *)notification;

- (void)collapseChildTableView;
- (void)openChildTableView;

@property (retain) NSMutableArray *selectedFields;
@property (retain) NSString *selectedObjectName;

@property (retain) NSString *previouslyColorized;
@property (retain) ZKDescribeGlobalSObject *previousColorizedDescribe;
@end


@interface ColorizerStyle : NSObject

@property (retain) NSColor *fieldColor;
@property (retain) NSColor *keywordColor;
@property (retain) NSNumber *underlineStyle;
@property (retain) NSDictionary *underlined;
@property (retain) NSDictionary *noUnderline;

+(ColorizerStyle *)style;

@end

@implementation ColorizerStyle

@synthesize fieldColor, keywordColor, underlineStyle, underlined, noUnderline;

-(id)init {
    self = [super init];
    self.keywordColor = [NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.8 alpha: 1.0];
    self.fieldColor = [NSColor colorWithCalibratedRed:0.8 green:0.25 blue:0.25 alpha: 1.0];
    
    self.underlineStyle = [NSNumber numberWithInt:(NSUnderlineStyleSingle | NSUnderlinePatternDot | NSUnderlineByWordMask)];
    NSMutableDictionary *u = [NSMutableDictionary dictionary];
    [u setObject:underlineStyle forKey:NSUnderlineStyleAttributeName];
    [u setObject:[NSColor redColor] forKey:NSUnderlineColorAttributeName];
    self.underlined = [NSDictionary dictionaryWithDictionary:u];
    
    NSMutableDictionary *nu = [NSMutableDictionary dictionary];
    [nu setObject:[NSNumber numberWithInt:NSUnderlineStyleNone] forKey:NSUnderlineStyleAttributeName];
    self.noUnderline = [NSDictionary dictionaryWithDictionary:nu];
    return self;
}

+(ColorizerStyle *)style {
    static ColorizerStyle *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ColorizerStyle alloc] init];
    });
    return instance;
}
 
@end

@implementation Explorer

@synthesize statusText, schemaViewIsActive, apiCallCountText, selectedObjectName, selectedFields, previouslyColorized, previousColorizedDescribe;

+ (void)initialize {
	NSMutableDictionary * defaults = [NSMutableDictionary dictionary];
	[defaults setObject:[NSNumber numberWithBool:NO] forKey:@"details"];
	[defaults setObject:@"select id, firstname, lastname from contact" forKey:@"soql"];

	NSString *prod = @"https://www.salesforce.com";
	NSString *test = @"https://test.salesforce.com";
	
	NSMutableArray * defaultServers = [NSMutableArray arrayWithObjects:prod, test, nil];
	[defaults setObject:defaultServers forKey:@"servers"];
	[defaults setObject:prod forKey:@"server"];
    [defaults setObject:[NSNumber numberWithBool:YES] forKey:PREF_QUERY_SORT_FIELDS];
    [defaults setObject:[NSNumber numberWithBool:NO] forKey:PREF_SKIP_ADDRESS_FIELDS];
    [defaults setObject:[NSNumber numberWithInt:9] forKey:PREF_TEXT_SIZE];
    [defaults setObject:[NSNumber numberWithBool:YES] forKey:PREF_SORTED_FIELD_LIST];
    [defaults setObject:[NSNumber numberWithBool:YES] forKey:PREF_QUIT_ON_LAST_WINDOW_CLOSE];
    
	[[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

+(NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    NSSet *paths = [super keyPathsForValuesAffectingValueForKey:key];
    if ([key isEqualToString:@"canQueryMore"])
        return [paths setByAddingObjectsFromArray:[NSArray arrayWithObjects:@"currentResults", @"rowsLoadedStatusText", nil]];
    return paths;
}

-(void)updateMenuState {
    NSInteger currentSize = [[[NSUserDefaults standardUserDefaults] objectForKey:PREF_TEXT_SIZE] intValue];
    for (NSMenuItem *i in [soqlContextMenu itemArray]) {
        for (NSMenuItem *c in [[i submenu] itemArray]) {
            if ([c target] == nil) {
                [c setAction:@selector(updateQueryTextFontSize:)];
                [c setTarget:self];
            }
            [c setState:[c tag] == currentSize ? NSOnState : NSOffState];
        }
    }
}

- (void)awakeFromNib {
	[myWindow setContentBorderThickness:28.0 forEdge:NSMinYEdge]; 	
	[myWindow setContentBorderThickness:28.0 forEdge:NSMaxYEdge]; 	
    [myWindow setDelegate:self];
    [soql setEnabledTextCheckingTypes:0];
    
	// Turn on full-screen option in Lion
	//if ([myWindow respondsToSelector:@selector(setCollectionBehavior:)]) {
	//	[myWindow setCollectionBehavior:[myWindow collectionBehavior] | (1 << 7)];
	//}
	
	[soqlSchemaTabs setDelegate:self];
	[soqlHeader setHeaderText:@"Query"];
	[self setStatusText:@""];
	
	[progress setUsesThreadedAnimation:YES];
	[describeList setDoubleAction:@selector(describeItemClicked:)];	
	[rootTableView setTarget:self];
	[rootTableView setDoubleAction:@selector(queryResultDoubleClicked:)];
	rootResults = [[QueryResultTable alloc] initForTableView:rootTableView];
	[rootResults setDelegate:self];
	[rootResults addObserver:self forKeyPath:@"hasCheckedRows" options:0 context:nil];
	childResults = [[QueryResultTable alloc] initForTableView:childTableView];
	[childResults setDelegate:self];
	[self collapseChildTableView];
	[self updateMenuState];
    [self performSelector:@selector(initUi:) withObject:nil afterDelay:0];
       
    [queryListController setDelegate:self];
    [queryListController addObserver:self forKeyPath:KEYPATH_WINDOW_VISIBLE options:NSKeyValueObservingOptionNew context:nil];
    [queryListController retain];
    [detailsController addObserver:self forKeyPath:KEYPATH_WINDOW_VISIBLE options:NSKeyValueObservingOptionNew context:nil];
    [detailsController retain];
}

- (void)dealloc {
    [detailsController removeObserver:self forKeyPath:KEYPATH_WINDOW_VISIBLE];
    [detailsController autorelease];
    [queryListController removeObserver:self forKeyPath:KEYPATH_WINDOW_VISIBLE];
    [queryListController release];
    [selectedFields release];
    [selectedObjectName release];
	[sforce release];
	[descDataSource release];
	[loginController release];
	[statusText release];
	[rootResults removeObserver:self forKeyPath:@"hasCheckedRows"];
	[rootResults release];
	[childResults release];
    self.previouslyColorized = nil;
    self.previousColorizedDescribe= nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
	[super dealloc];
}

- (void)windowWillClose:(NSNotification *)notification {
    [descDataSource stopBackgroundDescribe];
}

-(void)updateQueryTextFontSize:(id)sender {
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:[sender tag]] forKey:PREF_TEXT_SIZE];
    [self updateMenuState];
    [self colorize];    
}

-(void)updateCallCount:(ZKSforceClient *)c {
    ZKLimitInfoHeader *h = [c lastLimitInfoHeader];
    ZKLimitInfo *api = [h limitInfoOfType:@"API REQUESTS"];
    NSString *newVal = (api == nil) ? nil : [NSString stringWithFormat:@"Org API calls %d/%d", [api current], [api limit]];
    if ([NSThread isMainThread])
        self.apiCallCountText = newVal;
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apiCallCountText = newVal;
        });
    }
}

- (void)collapseChildTableView {
	if (![soqlTextSplitView isSubviewCollapsed:[[childTableView superview] superview]]) {
		NSRect viewFrame = [[[childTableView superview] superview] frame];
		uncollapsedDividerPosition = viewFrame.origin.y + viewFrame.size.height;
		[soqlTextSplitView setPosition:[soqlTextSplitView maxPossiblePositionOfDividerAtIndex:1] ofDividerAtIndex:1];
	}
}

- (void)openChildTableView {
	if ([soqlTextSplitView isSubviewCollapsed:[[childTableView superview] superview]]) {
		CGFloat p = [soqlTextSplitView maxPossiblePositionOfDividerAtIndex:1] - MIN_PANE_SIZE;
		[soqlTextSplitView setPosition:p ofDividerAtIndex:1];
	}
}

- (IBAction)initUi:(id)sender {
	[self setSoqlString:[[NSUserDefaults standardUserDefaults] stringForKey:@"soql"]];
    [self performSelector:@selector(showLogin:) withObject:nil afterDelay:0];
}

- (IBAction)showLogin:(id)sender {
	[loginController release];
	loginController = [[ZKLoginController alloc] init];
	[loginController setClientIdFromInfoPlist];
    [loginController setDelegate:self];
	NSNumber *apiVersion = [[NSUserDefaults standardUserDefaults] objectForKey:@"zkApiVersion"];
	if (apiVersion != nil)
		[loginController setPreferedApiVersion:[apiVersion intValue]];
	[loginController showLoginSheet:myWindow target:self selector:@selector(loginComplete:)];
}

-(void)loginControllerLoginCancelled:(ZKLoginController *)controller {
    [myWindow close];
}

- (void)loginComplete:(ZKSforceClient *)sf {
	[sforce release];
	sforce = [sf retain];
    [sforce setDelegate:self];
	[loginController release];
	loginController = nil;
    [self performSelector:@selector(postLogin:) withObject:nil afterDelay:0];
}

- (void)closeLoginPanelIfOpen:(id)sender {
	[loginController cancelLogin:sender];
}

- (BOOL)isLoggedIn {
	return [sforce loggedIn];
}

// returns the urlNew pattern from any sobject we can find it in, starting with those we've already described.
-(NSString *)urlNewForAnyType {
    for (ZKDescribeGlobalSObject *obj in [descDataSource SObjects]) {
        if ([descDataSource hasDescribe:[obj name]]) {
            ZKDescribeSObject *desc = [descDataSource describe:[obj name]];
            if ([desc urlNew] != nil)
                return [desc urlNew];
        }
    }
    // not found in what we already have, going to have to make an actual describe call, try a custom object first
    for (ZKDescribeGlobalSObject *obj in [descDataSource SObjects]) {
        if ([obj custom])
            return [[descDataSource describe:[obj name]] urlNew];
    }
    // no custom objects, try some well know ones that we know have urlNew set
    NSArray *wellKnown = [NSArray arrayWithObjects:@"Task", @"Event", @"Contact", @"Account", @"Case", @"User", nil];
    for (NSString *type in wellKnown) {
        NSString *url = [[descDataSource describe:type] urlNew];
        if (url != nil) return url;
    }
    // sheesh, still not found, try every type we know about
    for (ZKDescribeGlobalSObject *obj in [descDataSource SObjects]) {
        NSString *url = [[descDataSource describe:[obj name]] urlNew];
        if (url != nil) return url;
    }
    return nil; // give up
}

- (void)launchSfdcBrowser:(NSString *)retUrl {
	NSURL *url = [NSURL URLWithString:[self urlNewForAnyType]];
	NSURL *baseUiUrl = [NSURL URLWithString:@"/" relativeToURL:url];
	retUrl = retUrl == nil ? @"" : [NSString stringWithFormat:@"&retURL=%@", retUrl];
	NSURL *fd = [NSURL URLWithString:[NSString stringWithFormat:@"/secur/frontdoor.jsp?sid=%@%@", [sforce sessionId], retUrl] relativeToURL:baseUiUrl];
	[[NSWorkspace sharedWorkspace] openURL:fd];
}

- (IBAction)showInBrowser:(id)sender {
	[self launchSfdcBrowser:nil];
}

- (void)updateProgress:(BOOL)show {
	[progress setDoubleValue:show ? 50 : 0];
	if (show)
		[progress startAnimation:self];
	else
		[progress stopAnimation:self];
	[progress setHidden:!show];
	[progress display];
}

- (IBAction)postLogin:(id)sender {
	NSString *msg = [NSString stringWithFormat:@"Welcome %@ (instance:%@)",
                        [[sforce currentUserInfo] fullName],
                        [[sforce serverUrl] host]];
	[self setStatusText:msg];
    
    NSString *title = [NSString stringWithFormat:@"SoqlX : %@ (%@ on %@)",
                       [[sforce currentUserInfo] fullName],
                       [[sforce currentUserInfo] userName],
                       [sforce serverHostAbbriviation]];
    [myWindow setTitle:title];
    NSString *userId = [[sforce currentUserInfo] userId];
	[queryListController setPrefsPrefix:userId];
    [detailsController setPrefsPrefix:userId];

	[descDataSource release];
	descDataSource = [[DescribeListDataSource alloc] init];
	[apexController setSforceClient:sforce];
	[descDataSource setSforce:sforce];
	[describeList setDataSource:descDataSource];
	[describeList setDelegate:descDataSource];
	[describeList reloadData];

	[schemaController setDescribeDataSource:descDataSource];
	[self colorize];
	[self updateProgress:NO];
	[self willChangeValueForKey:@"isLoggedIn"];
	[self didChangeValueForKey:@"isLoggedIn"];
	[rootResults setQueryResult:nil];
	[childResults setQueryResult:nil];

    [sforce performDescribeGlobalThemeWithFailBlock:^(NSException *result) {
        NSLog(@"error doing descGT %@", result);
    } completeBlock:^(ZKDescribeGlobalTheme *result) {
        [self willChangeValueForKey:@"SObjects"];
        [descDataSource setTypes:result view:describeList];
        [self didChangeValueForKey:@"SObjects"];
    }];
}

- (void)setSoqlString:(NSString *)str {
	[[soql textStorage] setAttributedString:[[[NSAttributedString alloc] initWithString:str] autorelease]];
    self.previouslyColorized = nil;
    self.previousColorizedDescribe = nil;
	[self colorize];
}

- (void)queryTextListView:(QueryTextListView *)listView itemClicked:(QueryTextListViewItem *)item {
	NSString *t = [item text];
	if (t == nil || [t length] == 0) return;
	[self setSoqlString:t];
}

- (NSString *)soqlString {
	return [[soql textStorage] string];
}

typedef enum SoqlParsePosition {
	sppStart,
	sppFields,
	sppFrom,
	sppWhere,
	sppWhereAndOr,
	sppWhereNot,
	sppWhereField,
	sppWhereOperator,
	sppWhereLiteral
} SoqlParsePosition;
	
-(void)textDidChange:(NSNotification *)notification {
    [self colorize];
}

-(void)describeFinished:(NSNotification *)notification {
	[self performSelectorOnMainThread:@selector(colorize) withObject:nil waitUntilDone:NO];
}

- (void)enumerateWordsInString:(NSString *)s withBlock:(void(^)(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop)) block {
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByWords | NSStringEnumerationLocalized
                       usingBlock:block];
}

- (NSString *)parseEntityName:(NSString *)soqlText {
    __block NSString *entity = nil;
	__block BOOL atFrom = NO;
    [self enumerateWordsInString:soqlText withBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        if (atFrom) {
            entity = [substring retain];
            *stop = YES;
            
        } else if (NSOrderedSame == [substring caseInsensitiveCompare:@"from"]) {
            atFrom = YES;
        }
    }];
    return [entity autorelease];
}

- (void)colorize {
    ColorizerStyle *style = [ColorizerStyle style];
	
    NSTextStorage *soqlTextStorage = [soql textStorage];
    NSString *soqlText = [soqlTextStorage string];
    float fontSize = [[[NSUserDefaults standardUserDefaults] valueForKey:PREF_TEXT_SIZE] floatValue];
    
    NSFont *font = [NSFont fontWithName:@"Monaco" size:fontSize];
    
    if (font == nil) {
        NSLog(@"userFixedPitchFontOfSize:%f returned nil!", fontSize);
    } else {
        [soqlTextStorage setFont:font];
    }
    
	NSString *entity = [self parseEntityName:soqlText];
	ZKDescribeSObject *desc = nil;
	if (entity != nil) {
		if ([descDataSource hasDescribe:entity])
			desc = [descDataSource describe:entity];
		else if ([descDataSource isTypeDescribable:entity]) {
			[descDataSource prioritizeDescribe:entity];
		}
	}
	__block SoqlParsePosition p = sppStart;

    // we can skip setting the text attributes on anything that appears before this cut off as its the same as what we did last time around.
    NSUInteger alreadyProcessed = [soqlText commonPrefixWithString:self.previouslyColorized options:0].length;
    // when the desribe turns up, start again
    if (self.previousColorizedDescribe != desc)
        alreadyProcessed = 0;

    [self enumerateWordsInString:soqlText withBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        BOOL isKeyword = NO, underline = NO;
		if (p == sppStart && NSOrderedSame == [substring caseInsensitiveCompare:@"select"]) {
			p = sppFields;
			isKeyword = YES;
		} else if (p == sppFields) {
			if (NSOrderedSame == [substring caseInsensitiveCompare:@"from"]) {
				p = sppFrom;
				isKeyword = YES;
			} else { 
				if (desc != nil && [desc fieldWithName:substring] == nil) underline = YES;
			}
		} else if (p == sppFrom) {
			if (NSOrderedSame == [substring caseInsensitiveCompare:@"where"]) {
				p = sppWhere;
				isKeyword = YES;
			} else if (desc == nil) {
				underline = YES;
			}
		} else if (p == sppWhere || p == sppWhereLiteral || p == sppWhereAndOr) {
			if (NSOrderedSame == [substring caseInsensitiveCompare:@"not"]) {
				p = sppWhereNot;
				isKeyword = YES;
			} else if ((NSOrderedSame == [substring caseInsensitiveCompare:@"and"]) || (NSOrderedSame == [substring caseInsensitiveCompare:@"or"])) {
				p = sppWhereAndOr;
				isKeyword = YES;
			} else {
				p = sppWhereField;
				if (desc != nil && [desc fieldWithName:substring] == nil) underline = YES;
			}
		} else if (p == sppWhereNot) {
			p = sppWhereField;
			if (desc != nil && [desc fieldWithName:substring] == nil) underline = YES;
		} else if (p == sppWhereField) {
			p = sppWhereOperator;
			isKeyword = YES;
		} else if (p == sppWhereOperator) {
			p = sppWhereLiteral;
		} else if (p == sppWhereLiteral) {
			p = sppWhere;
		}

        if ((substringRange.length + substringRange.location) >= alreadyProcessed) {
            // These 2 calls are the expensive part of this, so only do them once we past the comon prefix of what we processed last time [as that won't change]
            [soqlTextStorage addAttributes:underline ? style.underlined : style.noUnderline range:substringRange];
            [soqlTextStorage addAttribute:NSForegroundColorAttributeName value:isKeyword ? style.keywordColor : style.fieldColor range:substringRange];
        }
    }];
    self.previouslyColorized = [NSString stringWithString:soqlText];
    self.previousColorizedDescribe = desc;
}

-(NSString *)removeSuffix:(NSString *)suffix from:(NSString *)src {
    if ([src hasSuffix:suffix])
        return [src substringToIndex:[src length] - [suffix length]];
    return src;
}

-(void)addSuffixes:(NSString *)prefix suffixes:(NSArray *)suffixes to:(NSMutableSet *)col {
    for (NSString *s in suffixes)
        [col addObject:[prefix stringByAppendingString:s]];
}

- (IBAction)describeItemClicked:(id)sender {
    if(selectedFields == nil) {
        selectedFields = [[NSMutableArray alloc] init];
    }
    ZKDescribeSObject * d;
    id selectedItem = [describeList itemAtRow:[describeList selectedRow]];
    
    if ([selectedItem isKindOfClass:[ZKDescribeField class]]) {
        if (![selectedObjectName isEqualToString:[(ZKDescribeGlobalSObject *)[selectedItem sobject] name]]) {
            [selectedFields removeAllObjects];
        }
        self.selectedObjectName = [(ZKDescribeGlobalSObject *)[selectedItem sobject] name];
        if ([selectedFields containsObject:selectedItem]) {
            [selectedFields removeObject:selectedItem];
        } else {
            [selectedFields addObject:selectedItem];
        }
        
    } else {
        self.selectedObjectName = [selectedItem name];
        d = [descDataSource describe:selectedObjectName];
        [selectedFields removeAllObjects];
        [selectedFields addObjectsFromArray:[d fields]];
    }
    
    NSMutableString * query = [NSMutableString string];
    [query appendString:@"select"];
    
    NSArray *fields = [[selectedFields copy] autorelease];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:PREF_QUERY_SORT_FIELDS]) {
        NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
        fields = [fields sortedArrayUsingDescriptors:[NSArray arrayWithObject:sd]];
    }
    // There's no point selecting both the compound address field,and its component parts, do one or the other.
    BOOL useComponentFields = [[NSUserDefaults standardUserDefaults] boolForKey:PREF_SKIP_ADDRESS_FIELDS];
    if (useComponentFields) {
            // easy case, just skip the compound fields
        fields = [fields filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"not (type in { 'address','location'})"]];
    } else {
        // more work, calculate set of the component field names to skip, based on the name of the compound Field + the standard trailers
        NSMutableSet *fieldsToSkip = [NSMutableSet set];
        for (ZKDescribeField * f in [fields filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type=='address' || type='location'"]]) {
            NSArray *lsuffixes = [NSArray arrayWithObjects:@"Longitude", @"Latitude",nil];
            NSArray *lcsuffixes= [NSArray arrayWithObjects:@"__Longitude__s", @"__Latitude__s",nil];
            NSArray *asuffixes = [NSArray arrayWithObjects:@"City", @"Country", @"CountryCode", @"State", @"StateCode", @"PostalCode", @"Street", nil];
            NSString *prefix = [f name];
            prefix = [self removeSuffix:@"__c" from:prefix];
            prefix = [self removeSuffix:@"Address" from:prefix];
            [self addSuffixes:prefix suffixes:lsuffixes to:fieldsToSkip];
            if ([[f type] isEqualToString:@"address"])
                [self addSuffixes:prefix suffixes:asuffixes to:fieldsToSkip];
            if ([f custom])
                [self addSuffixes:prefix suffixes:lcsuffixes to:fieldsToSkip];
        }
        fields = [fields filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"not (name in %@)", fieldsToSkip]];
    }

    for (ZKDescribeField *f in fields)
        [query appendFormat:@" %@,", [f name]];
    NSRange lastChar = {[query length]-1, 1};
    [query deleteCharactersInRange:lastChar];
    [query appendFormat:@" from %@", selectedObjectName];
    [self setSoqlString:query];
}

- (IBAction)filterSObjectListView:(id)sender {
	[descDataSource setFilter:[sender stringValue]];
}

- (void)setRowsLoadedStatusText:(ZKQueryResult *)qr {
	[self setStatusText:[NSString stringWithFormat:@"loaded %ld of %d total rows", (unsigned long)[[qr records] count], [qr size]]];
}

- (void)permformQuery:(BOOL)useQueryAll {
	[self updateProgress:YES];
	[queryListController addQuery:[self soqlString]];
	[[NSUserDefaults standardUserDefaults] setObject:[self soqlString] forKey:@"soql"];
	@try {
        NSString *highlightedSelection = [[self soqlString] substringWithRange:[soql selectedRange]];
        NSCharacterSet *separator = [NSCharacterSet newlineCharacterSet];
        NSArray* arryayOfQueries = [highlightedSelection componentsSeparatedByCharactersInSet: separator];
        NSString *query = [arryayOfQueries objectAtIndex: 0];
        
        
        ZKQueryResult *qr = nil;
        if ([[query lowercaseString] hasPrefix:@"find "]) {
            qr = [SearchQueryResult searchQueryResults:[sforce search:query]];
        } else {
            qr = useQueryAll ? [sforce queryAll:query] : [sforce query:query];
        }
		if ([qr size] > 0) {
			if ([[qr records] count] == 0) {
				[self setStatusText:[NSString stringWithFormat:@"Count query result is %d rows", [qr size]]];
			} else {
				[rootResults setQueryResult:qr];
				[childResults setQueryResult:nil];
				[self setRowsLoadedStatusText:qr];
			}
		} else {
			[self setStatusText:@"Query returned 0 rows"];
			[rootResults setQueryResult:nil];
			[childResults setQueryResult:nil];
		}
	}
	@catch (ZKSoapException *ex)
	{
		[self updateProgress:NO];
		NSAlert * a = [NSAlert alertWithMessageText:[ex reason] defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:@"Query failed"];
		[a runModal];
	}
	[self updateProgress:NO];
}

- (IBAction)queryResultDoubleClicked:(id)sender {
	int cc = [sender clickedColumn];
	if (cc > -1) {
		NSTableColumn *c = [[rootTableView tableColumns] objectAtIndex:cc];
		NSObject *val = [[[[rootResults queryResult]  records] objectAtIndex:[sender clickedRow]] fieldValue:[c identifier]];
		if ([val isKindOfClass:[ZKQueryResult class]]) {
			ZKQueryResult *qr = (ZKQueryResult *)val;
			[self openChildTableView];
			[childResults setQueryResult:qr];
		} else {
			[rootTableView editColumn:[sender clickedColumn] row:[sender clickedRow] withEvent:nil select:YES]; 
		}
	}
}

- (IBAction)saveQueryResults:(id)sender {
	ResultsSaver *saver = [[[ResultsSaver alloc] initWithResults:rootResults client:sforce] autorelease];
	[saver save:myWindow];
}

- (IBAction)executeQuery:(id)sender {
	[self permformQuery:NO];
}	

- (IBAction)executeQueryAll:(id)sender {
	[self permformQuery:YES];
}

- (BOOL)canQueryMore {
	return [[rootResults queryResult] queryLocator] != nil;
}

- (BOOL)hasSelectedForDelete {	
	return [[rootResults wrapper] hasCheckedRows];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (object == rootResults) {
		[self willChangeValueForKey:@"hasSelectedForDelete"];
		[self didChangeValueForKey:@"hasSelectedForDelete"];
	} else if (object == detailsController) {
        [self.detailsRecentSelector setSelected:[[change objectForKey:NSKeyValueChangeNewKey] boolValue] forSegment:0];
    } else if (object == queryListController) {
        [self.detailsRecentSelector setSelected:[[change objectForKey:NSKeyValueChangeNewKey] boolValue] forSegment:1];
    }
}

- (IBAction)updateDetailsRecentSelection:(id)sender {
    [detailsController setWindowVisible:[sender isSelectedForSegment:0]];
    [queryListController setWindowVisible:[sender isSelectedForSegment:1]];
}

- (IBAction)deleteCheckedRows:(id)sender {
	BulkDelete *bd = [[BulkDelete alloc] initWithClient:sforce];
	[bd performBulkDelete:rootResults  window:myWindow];
}

- (void)dataChangedOnObject:(ZKSObject *)anObject field:(NSString *)fieldName value:(id)newValue {
	id existingVal = [anObject fieldValue:fieldName];
	if ([existingVal isEqualToString:newValue]) return;
	if (existingVal == nil && [newValue length] == 0) return;
	[self setStatusText:[NSString stringWithFormat:@"Updating field %@ on row with Id %@", fieldName, [anObject id]]];
	ZKSObject *update = [ZKSObject withTypeAndId:[anObject type] sfId:[anObject id]];
	[update setFieldValue:newValue field:fieldName];
    @try {
        ZKSaveResult *sr = [[sforce update:[NSArray arrayWithObject:update]] objectAtIndex:0];
        if ([sr success]) {
            [self setStatusText:[NSString stringWithFormat:@"Updated field %@ on row with Id %@", fieldName, [anObject id]]];
            [anObject setFieldValue:newValue field:fieldName];
        } else {
            NSAlert * a = [NSAlert alertWithMessageText:[sr message]
                                          defaultButton:@"Close"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:@"%@", [sr statusCode]];
            [a runModal];
        }
    } @catch (ZKSoapException *ex) {
        NSAlert *a =[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Unable to update field %@", fieldName]
                                    defaultButton:@"Close"
                                  alternateButton:nil
                                      otherButton:nil
                        informativeTextWithFormat:@"%@", [ex reason]];
        [a runModal];
    }
}

- (IBAction)queryMore:(id)sender {
	[self updateProgress:YES];
	ZKQueryResult * next = [sforce queryMore:[[rootResults queryResult] queryLocator]];
	NSMutableArray *allRecs = [NSMutableArray arrayWithArray:[[rootResults queryResult] records]];
	[allRecs addObjectsFromArray:[next records]];
	ZKQueryResult * total = [[ZKQueryResult alloc] initWithRecords:allRecs size:[next size] done:[next done] queryLocator:[next queryLocator]];
	[rootResults setQueryResult:total];
	[self setRowsLoadedStatusText:total];
	[self updateProgress:NO];
	[total release];
}

- (DescribeListDataSource *)describeDataSource {
	return descDataSource;
}

- (NSArray *)SObjects {
	return [descDataSource SObjects];
}

- (ZKDescribeSObject *)selectedSObject {
	id selectedItem = [describeList itemAtRow:[describeList selectedRow]];
	if ([selectedItem isKindOfClass:[NSString class]]) {
		// sobject name
		return [descDataSource describe:selectedItem];
        
    } else if ([selectedItem isKindOfClass:[ZKDescribeGlobalSObject class]]) {
        // sobject desc
        return [descDataSource describe:[selectedItem name]];
        
	} else if ([selectedItem isKindOfClass:[ZKDescribeField class]]) {
		// field
		return [(ZKDescribeField *)selectedItem sobject];
    }
    // unknown
    NSLog(@"selected item from describeList of unexpected type %@ %@", selectedItem, [selectedItem class]);
    return selectedItem;
}

// When the user selected an sobject we don't have a describe for, we'll do a describe in the background
// then re-update the UI/data sources.
-(void)asyncSelectedSObjectChanged:(NSString *)sobjectType {
    [self updateProgress:YES];
    [detailsController setDataSource:nil];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [descDataSource describe:sobjectType];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self selectedSObjectChanged:self];
            [self updateProgress:NO];
        });
    });
}

- (IBAction)selectedSObjectChanged:(id)sender {
	id selectedItem = [describeList itemAtRow:[describeList selectedRow]];
	NSObject<NSTableViewDataSource> *dataSource = nil;
	if ([selectedItem isKindOfClass:[ZKDescribeGlobalSObject class]]) {
		// sobject
        if (![descDataSource hasDescribe:[selectedItem name]] && ![self schemaViewIsActive]) {
            [self asyncSelectedSObjectChanged:[selectedItem name]];
            return;
        }
		ZKDescribeSObject *desc = [descDataSource describe:[selectedItem name]];
		dataSource = [[[SObjectDataSource alloc] initWithDescribe:desc] autorelease];
        [detailsController setIcon:[descDataSource iconForType:[selectedItem name]]];
		if ([[[soqlSchemaTabs selectedTabViewItem] identifier] isEqualToString:schemaTabId])
			[schemaController setSchemaViewToSObject:desc];
	} else {
		// field
		dataSource = [[[SObjectFieldDataSource alloc] initWithDescribe:selectedItem] autorelease];
        [detailsController  setIcon:nil];
	}
	[detailsController setDataSource:dataSource];
}

- (IBAction)generateReportForSelection:(id)sender {
	ZKDescribeSObject *sobject = [self selectedSObject]; 
	if (sobject == nil) return;
	ReportDocument *d = [[ReportDocument alloc] init];
	[d makeWindowControllers];
	[d showWindows];
	[d setSObjectType:[sobject name] andDataSource:[self describeDataSource]];
}

-(NSString *)idOfSelectedRowInTableVew:(NSTableView *)tv primaryIdOnly:(BOOL)primaryIdOnly {
	int r = [tv clickedRow];
	int c = [tv clickedColumn];
	if (r >= 0 && c >= 0) {
		NSTableColumn *tc = [[tv tableColumns] objectAtIndex:c];
		if (primaryIdOnly 
			|| (![[tc identifier] hasSuffix:@"Id"]) 
			|| ([[[tv dataSource] tableView:tv objectValueForTableColumn:tc row:r] length] != 18) ) {
			tc = [tv tableColumnWithIdentifier:@"Id"];
		}
		if (tc != nil) {
			NSString *theId = [[tv dataSource] tableView:tv objectValueForTableColumn:tc row:r];
			if ([theId length] == 18) 
				return theId;
		}
	}
	return nil;
}

- (IBAction)showSelectedIdInBrowser:(NSTableView *)tv {
	NSString *theId = [self idOfSelectedRowInTableVew:tv primaryIdOnly:NO];
	if (theId == nil) return;
	NSString *retUrl = [NSString stringWithFormat:@"/%@", theId];
	[self launchSfdcBrowser:retUrl];
}

- (IBAction)showSelectedIdFronRootInBrowser:(id)sender {
	[self showSelectedIdInBrowser:rootTableView];
}

- (IBAction)showSelectedIdFronChildInBrowser:(id)sender {
	[self showSelectedIdInBrowser:childTableView];
}

- (void)deleteSelectedRowInTable:(QueryResultTable *)tr {
	NSString *theId = [self idOfSelectedRowInTableVew:[tr table] primaryIdOnly:YES];
	if (theId == nil) return;
	ZKSaveResult *sr = [[sforce delete:[NSArray arrayWithObject:theId]] objectAtIndex:0];
	if ([sr success]) {
		int r = [[tr table] clickedRow];
		[tr removeRowAtIndex:r];
		[self setRowsLoadedStatusText:[tr queryResult]];
	} else {
		NSAlert * a = [NSAlert alertWithMessageText:[sr message] defaultButton:@"Cancel" alternateButton:nil otherButton:nil informativeTextWithFormat:@"%@", [sr statusCode]];
		[a runModal];
	}
}

- (IBAction)deleteSelectedRow:(id)sender {
	QueryResultTable *t = [sender tag] == 1 ? rootResults : childResults;
	[self deleteSelectedRowInTable:t];
}

// NSTabView delegate
- (void)tabView:(NSTabView *)tab didSelectTabViewItem:(NSTabViewItem *)item {
	if ([[item identifier] isEqualToString:schemaTabId]) {
		[self setSchemaViewIsActive:YES];
		[self selectedSObjectChanged:self];
	} else {
		[self setSchemaViewIsActive:NO];
	}
}

// NSSplitView delegate
- (CGFloat)splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)offset {
	return proposedMin + MIN_PANE_SIZE;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)offset {
	return proposedMax - MIN_PANE_SIZE;
}

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview {
	return subview == [[childTableView superview] superview];
}

- (BOOL)splitView:(NSSplitView *)splitView shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex {
	return dividerIndex == 1 && [self splitView:splitView canCollapseSubview:subview];
}

// ZKBaseClientDelegate
-(void)client:(ZKBaseClient *)client sentRequest:(NSString *)payload named:(NSString *)callName to:(NSURL *)destination withResponse:(zkElement *)response in:(NSTimeInterval)time {
    [self updateCallCount:(ZKSforceClient *)client];
}

-(void)client:(ZKBaseClient *)client sentRequest:(NSString *)payload named:(NSString *)callName to:(NSURL *)destination withException:(NSException *)ex    in:(NSTimeInterval)time {
    
}

@end

