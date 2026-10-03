module.exports = {
  preset: '@react-native/jest-preset',
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native(-url-polyfill)?|@react-native(-community)?)/)',
  ],
};
