#import "WPTableViewHandler.h"
#import "WPTableViewSectionHeaderFooterView.h"
#import "WPTableViewCell.h"
#import "WordPress-Swift.h"

static NSString * const DefaultCellIdentifier = @"DefaultCellIdentifier";
static CGFloat const DefaultCellHeight = 44.0;

@interface WPTableViewHandler ()

@property (nonatomic, strong, readwrite) UITableView *tableView;
@property (nonatomic, strong, readwrite) NSFetchedResultsController *resultsController;
@property (nonatomic, strong) NSIndexPath *indexPathSelectedBeforeUpdates;
@property (nonatomic, strong) NSIndexPath *indexPathSelectedAfterUpdates;
@property (nonatomic, strong) NSMutableArray *sectionHeaders;
@property (nonatomic, strong) NSMutableDictionary *cachedRowHeights;
@property (nonatomic, strong) NSMutableArray *rowsWithInvalidatedHeights;
@property (nonatomic, readwrite) BOOL isScrolling;
@property (nonatomic) BOOL refreshingTableViewPreservingOffset;
@property (nonatomic, strong) NSArray *fetchedResultsBeforeChange;
@property (nonatomic, strong) NSArray *fetchedResultsIndexPathsBeforeChange;
@property (nonatomic, strong) NSArray *rowHeightsBeforeChange;

@end

@implementation WPTableViewHandler

#pragma mark - LifeCycle Methods

- (void)dealloc
{
    _resultsController.delegate = nil;
    _tableView.delegate = nil;
    _tableView.dataSource = nil;
}

- (instancetype)initWithTableView:(UITableView *)tableView
{
    self = [super init];
    if (self) {
        _sectionHeaders = [NSMutableArray array];
        _cachedRowHeights = [NSMutableDictionary dictionary];
        _rowsWithInvalidatedHeights = [NSMutableArray array];
        _updateRowAnimation = UITableViewRowAnimationFade;
        _insertRowAnimation = UITableViewRowAnimationFade;
        _deleteRowAnimation = UITableViewRowAnimationFade;
        _moveRowAnimation = UITableViewRowAnimationFade;
        _sectionRowAnimation = UITableViewRowAnimationFade;
        _tableView = tableView;
        _tableView.delegate = self;
        _tableView.dataSource = self;
        [_tableView registerClass:[WPTableViewCell class] forCellReuseIdentifier:DefaultCellIdentifier];
    }
    return self;
}


#pragma mark - Public Methods

- (void)clearCachedRowHeights
{
    [self.cachedRowHeights removeAllObjects];
}

- (void)refreshTableView
{
    [self clearCachedRowHeights];
    [self.tableView reloadData];
}

