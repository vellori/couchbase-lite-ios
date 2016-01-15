//
//  CBL_ForestDBStorage.mm
//  CouchbaseLite
//
//  Created by Jens Alfke on 1/13/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

extern "C" {
#import "CBL_ForestDBStorage.h"
#import "CBL_ForestDBViewStorage.h"
#import "CouchbaseLitePrivate.h"
#import "CBLInternal.h"
#import "CBL_BlobStore.h"
#import "CBL_Attachment.h"
#import "CBLBase64.h"
#import "CBLMisc.h"
#import "CBLSymmetricKey.h"
#import "ExceptionUtils.h"
#import "MYAction.h"
#import "MYBackgroundMonitor.h"
}
#import "CBLForestBridge.h"
    

#define kDBFilename @"db.forest"

// Size of ForestDB buffer cache allocated for a database
#define kDBBufferCacheSize (8*1024*1024)

// ForestDB Write-Ahead Log size (# of records)
#define kDBWALThreshold 1024

// How often ForestDB should check whether databases need auto-compaction
#define kAutoCompactInterval (15.0)

// Percentage of wasted space in db file that triggers auto-compaction
#define kCompactionThreshold 70

#define kDefaultMaxRevTreeDepth 20


@implementation CBL_ForestDBStorage
{
    @private
    NSString* _directory;
    BOOL _readOnly;
    C4Database* _forest;
    NSMapTable* _views;
}

@synthesize delegate=_delegate, directory=_directory, autoCompact=_autoCompact;
@synthesize maxRevTreeDepth=_maxRevTreeDepth, encryptionKey=_encryptionKey;


static void FDBLogCallback(C4LogLevel level, C4Slice message) {
    switch (level) {
        case kC4LogDebug:
            LogTo(CBLDatabaseVerbose, @"ForestDB: %.*s", (int)message.size, message.buf);
            break;
        case kC4LogInfo:
            LogTo(CBLDatabase, @"ForestDB: %.*s", (int)message.size, message.buf);
            break;
        case kC4LogWarning:
            Warn(@"%.*s", (int)message.size, message.buf);
            break;
        case kC4LogError: {
            bool raises = gMYWarnRaisesException;
            gMYWarnRaisesException = NO;    // don't throw from a ForestDB callback!
            Warn(@"ForestDB error: %.*s", (int)message.size, message.buf);
            gMYWarnRaisesException = raises;
            break;
        }
        default:
            break;
    }
}


#ifdef TARGET_OS_IPHONE
static MYBackgroundMonitor *bgMonitor;
#endif


#if 0 // TODO
static void onCompactCallback(C4Database *db, bool compacting) {
    const char *what = (compacting ?"starting" :"finished");
    NSString* path = slice2string(c4db_getPath(db));
    NSString* viewName = path.lastPathComponent;
    path = path.stringByDeletingLastPathComponent;
    NSString* dbName = path.lastPathComponent.stringByDeletingPathExtension;
    if ([viewName isEqualToString: kDBFilename]) {
        Log(@"Database '%@' %s compaction", dbName, what);
    } else {
        dbName = [dbName stringByAppendingPathComponent: viewName];
        Log(@"View index '%@/%@' %s compaction",
            dbName, viewName.stringByDeletingPathExtension, what);
    }
}
#endif


+ (void) initialize {
    if (self == [CBL_ForestDBStorage class]) {
        Log(@"Initializing ForestDB");
        C4LogLevel logLevel = kC4LogWarning;
        if (WillLogTo(CBLDatabaseVerbose))
            logLevel = kC4LogDebug;
        else if (WillLogTo(CBLDatabase))
            logLevel = kC4LogInfo;
        c4log_register(logLevel, FDBLogCallback);
        C4GenerateOldStyleRevIDs = true; // Compatible with CBL 1.x

//TODO        Database::onCompactCallback = onCompactCallback;

#if TARGET_OS_IPHONE
        bgMonitor = [[MYBackgroundMonitor alloc] init];
        bgMonitor.onAppBackgrounding = ^{
            if ([self checkStillCompacting])
                [bgMonitor beginBackgroundTaskNamed: @"Database compaction"];
        };
        bgMonitor.onAppForegrounding = ^{
            [self cancelPreviousPerformRequestsWithTarget: self
                                                 selector: @selector(checkStillCompacting)
                                                   object: nil];
        };
#endif
    }
}


#if TARGET_OS_IPHONE
+ (BOOL) checkStillCompacting {
    if (Database::isAnyCompacting()) {
        Log(@"Database still compacting; delaying app suspend...");
        [self performSelector: @selector(checkStillCompacting) withObject: nil afterDelay: 0.5];
        return YES;
    } else {
        if (bgMonitor.hasBackgroundTask) {
            Log(@"Database finished compacting; allowing app to suspend.");
            [bgMonitor endBackgroundTask];
        }
        return NO;
    }
}
#endif


- (instancetype) init {
    self = [super init];
    if (self) {
        _autoCompact = YES;
        _maxRevTreeDepth = kDefaultMaxRevTreeDepth;
    }
    return self;
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@]", self.class, _directory];
}


- (BOOL) databaseExistsIn: (NSString*)directory {
    NSString* dbPath = [directory stringByAppendingPathComponent: kDBFilename];
    if ([[NSFileManager defaultManager] fileExistsAtPath: dbPath isDirectory: NULL])
        return YES;
    // If "db.forest" doesn't exist (auto-compaction will add numeric suffixes), check for meta:
    dbPath = [dbPath stringByAppendingString: @".meta"];
    return [[NSFileManager defaultManager] fileExistsAtPath: dbPath isDirectory: NULL];
}


