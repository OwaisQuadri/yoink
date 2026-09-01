export function rankMediaCandidates(candidates) {
  return candidates
    .filter((candidate) => candidate.playable && !candidate.protected)
    .sort((a, b) =>
      Number(b.verified !== false) - Number(a.verified !== false)
      || (b.height ?? 0) - (a.height ?? 0)
      || (b.advertisedHeight ?? 0) - (a.advertisedHeight ?? 0)
      || (b.frameRate ?? 0) - (a.frameRate ?? 0)
      || Number(Boolean(b.direct)) - Number(Boolean(a.direct))
      || (b.bitrate ?? 0) - (a.bitrate ?? 0)
      || Number(Boolean(b.hasEnglishSubtitles)) - Number(Boolean(a.hasEnglishSubtitles))
      || (a.serverOrder ?? 0) - (b.serverOrder ?? 0))
}
