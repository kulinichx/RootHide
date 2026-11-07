"""Opt-in observation contracts, not a UIKit reproduction of the bounce."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


BASE = "Application/Dopamine/UI/Settings/PSLists/DOPSListController.m"


class ScrollDiagnosticsContracts(unittest.TestCase):
    def method(self, selector):
        return extract(source(BASE).split("@implementation DOPSListController\n", 1)[1],
                       selector)

    def test_sampling_is_opt_in_and_does_not_replace_native_scroll_delegates(self):
        install = self.method("- (void)installScrollDiagnosticsForBackButton:")
        self.assertIn("_table.panGestureRecognizer addTarget:self", install)
        self.assertIn("UILongPressGestureRecognizer", install)
        load = self.method("- (void)viewDidLoad")
        self.assertNotIn("scrollTraceArmed = YES", load)
        pan = self.method("- (void)scrollDiagnosticsPan:")
        self.assertIn("!self.scrollTraceArmed", pan)
        self.assertIn("pan.state != UIGestureRecognizerStateBegan", pan)
        self.assertIn("NSRunLoopCommonModes", pan)
        for token in ("_table.delegate =", "scrollViewDidScroll:",
                      "scrollViewWillBeginDragging:"):
            self.assertNotIn(token, source(BASE))

    def test_sample_storage_is_bounded_and_tick_does_not_allocate_or_write_files(self):
        self.assertIn("DOScrollTraceCapacity = 1024", source(BASE))
        record = self.method("- (void)recordScrollDiagnosticsPhase:")
        self.assertIn("!self.scrollTraceCapturing", record)
        self.assertIn("self.scrollTraceWriteCount % DOScrollTraceCapacity", record)
        for body in (record, self.method("- (void)scrollDiagnosticsTick:")):
            for token in ("writeTo", "NSJSONSerialization", "addObject:",
                          "stringWithFormat:", "NSLog", "dispatch_"):
                self.assertNotIn(token, body)

    def test_trace_reads_actual_insets_and_positions_without_changing_them(self):
        record = self.method("- (void)recordScrollDiagnosticsPhase:")
        for field in ("_table.frame", "_table.bounds", "_table.contentSize",
                      "_table.contentInset", "_table.adjustedContentInset",
                      "self.view.safeAreaInsets", "_table.decelerating"):
            self.assertIn(field, record)
        diagnostics = source(BASE).split("#pragma mark - Opt-in scroll diagnostics", 1)[1]
        for forbidden in ("_table.frame =", "_table.bounds =", "_table.contentInset =",
                          "_table.contentOffset =", "setContentOffset:",
                          "setContentInset:", "reloadData", "layoutIfNeeded"):
            self.assertNotIn(forbidden, diagnostics)

    def test_layout_samples_bracket_the_real_superclass_and_rc9_operations(self):
        layout = self.method("- (void)viewDidLayoutSubviews")
        self.assertLess(layout.index("recordScrollDiagnosticsPhase:3"),
                        layout.index("[super viewDidLayoutSubviews]"))
        self.assertLess(layout.index("[super viewDidLayoutSubviews]"),
                        layout.index("recordScrollDiagnosticsPhase:4"))
        self.assertLess(layout.index("recordScrollDiagnosticsPhase:4"),
                        layout.index("_table.frame = tableFrame;"))
        self.assertLess(layout.index("_table.contentInset = insets;"),
                        layout.index("recordScrollDiagnosticsPhase:5"))

    def test_link_target_is_weak_and_sampling_stops_on_idle_timeout_and_lifecycle(self):
        self.assertIn("@property(nonatomic, weak) DOPSListController *controller;",
                      source(BASE))
        pan = self.method("- (void)scrollDiagnosticsPan:")
        self.assertIn("displayLinkWithTarget:target", pan)
        self.assertNotIn("displayLinkWithTarget:self", pan)
        tick = self.method("- (void)scrollDiagnosticsTick:")
        for guard in ("!self.viewIfLoaded.window", "UIApplicationStateActive",
                      "topViewController != self", ">= 8.0", ">= 0.5"):
            self.assertIn(guard, tick)
        stop = self.method("- (void)stopScrollDiagnosticsWithReason:")
        self.assertIn("self.scrollTraceCapturing = NO;", stop)
        self.assertIn("[self.scrollTraceLink invalidate];", stop)
        self.assertIn("self.scrollTraceLink = nil;", stop)
        for selector in ("- (void)scrollDiagnosticsWillResignActive:",
                         "- (void)viewWillDisappear:"):
            method = self.method(selector)
            self.assertIn("self.scrollTraceArmed = NO;", method)
            self.assertIn("stopScrollDiagnosticsWithReason:", method)
        self.assertIn("[_scrollTraceLink invalidate];", self.method("- (void)dealloc"))

    def test_export_stops_sampling_and_reports_build_and_dropped_samples(self):
        export = self.method("- (void)scrollDiagnosticsPressed:")
        self.assertLess(export.index('stopScrollDiagnosticsWithReason:@"share_requested"'),
                        export.index("NSJSONSerialization"))
        for field in ('@"CFBundleVersion"', '@"table_class"', '@"dropped_samples"',
                      '@"before_preferences_layout"', '@"after_preferences_layout"',
                      '@"after_rc9_layout"', '@"source_commit"'):
            self.assertIn(field, export)
        self.assertIn("MIN(self.scrollTraceWriteCount, DOScrollTraceCapacity)", export)
        self.assertIn("DOScrollTraceRecords(self.scrollTraceBuffer.bytes,", export)
        records = extract(source(BASE), "static NSArray *DOScrollTraceRecords(")
        self.assertIn("samples[i % DOScrollTraceCapacity]", records)
        self.assertIn('@"resting_top_y"', records)
        self.assertIn("NSDataWritingAtomic", export)
        self.assertIn("share.popoverPresentationController.sourceView = press.view;", export)

    def test_prompt_arms_only_after_confirmation_with_a_weak_controller(self):
        export = self.method("- (void)scrollDiagnosticsPressed:")
        self.assertIn("__weak typeof(self) weakSelf = self;", export)
        confirmation = export.split("onConfirm:^{", 1)[1].split("}];", 1)[0]
        self.assertIn("weakSelf.viewIfLoaded.window", confirmation)
        self.assertIn("UIApplicationStateActive", confirmation)
        self.assertIn("weakSelf.scrollTraceArmed = YES;", confirmation)
        prompt = self.method("- (void)showScrollDiagnosticsMessage:")
        self.assertIn("if (confirm) confirm();", prompt)

    def test_stopped_capture_reason_is_not_overwritten_by_later_export(self):
        stop = self.method("- (void)stopScrollDiagnosticsWithReason:")
        guard = "if (!self.scrollTraceCapturing && !self.scrollTraceLink) return;"
        self.assertIn(guard, stop)
        self.assertLess(stop.index(guard), stop.index("recordScrollDiagnosticsPhase:6"))
        self.assertLess(stop.index(guard), stop.index("self.scrollTraceStopReason = reason;"))

    def test_export_keeps_nonfinite_geometry_as_text_instead_of_losing_the_trace(self):
        number = extract(source(BASE), "static id DOScrollTraceNumber(")
        self.assertIn("isfinite(value)", number)
        self.assertIn('stringWithFormat:@"%.17g", value', number)
        self.assertIn("python3 tests/test_rc9_scroll_diagnostics.py --native",
                      source(".github/workflows/roothide.yml"))

    def test_only_settings_and_about_install_the_diagnostic_trigger(self):
        for name in ("DOSettingsController", "DOCreditsViewController"):
            page = source(f"Application/Dopamine/UI/Settings/{name}.m")
            install = extract(page, "- (void)customGlassInstallBackNavigation")
            self.assertEqual(install.count("installScrollDiagnosticsForBackButton:"), 1)
        schedule = source("Application/Dopamine/UI/Settings/DOLowPowerScheduleController.m")
        self.assertNotIn("installScrollDiagnosticsForBackButton:", schedule)


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>

// UIKit's four-scalar inset type is represented here; UIKit itself is not run.
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
'''

NATIVE_MAIN = r'''
int main(void) { @autoreleasepool {
    assert([DOScrollTraceRecords(NULL, 0) count] == 0);
    NSMutableData *data = [NSMutableData
        dataWithLength:sizeof(DOScrollTraceSample) * DOScrollTraceCapacity];
    DOScrollTraceSample *samples = data.mutableBytes;
    for (NSNumber *length in @[@1, @1023, @1024, @1025, @3100]) {
        NSUInteger written = length.unsignedIntegerValue;
        for (NSUInteger i = 0; i < written; i++) {
            samples[i % DOScrollTraceCapacity] = (DOScrollTraceSample){
                .timestamp = (double)i / 60.0, .phase = 2,
                .offset = CGPointMake(0, (CGFloat)i),
                .frame = CGRectMake(12, 5, 300, 600),
                .adjustedInset = {10, 20, 30, 40},
                .decelerating = YES,
            };
        }
        NSArray *records = DOScrollTraceRecords(samples, written);
        NSUInteger count = MIN(written, DOScrollTraceCapacity);
        assert(records.count == count);
        for (NSUInteger i = 0; i < count; i++) {
            NSDictionary *record = records[i];
            assert([record[@"offset_y"] unsignedIntegerValue] == written - count + i);
            assert([record[@"resting_top_y"] doubleValue] == -10.0);
            assert(([record[@"table_frame"] isEqualToArray:@[@12, @5, @300, @600]]));
            assert(([record[@"adjusted_inset"] isEqualToArray:@[@10, @20, @30, @40]]));
            assert([record[@"decelerating"] boolValue]);
        }
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:records options:0 error:&error];
        assert(json && !error);
        NSArray *decoded = [NSJSONSerialization JSONObjectWithData:json options:0 error:&error];
        assert(decoded.count == records.count && !error);
    }
    samples[0] = (DOScrollTraceSample){
        .timestamp = NAN, .offset = CGPointMake(0, INFINITY),
        .frame = CGRectMake(NAN, INFINITY, -INFINITY, 10),
        .adjustedInset = {NAN, -INFINITY, INFINITY, 0},
    };
    NSArray *records = DOScrollTraceRecords(samples, 1);
    assert([records[0][@"seconds"] isKindOfClass:NSString.class]);
    assert([records[0][@"offset_y"] isKindOfClass:NSString.class]);
    NSError *error = nil;
    assert([NSJSONSerialization dataWithJSONObject:records options:0 error:&error]);
    assert(!error);
    puts("PASS: production scroll record export, wrap order, capacity, exact geometry, JSON round-trip and nonfinite values; no UIKit execution");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    text = source(BASE)
    sample_type = text.split("typedef struct {", 1)[1].split("} DOScrollTraceSample;", 1)[0]
    pieces = [NATIVE_PREFIX,
              "static NSUInteger const DOScrollTraceCapacity = 1024;",
              "typedef struct {" + sample_type + "} DOScrollTraceSample;"]
    for anchor in ("static id DOScrollTraceNumber(", "static NSArray *DOScrollTraceRect(",
                   "static NSArray *DOScrollTraceInsets(", "static NSArray *DOScrollTraceRecords("):
        pieces.append(extract(text, anchor))
    pieces.append(NATIVE_MAIN)
    with tempfile.TemporaryDirectory(prefix="rc9-scroll-diagnostics-") as directory:
        path = Path(directory) / "scroll_diagnostics.m"
        binary = Path(directory) / "scroll_diagnostics"
        path.write_text("\n".join(pieces), encoding="utf-8")
        try:
            subprocess.run([
                clang, "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
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
            print(f"::error title=Scroll diagnostic export regression::{escaped[:3000]}")
            sys.stderr.write(diagnostic)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ScrollDiagnosticsContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