- (BOOL)openInDirectory: (NSString *)directory
               readOnly: (BOOL)readOnly
                manager: (CBLManager*)manager
                  error: (NSError**)outError
{
    _directory = [directory copy];
    _readOnly = readOnly;
    return [self reopen: outError];
}


- (BOOL) reopen: (NSError**)outError {
    if (_encryptionKey)
        LogTo(CBLDatabase, @"Database is encrypted; setting CBForest encryption key");
    NSString* forestPath = [_directory stringByAppendingPathComponent: kDBFilename];
    C4DatabaseFlags flags = _readOnly ? kC4DB_ReadOnly : kC4DB_Create;
    if (_autoCompact)
        flags |= kC4DB_AutoCompact;
    C4EncryptionKey encKey = symmetricKey2Forest(_encryptionKey);

    C4Error c4err;
    _forest = c4db_open(string2slice(forestPath), flags, &encKey, &c4err);
    if (!_forest)
        err2OutNSError(c4err, outError);
    return (_forest != nil);
}


- (void) close {
    c4db_close(_forest, NULL);
    _forest = NULL;
}


- (MYAction*) actionToChangeEncryptionKey: (CBLSymmetricKey*)newKey {
    MYAction* action = [MYAction new];

    // Re-key the views!
    NSArray* viewNames = self.allViewNames;
    for (NSString* viewName in viewNames) {
        CBL_ForestDBViewStorage* viewStorage = [self viewStorageNamed: viewName create: YES];
        [action addAction: [viewStorage actionToChangeEncryptionKey]];
    }

    // Re-key the database:
    CBLSymmetricKey* oldKey = _encryptionKey;
    [action addPerform: ^BOOL(NSError **outError) {
        C4EncryptionKey encKey = symmetricKey2Forest(newKey);
        C4Error c4Err;
        if (!c4db_rekey(_forest, &encKey, &c4Err))
            return err2OutNSError(c4Err, outError);
        self.encryptionKey = newKey;
        return YES;
    } backOut:^BOOL(NSError **outError) {
        //FIX: This can potentially fail. If it did, the database would be lost.
        // It would be safer to save & restore the old db file, the one that got replaced
        // during rekeying, but the ForestDB API doesn't allow preserving it...
        C4EncryptionKey encKey = symmetricKey2Forest(oldKey);
        c4db_rekey(_forest, &encKey, NULL);
        self.encryptionKey = oldKey;
        return YES;
    } cleanUp: nil];

    return action;
}


- (void*) forestDatabase {
    return _forest;
}


- (NSUInteger) documentCount {
    return c4db_getDocumentCount(_forest);
}


- (SequenceNumber) lastSequence {
    return c4db_getLastSequence(_forest);
}


- (BOOL) compact: (NSError**)outError {
    C4Error c4Err;
    return c4db_compact(_forest, &c4Err) || err2OutNSError(c4Err, outError);
}


- (CBLStatus) inTransaction: (CBLStatus(^)())block {
    if (c4db_isInTransaction(_forest)) {
        return block();
    } else {
        LogTo(CBLDatabase, @"BEGIN transaction...");
        C4Error c4Err;
        if (!c4db_beginTransaction(_forest, &c4Err))
            return err2status(c4Err);
        CBLStatus status = block();
        BOOL commit = !CBLStatusIsError(status);
        LogTo(CBLDatabase, @"END transaction...");
        if (!c4db_endTransaction(_forest, commit, &c4Err) && commit) {
            status = err2status(c4Err);
            commit = NO;
        }
        [_delegate storageExitedTransaction: commit];
        return status;
    }
}

- (BOOL) inTransaction {
    return _forest && c4db_isInTransaction(_forest);
}


#pragma mark - DOCUMENTS:


- (CBLStatus) _withVersionedDoc: (UU NSString*)docID
                      mustExist: (BOOL)mustExist
                             do: (CBLStatus(^)(C4Document*))block
{
    __block C4Document* doc = NULL;
    __block C4Error c4err;
    CBLWithStringBytes(docID, ^(const char *docIDBuf, size_t docIDSize) {
        doc = c4doc_get(_forest, (C4Slice){docIDBuf, docIDSize}, mustExist, &c4err);
    });
    if (!doc)
        return err2status(c4err);
    CBLStatus status = block(doc);
    c4doc_free(doc);
    return status;
}


static CBLStatus selectRev(C4Document* doc, NSString* revID, BOOL withBody) {
    __block CBLStatus status = kCBLStatusOK;
    if (revID) {
        CBLWithStringBytes(revID, ^(const char *buf, size_t size) {
            C4Error c4err;
            if (!c4doc_selectRevision(doc, (C4Slice){buf, size}, withBody, &c4err))
                status = err2status(c4err);
        });
    } else {
        if (!c4doc_selectCurrentRevision(doc))
            status = kCBLStatusDeleted;
    }
    return status;
}


