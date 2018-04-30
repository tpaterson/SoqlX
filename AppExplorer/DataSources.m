// Copyright (c) 2006,2014,2016 Simon Fell
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

#import "DataSources.h"
#import "zkSforce.h"
#import "HighlightTextFieldCell.h"
#import "ZKDescribeThemeItem+ZKFindResource.h"
#import "Prefs.h"

@interface DescribeListDataSource ()
-(void)updateFilter;
-(void)prefsChanged:(NSNotification *)notif;
-(void)startBackgroundDescribes;
@end

@interface ZKDescribeField (ZKDataSourceHelpers)
-(BOOL)fieldMatchesFilter:(NSString *)filter;
-(NSString *)defaultValueAsString;
@end

@implementation ZKDescribeField (Filtering)

-(BOOL)fieldMatchesFilter:(NSString *)filter {
	if (filter == nil) return NO;
	return [[self name] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
}

-(NSString *)defaultValueAsString {
    NSObject *dv = [[self defaultValue] value];
    return dv == nil ? @"" : [dv description];
}

@end

@implementation DescribeListDataSource

- (id)init {
	self = [super init];
    fieldSortOrder = [[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)] retain];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(prefsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    stopBackgroundDescribes = 0;
	return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
	[types release];
	[sforce release];
	[operations release];
	[describes release];
    [sortedDescribes release];
	[filter release];
	[filteredTypes release];
	[outlineView release];
	[descGlobalSobjects release];
    [icons release];
    [fieldSortOrder release];
	[super dealloc];
}

-(void)prefsChanged:(NSNotification *)notif {
    [outlineView reloadData];
}

- (void)setTypes:(ZKDescribeGlobalTheme *)t view:(NSOutlineView *)ov {
	outlineView = [ov retain];
	types = [t.global.sobjects retain];
	describes = [[NSMutableDictionary alloc] init];
    sortedDescribes = [[NSMutableDictionary alloc] init];
	operations = [[NSMutableDictionary alloc] init];
	icons = [[NSMutableDictionary alloc] init];
    
	NSMutableDictionary *byname = [NSMutableDictionary dictionary];
	for (ZKDescribeGlobalSObject *o in types)
		[byname setObject:o forKey:[[o name] lowercaseString]];
		
	descGlobalSobjects = [byname retain];
    
    NSString *sid = sforce.sessionId;
    for (ZKDescribeThemeItem *r in t.theme.themeItems) {
        ZKDescribeIcon *i = [r iconWithHeight:16 theme:@"theme3"];
        [i fetchIconUsingSessionId:sid whenCompleteDo:^(NSImage *img) {
            NSString *tn = [[r name] lowercaseString];
            [icons setValue:img forKey:tn];
            [outlineView reloadItem:[byname objectForKey:tn]];
        }];
    }
    [self startBackgroundDescribes];
	[self updateFilter];
}

- (NSImage *)iconForType:(NSString *)type {
    return [icons valueForKey:[type lowercaseString]];
}

- (void)setSforce:(ZKSforceClient *)sf {
	sforce = [[sf copy] retain];
}

- (void)prioritizeDescribe:(NSString *)type {
	NSOperation *op = [operations objectForKey:[type lowercaseString]];
	[op setQueuePriority:NSOperationQueuePriorityHigh];
}

-(void)setFilteredTypes:(NSArray *)t {
	NSArray *old = filteredTypes;
	[filteredTypes autorelease];
	filteredTypes = [t retain];
	if (![old isEqualToArray:t])
		[outlineView reloadData];
}

-(BOOL)filterIncludesType:(NSString *)type {
	if ([type rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound)
		return YES; // easy, type contains the filter clause
	if (![self hasDescribe:type]) 
		return NO;	// we haven't described it yet
	for (ZKDescribeField *f in [[self describe:type] fields]) {
		if ([f fieldMatchesFilter:filter])
			return YES;
	}
	return NO;
}

-(void)updateFilter {
	if ([filter length] == 0) {
		[self setFilteredTypes:types];
		return;
	}
	NSMutableArray *ft = [NSMutableArray array];
	for (ZKDescribeGlobalSObject *type in types) {
		if ([self filterIncludesType:[type name]])
			[ft addObject:type];
	}
	[self setFilteredTypes:ft];
}

- (NSString *)filter {
	return filter;
}

- (void)setFilter:(NSString *)filterValue {
	[filter autorelease];
	filter = [filterValue copy];
	[self updateFilter];
}

- (NSArray *)SObjects {
	return types;
}

- (int)numberOfRowsInTableView:(NSTableView *)v {
	return [filteredTypes count];
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(int)rowIdx {
	return [[filteredTypes objectAtIndex:rowIdx] name];
}

- (BOOL)isTypeDescribable:(NSString *)type {
	return nil != [descGlobalSobjects objectForKey:[type lowercaseString]];
}

- (BOOL)hasDescribe:(NSString *)type {
	return nil != [describes objectForKey:[type lowercaseString]];
}

- (ZKDescribeSObject *)describe:(NSString *)type {
	NSString *t = [type lowercaseString];
	ZKDescribeSObject * d = [describes objectForKey:t];
	if (d == nil) {
		if (![self isTypeDescribable:t]) 
			return nil;
		d = [sforce describeSObject:t];
        // this is always called on the main thread, can fiddle with the cache directly
        NSArray *sortedFields = [[d fields] sortedArrayUsingDescriptors:@[fieldSortOrder]];
        [describes setObject:d forKey:t];
        [sortedDescribes setObject:sortedFields forKey:t];
        [self performSelectorOnMainThread:@selector(updateFilter) withObject:nil waitUntilDone:NO];
	}
	return d;
}

-(void)addDescribesToCache:(NSArray *)newDescribes {
    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:[newDescribes count]];
    for (ZKDescribeSObject * d in newDescribes) {
        [sorted addObject:[[d fields] sortedArrayUsingDescriptors:@[fieldSortOrder]]];
    }
    dispatch_async(dispatch_get_main_queue(), ^() {
        int i = 0;
        for (ZKDescribeSObject *d in newDescribes) {
            NSString *k = [d.name lowercaseString];
            if ([describes objectForKey:k] == nil) {
                [describes setObject:d forKey:k];
                [sortedDescribes setObject:[sorted objectAtIndex:i] forKey:k];
            }
            i++;
        }
        [self updateFilter];
    });
}

-(void)startBackgroundDescribes {
    ZKSforceClient *client = [sforce copyWithZone:nil];
    // stop race condition with the delegate going away from under us.
    [client.delegate retain];
    NSArray *toDescribe = [descGlobalSobjects allKeys];
    const int DEFAULT_DESC_BATCH = 16;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^() {
        NSMutableArray *batch = [NSMutableArray arrayWithCapacity:DEFAULT_DESC_BATCH];
        NSArray *leftTodo = toDescribe;
        NSArray __block *alreadyDescribed = nil;
        int i;
        int batchSize = DEFAULT_DESC_BATCH;
        while ([leftTodo count] > 0 && (OSAtomicAdd32(0, &stopBackgroundDescribes) == 0)) {
            dispatch_sync(dispatch_get_main_queue(), ^() {
                alreadyDescribed = [[describes allKeys] retain];
            });
            [batch removeAllObjects];
            for (i=[leftTodo count]-1; i >= 0; i--) {
                NSString *item = leftTodo[i];
                if ([alreadyDescribed containsObject:item]) {
                    continue;
                }
                [batch addObject:item];
                if ([batch count] >= batchSize) break;
            }
            if ([batch count] > 0) {
                @try {
                    NSArray *res = [client describeSObjects:batch];
                    [self addDescribesToCache:res];
                    batchSize = MIN(DEFAULT_DESC_BATCH, MAX(2, batchSize * 3/2));
                } @catch (NSException *ex) {
                    NSLog(@"Failed to describe %@: %@", batch, ex);
                    batchSize = MAX(1, batchSize / 2);
                    continue;
                }
            }
            leftTodo = [leftTodo subarrayWithRange:NSMakeRange(0, i+1)];
            [alreadyDescribed release];
        }
        dispatch_async(dispatch_get_main_queue(), ^() {
            [client.delegate autorelease];
            [client autorelease];
            // sanity check we got everything
            if ([descGlobalSobjects count] != [describes count]) {
                NSLog(@"Background describe finished, but there are still missing describes");
                for (NSString *k in [descGlobalSobjects allKeys]) {
                    if ([describes objectForKey:k] == nil) {
                        NSLog(@"\t%@", k);
                    }
                }
            }
        });
    });
}

-(void)stopBackgroundDescribe {
    OSAtomicIncrement32(&stopBackgroundDescribes);
}

// for use in an outline view
- (int)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
	if (item == nil) return [filteredTypes count];
	return [[[self describe:[item name]] fields] count];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item  {
	return item == nil || [item isKindOfClass:[ZKDescribeGlobalSObject class]];
}

- (id)outlineView:(NSOutlineView *)outlineView child:(int)index ofItem:(id)item {
	if (item == nil) return [filteredTypes objectAtIndex:index];
    NSArray *fields = [[self describe:[item name]] fields];
    BOOL isSorted = [[NSUserDefaults standardUserDefaults] boolForKey:PREF_SORTED_FIELD_LIST];
    if (isSorted)
        fields = [sortedDescribes objectForKey:[[item name] lowercaseString]];
	id f = [fields objectAtIndex:index];
	return f;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
	if ([[[tableColumn headerCell] stringValue] isEqualToString:@"SObjects"]) {
		return [item name];
	}
	return nil;
}

-(NSCell *)outlineView:(NSOutlineView *)outlineView dataCellForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
	HighlightTextFieldCell *c = [tableColumn dataCell];
    c.zkImage = nil;
    c.zkStandout = NO;
    c.zkTextXOffset = 8;
	//[c setTextColor:[NSColor blackColor]];
    float fontSize = [[[NSUserDefaults standardUserDefaults] valueForKey:PREF_TEXT_SIZE] floatValue];
    
    NSFont *font = [NSFont fontWithName:@"Monaco" size:fontSize];
    
    [c setFont:font];
    
    if ([item isKindOfClass:[ZKDescribeGlobalSObject class]]) {
        c.zkTextXOffset = 18;
        c.zkImage = [self iconForType:[item name]];

	} else if ([item isKindOfClass:[ZKDescribeField class]]) {
		if ([item fieldMatchesFilter:filter]) {
			//[c setFont:[NSFont boldSystemFontOfSize:13.0f]];
			//[c setTextColor:[[NSColor blueColor] blendedColorWithFraction:0.5 ofColor:[NSColor blackColor]]];
			[c setZkStandout:YES];
		}
	}
	return c;
}

