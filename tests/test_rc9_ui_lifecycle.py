"""UI source contracts, not UIKit execution or iOS device validation."""
import unittest

from test_rc9_services import extract, source


HEADER = "Application/Dopamine/UI/DOHeaderView.m"
MAIN = "Application/Dopamine/UI/DOMainViewController.m"
CREDITS = "Application/Dopamine/UI/Settings/Specifiers/DOCreditsCell.m"


def header_method(selector):
    return extract(source(HEADER), selector)


def main_method(selector):
    text = source(MAIN).split("@implementation DOMainViewController\n", 1)[1]
    return extract(text, selector)


class UptimeLifecycleContracts(unittest.TestCase):
    def test_initialization_only_registers_observers_not_a_running_timer(self):
        init = header_method("-(id)initWithImage:")
        self.assertIn("[self updateLabel];", init)
        self.assertNotIn("timerWithTimeInterval:", init)
        self.assertNotIn("scheduledTimerWithTimeInterval:", source(HEADER))
        self.assertEqual(init.count("addObserver:self"), 1)
        for name in (
            "UIApplicationDidBecomeActiveNotification",
            "UIApplicationWillResignActiveNotification",
            "UISceneDidActivateNotification", "UISceneWillDeactivateNotification",
            "UIWindowDidBecomeVisibleNotification", "UIWindowDidBecomeHiddenNotification",
        ):
            self.assertEqual(init.count(name), 1)

    def test_timer_requires_a_visible_page_window_and_active_scene_and_app(self):
        resume = header_method("- (void)resumeUptimeUpdates")
        guard = extract(resume, "if (!self.uptimeUpdatesEnabled")
        for condition in (
            "!self.window", "self.window.hidden",
            "self.window.windowScene.activationState != UISceneActivationStateForegroundActive",
            "UIApplication.sharedApplication.applicationState != UIApplicationStateActive",
        ):
            self.assertIn(condition, guard)
        self.assertIn("[self stopUptimeTimer];", guard)
        self.assertIn("return;", guard)
        self.assertLess(resume.index(guard), resume.index("[self updateLabel];"))
        self.assertLess(resume.index("[self updateLabel];"),
                        resume.index("if (self.uptimeTimer) return;"))
        self.assertLess(resume.index("if (self.uptimeTimer) return;"),
                        resume.index("[NSTimer timerWithTimeInterval:"))

    def test_timer_callback_has_weak_ownership_and_rechecks_visibility(self):
        resume = header_method("- (void)resumeUptimeUpdates")
        self.assertIn("__weak typeof(self) weakSelf = self;", resume)
        callback = extract(resume, "block:^(NSTimer *timer)")
        self.assertIn("__strong typeof(weakSelf) strongSelf = weakSelf;", callback)
        self.assertIn("[timer invalidate];", callback)
        self.assertIn("[strongSelf resumeUptimeUpdates];", callback)
        self.assertNotIn("[self ", callback)
        self.assertNotIn("target:self", resume)

    def test_minute_alignment_and_clock_definition_are_preserved(self):
        resume = header_method("- (void)resumeUptimeUpdates")
        self.assertIn("timerWithTimeInterval:60.0 repeats:YES", resume)
        self.assertIn("60.0 - fmod([self systemUptime], 60.0)", resume)
        self.assertIn("dateWithTimeIntervalSinceNow:delay", resume)
        self.assertIn("forMode:NSRunLoopCommonModes", resume)
        clock = header_method("- (NSTimeInterval)systemUptime")
        self.assertIn("clock_gettime(CLOCK_MONOTONIC_RAW, &ts);", clock)
        self.assertIn("ts.tv_nsec / 1000000000.0", clock)
        self.assertNotIn("mach_continuous_time", source(HEADER))
        label = header_method("- (NSString *)formatUptime")
        for value in (
            "[self systemUptime]", "NSCalendarUnitDay", "NSCalendarUnitHour",
            "NSCalendarUnitMinute", "NSDateComponentsFormatterUnitsStyleFull",
            "System_Uptime_Less_Than_Minute", "System_Uptime_Prefix",
            "uptime: less than 1 minute",
        ):
            self.assertIn(value, label)

    def test_inactive_events_stop_before_state_changes_and_ignore_other_scenes(self):
        handler = header_method("- (void)uptimeContextDidChange:")
        self.assertIn("notification.object != self.window.windowScene) return;", handler)
        self.assertIn("notification.object != self.window) return;", handler)
        stop = extract(handler, "if ([name isEqualToString:UIApplicationWillResignActiveNotification]")
        self.assertIn("UISceneWillDeactivateNotification", stop)
        self.assertIn("UIWindowDidBecomeHiddenNotification", stop)
        self.assertIn("[self stopUptimeTimer];", stop)
        self.assertIn("[self resumeUptimeUpdates];", handler)

    def test_window_moves_stop_old_timer_before_resuming(self):
        move = header_method("- (void)didMoveToWindow")
        self.assertIn("[super didMoveToWindow];", move)
        self.assertLess(move.index("[self stopUptimeTimer];"),
                        move.index("[self resumeUptimeUpdates];"))
        setter = header_method("- (void)setUptimeUpdatesEnabled:")
        self.assertLess(setter.index("_uptimeUpdatesEnabled = enabled;"),
                        setter.index("[self resumeUptimeUpdates];"))

    def test_stop_and_deallocation_release_timer_and_observers(self):
        stop = header_method("- (void)stopUptimeTimer")
        self.assertLess(stop.index("[self.uptimeTimer invalidate];"),
                        stop.index("self.uptimeTimer = nil;"))
        dealloc = header_method("- (void)dealloc")
        self.assertIn("[_uptimeTimer invalidate];", dealloc)
        self.assertIn("removeObserver:self", dealloc)
        self.assertIn("_uptimeHeaderView.uptimeUpdatesEnabled = NO;",
                      main_method("- (void)dealloc"))

    def test_both_home_layouts_share_the_controller_visibility_gate(self):
        text = source(MAIN).split("@implementation DOMainViewController\n", 1)[1]
        self.assertEqual(text.count("DOHeaderView *headerView = [[DOHeaderView alloc]"), 2)
        self.assertEqual(text.count("self.uptimeHeaderView = headerView;"), 2)
        appear = main_method("- (void)viewWillAppear:")
        disappear = main_method("- (void)viewWillDisappear:")
        self.assertIn("[super viewWillAppear:animated];", appear)
        self.assertIn("self.uptimeUpdatesVisible = YES;", appear)
        self.assertIn("self.uptimeHeaderView.uptimeUpdatesEnabled = YES;", appear)
        self.assertIn("[super viewWillDisappear:animated];", disappear)
        self.assertIn("self.uptimeUpdatesVisible = NO;", disappear)
        self.assertIn("self.uptimeHeaderView.uptimeUpdatesEnabled = NO;", disappear)

    def test_replacing_header_disables_previous_instance_before_assignment(self):
        setter = main_method("- (void)setUptimeHeaderView:")
        self.assertLess(setter.index("_uptimeHeaderView.uptimeUpdatesEnabled = NO;"),
                        setter.index("_uptimeHeaderView = headerView;"))
        self.assertIn("_uptimeHeaderView.uptimeUpdatesEnabled = self.uptimeUpdatesVisible;", setter)