- (CBL_MutableRevision*) getDocumentWithID: (NSString*)docID
                                revisionID: (NSString*)inRevID
                                  withBody: (BOOL)withBody
                                    status: (CBLStatus*)outStatus
{
    __block CBL_MutableRevision* result = nil;
    *outStatus = [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
#if DEBUG
        LogTo(CBLDatabase, @"Read %@ rev %@", docID, inRevID);
#endif
        CBLStatus status = selectRev(doc, inRevID, withBody);
        if (!CBLStatusIsError(status)) {
            if (!inRevID && (doc->selectedRev.flags & kRevDeleted))
                status = kCBLStatusDeleted;
            else
                result = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                docID: docID revID: inRevID
                                                             withBody: withBody status: &status];
        }
        return status;
    }];
    return result;
}


- (NSDictionary*) getBodyWithID: (NSString*)docID
                       sequence: (SequenceNumber)sequence
                         status: (CBLStatus*)outStatus
{
    __block NSMutableDictionary* result = nil;
    *outStatus = [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
#if DEBUG
        LogTo(CBLDatabase, @"Read %@ seq %lld", docID, sequence);
#endif
        do {
            if (doc->selectedRev.sequence == (C4SequenceNumber)sequence) {
                result = [CBLForestBridge bodyOfSelectedRevision: doc];
                if (!result)
                    return kCBLStatusNotFound;
                result[@"_id"] = docID;
                result[@"_rev"] = slice2string(doc->selectedRev.revID);
                if (doc->selectedRev.flags & kRevDeleted)
                    result[@"_deleted"] = @YES;
                return kCBLStatusOK;
            }
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusNotFound;
    }];
    return result;
}


- (CBLStatus) loadRevisionBody: (CBL_MutableRevision*)rev {
    return [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (CBLStatusIsError(status))
            return status;
        return [CBLForestBridge loadBodyOfRevisionObject: rev fromSelectedRevision: doc];
    }];
}


- (SequenceNumber) getRevisionSequence: (CBL_Revision*)rev {
    __block SequenceNumber sequence = 0;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (!CBLStatusIsError(status))
            sequence = doc->selectedRev.sequence;
        return kCBLStatusOK;
    }];
    return sequence;
}


#pragma mark - HISTORY:


- (CBL_Revision*) getParentRevision: (CBL_Revision*)rev {
    if (!rev.docID || !rev.revID)
        return nil;
    __block CBL_Revision* parent = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (CBLStatusIsError(status))
            return status;
        if (!c4doc_selectParentRevision(doc))
            return kCBLStatusNotFound;
        parent = [CBLForestBridge revisionObjectFromForestDoc: doc docID: rev.docID revID: nil
                                                     withBody: YES status: &status];
        return status;
    }];
    return parent;
}


- (CBL_RevisionList*) getAllRevisionsOfDocumentID: (NSString*)docID
                                      onlyCurrent: (BOOL)onlyCurrent
{
    __block CBL_RevisionList* revs = nil;
    [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
        revs = [[CBL_RevisionList alloc] init];
        do {
            if (onlyCurrent && !(doc->selectedRev.flags & kRevLeaf))
                continue;
            CBLStatus status;
            CBL_Revision *rev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                       docID: docID
                                                                       revID: nil
                                                                    withBody: NO
                                                                      status: &status];
            if (rev)
                [revs addRev: rev];
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusOK;
    }];
    return revs;
}


- (NSArray*) getPossibleAncestorRevisionIDs: (CBL_Revision*)rev
                                      limit: (unsigned)limit
                            onlyAttachments: (BOOL)onlyAttachments
{
    unsigned generation = [CBL_Revision generationFromRevID: rev.revID];
    if (generation <= 1)
        return nil;
    __block NSMutableArray* revIDs = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        revIDs = $marray();
        do {
            C4RevisionFlags flags = doc->selectedRev.flags;
            if (!(flags & kRevDeleted) && (!onlyAttachments || (flags & kRevHasAttachments))
                            && c4rev_getGeneration(doc->selectedRev.revID) < generation
                            && c4doc_hasRevisionBody(doc)) {
                [revIDs addObject: slice2string(doc->selectedRev.revID)];
                if (limit && revIDs.count >= limit)
                    break;
            }
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusOK;
    }];
    return revIDs;
}


- (NSString*) findCommonAncestorOf: (CBL_Revision*)rev withRevIDs: (NSArray*)revIDs {
    unsigned generation = [CBL_Revision generationFromRevID: rev.revID];
    if (generation <= 1 || revIDs.count == 0)
        return nil;
    revIDs = [revIDs sortedArrayUsingComparator: ^NSComparisonResult(NSString* id1, NSString* id2) {
        return CBLCompareRevIDs(id2, id1); // descending order of generation
    }];
    __block NSString* commonAncestor = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        for (NSString* possibleRevID in revIDs) {
            if ([CBL_Revision generationFromRevID: possibleRevID] <= generation) {
                CBLWithStringBytes(possibleRevID, ^(const char *buf, size_t size) {
                    if (c4doc_selectRevision(doc, (C4Slice){buf, size}, false, NULL))
                        commonAncestor = possibleRevID;
                });
                if (commonAncestor)
                    break;
            }
        }
        return kCBLStatusOK;
    }];
    return commonAncestor;
}
    

