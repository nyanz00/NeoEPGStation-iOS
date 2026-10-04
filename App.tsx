import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Image,
  KeyboardAvoidingView,
  Modal,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import {
  apiURL,
  getChannels,
  getRecording,
  getRecordings,
  normalizeServerURL,
  requestHeaders,
} from './src/api';
import type { Recording, Recordings, VideoFile } from './src/api';
import { native } from './src/native';
import type { Connection } from './src/native';
import { AppShell } from './src/ui/AppShell';
import { NavigationSettings } from './src/ui/NavigationSettings';
import { defaultShortcuts, sanitizeShortcuts } from './src/ui/navigation';
import type { Destination } from './src/ui/navigation';
import { theme as colors } from './src/ui/theme';
import { Icon } from './src/ui/Icon';
import { FixtureThumbnail } from './src/ui/FixtureThumbnail';
import { uiFixture } from './src/ui/fixture';

const empty: Connection = { url: '' };

function AppContent() {
  const [connection, setConnection] = useState<Connection | null>(null);
  const [form, setForm] = useState<Connection>(empty);
  const [connected, setConnected] = useState(false);
  const [routes, setRoutes] = useState<Destination[]>(['recorded']);
  const [sidebarWidth, setSidebarWidth] = useState<number | null>(null);
  const [shortcuts, setShortcuts] = useState<Destination[]>(defaultShortcuts);
  const current = routes[routes.length - 1];
  const settings = current === 'settings' || !connected;
  function navigate(id: Destination) {
    if (current === id) {
      return;
    }
    details.current?.abort();
    setSelected(null);
    setRoutes(previous =>
      previous[previous.length - 1] === id
        ? previous
        : [...previous.slice(-19), id],
    );
  }
  function back() {
    if (routes.length > 1) {
      details.current?.abort();
      setSelected(null);
      const next = routes.slice(0, -1);
      setRoutes(next);
    }
  }
  async function saveShortcuts(next: Destination[]) {
    await native.saveNavigation(next);
    setShortcuts(next);
  }
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [data, setData] = useState<Recordings>({ records: [], total: 0 });
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState<Recording | null>(null);
  const [opening, setOpening] = useState<number | null>(null);
  const [channels, setChannels] = useState<Map<number, string>>(new Map());
  const needsChannels = data.records.some(item => item.channelId !== undefined);
  const scrollPosition = useRef(0);
  const loadedOffset = useRef(0);
  useEffect(() => {
    if (!connection || !needsChannels || native.uiSmoke) {
      return;
    }
    const controller = new AbortController();
    setChannels(new Map());
    getChannels(connection, controller.signal)
      .then(items => {
        if (!controller.signal.aborted) {
          setChannels(new Map(items.map(item => [item.id, item.name])));
        }
      })
      .catch(() => {
        /* Keep recordings available even when channel metadata fails. */
      });
    return () => controller.abort();
  }, [connection, needsChannels]);
  useEffect(() => {
    if (!native.uiSmoke || !ready) {
      return;
    }
    const timer = setTimeout(() => {
      void native.reportUIReady({
        stage: native.uiSmoke!,
        route: current,
        shortcuts,
        theme: 'neon-teal-dark',
        recordCount: data.records.length,
        sidebarWidth,
      });
    }, 800);
    return () => clearTimeout(timer);
  }, [ready, current, shortcuts, data.records.length, sidebarWidth]);
  const request = useRef<AbortController | null>(null);
  const details = useRef<AbortController | null>(null);
  const mounted = useRef(true);
  const openingRef = useRef(false);
  const pendingPlayback = useRef<Parameters<typeof native.play>[0] | null>(
    null,
  );

  useEffect(() => {
    mounted.current = true;
    if (native.uiSmoke) {
      setConnection({ url: 'https://example.com' });
      setForm({ url: 'https://example.com' });
      setData(uiFixture);
      setConnected(true);
      if (native.uiSmoke === 'settings') {
        setRoutes(['recorded', 'settings']);
      }
      setReady(true);
      return () => {
        mounted.current = false;
      };
    }
    native
      .loadNavigation()
      .then(items => {
        if (mounted.current) {
          setShortcuts(sanitizeShortcuts(items));
        }
      })
      .catch(() => {
        /* A missing preference must not prevent connecting. */
      });
    native
      .loadConnection()
      .then(async saved => {
        if (!mounted.current) {
          return;
        }
        if (saved) {
          setConnection(saved);
          setForm(saved);
          await load(saved, 0);
        }
      })
      .catch(() => {
        if (mounted.current) {
          setError('保存した接続設定を読み込めませんでした。');
        }
      })
      .finally(() => {
        if (mounted.current) {
          setReady(true);
        }
      });
    return () => {
      mounted.current = false;
      request.current?.abort();
      details.current?.abort();
    };
  }, []);

  async function load(target: Connection, pageOffset: number, save = false) {
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setBusy(true);
    setError('');
    try {
      const prepared = save ? await native.saveConnection(target) : target;
      if (controller.signal.aborted) {
        return;
      }
      const result = await getRecordings(
        prepared,
        pageOffset,
        controller.signal,
      );
      if (!mounted.current || controller.signal.aborted) {
        return;
      }
      setConnection(prepared);
      setForm(prepared);
      setData(result);
      if (pageOffset !== loadedOffset.current || save) {
        scrollPosition.current = 0;
      }
      loadedOffset.current = pageOffset;
      setOffset(pageOffset);
      setConnected(true);
      if (save) {
        setRoutes(['recorded']);
      }
    } catch (cause) {
      if (mounted.current && !controller.signal.aborted) {
        setError(
          cause instanceof Error
            ? cause.message
            : '録画一覧を取得できませんでした。',
        );
      }
    } finally {
      if (mounted.current && request.current === controller) {
        setBusy(false);
      }
    }
  }

  function connect() {
    try {
      const url = normalizeServerURL(form.url);
      void load({ ...form, url }, 0, true);
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'サーバーURLを確認してください。',
      );
    }
  }

  async function select(item: Recording) {
    if (!connection || openingRef.current) {
      return;
    }
    openingRef.current = true;
    setOpening(item.id);
    const controller = new AbortController();
    details.current = controller;
    try {
      const detail = await getRecording(connection, item.id, controller.signal);
      if (mounted.current && !controller.signal.aborted) {
        setSelected(detail);
      }
    } catch (cause) {
      if (mounted.current && !controller.signal.aborted) {
        Alert.alert(
          '録画情報',
          cause instanceof Error ? cause.message : '取得できませんでした。',
        );
      }
    } finally {
      openingRef.current = false;
      if (mounted.current) {
        setOpening(null);
      }
    }
  }

  function play(file: VideoFile) {
    if (!connection || !selected || openingRef.current) {
      return;
    }
    openingRef.current = true;
    pendingPlayback.current = {
      url: apiURL(connection, `/videos/${file.id}`),
      title: selected.name,
      networkCaching: 5000,
    };
    setSelected(null);
  }

  async function playAfterDismiss() {
    const options = pendingPlayback.current;
    pendingPlayback.current = null;
    if (!options) {
      return;
    }
    if (!mounted.current) {
      openingRef.current = false;
      return;
    }
    try {
      await native.play(options);
    } catch {
      Alert.alert('再生', 'プレイヤーを開始できませんでした。');
    } finally {
      openingRef.current = false;
    }
  }

  const button = (label: string, action: () => void, disabled = false) => (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={action}
      style={[
        styles.button,
        { backgroundColor: colors.accent },
        disabled && styles.disabled,
      ]}
    >
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );

  return (
    <SafeAreaView style={[styles.root, { backgroundColor: colors.paper }]}>
      <StatusBar barStyle="light-content" />
      <AppShell
        current={settings ? 'settings' : current}
        navigate={navigate}
        back={back}
        canGoBack={routes.length > 1}
        shortcuts={shortcuts}
        onSidebarLayout={setSidebarWidth}
        initialMenu={native.uiSmoke === 'menu'}
        actions={
          !settings && current === 'recorded' ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="更新"
              disabled={busy}
              onPress={() => {
                if (connection) {
                  void load(connection, offset);
                }
              }}
              style={styles.iconButton}
            >
              <Icon name="Refresh" color={colors.text} />
            </Pressable>
          ) : undefined
        }
      >
        {!ready ? (
          <ActivityIndicator style={styles.loading} color={colors.accent} />
        ) : settings ? (
          <KeyboardAvoidingView style={styles.grow} behavior="padding">
            <ScrollView
              keyboardShouldPersistTaps="handled"
              contentContainerStyle={styles.form}
            >
              <Text style={[styles.heading, { color: colors.text }]}>
                サーバー接続
              </Text>
              <Text style={{ color: colors.muted }}>NeoEPGStationのURL</Text>
              <TextInput
                accessibilityLabel="サーバーURL"
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
                placeholder="https://example.com/epgstation"
                placeholderTextColor={colors.muted}
                editable={!busy}
                value={form.url}
                onChangeText={url => setForm({ ...form, url })}
                style={[
                  styles.input,
                  { color: colors.text, borderColor: colors.border },
                ]}
              />
              {button(
                busy ? '接続中…' : '保存して接続',
                connect,
                busy || !form.url.trim(),
              )}
              {!!connection &&
                button(
                  '録画一覧に戻る',
                  () => {
                    if (connected) {
                      navigate('recorded');
                    } else {
                      void load(connection, offset);
                    }
                  },
                  busy,
                )}
              <Text style={[styles.hint, { color: colors.muted }]}>
                接続先はこの端末に保存し、次回から自動で接続します。
              </Text>
              {!!error && (
                <Text accessibilityRole="alert" style={styles.error}>
                  {error}
                </Text>
              )}
              {connected && (
                <NavigationSettings value={shortcuts} save={saveShortcuts} />
              )}
            </ScrollView>
          </KeyboardAvoidingView>
        ) : current !== 'recorded' ? (
          <View style={styles.placeholder}>
            <Text style={[styles.heading, { color: colors.text }]}>
              この画面は準備中です
            </Text>
            <Text style={[styles.hint, { color: colors.muted }]}>
              現在は録画済みの一覧とPLAY再生を利用できます。
            </Text>
            {button('録画済みを開く', () => navigate('recorded'))}
          </View>
        ) : (
          <View style={styles.grow}>
            <View style={styles.toolbar}>
              <Text style={[styles.caption, { color: colors.muted }]}>
                {data.total}件 · 新しい順
              </Text>
            </View>
            {!!error && (
              <Text accessibilityRole="alert" style={styles.error}>
                {error}
              </Text>
            )}
            <FlatList
              data={data.records}
              contentOffset={{ x: 0, y: scrollPosition.current }}
              onScroll={event => {
                scrollPosition.current = event.nativeEvent.contentOffset.y;
              }}
              scrollEventThrottle={100}
              keyExtractor={item => String(item.id)}
              refreshing={busy}
              onRefresh={() => {
                if (connection) {
                  void load(connection, offset);
                }
              }}
              contentContainerStyle={styles.list}
              ListEmptyComponent={
                <Text style={[styles.hint, { color: colors.muted }]}>
                  {busy ? '読み込み中…' : '録画がありません。'}
                </Text>
              }
              renderItem={({ item }) => (
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel={`${item.name}の再生ファイルを選択`}
                  onPress={() => {
                    void select(item);
                  }}
                  disabled={opening !== null}
                  style={[
                    styles.card,
                    {
                      backgroundColor: colors.paper,
                      borderColor: colors.border,
                    },
                  ]}
                >
                  {native.uiSmoke ? (
                    <View style={styles.thumbnail}>
                      <FixtureThumbnail id={item.id} />
                    </View>
                  ) : connection && item.thumbnails?.[0] !== undefined ? (
                    <Image
                      style={styles.thumbnail}
                      resizeMode="cover"
                      source={{
                        uri: apiURL(
                          connection,
                          `/thumbnails/${item.thumbnails[0]}`,
                        ),
                        headers: requestHeaders(connection),
                      }}
                    />
                  ) : (
                    <View
                      style={[
                        styles.thumbnail,
                        { backgroundColor: colors.border },
                      ]}
                    />
                  )}
                  <View style={styles.cardBody}>
                    <Text
                      style={[styles.recordingName, { color: colors.text }]}
                      numberOfLines={1}
                    >
                      {item.name}
                    </Text>
                    <Text
                      numberOfLines={1}
                      style={[styles.caption, { color: colors.muted }]}
                    >
                      {item.channelName ||
                        (item.channelId !== undefined
                          ? channels.get(item.channelId) ||
                            String(item.channelId)
                          : '\u00a0')}
                    </Text>
                    <Text
                      numberOfLines={1}
                      style={[styles.caption, { color: colors.muted }]}
                    >
                      {new Date(item.startAt).toLocaleString('ja-JP')} –{' '}
                      {new Date(item.endAt).toLocaleTimeString('ja-JP', {
                        hour: '2-digit',
                        minute: '2-digit',
                      })}
                    </Text>
                    <Text
                      numberOfLines={1}
                      style={[styles.caption, { color: colors.muted }]}
                    >
                      {item.isRecording
                        ? '録画中'
                        : opening === item.id
                        ? '読み込み中…'
                        : item.description || '\u00a0'}
                    </Text>
                  </View>
                </Pressable>
              )}
            />
            <View style={styles.pagination}>
              {button(
                '前へ',
                () => {
                  if (connection) {
                    void load(connection, Math.max(0, offset - 30));
                  }
                },
                busy || offset === 0,
              )}
              <Text style={{ color: colors.muted }}>
                {Math.min(offset + 1, data.total)}–
                {Math.min(offset + data.records.length, data.total)}
              </Text>
              {button(
                '次へ',
                () => {
                  if (connection) {
                    void load(connection, offset + 30);
                  }
                },
                busy || offset + 30 >= data.total,
              )}
            </View>
          </View>
        )}
      </AppShell>
      <Modal
        visible={selected !== null}
        transparent
        animationType="fade"
        onRequestClose={() => setSelected(null)}
        onDismiss={() => {
          void playAfterDismiss();
        }}
      >
        <View style={styles.modalBackdrop}>
          <View style={[styles.modal, { backgroundColor: colors.paper }]}>
            <Text style={[styles.heading, { color: colors.text }]}>
              {selected?.name}
            </Text>
            <ScrollView>
              {selected?.videoFiles?.map(file => (
                <Pressable
                  key={file.id}
                  accessibilityRole="button"
                  onPress={() => {
                    void play(file);
                  }}
                  style={[styles.file, { borderBottomColor: colors.border }]}
                >
                  <Text style={{ color: colors.text }}>
                    {file.name || file.filename || `ファイル ${file.id}`}
                  </Text>
                  <Text style={[styles.hint, { color: colors.muted }]}>
                    {file.type === 'ts' ? '元TS' : 'エンコード済み'} ·{' '}
                    {(file.size / 1024 / 1024).toFixed(1)} MB · PLAY
                  </Text>
                </Pressable>
              ))}
              {!selected?.videoFiles?.length && (
                <Text style={[styles.hint, { color: colors.muted }]}>
                  再生できるファイルがありません。
                </Text>
              )}
            </ScrollView>
            {button('閉じる', () => setSelected(null))}
          </View>
        </View>
      </Modal>
    </SafeAreaView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <AppContent />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  grow: { flex: 1 },
  loading: { flex: 1 },
  header: {
    padding: 16,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottomWidth: 1,
  },
  title: { fontSize: 21, fontWeight: '700' },
  heading: { fontSize: 18, fontWeight: '600', flexShrink: 1 },
  form: {
    padding: 16,
    gap: 14,
    width: '100%',
    maxWidth: 620,
    alignSelf: 'center',
  },
  input: { borderWidth: 1, borderRadius: 6, padding: 12, fontSize: 16 },
  button: {
    borderRadius: 6,
    paddingHorizontal: 16,
    paddingVertical: 12,
    alignItems: 'center',
  },
  disabled: { opacity: 0.45 },
  buttonText: { color: '#ffffff', fontWeight: '600' },
  hint: { marginTop: 8, fontSize: 13 },
  error: { color: '#ff5252', padding: 12 },
  iconButton: {
    width: 44,
    height: 48,
    alignItems: 'center',
    justifyContent: 'center',
  },
  placeholder: {
    flex: 1,
    padding: 24,
    gap: 16,
    justifyContent: 'center',
    alignItems: 'center',
  },
  caption: { fontSize: 12, lineHeight: 18 },
  toolbar: {
    paddingHorizontal: 8,
    paddingVertical: 6,
    gap: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  list: { padding: 4, gap: 4 },
  card: {
    height: 108,
    borderRadius: 6,
    flexDirection: 'row',
    overflow: 'hidden',
  },
  thumbnail: { width: '32%', maxWidth: 190, height: '100%' },
  cardBody: { flex: 1, padding: 8, justifyContent: 'center', gap: 3 },
  recordingName: { fontSize: 14, fontWeight: '700', lineHeight: 20 },
  pagination: {
    padding: 16,
    gap: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.6)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  modal: {
    width: '100%',
    maxWidth: 600,
    maxHeight: '80%',
    padding: 20,
    borderRadius: 12,
    gap: 16,
  },
  file: { paddingVertical: 16, borderBottomWidth: 1 },
});
