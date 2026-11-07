"""Preferences frame ownership regression using measured input geometry.

The native test runs the production layout method with a counted superclass and
table double. It checks ownership, not UIKit bounce physics or device acceptance.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import ROOT, extract, source


BASE = "Application/Dopamine/UI/Settings/PSLists/DOPSListController.m"
FIXTURE = ROOT / "tests/fixtures/settings-top-bounce-ios166-c3610a00.json"


def layout_method():
    return extract(source(BASE), "- (void)viewDidLayoutSubviews")


class ListLayoutContracts(unittest.TestCase):
    def test_rc9_does_not_resize_or_reposition_the_preferences_table(self):
        layout = layout_method()
        self.assertEqual(layout.count("[super viewDidLayoutSubviews];"), 1)
        for token in ("_table.frame", "_table.bounds", ".transform", "setFrame:",
                      "setBounds:", "contentOffset", "setContentOffset:",
                      "layoutIfNeeded", "reloadData", "dispatch_", "return;"):
            self.assertNotIn(token, layout)

    def test_bottom_padding_is_guarded_and_does_not_change_native_top_policy(self):
        layout = layout_method()
        self.assertIn("UIEdgeInsets insets = _table.contentInset;", layout)
        self.assertIn("insets.bottom = 24.0;", layout)
        self.assertIn("if (!UIEdgeInsetsEqualToEdgeInsets(_table.contentInset, insets))",
                      layout)
        for token in ("insets.top =", "insets.left =", "insets.right =",
                      "contentInsetAdjustmentBehavior", "estimated", "bounces"):
            self.assertNotIn(token, layout)

    def test_measured_trace_records_resets_inside_the_parent_layout(self):
        report = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cycles = report["layout_cycles"]
        self.assertEqual(report["source_sample_count"], 109)
        self.assertEqual(report["source_dropped_samples"], 0)
        self.assertEqual(len(cycles), 9)
        self.assertEqual(sum(c["before_y"] < 0 for c in cycles), 6)
        self.assertTrue(all(c["preferences_y"] == c["rc9_y"] == 0 for c in cycles))
        self.assertEqual(report["page_bounds"],
                         report["table_frame_after_preferences_each_layout"])
        self.assertEqual(report["table_frame_before_each_layout"],
                         report["table_frame_after_rc9_each_layout"])
        self.assertNotEqual(report["table_frame_before_each_layout"],
                            report["table_frame_after_preferences_each_layout"])
        self.assertEqual(report["content_inset_all_samples"],
                         report["adjusted_inset_all_samples"])

    def test_both_pages_use_the_shared_layout_and_refresh_existing_glass(self):
        for name in ("DOSettingsController", "DOCreditsViewController"):
            prefix = f"Application/Dopamine/UI/Settings/{name}"
            self.assertIn(f"@interface {name} : DOPSListController",
                          source(prefix + ".h"))
            text = source(prefix + ".m").split(f"@implementation {name}\n", 1)[1]
            layout = extract(text, "- (void)viewDidLayoutSubviews")
            self.assertIn("[super viewDidLayoutSubviews];", layout)
            self.assertIn("[self customGlassRefreshSectionBackdrops];", layout)
            for token in (".frame =", "contentOffset", "contentInset", "reloadData"):
                self.assertNotIn(token, layout)

    def test_ci_runs_the_counted_native_layout_regression(self):
        self.assertIn("python3 tests/test_rc9_list_layout.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>

typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static BOOL UIEdgeInsetsEqualToEdgeInsets(UIEdgeInsets a, UIEdgeInsets b) {
    return a.top == b.top && a.left == b.left &&
        a.bottom == b.bottom && a.right == b.right;
}

@interface RCTestView : NSObject
@property(nonatomic) CGRect bounds;
@end
@implementation RCTestView
@end

@interface RCTestTable : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) UIEdgeInsets contentInset;
@property(nonatomic) NSUInteger frameWrites;
@property(nonatomic) NSUInteger insetWrites;
@end
@implementation RCTestTable
@synthesize frame = _frame, contentInset = _contentInset;
- (void)setFrame:(CGRect)frame {
    _frame = frame;
    self.frameWrites++;
}
- (void)setContentInset:(UIEdgeInsets)insets {
    _contentInset = insets;
    self.insetWrites++;
}
@end

// This counted parent is a contract boundary, not a Preferences implementation.
@interface PSListController : NSObject {
@public
    RCTestTable *_table;
}
@property(nonatomic, strong) RCTestView *view;
@property(nonatomic) NSUInteger parentLayouts;
- (void)viewDidLayoutSubviews;
@end
@implementation PSListController
- (void)viewDidLayoutSubviews {
    self.parentLayouts++;
    _table.frame = self.view.bounds;
}
@end

@interface DOPSListController : PSListController
@property(nonatomic, strong) NSMutableArray<NSNumber *> *phases;
- (void)recordScrollDiagnosticsPhase:(NSUInteger)phase;
@end
@implementation DOPSListController
- (void)recordScrollDiagnosticsPhase:(NSUInteger)phase {
    [self.phases addObject:@(phase)];
}
'''

NATIVE_MAIN = r'''
@end

static CGRect rectFromArray(NSArray<NSNumber *> *a) {
    assert(a.count == 4);
    return CGRectMake(a[0].doubleValue, a[1].doubleValue,
        a[2].doubleValue, a[3].doubleValue);
}

int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:
        [NSString stringWithUTF8String:argv[1]] options:0 error:&error];
    assert(data && !error);
    NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:data
        options:0 error:&error];
    assert(fixture && !error);
    NSArray *frames = @[fixture[@"page_bounds"], @[@0, @0, @375, @600],
        @[@0, @0, @744, @500]];
    for (NSArray *frame in frames) {
        for (NSDictionary *cycle in fixture[@"layout_cycles"]) {
            DOPSListController *controller = [DOPSListController new];
            controller.view = [RCTestView new];
            controller.view.bounds = rectFromArray(frame);
            controller->_table = [RCTestTable new];
            RCTestTable *table = controller->_table;
            table.frame = controller.view.bounds;
            CGPoint incomingOffset = CGPointMake(2, [cycle[@"before_y"] doubleValue]);
            table.contentOffset = incomingOffset;
            UIEdgeInsets insets = {31, 2, 9, 4};
            table.contentInset = insets;
            table.frameWrites = 0;
            table.insetWrites = 0;
            controller.phases = [NSMutableArray new];

            for (NSUInteger pass = 1; pass <= 200; pass++) {
                [controller.phases removeAllObjects];
                [controller viewDidLayoutSubviews];
                // No resize after the parent, and no second writer of frame.
                assert(CGRectEqualToRect(table.frame, controller.view.bounds));
                assert(table.frameWrites == controller.parentLayouts);
                assert(controller.parentLayouts == pass);
                assert(CGPointEqualToPoint(table.contentOffset, incomingOffset));
                insets.bottom = 24;
                assert(UIEdgeInsetsEqualToEdgeInsets(table.contentInset, insets));
                assert(table.insetWrites == 1);
                assert(([controller.phases isEqualToArray:@[@3, @4, @5]]));
            }
        }
    }
    puts("PASS: production layout keeps parent frame and offset, one-time bottom padding and trace ordering; nine measured offsets, three viewport sizes, 200 passes; no UIKit execution");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    code = "\n".join((NATIVE_PREFIX, layout_method(), NATIVE_MAIN))
    with tempfile.TemporaryDirectory(prefix="rc9-list-layout-") as directory:
        path = Path(directory) / "list_layout.m"
        binary = Path(directory) / "list_layout"
        path.write_text(code, encoding="utf-8")
        subprocess.run([
            clang, "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
            "-Wall", "-Wextra", "-Werror", "-O1", "-g",
            "-fsanitize=address,undefined", str(path), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(FIXTURE)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ListLayoutContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