- (NSArray*) getRevisionHistory: (CBL_Revision*)rev
                   backToRevIDs: (NSSet*)ancestorRevIDs
{
    NSMutableArray* history = [NSMutableArray array];
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        NSString* revID = rev.revID;
        C4Error c4err;
        if (revID && !c4doc_selectRevision(doc, string2slice(revID), false, &c4err))
            return err2status(c4err);
        do {
            CBLStatus status;
            CBL_MutableRevision* ancestor = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                                   docID: rev.docID
                                                                                   revID: nil
                                                                                withBody: NO
                                                                                  status: &status];
            if (!ancestor)
                return status;
            ancestor.missing = !c4doc_hasRevisionBody(doc);
            [history addObject: ancestor];
            if ([ancestorRevIDs containsObject: ancestor.revID])
                break;
        } while (c4doc_selectParentRevision(doc));
        return kCBLStatusOK;
    }];
    return history;
}


- (CBL_RevisionList*) changesSinceSequence: (SequenceNumber)lastSequence
                                   options: (const CBLChangesOptions*)options
                                    filter: (CBL_RevisionFilter)filter
                                    status: (CBLStatus*)outStatus
{
    // http://wiki.apache.org/couchdb/HTTP_database_API#Changes
    if (!options) options = &kDefaultCBLChangesOptions;
    
    if (options->descending) {
        // https://github.com/couchbase/couchbase-lite-ios/issues/641
        *outStatus = kCBLStatusNotImplemented;
        return nil;
    }

    BOOL withBody = (options->includeDocs || filter != nil);
    unsigned limit = options->limit;

    C4EnumeratorOptions c4opts = kC4DefaultEnumeratorOptions;
    c4opts.flags |= kC4IncludeDeleted;
    C4Error c4err = {};
    CLEANUP(C4DocEnumerator)* e = c4db_enumerateChanges(_forest, lastSequence, &c4opts, &c4err);
    if (!e) {
        *outStatus = err2status(c4err);
        return nil;
    }
    CBL_RevisionList* changes = [[CBL_RevisionList alloc] init];
    while (limit-- > 0 && c4enum_next(e, &c4err)) {
        @autoreleasepool {
            CLEANUP(C4Document) *doc = c4enum_getDocument(e, &c4err);
            if (!doc)
                break;
            NSString* docID = slice2string(doc->docID);
            do {
                CBL_MutableRevision* rev;
                rev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                             docID: docID
                                                             revID: nil
                                                          withBody: withBody
                                                            status: outStatus];
                if (!rev)
                    return nil;
                if (!filter || filter(rev)) {
                    if (!options->includeDocs)
                        rev.body = nil;
                    [changes addRev: rev];
                }
            } while (options->includeConflicts && c4doc_selectNextLeafRevision(doc, true, withBody,
                                                                               &c4err));
            if (c4err.code)
                break;
        }
    }
    if (c4err.code) {
        *outStatus = err2status(c4err);
        return nil;
    }
    return changes;
}


- (CBLQueryIteratorBlock) getAllDocs: (CBLQueryOptions*)options
                              status: (CBLStatus*)outStatus
{
    if (!options)
        options = [CBLQueryOptions new];

    C4EnumeratorOptions c4options = {0, 0};
    BOOL includeDocs = (options->includeDocs || options.filter);
    if (includeDocs || options->allDocsMode >= kCBLShowConflicts)
        c4options.flags |= kC4IncludeBodies;
    if (options->descending)
        c4options.flags |= kC4Descending;
    if (options->inclusiveStart)
        c4options.flags |= kC4InclusiveStart;
    if (options->inclusiveEnd)
        c4options.flags |= kC4InclusiveEnd;
    if (options->allDocsMode == kCBLIncludeDeleted)
        c4options.flags |= kC4IncludeDeleted;
    if (options->allDocsMode != kCBLOnlyConflicts)
        c4options.flags |= kC4IncludeNonConflicted;
    __block unsigned limit = options->limit;
    __block unsigned skip = options->skip;
    CBLQueryRowFilter filter = options.filter;

    __block C4DocEnumerator* e;
    C4Error c4err;
    if (options.keys) {
        size_t nKeys = options.keys.count;
        C4Slice *keySlices = (C4Slice*)malloc(nKeys * sizeof(C4Slice));
        size_t i = 0;
        for (NSString* key in options.keys)
            keySlices[i++] = string2slice(key);
        e = c4db_enumerateSomeDocs(_forest, keySlices, nKeys, &c4options, &c4err);
    } else {
        id startKey, endKey;
        if (options->descending) {
            startKey = CBLKeyForPrefixMatch(options.startKey, options->prefixMatchLevel);
            endKey = options.endKey;
        } else {
            startKey = options.startKey;
            endKey = CBLKeyForPrefixMatch(options.endKey, options->prefixMatchLevel);
        }
        e = c4db_enumerateAllDocs(_forest,
                                  string2slice(startKey),
                                  string2slice(endKey),
                                  &c4options,
                                  &c4err);
    }
    if (!e) {
        *outStatus = err2status(c4err);
        return nil;
    }

    // The rest is the block that gets called later to return the next row:
    return ^CBLQueryRow*() {
        if (!e)
            return nil;
        C4Error c4err;
        while (c4enum_next(e, &c4err)) {
            CLEANUP(C4Document)* doc = c4enum_getDocument(e, &c4err);
            if (!doc)
                break;
            NSString* docID = slice2string(doc->docID);
            if (!(doc->flags & kExists)) {
                LogTo(QueryVerbose, @"AllDocs: No such row with key=\"%@\"",
                      docID);
                return [[CBLQueryRow alloc] initWithDocID: nil
                                                 sequence: 0
                                                      key: docID
                                                    value: nil
                                              docRevision: nil
                                                  storage: nil];
            }

            bool deleted = (doc->flags & kDeleted) != 0;
            if (deleted && options->allDocsMode != kCBLIncludeDeleted && !options.keys)
                continue; // skip deleted doc
            if (!(doc->flags & kConflicted) && options->allDocsMode == kCBLOnlyConflicts)
                continue; // skip non-conflicted doc
            if (skip > 0) {
                --skip;
                continue;
            }

            NSString* revID = slice2string(doc->revID);

            CBL_Revision* docRevision = nil;
            if (includeDocs) {
                // Fill in the document contents:
                CBLStatus status;
                docRevision = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                     docID: docID
                                                                     revID: revID
                                                                  withBody: YES
                                                                    status: &status];
                if (!docRevision)
                    Warn(@"AllDocs: Unable to read body of doc %@: status %d", docID, status);
            }

            NSMutableArray* conflicts = nil;
            if (options->allDocsMode >= kCBLShowConflicts && (doc->flags & kConflicted)) {
                conflicts = [NSMutableArray array];
                [conflicts addObject: revID];
                while (c4doc_selectNextLeafRevision(doc, false, false, NULL)) {
                    NSString* conflictID = slice2string(doc->selectedRev.revID);
                    [conflicts addObject: conflictID];
                }
                if (conflicts.count == 1)
                    conflicts = nil;
            }

            NSDictionary* value = $dict({@"rev", revID},
                                        {@"deleted", (deleted ?$true : nil)},
                                        {@"_conflicts", conflicts});  // (not found in CouchDB)
            LogTo(QueryVerbose, @"AllDocs: Found row with key=\"%@\", value=%@",
                  docID, value);
            CBLQueryRow *row = [[CBLQueryRow alloc] initWithDocID: docID
                                                 sequence: doc->sequence
                                                      key: docID
                                                    value: value
                                              docRevision: docRevision
                                                  storage: nil];
            if (filter && !filter(row)) {
                LogTo(QueryVerbose, @"   ... on 2nd thought, filter predicate skipped that row");
                continue;
            }

            if (limit > 0 && --limit == 0) {
                c4enum_free(e);
                e = NULL;
            }
            return row;
        }
        if (c4err.code)
            Warn(@"AllDocs: Enumeration failed: %d", err2status(c4err));
        return nil;
    };
}