class CreditsLayoutContracts(unittest.TestCase):
    def test_only_outer_list_scrolls_and_names_and_links_are_preserved(self):
        text = source(CREDITS)
        init = extract(text.split("@implementation DOCreditsCell\n", 1)[1],
                       "- (id)initWithSpecifier:")
        self.assertIn("self.collectionView.scrollEnabled = NO;", init)
        for value in (
            '[specifier propertyForKey:@"names"]',
            "self.collectionView.delegate = self;",
            "self.collectionView.dataSource = self;",
        ):
            self.assertIn(value, init)
        self.assertIn('[cell setName:name[@"name"] url:[NSURL URLWithString:name[@"link"]]];', text)
        self.assertIn("openURL:self.url", text)

    def test_width_invalidation_is_guarded_and_records_width_first(self):
        text = source(CREDITS).split("@implementation DOCreditsCell\n", 1)[1]
        layout = extract(text, "- (void)layoutSubviews")
        self.assertIn("[super layoutSubviews];", layout)
        self.assertIn("CGRectGetWidth(self.collectionView.bounds)", layout)
        guard = extract(layout, "if (width > 0 && width != self.lastCollectionWidth)")
        self.assertLess(guard.index("self.lastCollectionWidth = width;"),
                        guard.index("invalidateLayout"))
        self.assertEqual(layout.count("invalidateLayout"), 1)

    def test_all_rows_have_height_for_the_unchanged_two_column_grid(self):
        text = source(CREDITS).split("@implementation DOCreditsCell\n", 1)[1]
        size = extract(text, "- (CGSize)collectionView:")
        height = extract(text, "- (CGFloat)preferredHeightForWidth:")
        self.assertIn("collectionView.frame.size.width/2, CREDITS_CELL_HEIGHT", size)
        self.assertIn("CREDITS_CELL_HEIGHT * ceil(self.names.count/2.0)", height)
        init = extract(text, "- (id)initWithSpecifier:")
        for property_name in ("minimumInteritemSpacing", "minimumLineSpacing"):
            self.assertIn(f"layout.{property_name} = 0;", init)
        self.assertIn("layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);", init)


