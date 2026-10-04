import React, { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { destinations } from './navigation';
import type { Destination } from './navigation';
import { Icon } from './Icon';
import { theme } from './theme';

export function NavigationSettings({
  value,
  save,
}: {
  value: Destination[];
  save: (next: Destination[]) => Promise<void>;
}) {
  const [draft, setDraft] = useState(value);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');
  useEffect(() => {
    setDraft(value);
  }, [value]);
  function move(index: number, direction: number) {
    const next = [...draft];
    [next[index], next[index + direction]] = [
      next[index + direction],
      next[index],
    ];
    setDraft(next);
    setMessage('');
  }
  async function apply() {
    setSaving(true);
    setMessage('');
    try {
      await save(draft);
      setMessage('保存しました。');
    } catch {
      setMessage('保存できませんでした。もう一度お試しください。');
    } finally {
      setSaving(false);
    }
  }
  return (
    <View style={styles.root}>
      <Text style={styles.heading}>下部ナビゲーション</Text>
      <Text style={styles.hint}>
        よく使う項目を1〜5個選び、表示順を変更できます。
      </Text>
      {draft.map((id, index) => (
        <View key={id} style={styles.row}>
          <Text style={styles.label}>
            {destinations.find(item => item.id === id)!.title}
          </Text>
          {([-1, 1] as const).map(direction => (
            <Pressable
              key={direction}
              accessibilityRole="button"
              accessibilityLabel={`${id}を${direction === -1 ? '上' : '下'}へ`}
              disabled={
                saving ||
                index + direction < 0 ||
                index + direction >= draft.length
              }
              style={[
                styles.control,
                (index + direction < 0 || index + direction >= draft.length) &&
                  styles.disabled,
              ]}
              onPress={() => move(index, direction)}
            >
              <Icon
                name={direction === -1 ? 'ArrowUpward' : 'ArrowDownward'}
                color={theme.muted}
              />
            </Pressable>
          ))}
        </View>
      ))}
      <View style={styles.choices}>
        {destinations.map(item => {
          const checked = draft.includes(item.id);
          return (
            <Pressable
              key={item.id}
              accessibilityRole="checkbox"
              accessibilityState={{ checked }}
              accessibilityLabel={`表示項目：${item.title}`}
              disabled={
                saving || (checked ? draft.length === 1 : draft.length === 5)
              }
              onPress={() => {
                setDraft(
                  checked
                    ? draft.filter(id => id !== item.id)
                    : [...draft, item.id],
                );
                setMessage('');
              }}
              style={[styles.choice, checked && styles.checked]}
            >
              <Icon
                name={checked ? 'Check' : item.icon}
                color={checked ? theme.accent : theme.muted}
                size={20}
              />
              <Text style={styles.choiceText}>{item.title}</Text>
            </Pressable>
          );
        })}
      </View>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="ナビゲーションを保存"
        disabled={saving}
        onPress={() => {
          void apply();
        }}
        style={styles.save}
      >
        <Text style={styles.saveText}>{saving ? '保存中…' : '保存'}</Text>
      </Pressable>
      {!!message && (
        <Text accessibilityRole="alert" style={styles.hint}>
          {message}
        </Text>
      )}
    </View>
  );
}
const styles = StyleSheet.create({
  root: { gap: 12, marginTop: 24 },
  heading: { color: theme.text, fontSize: 18, fontWeight: '600' },
  hint: { color: theme.muted, fontSize: 13, lineHeight: 20 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  label: { color: theme.text, flex: 1, fontSize: 14 },
  control: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
  disabled: { opacity: 0.3 },
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  choice: {
    minHeight: 44,
    flexDirection: 'row',
    gap: 8,
    paddingHorizontal: 10,
    alignItems: 'center',
    borderRadius: 6,
    borderWidth: 1,
    borderColor: theme.border,
  },
  checked: { backgroundColor: theme.selected, borderColor: theme.accent },
  choiceText: { color: theme.text, fontSize: 13 },
  save: {
    alignSelf: 'flex-end',
    minHeight: 42,
    paddingHorizontal: 24,
    justifyContent: 'center',
    backgroundColor: theme.accent,
    borderRadius: 7,
  },
  saveText: { color: theme.text, fontWeight: '600' },
});