- (BOOL) findMissingRevisions: (CBL_RevisionList*)revs
                       status: (CBLStatus*)outStatus
{
    CBL_RevisionList* sortedRevs = [revs mutableCopy];
    [sortedRevs sortByDocID];

    CLEANUP(C4Document)* doc = NULL;
    NSString* lastDocID = nil;
    C4Error c4err = {};
    for (CBL_Revision* rev in sortedRevs) {
        if (!$equal(rev.docID, lastDocID)) {
            lastDocID = rev.docID;
            c4doc_free(doc);
            doc = c4doc_get(_forest, string2slice(lastDocID), true, &c4err);
            if (!doc) {
                *outStatus = err2status(c4err);
                if (*outStatus != kCBLStatusNotFound)
                    return NO;
            }
        }
        if (doc && c4doc_selectRevision(doc, string2slice(rev.revID), false, NULL))
            [revs removeRevIdenticalTo: rev];   // not missing, so remove from list
    }
    return YES;
}


#pragma mark - PURGING / COMPACTING:


- (NSSet*) findAllAttachmentKeys: (NSError**)outError {
    NSMutableSet* keys = [NSMutableSet setWithCapacity: 1000];
    C4Error c4err;
    CLEANUP(C4DocEnumerator)* e = c4db_enumerateAllDocs(_forest, kC4SliceNull, kC4SliceNull,
                                                        NULL, &c4err);
    if (!e) {
        err2OutNSError(c4err, outError);
        return nil;
    }

    while (c4enum_next(e, &c4err)) {
        CLEANUP(C4Document)* doc = c4enum_getDocument(e, &c4err);
        if (!doc) {
            err2OutNSError(c4err, outError);
            return nil;
        }
        C4DocumentFlags flags = doc->flags;
        if (!(flags & kHasAttachments) || ((flags & kDeleted) && !(flags & kConflicted)))
            continue;

        // Since db is assumed to have just been compacted, we know that non-current revisions
        // won't have any bodies. So only scan the current revs.
        do {
            if (doc->selectedRev.flags & kRevHasAttachments) {
                if (!c4doc_loadRevisionBody(doc, &c4err)) {
                    err2OutNSError(c4err, outError);
                    return nil;
                }
                C4Slice body = doc->selectedRev.body;
                if (body.size > 0) {
                    NSDictionary* rev = slice2mutableDict(body);
                    [rev.cbl_attachments enumerateKeysAndObjectsUsingBlock:
                        ^(id key, NSDictionary* att, BOOL *stop) {
                            CBLBlobKey blobKey;
                            if ([CBL_Attachment digest: att[@"digest"] toBlobKey: &blobKey]) {
                                NSData* keyData = [[NSData alloc] initWithBytes: &blobKey
                                                                         length: sizeof(blobKey)];
                                [keys addObject: keyData];
                            }
                        }];
                }
            }
        } while (c4doc_selectNextLeafRevision(doc, false, false, &c4err));
    }
    if (c4err.code) {
        err2OutNSError(c4err, outError);
        keys = nil;
    }
    return keys;
}


