import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  final metrics = FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 100,
    pixels: 100,
    viewportDimension: 50,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );

  test('as a parent or unapplied it keeps the edges: damped on a phone (A03.5), hard on a desktop', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // AlwaysScrollable over the unapplied physics scrolled past the end (M13.1).
    const nested = AlwaysScrollableScrollPhysics(parent: PureLiveScrollPhysics());
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(nested.applyBoundaryConditions(metrics, 130), 0, reason: '$platform: past the end with the finger');
      expect(const PureLiveScrollPhysics().applyTo(null), isA<PureLiveDampedScrollPhysics>());
      expect(const PureLiveScrollPhysics().spring, AppMotion.refreshSpring);
    }
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(nested.applyBoundaryConditions(metrics, 130), 30, reason: '$platform');
      expect(const PureLiveScrollPhysics().applyTo(null), isA<ClampingScrollPhysics>());
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('the pixel stop is opt-in, and it raises only the velocity tolerance', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final base = const PureLiveDampedScrollPhysics().toleranceFor(metrics);
    final stopped = const PureLiveDampedScrollPhysics(stopVelocity: 40).toleranceFor(metrics);
    // Springs keep Flutter's distance: they still settle inside a third of a
    // pixel, so the header and the edge bounces are unchanged.
    expect(stopped.distance, base.distance);
    expect(stopped.velocity, 40);
    // Never slower than Flutter's own stop speed, and off by default (the
    // 3.x tolerances of A03.1 and A03.5).
    expect(const PureLiveDampedScrollPhysics(stopVelocity: 4).toleranceFor(metrics).velocity, base.velocity);
    final untold = const PureLiveScrollPhysics().applyTo(null).toleranceFor(metrics);
    expect(untold.distance, base.distance);
    expect(untold.velocity, base.velocity);
    // PureLiveScrollPhysics forwards it to the damped physics it builds.
    expect(const PureLiveScrollPhysics(stopVelocity: 40).applyTo(null).toleranceFor(metrics).velocity, 40);
  });

  testWidgets('a list told where to stop ends its fling on whole pixels', (tester) async {
    tester.view.physicalSize = const Size(1200, 2607);
    tester.view.devicePixelRatio = 3;
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) => ListView.builder(
            physics: PureLiveScrollPhysics(stopVelocity: pixelStopVelocity(context)),
            itemCount: 200,
            itemExtent: 100,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      ),
    );
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    for (final velocity in [500.0, 1500.0, 6000.0]) {
      position.jumpTo(4000);
      await tester.pump();
      (position as ScrollPositionWithSingleContext).goBallistic(velocity);
      var last = position.pixels;
      final steps = <double>[];
      var frames = 0;
      while (position.isScrollingNotifier.value && frames < 2000) {
        await tester.pump(const Duration(microseconds: 8333));
        frames++;
        steps.add((position.pixels - last).abs());
        last = position.pixels;
      }
      final moving = steps.where((step) => step > 0).toList();
      // One physical pixel a frame on this display (40 dp/s): the tail has no
      // frame moving a fraction of one.
      final under = moving.where((step) => step < 1 / 3 - 0.02).toList();
      expect(under.length, lessThanOrEqualTo(1), reason: '$velocity dp/s: $under');
      expect(moving.last, greaterThan(1 / 3 - 0.02), reason: '$velocity dp/s');
    }
  });

  test('strips and pages: damped past their ends, put back inside when the content shrinks at rest', () {
    const physics = PureLiveBoundedScrollPhysics();
    expect(physics.applyBoundaryConditions(metrics, 130), 0);
    final shrunk = metrics.copyWith(maxScrollExtent: 40, pixels: 100);
    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: metrics,
        newPosition: shrunk,
        isScrolling: false,
        velocity: 0,
      ),
      40,
    );
  });

  testWidgets('a list under it stops at its end', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(parent: PureLiveScrollPhysics()),
          children: [for (var i = 0; i < 20; i++) SizedBox(height: 50, child: Text('$i'))],
        ),
      ),
    );
    await tester.fling(find.byType(ListView), const Offset(0, -5000), 5000);
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.maxScrollExtent);
  });
  testWidgets('A11.6: a list built again comes back where it was; another id starts at the top', (tester) async {
    var shown = true;
    var id = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        // A route gives its pages a PageStorage; here one of its own.
        child: PageStorage(
          bucket: PageStorageBucket(),
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return shown
                  ? KeepScrollPosition(
                      id: id,
                      child: ListView(children: [for (var i = 0; i < 50; i++) SizedBox(height: 50, child: Text('$i'))]),
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    double offset() => tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    final before = offset();
    expect(before, greaterThan(0));

    setOuter(() => shown = false);
    await tester.pump();
    expect(find.byType(ListView), findsNothing);
    setOuter(() => shown = true);
    await tester.pump();
    expect(offset(), before);

    setOuter(() => id = 'b');
    await tester.pump();
    expect(offset(), 0);
  });
}
