import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  BackHandler,
  Image,
  PanResponder,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Icon } from './Icon';
import { destinations, swipeIntent } from './navigation';
import type { Destination } from './navigation';
import { theme as colors } from './theme';

export function AppShell({
  current,
  navigate,
  back,
  canGoBack,
  shortcuts,
  actions,
  children,
  initialMenu = false,
}: {
  current: Destination;
  navigate: (id: Destination) => void;
  back: () => void;
  canGoBack: boolean;
  shortcuts: Destination[];
  actions?: React.ReactNode;
  children: React.ReactNode;
  initialMenu?: boolean;
}) {
  const { width } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const isPad = Platform.OS === 'ios' && Platform.isPad;
  const [sidebar, setSidebar] = useState(true);
  const [menu, setMenu] = useState(initialMenu);
  const progress = useRef(new Animated.Value(initialMenu ? 1 : 0)).current;
  const height = useRef(0);
  const intent = useRef<'menu' | 'back' | 'close' | null>(null);
  const drawerWidth = Math.min(240, width * 0.85);
  const page = destinations.find(item => item.id === current)!;

  function animateMenu(open: boolean) {
    if (open) {
      setMenu(true);
    }
    Animated.timing(progress, {
      toValue: open ? 1 : 0,
      duration: 200,
      useNativeDriver: true,
    }).start(({ finished }) => {
      if (finished && !open) {
        setMenu(false);
      }
    });
  }
  function choose(id: Destination) {
    animateMenu(false);
    navigate(id);
  }
  useEffect(() => {
    const listener = BackHandler.addEventListener('hardwareBackPress', () => {
      if (menu) {
        animateMenu(false);
        return true;
      }
      if (canGoBack) {
        back();
        return true;
      }
      return false;
    });
    return () => listener.remove();
    // BackHandler always uses the current route and menu state.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [menu, canGoBack, back]);

  const responder = PanResponder.create({
    onMoveShouldSetPanResponderCapture: (_, gesture) => {
      if (isPad) {
        return false;
      }
      if (menu) {
        intent.current =
          gesture.dx < -12 && Math.abs(gesture.dx) > Math.abs(gesture.dy) * 1.6
            ? 'close'
            : null;
      } else {
        intent.current = swipeIntent(
          gesture.x0,
          gesture.y0 - insets.top,
          width,
          height.current,
          gesture.dx,
          gesture.dy,
          canGoBack,
        );
      }
      return intent.current !== null;
    },
    onPanResponderGrant: () => {
      if (intent.current === 'menu') {
        setMenu(true);
        progress.setValue(0);
      }
    },
    onPanResponderMove: (_, gesture) => {
      if (intent.current === 'menu') {
        progress.setValue(Math.min(1, Math.max(0, gesture.dx / drawerWidth)));
      }
      if (intent.current === 'close') {
        progress.setValue(
          Math.min(1, Math.max(0, 1 + gesture.dx / drawerWidth)),
        );
      }
    },
    onPanResponderRelease: (_, gesture) => {
      if (
        intent.current === 'back' &&
        (gesture.dx > 60 || (gesture.dx > 24 && gesture.vx > 0.4))
      ) {
        back();
      }
      if (intent.current === 'menu') {
        animateMenu(gesture.dx > drawerWidth * 0.3 || gesture.vx > 0.4);
      }
      if (intent.current === 'close') {
        animateMenu(!(gesture.dx < -drawerWidth * 0.3 || gesture.vx < -0.4));
      }
      intent.current = null;
    },
    onPanResponderTerminate: () => {
      animateMenu(intent.current === 'close');
      intent.current = null;
    },
  });

  const menuContent = (persistent: boolean) => (
    <View style={[styles.drawer, { width: drawerWidth }]}>
      <View style={styles.brand}>
        <Image
          source={require('../../assets/nyanz-smile.png')}
          style={styles.logo}
        />
        <Text style={styles.brandText}>NeoEPGStation</Text>
      </View>
      <ScrollView contentContainerStyle={styles.menuItems}>
        {destinations.map(item => (
          <Pressable
            key={item.id}
            accessibilityRole="button"
            accessibilityLabel={`メニュー：${item.title}`}
            accessibilityState={{ selected: current === item.id }}
            onPress={() => (persistent ? navigate(item.id) : choose(item.id))}
            style={[styles.menuItem, current === item.id && styles.selected]}
          >
            <View style={styles.menuIcon}>
              <Icon name={item.icon} color={colors.muted} />
            </View>
            <Text style={styles.menuText}>{item.title}</Text>
          </Pressable>
        ))}
      </ScrollView>
      {!persistent && (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="メニューを閉じる"
          onPress={() => animateMenu(false)}
          style={styles.menuItem}
        >
          <View style={styles.menuIcon}>
            <Icon name="Close" color={colors.muted} />
          </View>
          <Text style={styles.menuText}>閉じる</Text>
        </Pressable>
      )}
    </View>
  );

  return (
    <View
      style={styles.root}
      {...responder.panHandlers}
      onLayout={event => {
        height.current = event.nativeEvent.layout.height;
      }}
    >
      <View
        style={styles.row}
        accessibilityElementsHidden={menu}
        importantForAccessibility={menu ? 'no-hide-descendants' : 'auto'}
      >
        {isPad && sidebar && menuContent(true)}
        <View style={styles.body}>
          <View style={styles.header}>
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="メニューを開く"
              onPress={() => (isPad ? setSidebar(!sidebar) : animateMenu(true))}
              style={styles.iconButton}
            >
              <Icon name="Menu" color={colors.text} />
            </Pressable>
            {canGoBack && (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="戻る"
                onPress={back}
                style={styles.iconButton}
              >
                <Icon name="ArrowBack" color={colors.text} />
              </Pressable>
            )}
            <Text
              accessibilityRole="header"
              numberOfLines={1}
              style={styles.title}
            >
              {page.title}
            </Text>
            {actions}
          </View>
          <View style={styles.body}>{children}</View>
          {!isPad && (
            <View style={styles.bottom}>
              {shortcuts.map(id => {
                const item = destinations.find(entry => entry.id === id)!;
                const active = current === id;
                return (
                  <Pressable
                    key={id}
                    accessibilityRole="tab"
                    accessibilityLabel={`ナビゲーション：${item.title}`}
                    accessibilityState={{ selected: active }}
                    onPress={() => navigate(id)}
                    style={styles.tab}
                  >
                    <Icon
                      name={item.icon}
                      color={active ? colors.accent : colors.muted}
                    />
                    <Text
                      numberOfLines={1}
                      style={[
                        styles.tabText,
                        { color: active ? colors.accent : colors.muted },
                      ]}
                    >
                      {item.title}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          )}
        </View>
      </View>
      {menu && (
        <View style={StyleSheet.absoluteFill} accessibilityViewIsModal>
          <Animated.View
            style={[
              StyleSheet.absoluteFill,
              styles.scrim,
              { opacity: progress },
            ]}
          >
            <Pressable
              style={styles.body}
              accessibilityRole="button"
              accessibilityLabel="メニューの背景を閉じる"
              onPress={() => animateMenu(false)}
            />
          </Animated.View>
          <Animated.View
            style={[
              styles.floatingDrawer,
              {
                transform: [
                  {
                    translateX: progress.interpolate({
                      inputRange: [0, 1],
                      outputRange: [-drawerWidth, 0],
                    }),
                  },
                ],
              },
            ]}
          >
            {menuContent(false)}
          </Animated.View>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.background },
  row: { flex: 1, flexDirection: 'row' },
  body: { flex: 1 },
  header: {
    minHeight: 56,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 4,
    backgroundColor: colors.header,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  title: { flex: 1, fontSize: 20, fontWeight: '500', color: colors.text },
  iconButton: {
    width: 44,
    height: 48,
    alignItems: 'center',
    justifyContent: 'center',
  },
  drawer: {
    flex: 1,
    backgroundColor: colors.paper,
    borderRightWidth: StyleSheet.hairlineWidth,
    borderRightColor: colors.border,
  },
  brand: {
    minHeight: 60,
    paddingHorizontal: 16,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  logo: { width: 28, height: 28 },
  brandText: { color: colors.text, fontSize: 18, fontWeight: '700' },
  menuItems: { paddingVertical: 8 },
  menuItem: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
  },
  menuIcon: { width: 40 },
  menuText: { color: colors.text, fontSize: 14 },
  selected: { backgroundColor: colors.selected },
  bottom: {
    minHeight: 58,
    flexDirection: 'row',
    backgroundColor: colors.paper,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
  },
  tab: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 4,
    paddingVertical: 7,
  },
  tabText: { fontSize: 10 },
  scrim: { backgroundColor: 'rgba(0,0,0,0.6)' },
  floatingDrawer: { position: 'absolute', top: 0, left: 0, bottom: 0 },
});