- (CBLStatus) purgeRevisions: (NSDictionary*)docsToRevs
                      result: (NSDictionary**)outResult
{
    // <http://wiki.apache.org/couchdb/Purge_Documents>
    NSMutableDictionary* result = $mdict();
    if (outResult)
        *outResult = result;
    if (docsToRevs.count == 0)
        return kCBLStatusOK;
    LogTo(CBLDatabase, @"Purging %lu docs...", (unsigned long)docsToRevs.count);
    return [self inTransaction: ^CBLStatus {
        for (NSString* docID in docsToRevs) {
            C4Slice docIDSlice = string2slice(docID);
            C4Error c4err;

            NSArray* revsPurged;
            NSArray* revIDs = $castIf(NSArray, docsToRevs[docID]);
            if (!revIDs) {
                return kCBLStatusBadParam;
            } else if (revIDs.count == 0) {
                revsPurged = @[];
            } else if ([revIDs containsObject: @"*"]) {
                // Delete all revisions if magic "*" revision ID is given:
                if (!c4db_purgeDoc(_forest, docIDSlice, &c4err))
                    return err2status(c4err);
                revsPurged = @[@"*"];
                LogTo(CBLDatabase, @"Purged doc '%@'", docID);
            } else {
                CLEANUP(C4Document)* doc = c4doc_get(_forest, docIDSlice, true, &c4err);
                if (!doc)
                    return err2status(c4err);
                NSMutableArray* purged = $marray();
                for (NSString* revID in revIDs) {
                    if (c4doc_purgeRevision(doc, string2slice(revID), &c4err) > 0)
                        [purged addObject: revID];
                }
                if (purged.count > 0) {
                    if (!c4doc_save(doc, _maxRevTreeDepth, &c4err))
                        return err2status(c4err);
                    LogTo(CBLDatabase, @"Purged doc '%@' revs %@", docID, revIDs);
                }
                revsPurged = purged;
            }
            result[docID] = revsPurged;
        }
        return kCBLStatusOK;
    }];
}


#pragma mark - LOCAL DOCS:


- (CBL_MutableRevision*) getLocalDocumentWithID: (NSString*)docID
                                     revisionID: (NSString*)revID
{
    if (![docID hasPrefix: @"_local/"])
        return nil;
    C4Error c4err;
    CLEANUP(C4RawDocument) *doc = c4raw_get(_forest, C4STR("_local"), string2slice(docID), &c4err);
    if (!doc)
        return nil;

    NSString* gotRevID = slice2string(doc->meta);
    if (!gotRevID)
        return nil;
    if (revID && !$equal(revID, gotRevID))
        return nil;
    NSMutableDictionary* properties = slice2mutableDict(doc->body);
    if (!properties)
        return nil;
    properties[@"_id"] = docID;
    properties[@"_rev"] = gotRevID;
    CBL_MutableRevision* result = [[CBL_MutableRevision alloc] initWithDocID: docID revID: gotRevID
                                                                     deleted: NO];
    result.properties = properties;
    return result;
}


- (CBL_Revision*) putLocalRevision: (CBL_Revision*)revision
                    prevRevisionID: (NSString*)prevRevID
                          obeyMVCC: (BOOL)obeyMVCC
                            status: (CBLStatus*)outStatus
{
    NSString* docID = revision.docID;
    if (![docID hasPrefix: @"_local/"]) {
        *outStatus = kCBLStatusBadID;
        return nil;
    }
    if (revision.deleted) {
        // DELETE:
        *outStatus = [self deleteLocalDocumentWithID: docID
                                          revisionID: prevRevID
                                            obeyMVCC: obeyMVCC];
        return *outStatus < 300 ? revision : nil;
    } else {
        // PUT:
        __block CBL_Revision* result = nil;
        *outStatus = [self inTransaction: ^CBLStatus {
            NSData* json = revision.asCanonicalJSON;
            if (!json)
                return kCBLStatusBadJSON;

            C4Slice key = string2slice(docID);
            C4Error c4err;
            CLEANUP(C4RawDocument) *doc = c4raw_get(_forest, C4STR("_local"), key, &c4err);
            NSString* actualPrevRevID = doc ? slice2string(doc->meta) : nil;
            if (obeyMVCC && !$equal(prevRevID, actualPrevRevID))
                return kCBLStatusConflict;
            unsigned generation = [CBL_Revision generationFromRevID: actualPrevRevID];
            NSString* newRevID = $sprintf(@"%d-local", generation + 1);

            if (!c4raw_put(_forest, C4STR("_local"), key,
                           string2slice(newRevID), data2slice(json), &c4err))
                return err2status(c4err);

            result = [revision mutableCopyWithDocID: docID revID: newRevID];
            return kCBLStatusCreated;
        }];
        return result;
    }
}