-(CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
	if ([item isKindOfClass:[ZKDescribeField class]]) {
		if ([item fieldMatchesFilter:filter]) {
			return [ov rowHeight] + 4;
		}
	}
    return [ov rowHeight];
}

@end

@implementation SObjectDataSource


- (id)initWithDescribe:(ZKDescribeSObject *)s {
	self = [super init];
	sobject = [s retain];
	
	NSMutableArray *t = [NSMutableArray arrayWithObjects:@"Name", @"Label", @"PluralLabel", @"Key Prefix", @"Custom", 
				@"Createable", @"Updateable", @"Activateable", @"Deletable", @"Undeletable", 
				@"Mergeable", @"Queryable", @"Retrieveable", @"Searchable", @"Layoutable",
				@"Replicateable", @"Triggerable", @"MRU Enabled", @"Has Subtypes",
                @"URL for Edit", @"URL for Detail", @"URL for New", nil];
	NSArray *cr = [s childRelationships];
	if ([cr count] > 0) {
		NSString *sectionTitle = [NSString stringWithFormat:@"Relationships to %@", [sobject name]];
		NSAttributedString *boldTitle = [[[NSAttributedString alloc] initWithString:sectionTitle attributes:[NSDictionary dictionaryWithObject:[NSFont boldSystemFontOfSize:11] forKey:NSFontAttributeName]] autorelease];
		[t addObject:boldTitle]; 
		for (ZKChildRelationship *r in cr) {
			[t addObject:[NSString stringWithFormat:@"%@.%@", [r childSObject], [r field]]];
		}
	}
	titles = [t retain];
	return self;
}