- (void)refreshTableViewPreservingOffset
{
    [self preserveRowInfoBeforeContentChanges];

    // Make sure its necessary to account for previously existing rows.
    // We check here vs in `controllerWillChangeContent:` in order to reload
    // the table view if necessary.
    if ([self.fetchedResultsBeforeChange count] == 0) {
        if ([self.delegate respondsToSelector:@selector(tableViewHandlerWillRefreshTableViewPreservingOffset:)]) {
            [self.delegate tableViewHandlerWillRefreshTableViewPreservingOffset:self];
        }

        [self.tableView reloadData];
        [self discardPreservedRowInfo];

        if ([self.delegate respondsToSelector:@selector(tableViewHandlerDidRefreshTableViewPreservingOffset:)]) {
            [self.delegate tableViewHandlerDidRefreshTableViewPreservingOffset:self];
        }
        return;
    }

    self.refreshingTableViewPreservingOffset = YES;

    // Get the current visible index paths before reloading data.
    NSArray *visibleIndexPaths = [self.tableView indexPathsForVisibleRows];

    // Get the delta of the current offset and the sum of the preserved row
    // heights, up to but not including the first visible row.
    CGFloat offsetHeightDelta = [self contentOffsetAndPreservedRowHeightDelta];

    // Notify the delegate that a refresh is about to occur. Allows the delegate
    // perform any final clean up, e.g. dismissing a UIRefreshControl.
    if ([self.delegate respondsToSelector:@selector(tableViewHandlerWillRefreshTableViewPreservingOffset:)]) {
        [self.delegate tableViewHandlerWillRefreshTableViewPreservingOffset:self];
    }

    // Clear cached heights and reload the tableview
    [self refreshTableView];

    // Find the indexPath of the first visible object after changes
    // If the first object was deleted, try the next in line of the previously
    // visible objects until a match is found.
    CGFloat heightAdjustment = 0;
    NSIndexPath *newIndexPath = nil;
    for (NSInteger i = 0; i < [visibleIndexPaths count]; i++) {
        NSIndexPath *path = visibleIndexPaths[i];
        NSInteger index = [self.fetchedResultsIndexPathsBeforeChange indexOfObject:path];
        NSManagedObject *obj = self.fetchedResultsBeforeChange[index];
        if (obj.isFault) {
            NSError *error;
            obj = [self.resultsController.managedObjectContext existingObjectWithID:obj.objectID error:&error];
            if (error) {
                DDLogError(@"%@, Error %@", NSStringFromSelector(_cmd), error);
            }
        }
        newIndexPath = [self.resultsController indexPathForObject:obj];
        if (newIndexPath) {
            break;
        }

        // Visible cell not found. Add its height to the adjustment.
        NSNumber *height = self.rowHeightsBeforeChange[i];
        heightAdjustment += [height floatValue];
    }

    // If none of the previously visible objects exist, find the first object
    // preceding the first visible cell instead.
    if (!newIndexPath) {
        heightAdjustment = 0; // Discard any height adjustment.
        newIndexPath = [self indexPathForFirstObjectPrecedingPreservedVisibleIndexPath:[visibleIndexPaths firstObject]];
    }

    if (!newIndexPath) {
        // Fail safe. If the new index path is nil set the offset to 0
        [self.tableView setContentOffset:CGPointZero];

    } else {
        // Now that we know the new location. Get the sum of the row heights for all
        // preceeding rows. Add the delta and any adjustment.
        CGFloat rowHeights = [self totalHeightForRowsAboveIndexPath:newIndexPath];
        rowHeights += (offsetHeightDelta + heightAdjustment);
        // Set the tableview to the new offset
        CGPoint newOffset = CGPointMake([self.tableView contentOffset].x, rowHeights);
        [self.tableView setContentOffset:newOffset];
    }

    // Clean up
    self.refreshingTableViewPreservingOffset = NO;
    [self discardPreservedRowInfo];

    // Notify the delegate that a refresh has occured. Allows the delegate
    // perform any corrections to the offset, e.g. a negative offset due to a content
    // change that was not a post inserted above the previous zero visible index.
    if ([self.delegate respondsToSelector:@selector(tableViewHandlerDidRefreshTableViewPreservingOffset:)]) {
        [self.delegate tableViewHandlerDidRefreshTableViewPreservingOffset:self];
    }
}


#pragma mark - Private Methods

- (void)cacheRowHeight:(CGFloat)height forIndexPath:(NSIndexPath *)indexPath
{
    [self.cachedRowHeights setObject:@(height) forKey:[indexPath toString]];
}

- (CGFloat)cachedRowHeightForIndexPath:(NSIndexPath *)indexPath
{
    return [[self.cachedRowHeights numberForKey:[indexPath toString]] floatValue];
}

- (void)refreshCachedRowHeightsForWidth:(CGFloat)width
{
    if (!self.cacheRowHeights || ![self.delegate respondsToSelector:@selector(tableView:heightForRowAtIndexPath:forWidth:)]) {
        return;
    }

    NSMutableDictionary *cachedRowHeights = [NSMutableDictionary dictionary];
    for (NSObject<NSFetchRequestResult> *obj in self.resultsController.fetchedObjects) {
        NSIndexPath *indexPath = [self.resultsController indexPathForObject:obj];
        if (!indexPath) {
            continue;
        }
        CGFloat height = [self.delegate tableView:self.tableView heightForRowAtIndexPath:indexPath forWidth:width];
        [cachedRowHeights setObject:@(height) forKey:[indexPath toString]];
    }

    self.cachedRowHeights = cachedRowHeights;
}

