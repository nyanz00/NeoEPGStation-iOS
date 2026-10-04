import React from 'react';
import Svg, { Circle, Path, Rect } from 'react-native-svg';

// Synthetic, code-drawn thumbnails for public CI screenshots.
export function FixtureThumbnail({ id }: { id: number }) {
  const palette = ['#206d70', '#594272', '#31577c', '#72542c'];
  return (
    <Svg
      width="100%"
      height="100%"
      viewBox="0 0 192 108"
      preserveAspectRatio="xMidYMid slice"
      accessible={false}
    >
      <Rect
        width="192"
        height="108"
        fill={palette[(id - 1) % palette.length]}
      />
      <Circle cx="140" cy="32" r="20" fill="#ffffff" opacity={0.2} />
      <Path
        d="M0 94L54 32L100 76L140 52L192 98V108H0Z"
        fill="#ffffff"
        opacity={0.25}
      />
    </Svg>
  );
}