- (CBLStatus) deleteLocalDocumentWithID: (NSString*)docID
                             revisionID: (NSString*)revID
                               obeyMVCC: (BOOL)obeyMVCC
{
    if (![docID hasPrefix: @"_local/"])
        return kCBLStatusBadID;
    if (obeyMVCC && !revID) {
        // Didn't specify a revision to delete: kCBLStatusNotFound or a kCBLStatusConflict, depending
        return [self getLocalDocumentWithID: docID revisionID: nil] ? kCBLStatusConflict : kCBLStatusNotFound;
    }

    return [self inTransaction: ^CBLStatus {
        C4Slice key = string2slice(docID);
        C4Error c4err;
        CLEANUP(C4RawDocument) *doc = c4raw_get(_forest, C4STR("_local"), key, &c4err);
        if (!doc)
            return err2status(c4err);

        else if (obeyMVCC && !$equal(revID, slice2string(doc->meta)))
            return kCBLStatusConflict;
        else {
            if (!c4raw_put(_forest, C4STR("_local"), key, kC4SliceNull, kC4SliceNull, &c4err))
                return err2status(c4err);
            return kCBLStatusOK;
        }
    }];
}


#pragma mark - INFO FOR KEY:


- (NSString*) infoForKey: (NSString*)key {
    C4Error c4err;
    CLEANUP(C4RawDocument) *doc = c4raw_get(_forest, C4STR("info"), string2slice(key), &c4err);
    if (!doc)
        return nil;
    return slice2string(doc->body);
}


- (CBLStatus) setInfo: (NSString*)info forKey: (NSString*)key {
    return [self inTransaction: ^CBLStatus {
        C4Error c4err;
        if (!c4raw_put(_forest, C4STR("info"),
                       string2slice(key), kC4SliceNull, string2slice(info),
                       &c4err))
            return err2status(c4err);
        return kCBLStatusOK;
    }];
}


#pragma mark - INSERTION:


- (CBLDatabaseChange*) changeWithNewRevision: (CBL_Revision*)inRev
                                isWinningRev: (BOOL)isWinningRev
                                         doc: (C4Document*)doc
                                      source: (NSURL*)source
{
    NSString* winningRevID;
    if (isWinningRev)
        winningRevID = inRev.revID;
    else
        winningRevID = slice2string(doc->revID);
    BOOL inConflict = (doc->flags & kConflicted) != 0;
    return [[CBLDatabaseChange alloc] initWithAddedRevision: inRev
                                          winningRevisionID: winningRevID
                                                 inConflict: inConflict
                                                     source: source];
}


- (CBL_Revision*) addDocID: (NSString*)inDocID
                 prevRevID: (NSString*)inPrevRevID
                properties: (NSMutableDictionary*)properties
                  deleting: (BOOL)deleting
             allowConflict: (BOOL)allowConflict
           validationBlock: (CBL_StorageValidationBlock)validationBlock
                    status: (CBLStatus*)outStatus
                     error: (NSError **)outError
{
    if (outError)
        *outError = nil;

    if (_readOnly) {
        *outStatus = kCBLStatusForbidden;
        CBLStatusToOutNSError(*outStatus, outError);
        return nil;
    }

    __block NSData* json = nil;
    if (properties) {
        json = [CBL_Revision asCanonicalJSON: properties error: NULL];
        if (!json) {
            *outStatus = kCBLStatusBadJSON;
            CBLStatusToOutNSError(*outStatus, outError);
            return nil;
        }
    } else {
        json = [NSData dataWithBytes: "{}" length: 2];
    }

    __block CBL_Revision* putRev = nil;
    __block CBLDatabaseChange* change = nil;

    *outStatus = [self inTransaction: ^CBLStatus {
        NSString* docID = inDocID;
        C4Slice prevRevIDSlice = string2slice(inPrevRevID);

        // Let CBForest load the doc and insert the new revision:
        C4DocPutRequest rq = {
            .body = data2slice(json),
            .docID = string2slice(docID),
            .deletion = (bool)deleting,
            .hasAttachments = (properties.cbl_attachments != nil),
            .existingRevision = false,
            .allowConflict = (bool)allowConflict,
            .history = &prevRevIDSlice,
            .historyCount = 1,
            .save = false
        };
        C4Error c4err;
        size_t commonAncestorIndex;
        CLEANUP(C4Document)* doc = c4doc_put(_forest, &rq, &commonAncestorIndex, &c4err);
        if (!doc)
            return err2status(c4err);

        if (!docID)
            docID = slice2string(doc->docID);
        NSString* newRevID = slice2string(doc->selectedRev.revID);

        // Create the new CBL_Revision:
        CBL_Body *body = nil;
        if (properties) {
            properties[@"_id"] = docID;
            properties[@"_rev"] = newRevID;
            body = [[CBL_Body alloc] initWithProperties: properties];
        }
        putRev = [[CBL_Revision alloc] initWithDocID: docID
                                               revID: newRevID
                                             deleted: deleting
                                                body: body];
        if (commonAncestorIndex == 0)
            return kCBLStatusOK;    // Revision already exists; no need to save

        // Run any validation blocks:
        if (validationBlock) {
            CBL_Revision* prevRev = nil;
            if (c4doc_selectParentRevision(doc)) {
                prevRev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                 docID: docID revID: nil
                                                              withBody: NO status: NULL];
            }

            CBLStatus status = validationBlock(putRev, prevRev, prevRev.revID, outError);
            if (CBLStatusIsError(status))
                return status;
        }

        // Save the updated doc:
        BOOL isWinner;
        if (![self saveForestDoc: doc revID: string2slice(newRevID)
                      properties: properties isWinner: &isWinner error: &c4err])
            return err2status(c4err);
        putRev.sequence = doc->sequence;
#if DEBUG
        LogTo(CBLDatabase, @"Saved %@", docID);
#endif

        change = [self changeWithNewRevision: putRev
                                isWinningRev: isWinner
                                         doc: doc
                                      source: nil];
        return deleting ? kCBLStatusOK : kCBLStatusCreated;
    }];

    if (CBLStatusIsError(*outStatus)) {
        // Check if the outError has a value to not override the validation error:
        if (outError && !*outError)
            CBLStatusToOutNSError(*outStatus, outError);
        return nil;
    }
    if (change)
        [_delegate databaseStorageChanged: change];
    return putRev;
}