- (void)clearCachedRowHeightsBelowIndexPath:(NSIndexPath *)indexPath
{
    if (!self.cacheRowHeights) {
        return;
    }

    NSString *nukedPathKey = indexPath.toString;
    NSMutableArray *invalidKeys = [NSMutableArray array];

    for (NSString *key in [self.cachedRowHeights allKeys]) {
        if ([key compare:nukedPathKey] == NSOrderedDescending) {
            [invalidKeys addObject:key];
        }
    }

    [self.cachedRowHeights removeObjectForKey:nukedPathKey];
    [self.cachedRowHeights removeObjectsForKeys:invalidKeys];
}

- (void)clearCachedRowHeightAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.cacheRowHeights) {
        return;
    }
    [self.cachedRowHeights removeObjectForKey:indexPath.toString];
}

- (void)invalidateCachedRowHeightAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.cacheRowHeights) {
        return;
    }

    NSString *key = [indexPath toString];
    NSNumber *height = [self.cachedRowHeights objectForKey:key];
    if (!height) {
        return;
    }

    [self.rowsWithInvalidatedHeights addObject:indexPath];
    [self clearCachedRowHeightAtIndexPath:indexPath];
}


#pragma mark - Required Delegate Methods

- (NSManagedObjectContext *)managedObjectContext
{
    return [self.delegate managedObjectContext];
}

- (NSFetchRequest *)fetchRequest
{
    return [self.delegate fetchRequest];
}

- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    [self.delegate configureCell:cell atIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
}


#pragma mark - Optional Delegate Methods

- (NSString *)sectionNameKeyPath
{
    if ([self.delegate respondsToSelector:@selector(sectionNameKeyPath)]) {
        return [self.delegate sectionNameKeyPath];
    }
    return nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:canEditRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView canEditRowAtIndexPath:indexPath];
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:commitEditingStyle:forRowAtIndexPath:)]) {
        [self.delegate tableView:tableView commitEditingStyle:editingStyle forRowAtIndexPath:indexPath];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:editingStyleForRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView editingStyleForRowAtIndexPath:indexPath];
    }
    return UITableViewCellEditingStyleNone;
}

- (NSArray *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:editActionsForRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView editActionsForRowAtIndexPath:indexPath];
    }
    
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView cellForRowAtIndexPath:indexPath];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DefaultCellIdentifier];

    if (self.tableView.isEditing) {
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    [self configureCell:cell atIndexPath:indexPath];

    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:titleForDeleteConfirmationButtonForRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView titleForDeleteConfirmationButtonForRowAtIndexPath:indexPath];
    }
    return nil;
}