- (void)dealloc {
	[sobject release];
	[titles release];
	[super dealloc];
}

- (NSString *)description {
	return [NSString stringWithFormat:@"SObject : %@", [sobject name]];
}

// for use in a table view
-(int)numberOfRowsInTableView:(NSTableView *)view {
	return [titles count];
}

-(id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(int)rowIdx {
	if ([[tc identifier] isEqualToString:@"title"])
		return [titles objectAtIndex:rowIdx];

	SEL selectors[] = { @selector(name), @selector(label), @selector(labelPlural), @selector(keyPrefix), @selector(custom),			
						@selector(createable), @selector(updateable), @selector(activateable), @selector(deletable), @selector(undeletable),
						@selector(mergeable), @selector(queryable), @selector(retrieveable), @selector(searchable), @selector(layoutable),
						@selector(replicateable), @selector(triggerable), @selector(mruEnabled), @selector(hasSubtypes),
                        @selector(urlEdit), @selector(urlDetail), @selector(urlNew) };

	int numSelectors = sizeof(selectors)/sizeof(*selectors);
	
	if (rowIdx < numSelectors) {
		SEL theSel = selectors[rowIdx];		
		id f = [sobject performSelector:theSel];
		const char *returnType = [[sobject methodSignatureForSelector:theSel] methodReturnType];
		if (returnType[0] == 'c') 	// aka char aka Bool			
			return f ? @"Yes" : @"";		
		return [sobject performSelector:theSel];
	}
	if (rowIdx == numSelectors)
		return @"";	// this is the value for the Child Relationships title row

	ZKChildRelationship *cr = [[sobject childRelationships] objectAtIndex:rowIdx - numSelectors -1];
	return [NSString stringWithFormat:@"%@", [cr relationshipName] == nil ? @"" : [cr relationshipName]];
}

@end

@implementation SObjectFieldDataSource

- (id)initWithDescribe:(ZKDescribeField *)f {
	self = [super init];
	field = [f retain];
	titles = [[NSArray arrayWithObjects:@"Name", @"Label", @"Type", @"Custom", @"Help Text",
					@"Length", @"Digits", @"Scale", @"Precision", @"Byte Length",
					@"Default Value", @"Createable", @"Updatable", @"Cascade Delete", @"Restricted Delete",
                    @"Default On Create", @"Calculated", @"AutoNumber",
					@"Unique", @"Case Sensitive", @"Name Pointing", @"Sortable", @"Groupable", @"Aggregatable", @"Permissionable",
					@"External Id", @"ID Lookup", @"Filterable", @"HTML Formatted", @"Name Field", @"Nillable", 
					@"Compound FieldName", @"Name Pointing", @"Extra TypeInfo", @"Reference To", @"Relationship Name",
					@"Dependent Picklist", @"Controller Name", @"Restricted Picklist", @"Query By Distance",
					@"Value Formula", @"Default Formula", @"Relationship Order (CJOs)", @"Write Requires Read on Master (CJOs)", @"Display Location in Decimal", nil] retain];
	return self;
}

- (void)dealloc {
	[field release];
	[titles release];
	[super dealloc];
}

- (NSString *)description {
	return [NSString stringWithFormat:@"Field : %@.%@", [[field sobject] name], [field name]];
}

// for use in a table view
- (int)numberOfRowsInTableView:(NSTableView *)view {
	return [titles count];
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(int)rowIdx {
	if ([[tc identifier] isEqualToString:@"title"])
		return [titles objectAtIndex:rowIdx];

	SEL selectors[] = { @selector(name), @selector(label), @selector(type), @selector(custom), @selector(inlineHelpText),
						@selector(length), @selector(digits), @selector(scale), @selector(precision), @selector(byteLength),			
						@selector(defaultValueAsString), @selector(createable), @selector(updateable), @selector(cascadeDelete), @selector(restrictedDelete),
                        @selector(defaultedOnCreate), @selector(calculated), @selector(autoNumber),
						@selector(unique), @selector(caseSensitive), @selector(namePointing), @selector(sortable), @selector(groupable), @selector(aggregatable), @selector(permissionable),
						@selector(externalId), @selector(idLookup), @selector(filterable), @selector(htmlFormatted), @selector(nameField), @selector(nillable),
						@selector(compoundFieldName), @selector(namePointing), @selector(extraTypeInfo), @selector(referenceTo), @selector(relationshipName),
						@selector(dependentPicklist), @selector(controllerName), @selector(restrictedPicklist), @selector(queryByDistance),
						@selector(calculatedFormula), @selector(defaultValueFormula), @selector(relationshipOrder), @selector(writeRequiresMasterRead), @selector(displayLocationInDecimal) };
	
	if (field == nil) return @"";
	id f = [field performSelector:selectors[rowIdx]];
	const char *returnType = [[field methodSignatureForSelector:selectors[rowIdx]] methodReturnType];
	
	if (returnType[0] == 'c')
		return f ? @"Yes" : @"";
	if (returnType[0] == 'i')
		return f == 0 ? (id)@"" : (id)[NSNumber numberWithInt:(int)f];
    if (returnType[0] == 'q')
        return [NSNumber numberWithLongLong:(long long)f];
	if (returnType[0] == '@') {
		if ([f isKindOfClass:[NSArray class]]) {
			if ([f count] == 0) return @"";
			return [f componentsJoinedByString:@", "];
		}
		return f;
	}
	NSLog(@"Unexpected return type of %c for selector %s", *returnType, sel_getName(selectors[rowIdx]));
	return f;
}

@end

@implementation NoSelection 

-(BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(int)rowIndex {
	return NO;
}

@end

