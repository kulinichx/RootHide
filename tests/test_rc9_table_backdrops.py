"""Backdrop ordering regression, not a UIKit bounce or device acceptance test.

The native harness executes the production method with Foundation arrays and a
small view-order test double. It does not simulate UIKit layout or rendering.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


BASE = "Application/Dopamine/UI/Settings/PSLists/DOPSListController"
SELECTOR = "- (void)keepTableBackdropViewsBehindContent:"


class TableBackdropContracts(unittest.TestCase):
    def test_shared_method_is_declared_and_repairs_only_incorrect_order(self):
        self.assertIn(SELECTOR, source(BASE + ".h"))
        method = extract(source(BASE + ".m"), SELECTOR)
        self.assertIn("if (!backdropViews.count) return;", method)
        self.assertIn("for (UIView *subview in _table.subviews)", method)
        self.assertIn("if (!contentSeen) continue;", method)
        self.assertIn("if (backdrop.superview == _table)", method)
        self.assertEqual(method.count("sendSubviewToBack:"), 1)
        self.assertLess(method.index("if (!contentSeen) continue;"),
                        method.index("sendSubviewToBack:"))

    def test_both_pages_preserve_cell_styling_and_use_guarded_ordering(self):
        for name in ("DOSettingsController", "DOCreditsViewController"):
            text = source(f"Application/Dopamine/UI/Settings/{name}.m")
            text = text.split(f"@implementation {name}\n", 1)[1]
            display = extract(
                text, "- (void)tableView:(UITableView *)tableView willDisplayCell:")
            self.assertIn("[self customGlassStyleVisibleCell:cell atIndexPath:indexPath];",
                          display)
            self.assertIn("if (DORHSupporterIsVerified())", display)
            self.assertIn(
                "[self keepTableBackdropViewsBehindContent:self.customGlassSectionBackdropViews.allValues];",
                display)
            self.assertNotIn("sendSubviewToBack:", display)
            self.assertNotIn("dispatch_async", display)

    def test_order_repair_does_not_change_scroll_state_or_material(self):
        method = extract(source(BASE + ".m"), SELECTOR)
        for token in ("contentOffset", "contentInset", "adjustedContentInset",
                      ".frame", ".bounds", ".transform", "reloadData",
                      "reloadMaterial", "layoutIfNeeded", "setNeedsLayout",
                      "dispatch_", "NSTimer", "animateWith"):
            self.assertNotIn(token, method)

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_table_backdrops.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

@interface UIView : NSObject
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, strong) NSMutableArray<UIView *> *subviews;
@property (nonatomic) NSUInteger reorderCount;
- (void)sendSubviewToBack:(UIView *)view;
@end

@implementation UIView
- (instancetype)init {
    self = [super init];
    if (self) _subviews = [NSMutableArray new];
    return self;
}
- (void)sendSubviewToBack:(UIView *)view {
    assert(view.superview == self);
    assert([self.subviews containsObject:view]);
    [self.subviews removeObjectIdenticalTo:view];
    [self.subviews insertObject:view atIndex:0];
    self.reorderCount++;
}
@end

@interface DOPSListController : NSObject {
@public
    UIView *_table;
}
- (void)keepTableBackdropViewsBehindContent:(NSArray<UIView *> *)backdropViews;
@end

@implementation DOPSListController
'''

NATIVE_MAIN = r'''
@end

static NSArray<UIView *> *makeViews(NSUInteger count) {
    NSMutableArray<UIView *> *views = [NSMutableArray new];
    for (NSUInteger i = 0; i < count; i++) [views addObject:[UIView new]];
    return views;
}

static void attach(UIView *table, NSArray<UIView *> *order) {
    for (UIView *view in table.subviews) view.superview = nil;
    table.subviews = [order mutableCopy];
    for (UIView *view in table.subviews) view.superview = table;
    table.reorderCount = 0;
}

static NSArray<UIView *> *contents(NSArray<UIView *> *order, NSArray<UIView *> *glass) {
    NSMutableArray<UIView *> *result = [NSMutableArray new];
    for (UIView *view in order)
        if (![glass containsObject:view]) [result addObject:view];
    return result;
}

static void checkRepair(DOPSListController *controller, NSArray<UIView *> *glass) {
    UIView *table = controller->_table;
    NSArray<UIView *> *before = [table.subviews copy];
    NSArray<UIView *> *contentBefore = contents(before, glass);
    BOOL needsRepair = NO, sawContent = NO;
    for (UIView *view in before) {
        if ([glass containsObject:view]) {
            if (sawContent) needsRepair = YES;
        } else {
            sawContent = YES;
        }
    }
    [controller keepTableBackdropViewsBehindContent:glass];
    assert([table.subviews count] == before.count);
    assert([[NSSet setWithArray:table.subviews] isEqualToSet:[NSSet setWithArray:before]]);
    assert([contents(table.subviews, glass) isEqualToArray:contentBefore]);
    sawContent = NO;
    for (UIView *view in table.subviews) {
        if ([glass containsObject:view]) assert(!sawContent);
        else sawContent = YES;
        assert(view.superview == table);
    }
    if (needsRepair) {
        assert(table.reorderCount > 0);
    } else {
        assert(table.reorderCount == 0);
        assert([table.subviews isEqualToArray:before]);
    }
    NSUInteger repairedCount = table.reorderCount;
    NSArray<UIView *> *repaired = [table.subviews copy];
    for (NSUInteger i = 0; i < 200; i++)
        [controller keepTableBackdropViewsBehindContent:glass];
    assert(table.reorderCount == repairedCount);
    assert([table.subviews isEqualToArray:repaired]);
}

static void permutations(DOPSListController *controller, NSMutableArray<UIView *> *order,
                         NSUInteger start, NSArray<UIView *> *glass, NSUInteger *cases) {
    if (start == order.count) {
        attach(controller->_table, order);
        checkRepair(controller, glass);
        (*cases)++;
        return;
    }
    for (NSUInteger i = start; i < order.count; i++) {
        [order exchangeObjectAtIndex:start withObjectAtIndex:i];
        permutations(controller, order, start + 1, glass, cases);
        [order exchangeObjectAtIndex:start withObjectAtIndex:i];
    }
}

int main(void) { @autoreleasepool {
    DOPSListController *controller = [DOPSListController new];
    controller->_table = [UIView new];
    [controller keepTableBackdropViewsBehindContent:nil];
    checkRepair(controller, @[]);

    // Every ordering of three surfaces and three content views.
    NSArray<UIView *> *glass = makeViews(3);
    NSMutableArray<UIView *> *order = [glass mutableCopy];
    [order addObjectsFromArray:makeViews(3)];
    NSUInteger cases = 0;
    permutations(controller, order, 0, glass, &cases);
    assert(cases == 720);

    // Different menu lengths must not make an already-correct hierarchy mutate.
    for (NSNumber *count in @[@0, @1, @50, @200]) {
        NSArray<UIView *> *rows = makeViews(count.unsignedIntegerValue);
        order = [glass mutableCopy];
        [order addObjectsFromArray:rows];
        attach(controller->_table, order);
        checkRepair(controller, glass);
        assert(controller->_table.reorderCount == 0);
        if (rows.count) {
            // A reused row inserted below all surfaces must still be repaired.
            order = [NSMutableArray arrayWithObject:rows.lastObject];
            [order addObjectsFromArray:glass];
            [order addObjectsFromArray:[rows subarrayWithRange:NSMakeRange(0, rows.count - 1)]];
            attach(controller->_table, order);
            checkRepair(controller, glass);
        }
    }

    // A stale surface from another table is never reparented or reordered.
    UIView *otherTable = [UIView new];
    UIView *detached = [UIView new];
    [otherTable.subviews addObject:detached];
    detached.superview = otherTable;
    NSMutableArray<UIView *> *withDetached = [glass mutableCopy];
    [withDetached addObject:detached];
    attach(controller->_table, [makeViews(2) arrayByAddingObjectsFromArray:glass]);
    checkRepair(controller, withDetached);
    assert(detached.superview == otherTable);
    assert(otherTable.reorderCount == 0);
    assert(otherTable.subviews.firstObject == detached);
    puts("PASS: production backdrop order guard; 720 permutations, repeated callbacks, short/long content and stale surfaces");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    code = "\n".join((NATIVE_PREFIX, extract(source(BASE + ".m"), SELECTOR), NATIVE_MAIN))
    with tempfile.TemporaryDirectory(prefix="rc9-table-backdrops-") as directory:
        path = Path(directory) / "table_backdrops.m"
        binary = Path(directory) / "table_backdrops"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([
                clang, "-fobjc-arc", "-framework", "Foundation",
                "-Wall", "-Wextra", "-Werror", "-O1", "-g",
                "-fsanitize=address,undefined", str(path), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout, end="")
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            if not diagnostic:
                diagnostic = f"native command exited with status {error.returncode}"
            escaped = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Table backdrop native regression::{escaped[:3000]}")
            sys.stderr.write(diagnostic)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(TableBackdropContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; --native requires macOS Foundation.")