/** Add an existing revision of a document (probably being pulled) plus its ancestors. */
- (CBLStatus) forceInsert: (CBL_Revision*)inRev
          revisionHistory: (NSArray*)history
          validationBlock: (CBL_StorageValidationBlock)validationBlock
                   source: (NSURL*)source
                    error: (NSError **)outError
{
    if (outError)
        *outError = nil;

    if (_readOnly) {
        CBLStatusToOutNSError(kCBLStatusForbidden, outError);
        return kCBLStatusForbidden;
    }

    NSData* json = inRev.asCanonicalJSON;
    if (!json) {
        CBLStatusToOutNSError(kCBLStatusBadJSON, outError);
        return kCBLStatusBadJSON;
    }

    __block CBLDatabaseChange* change = nil;

    C4Slice* historySlices = (C4Slice*)malloc(history.count * sizeof(C4Slice));
    size_t i = 0;
    for (NSString* revID in history)
        historySlices[i++] = string2slice(revID);

    CBLStatus status = [self inTransaction: ^CBLStatus {
        C4DocPutRequest rq = {
            .body = data2slice(json),
            .docID = string2slice(inRev.docID),
            .deletion = (bool)inRev.deleted,
            .hasAttachments = inRev.attachments != nil,
            .existingRevision = true,
            .allowConflict = true,
            .history = historySlices,
            .historyCount = history.count,
            .save = false
        };
        size_t commonAncestorIndex;
        C4Error c4err;
        CLEANUP(C4Document)* doc = c4doc_put(_forest, &rq, &commonAncestorIndex, &c4err);
        if (!doc)
            return err2status(c4err);

        if (commonAncestorIndex == 0)
            return kCBLStatusOK;    // Rev already existed; no change

        // Validate against the common ancestor:
        if (validationBlock) {
            CBL_Revision* prev = nil;
            if (commonAncestorIndex < history.count) {
                c4doc_selectRevision(doc, historySlices[commonAncestorIndex], false, NULL);
                CBLStatus status;
                prev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                              docID: inRev.docID revID: nil
                                                           withBody: NO status: &status];
            }
            NSString* parentRevID = (history.count > 1) ? history[1] : nil;
            CBLStatus status = validationBlock(inRev, prev, parentRevID, outError);
            if (CBLStatusIsError(status))
                return status;
        }

        // Save updated doc back to the database:
        BOOL isWinner;
        if (![self saveForestDoc: doc revID: historySlices[0] properties: inRev.properties
                        isWinner: &isWinner error: &c4err])
            return err2status(c4err);
        inRev.sequence = doc->sequence;
#if DEBUG
        LogTo(CBLDatabase, @"Saved %@", inRev.docID);
#endif
        change = [self changeWithNewRevision: inRev
                                isWinningRev: isWinner
                                         doc: doc
                                      source: source];
        return kCBLStatusCreated;
    }];

    if (change)
        [_delegate databaseStorageChanged: change];

    if (CBLStatusIsError(status)) {
        // Check if the outError has a value to not override the validation error:
        if (outError && !*outError)
            CBLStatusToOutNSError(status, outError);
    }
    return status;
}


- (BOOL) saveForestDoc: (C4Document*)doc
                 revID: (C4Slice)revID
            properties: (NSDictionary*)properties
              isWinner: (BOOL*)isWinner
                 error: (C4Error*)outErr
{
    // Is the new revision the winner?
    *isWinner = c4SliceEqual(revID, doc->revID);
    // Update the documentType:
    if (!*isWinner) {
        c4doc_selectCurrentRevision(doc);
        properties = [CBLForestBridge bodyOfSelectedRevision: doc];
    }
    c4doc_setType(doc, string2slice(properties[@"type"]));
    // Save:
    return c4doc_save(doc, _maxRevTreeDepth, outErr);
}


#pragma mark - VIEWS:


- (id<CBL_ViewStorage>) viewStorageNamed: (NSString*)name create:(BOOL)create {
    id<CBL_ViewStorage> view = [_views objectForKey: name];
    if (!view) {
        view = [[CBL_ForestDBViewStorage alloc] initWithDBStorage: self name: name create: create];
        if (view) {
            if (!_views)
                _views = [NSMapTable strongToWeakObjectsMapTable];
            [_views setObject: view forKey: name];
        }
    }
    return view;
}


- (void) forgetViewStorageNamed: (NSString*)viewName {
    [_views removeObjectForKey: viewName];
}


- (NSArray*) allViewNames {
    NSArray* filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: _directory
                                                                             error: NULL];
    // Mapping files->views may produce duplicates because there can be multiple files for the
    // same view, if compression is in progress. So use a set to coalesce them.
    NSMutableSet *viewNames = [NSMutableSet set];
    for (NSString* filename in filenames) {
        NSString* viewName = [CBL_ForestDBViewStorage fileNameToViewName: filename];
        if (viewName)
            [viewNames addObject: viewName];
    }
    return viewNames.allObjects;
}


@end