- (void)deletingSelectedRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(deletingSelectedRowAtIndexPath:)]) {
        [self.delegate deletingSelectedRowAtIndexPath:indexPath];
    }
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat height = DefaultCellHeight;

    if (self.cacheRowHeights) {
        height = [self cachedRowHeightForIndexPath:indexPath];
        if (height) {
            return height;
        }

        if ([self.rowsWithInvalidatedHeights containsObject:indexPath]) {
            // Recompute and return the real height.  It will end up in the cache automatically.
            [self.rowsWithInvalidatedHeights removeObject:indexPath];
            height = [self tableView:tableView heightForRowAtIndexPath:indexPath];
            return height;
        }
    }

    if (self.refreshingTableViewPreservingOffset) {
        // when refreshing this way we need to calculate actual heights not estimated heights.
        height = [self tableView:tableView heightForRowAtIndexPath:indexPath];
        return height;
    }

    if ([self.delegate respondsToSelector:@selector(tableView:estimatedHeightForRowAtIndexPath:)]) {
        height = [self.delegate tableView:tableView estimatedHeightForRowAtIndexPath:indexPath];
    }

    return height;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat height = DefaultCellHeight;

    if (self.cacheRowHeights) {
        height = [self cachedRowHeightForIndexPath:indexPath];
        if (height) {
            return height;
        }
    }

    if ([self.delegate respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)]) {
        height = [self.delegate tableView:tableView heightForRowAtIndexPath:indexPath];
        if (self.cacheRowHeights) {
            [self cacheRowHeight:height forIndexPath:indexPath];
        }
    }
    return height;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:shouldHighlightRowAtIndexPath:)]) {
        return [self.delegate tableView:tableView shouldHighlightRowAtIndexPath:indexPath];
    }
    return YES;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)]) {
        [self.delegate tableView:tableView willSelectRowAtIndexPath:indexPath];
    }
    return indexPath;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:willDisplayCell:forRowAtIndexPath:)]) {
        [self.delegate tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableView:didEndDisplayingCell:forRowAtIndexPath:)]) {
        [self.delegate tableView:tableView didEndDisplayingCell:cell forRowAtIndexPath:indexPath];
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {
        return [self.delegate tableView:tableView viewForHeaderInSection:section];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:heightForHeaderInSection:)]) {
        return [self.delegate tableView:tableView heightForHeaderInSection:section];
    }
    return UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:viewForFooterInSection:)]) {
        return [self.delegate tableView:tableView viewForFooterInSection:section];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:heightForFooterInSection:)]) {
        return [self.delegate tableView:tableView heightForFooterInSection:section];
    }
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:willDisplayHeaderView:forSection:)]) {
        [self.delegate tableView:tableView willDisplayHeaderView:view forSection:section];
    } else {
        [WPStyleGuide configureTableViewSectionHeader:view];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:willDisplayFooterView:forSection:)]) {
        [self.delegate tableView:tableView willDisplayFooterView:view forSection:section];
    } else {
        [WPStyleGuide configureTableViewSectionFooter:view];
    }
}

#pragma mark - TableView Datasource Methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [[self.resultsController sections] count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray *sections = [self.resultsController sections];
    if ([sections count] == 0) {
        return 0;
    }
    id <NSFetchedResultsSectionInfo> sectionInfo = nil;
    sectionInfo = [sections objectAtIndex:section];
    return [sectionInfo numberOfObjects];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
        return [self.delegate tableView:tableView titleForHeaderInSection:section];
    }
    id <NSFetchedResultsSectionInfo> sectionInfo = [[self.resultsController sections] objectAtIndex:section];
    return [sectionInfo name];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if ([self.delegate respondsToSelector:@selector(tableView:titleForFooterInSection:)]) {
        return [self.delegate tableView:tableView titleForFooterInSection:section];
    }
    return nil;
}

