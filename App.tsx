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
  useColorScheme,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import {
  apiURL,
  getRecording,
  getRecordings,
  normalizeServerURL,
  requestHeaders,
} from './src/api';
import type { Recording, Recordings, VideoFile } from './src/api';
import { native } from './src/native';
import type { Connection } from './src/native';

const empty: Connection = { url: '', username: '', password: '' };

function AppContent() {
  const dark = useColorScheme() === 'dark';
  const colors = dark
    ? {
        background: '#121212',
        paper: '#1e1e1e',
        text: '#ffffff',
        muted: '#b3b3b3',
        accent: '#2196f3',
        border: '#424242',
      }
    : {
        background: '#ffffff',
        paper: '#ffffff',
        text: '#212121',
        muted: '#666666',
        accent: '#1976d2',
        border: '#dddddd',
      };
  const [connection, setConnection] = useState<Connection | null>(null);
  const [form, setForm] = useState<Connection>(empty);
  const [settings, setSettings] = useState(true);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [data, setData] = useState<Recordings>({ records: [], total: 0 });
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState<Recording | null>(null);
  const [opening, setOpening] = useState<number | null>(null);
  const request = useRef<AbortController | null>(null);
  const details = useRef<AbortController | null>(null);
  const mounted = useRef(true);
  const openingRef = useRef(false);

  useEffect(() => {
    mounted.current = true;
    native
      .loadConnection()
      .then(saved => {
        if (!mounted.current) {
          return;
        }
        if (saved) {
          setConnection(saved);
          setForm(saved);
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
      setOffset(pageOffset);
      setSettings(false);
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
    } catch {
      setError(
        'http:// または https:// から始まるサーバーURLを入力してください。認証情報は下の欄で指定します。',
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

  async function play(file: VideoFile) {
    if (!connection || !selected || openingRef.current) {
      return;
    }
    openingRef.current = true;
    const title = selected.name;
    setSelected(null);
    try {
      await native.play({
        url: apiURL(connection, `/videos/${file.id}`),
        title,
        username: connection.username,
        password: connection.password,
        networkCaching: 5000,
      });
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
    <SafeAreaView style={[styles.root, { backgroundColor: colors.background }]}>
      <StatusBar barStyle={dark ? 'light-content' : 'dark-content'} />
      <View style={[styles.header, { borderBottomColor: colors.border }]}>
        <Text style={[styles.title, { color: colors.text }]}>
          NeoEPGStation
        </Text>
        {!settings &&
          button('接続設定', () => {
            request.current?.abort();
            details.current?.abort();
            setBusy(false);
            setError('');
            setSettings(true);
          })}
      </View>
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
            <Text style={{ color: colors.muted }}>
              Basic認証（設定している場合）
            </Text>
            <TextInput
              accessibilityLabel="Basic認証ユーザー名"
              autoCapitalize="none"
              autoCorrect={false}
              placeholder="ユーザー名"
              placeholderTextColor={colors.muted}
              editable={!busy}
              value={form.username}
              onChangeText={username => setForm({ ...form, username })}
              style={[
                styles.input,
                { color: colors.text, borderColor: colors.border },
              ]}
            />
            <TextInput
              accessibilityLabel="Basic認証パスワード"
              secureTextEntry
              autoCapitalize="none"
              placeholder="パスワード"
              placeholderTextColor={colors.muted}
              editable={!busy}
              value={form.password}
              onChangeText={password => setForm({ ...form, password })}
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
                  void load(connection, offset);
                },
                busy,
              )}
            <Text style={[styles.hint, { color: colors.muted }]}>
              接続先と認証情報はこの端末に保存します。
            </Text>
            {!!error && (
              <Text accessibilityRole="alert" style={styles.error}>
                {error}
              </Text>
            )}
          </ScrollView>
        </KeyboardAvoidingView>
      ) : (
        <View style={styles.grow}>
          <View style={styles.toolbar}>
            <Text style={[styles.heading, { color: colors.text }]}>
              録画済み · {data.total}件
            </Text>
            {button(
              '更新',
              () => {
                if (connection) {
                  void load(connection, offset);
                }
              },
              busy,
            )}
          </View>
          {!!error && (
            <Text accessibilityRole="alert" style={styles.error}>
              {error}
            </Text>
          )}
          <FlatList
            data={data.records}
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
                  { backgroundColor: colors.paper, borderColor: colors.border },
                ]}
              >
                {connection && item.thumbnails?.[0] !== undefined ? (
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
                    numberOfLines={3}
                  >
                    {item.name}
                  </Text>
                  <Text style={{ color: colors.muted }}>
                    {new Date(item.startAt).toLocaleString('ja-JP')}
                  </Text>
                  <Text style={[styles.hint, { color: colors.accent }]}>
                    {item.isRecording
                      ? '録画中'
                      : opening === item.id
                      ? '読み込み中…'
                      : '再生ファイルを選択'}
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
      <Modal
        visible={selected !== null}
        transparent
        animationType="fade"
        onRequestClose={() => setSelected(null)}
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
    padding: 24,
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
  toolbar: {
    padding: 16,
    gap: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  list: { padding: 16, gap: 12 },
  card: {
    borderWidth: 1,
    borderRadius: 6,
    flexDirection: 'row',
    overflow: 'hidden',
  },
  thumbnail: { width: 112, minHeight: 90 },
  cardBody: { flex: 1, padding: 12, gap: 8 },
  recordingName: { fontSize: 16, fontWeight: '600' },
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
    borderRadius: 6,
    gap: 16,
  },
  file: { paddingVertical: 16, borderBottomWidth: 1 },
});