class SettingsScrollLayoutContracts(unittest.TestCase):
    def settings_method(self, selector):
        text = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        return extract(text.split("@implementation DOSettingsController\n", 1)[1], selector)

    def test_only_schedule_extends_modal_bottom_without_moving_header(self):
        navigation = source("Application/Dopamine/UI/DONavigationController.m")
        frame = extract(navigation.split("@implementation DONavigationController\n", 1)[1],
                        "-(CGRect)_frameForViewController:")
        guard = "if ([viewController isKindOfClass:[DOLowPowerScheduleController class]])"
        self.assertIn('#import "Settings/DOLowPowerScheduleController.h"', navigation)
        self.assertNotIn('#import "Settings/DOSettingsController.h"', navigation)
        self.assertLess(frame.index("orig.origin.y ="), frame.index(guard))
        extension = frame.split(guard, 1)[1]
        self.assertIn("orig.size.height = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(orig);",
                      extension)
        self.assertNotIn("orig.origin.y =", extension)
        self.assertNotIn("orig.size.width =", extension)
        self.assertIn("return orig;", extension)
        self.assertNotIn("DOSettingsController", frame)

    def test_push_transition_applies_the_computed_final_frame(self):
        transition = source("Application/Dopamine/UI/Transition/DOModalTransitionPush.m")
        animate = extract(transition, "- (void)animateTransition:")
        self.assertIn("CGRect finalFrame = [transitionContext finalFrameForViewController:toViewController];",
                      animate)
        self.assertIn("toViewController.view.frame = finalFrame;", animate)
        self.assertLess(animate.index("toViewController.view.frame = finalFrame;"),
                        animate.index("[[transitionContext containerView] addSubview:toViewController.view]"))

    def test_scale_transition_applies_the_computed_final_frame(self):
        transition = source("Application/Dopamine/UI/Transition/DOModalTransitionScale.m")
        animate = extract(transition, "- (void)animateTransition:")
        self.assertIn("CGRect finalFrame = [transitionContext finalFrameForViewController:toViewController];",
                      animate)
        self.assertIn("toViewController.view.frame = finalFrame;", animate)
        self.assertLess(animate.index("toViewController.view.frame = finalFrame;"),
                        animate.index("[[transitionContext containerView] addSubview:toViewController.view]"))

    def test_schedule_uses_safe_area_padding_and_native_bounce_not_large_blank_space(self):
        schedule = source("Application/Dopamine/UI/Settings/DOLowPowerScheduleController.m")
        insets = extract(schedule, "- (void)refreshScheduleScrollInsets")
        self.assertIn("self.view.safeAreaInsets.bottom + 24.0", insets)
        self.assertNotIn("160.0", insets)
        load = extract(schedule, "- (void)viewDidLoad")
        for setting in ("self.tableView.bounces = YES;",
                        "self.tableView.alwaysBounceVertical = YES;"):
            self.assertIn(setting, load)

    def test_settings_keep_header_inset_and_add_safe_area_bottom_scroll_room(self):
        settings = self.settings_method("- (void)customGlassRefreshSettingsScrollInsets")
        self.assertIn("if (!self.customGlassInsetsConfigured)", settings)
        self.assertIn("insets = tableView.adjustedContentInset;", settings)
        self.assertIn("tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;",
                      settings)
        self.assertIn("insets.bottom = self.view.safeAreaInsets.bottom + 24.0;", settings)
        self.assertNotIn("insets.top =", settings)
        self.assertIn("tableView.automaticallyAdjustsScrollIndicatorInsets = NO;", settings)
        self.assertIn("tableView.scrollIndicatorInsets = insets;", settings)
        layout = self.settings_method("- (void)viewDidLayoutSubviews")
        self.assertIn("[self customGlassRefreshSettingsScrollInsets];", layout)

    def test_preferences_heights_are_resolved_before_scrolling_and_bounce_is_not_disabled(self):
        load = self.settings_method("- (void)viewDidLoad")
        for setting in ("_table.estimatedRowHeight = 0;",
                        "_table.estimatedSectionHeaderHeight = 0;",
                        "_table.estimatedSectionFooterHeight = 0;",
                        "_table.bounces = YES;",
                        "_table.alwaysBounceVertical = YES;"):
            self.assertIn(setting, load)
        appearance = self.settings_method("- (void)customGlassInstallPageAppearance")
        self.assertIn("tableView.clipsToBounds = YES;", appearance)

    def test_scroll_layout_preserves_glass_geometry_without_rebuilding_material(self):
        backdrops = self.settings_method("- (void)customGlassRefreshSectionBackdrops")
        self.assertLess(backdrops.index("[activeKeys addObject:key]"),
                        backdrops.index("if (CGRectIsEmpty(sectionRect)"))
        self.assertIn("DOPlaceCustomGlassSettingsSection(tableView, glass, sectionRect);", backdrops)
        created = extract(backdrops, "if (created)")
        self.assertIn("[glass reloadMaterial];", created)
        self.assertEqual(backdrops.count("[glass reloadMaterial];"),
                         created.count("[glass reloadMaterial];"))
        refresh = self.settings_method("- (void)customGlassRefreshPageAppearance")
        self.assertIn("[glass reloadMaterial];", refresh)
        layout = self.settings_method("- (void)viewDidLayoutSubviews")
        self.assertNotIn("reloadMaterial", layout)
        self.assertNotIn("reloadData", layout)
        self.assertNotIn("contentOffset", layout)

    def test_settings_glass_stays_behind_reused_cells_and_tracks_scroll_geometry(self):
        settings = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        background = extract(settings, "static UIView *DOCustomGlassSettingsBackground")
        place = extract(settings, "static void DOPlaceCustomGlassSettingsSection")
        settings_backdrops = self.settings_method("- (void)customGlassRefreshSectionBackdrops")
        scroll = self.settings_method("- (void)scrollViewDidScroll:")
        self.assertIn("tableView.backgroundView = background;", background)
        self.assertIn("background.clipsToBounds = YES;", background)
        self.assertIn("[background addSubview:glass];", place)
        self.assertIn("[tableView convertRect:glassRect toView:background]", place)
        self.assertIn("DOPlaceCustomGlassSettingsSection(tableView, glass, sectionRect);",
                      settings_backdrops)
        self.assertNotIn("[tableView insertSubview:glass", settings_backdrops)
        self.assertIn("if (scrollView != _table || !DORHSupporterIsVerified())", scroll)
        self.assertIn("if (!self.customGlassHasContentOffset)", scroll)
        self.assertIn("CGFloat offsetDelta = offsetY - self.customGlassLastContentOffsetY;", scroll)
        self.assertIn("frame.origin.y -= offsetDelta;", scroll)
        self.assertNotIn("rectForRowAtIndexPath", scroll)
        self.assertNotIn("reloadMaterial", scroll)
        self.assertNotIn("scrollView.contentOffset =", scroll)

        settings_display = self.settings_method(
            "- (void)tableView:(UITableView *)tableView willDisplayCell:")
        self.assertIn("[self customGlassStyleVisibleCell:cell atIndexPath:indexPath];", settings_display)
        self.assertNotIn("dispatch_async", settings_display)

        layout = self.settings_method("- (void)viewDidLayoutSubviews")
        self.assertNotIn("customGlassCleanupTableHairlines", layout)

    def test_base_list_does_not_reassign_an_unchanged_table_frame(self):
        base = source("Application/Dopamine/UI/Settings/PSLists/DOPSListController.m")
        layout = extract(base, "- (void)viewDidLayoutSubviews")
        self.assertIn("if (!CGRectEqualToRect(_table.frame, tableFrame))", layout)
        self.assertIn("_table.frame = tableFrame;", layout)
        self.assertNotIn("contentOffset", layout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