#pragma mark - UIScrollViewDelegate Methods

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    self.isScrolling = YES;
    if ([self.delegate respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [self.delegate scrollViewWillBeginDragging:scrollView];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    self.isScrolling = NO;
    if ([self.delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [self.delegate scrollViewDidEndDecelerating:scrollView];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if ([self.delegate respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [self.delegate scrollViewDidScroll:scrollView];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    self.isScrolling = decelerate;
    if ([self.delegate respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [self.delegate scrollViewDidEndDragging:scrollView willDecelerate:(BOOL)decelerate];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset
{
    if ([self.delegate respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)]) {
        [self.delegate scrollViewWillEndDragging:scrollView withVelocity:velocity targetContentOffset:targetContentOffset];
    }
}


#pragma mark - Fetched results controller

- (NSFetchedResultsController *)resultsController
{
    if (_resultsController != nil) {
        return _resultsController;
    }

    NSFetchRequest *fetchRequest = [self fetchRequest];
    if (!fetchRequest) {
        return nil;
    }

    NSManagedObjectContext *moc = [self managedObjectContext];
    _resultsController = [[NSFetchedResultsController alloc] initWithFetchRequest:[self fetchRequest]
                                                             managedObjectContext:moc
                                                               sectionNameKeyPath:[self sectionNameKeyPath]
                                                                        cacheName:nil];
    _resultsController.delegate = self;

    NSError *error = nil;
    if (![_resultsController performFetch:&error]) {
        DDLogError(@"%@ couldn't fetch %@: %@", self, [[self fetchRequest] entityName], [error localizedDescription]);
        _resultsController = nil;
    }

    return _resultsController;
}

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
    if ([self.delegate respondsToSelector:@selector(tableViewWillChangeContent:)]) {
        [self.delegate tableViewWillChangeContent:self.tableView];
    }

    self.indexPathSelectedBeforeUpdates = [self.tableView indexPathForSelectedRow];
    [self.tableView beginUpdates];
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    [self.tableView endUpdates];
    
    if (self.indexPathSelectedAfterUpdates) {
        [self.tableView selectRowAtIndexPath:self.indexPathSelectedAfterUpdates animated:NO scrollPosition:UITableViewScrollPositionNone];
    } else if (self.indexPathSelectedBeforeUpdates) {
        [self.tableView selectRowAtIndexPath:self.indexPathSelectedBeforeUpdates animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    
    self.indexPathSelectedBeforeUpdates = nil;
    self.indexPathSelectedAfterUpdates = nil;

    if ([self.delegate respondsToSelector:@selector(tableViewDidChangeContent:)]) {
        [self.delegate tableViewDidChangeContent:self.tableView];
    }
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    if (NSFetchedResultsChangeUpdate == type && newIndexPath && ![newIndexPath isEqual:indexPath]) {
        // Seriously, Apple?
        // http://developer.apple.com/library/ios/#releasenotes/iPhone/NSFetchedResultsChangeMoveReportedAsNSFetchedResultsChangeUpdate/_index.html
        type = NSFetchedResultsChangeMove;
    }

    if (newIndexPath == nil) {
        // It seems in some cases newIndexPath can be nil for updates
        newIndexPath = indexPath;
    }
    
    switch(type) {
        case NSFetchedResultsChangeInsert:
        {
            [self clearCachedRowHeightsBelowIndexPath:newIndexPath];
            [self.tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:self.insertRowAnimation];
        }
            break;
        case NSFetchedResultsChangeDelete:
        {
            [self clearCachedRowHeightsBelowIndexPath:indexPath];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:self.deleteRowAnimation];
            if ([self.indexPathSelectedBeforeUpdates isEqual:indexPath]) {
                [self deletingSelectedRowAtIndexPath:indexPath];
            }
        }
            break;
        case NSFetchedResultsChangeUpdate:
        {
            [self invalidateCachedRowHeightAtIndexPath:indexPath];
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:self.updateRowAnimation];
        }
            break;
        case NSFetchedResultsChangeMove:
        {
            NSIndexPath *lowerIndexPath = indexPath;
            if ([indexPath compare:newIndexPath] == NSOrderedDescending) {
                lowerIndexPath = newIndexPath;
            }
            [self clearCachedRowHeightsBelowIndexPath:lowerIndexPath];

            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:self.moveRowAnimation];
            [self.tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:self.moveRowAnimation];
            if ([self.indexPathSelectedBeforeUpdates isEqual:indexPath] && self.indexPathSelectedAfterUpdates == nil) {
                self.indexPathSelectedAfterUpdates = newIndexPath;
            }
        }
            break;
        default:
            break;
    }
}

- (void)controller:(NSFetchedResultsController *)controller didChangeSection:(id)sectionInfo atIndex:(NSUInteger)sectionIndex forChangeType:(NSFetchedResultsChangeType)type
{
    if (type == NSFetchedResultsChangeInsert) {
        [self.tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:self.sectionRowAnimation];
    } else if (type == NSFetchedResultsChangeDelete) {
        [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:self.sectionRowAnimation];
    }
}


#pragma mark - Refresh and Preserve Offset Methods

- (void)preserveRowInfoBeforeContentChanges
{
    self.fetchedResultsBeforeChange = [[self.resultsController fetchedObjects] copy];
    NSIndexPath *lastVisibleIndexPath = [[self.tableView indexPathsForVisibleRows] lastObject];

    NSMutableArray *indexPaths = [NSMutableArray array];
    NSMutableArray *rowHeights = [NSMutableArray array];
    for (NSManagedObject *object in self.fetchedResultsBeforeChange) {
        NSIndexPath *indexPath = [self.resultsController indexPathForObject:object];
        if (!indexPath) {
            continue;
        }
        // Only preserve info relevant to the current scroll offset. Anything else is extra work.
        NSComparisonResult order = [indexPath compare:lastVisibleIndexPath];
        if (order == NSOrderedDescending) {
            continue;
        }

        [indexPaths addObject:indexPath];

        CGFloat height;
        // Use a cached height if we have one.
        if (self.cacheRowHeights && [[self.cachedRowHeights allKeys] containsObject:indexPath]) {
            height = [[self.cachedRowHeights objectForKey:indexPath] floatValue];
        } else {

            height = [self tableView:self.tableView heightForRowAtIndexPath:indexPath];
        }
        [rowHeights addObject:@(height)];
    }

    self.rowHeightsBeforeChange = rowHeights;
    self.fetchedResultsIndexPathsBeforeChange = indexPaths;
}

- (CGFloat)contentOffsetAndPreservedRowHeightDelta
{
    // Get the current scroll offset
    CGPoint offset = [[self tableView] contentOffset];

    NSArray *visibleIndexPaths = [self.tableView indexPathsForVisibleRows];
    NSIndexPath *firstVisibleIndexPath = [visibleIndexPaths firstObject];

    // Get the sum of the height of all cells up to but not including the first visible cell
    CGFloat rowHeights = 0;
    for (NSInteger i = 0; i < [self.fetchedResultsIndexPathsBeforeChange count]; i++) {
        NSIndexPath *path = self.fetchedResultsIndexPathsBeforeChange[i];
        if ([firstVisibleIndexPath compare:path] == NSOrderedDescending) {
            NSNumber *height = self.rowHeightsBeforeChange[i];
            rowHeights += [height floatValue];
        }
    }

    // Get the delta between the sum of the row heights and the current offset
    // offset.y should be the greater of the two.
    CGFloat offsetHeightDelta = offset.y - rowHeights;
    return offsetHeightDelta;
}

- (NSIndexPath *)indexPathForFirstObjectPrecedingPreservedVisibleIndexPath:(NSIndexPath *)indexPath
{
    NSInteger index = [self.fetchedResultsIndexPathsBeforeChange indexOfObject:indexPath];
    if (NSNotFound == index) {
        return nil;
    }
    NSArray *arr = [self.fetchedResultsIndexPathsBeforeChange subarrayWithRange:NSMakeRange(0, index)];
    for (NSInteger  i = [arr count] -1; i > 0; i-- ) {
        NSManagedObject *obj = self.fetchedResultsBeforeChange[i];
        NSIndexPath *newIndexPath = [self.resultsController indexPathForObject:obj];
        if (newIndexPath) {
            return newIndexPath;
        }
    }
    return nil;
}

- (CGFloat)totalHeightForRowsAboveIndexPath:(NSIndexPath *)indexPath
{
    // Get the sum of the row heights for all preceeding rows.
    NSManagedObject *lastObject = [self.resultsController objectAtIndexPath:indexPath];
    NSInteger index = [[self.resultsController fetchedObjects] indexOfObject:lastObject];
    CGFloat rowHeights = 0;
    for (NSInteger i = 0; i < index; i++) {
        NSManagedObject *object = [self.resultsController.fetchedObjects objectAtIndex:i];
        NSIndexPath *path = [self.resultsController indexPathForObject:object];

        // Get the height from the delegate method so we can respect height caching.
        CGFloat height = [self tableView:self.tableView heightForRowAtIndexPath:path];
        rowHeights += height;
    }
    return rowHeights;
}

- (void)discardPreservedRowInfo
{
    self.rowHeightsBeforeChange = nil;
    self.fetchedResultsBeforeChange = nil;
    self.fetchedResultsIndexPathsBeforeChange = nil;
}

@end
