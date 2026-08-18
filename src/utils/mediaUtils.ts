const STORAGE_BASE_URL = 'https://ixkganrxtkywypvqkqkn.supabase.co/storage/v1';

/**
 * Normalizes any image URL (Direct, Supabase Storage, Google Drive share URL, or fallback).
 */
export function normalizeImageUrl(
  imagePath?: string | null,
  defaultBucket: string = 'profile-images',
  fallbackPlaceholder?: string
): string {
  if (!imagePath || !imagePath.trim()) {
    return fallbackPlaceholder || 'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&fit=crop&crop=face';
  }

  const raw = imagePath.trim();

  // 1. Handle Google Drive Share URLs
  // Patterns:
  // - https://drive.google.com/file/d/{ID}/view...
  // - https://drive.google.com/open?id={ID}
  // - https://drive.google.com/uc?id={ID}
  // - https://drive.google.com/uc?export=view&id={ID}
  if (raw.includes('drive.google.com') || raw.includes('docs.google.com')) {
    const fileIdMatch =
      raw.match(/\/file\/d\/([a-zA-Z0-9_-]+)/) ||
      raw.match(/[?&]id=([a-zA-Z0-9_-]+)/);

    if (fileIdMatch && fileIdMatch[1]) {
      const fileId = fileIdMatch[1];
      // Google's direct CDN display URL for public drive files
      return `https://lh3.googleusercontent.com/d/${fileId}`;
    }
  }

  // 2. Direct HTTP/HTTPS or Blob/Data URLs
  if (raw.startsWith('http://') || raw.startsWith('https://') || raw.startsWith('blob:') || raw.startsWith('data:image')) {
    return raw;
  }

  // 3. Supabase Storage Path (e.g. 'profile-images/uuid.png' or 'uuid.png')
  const cleanPath = raw.startsWith('/') ? raw.slice(1) : raw;
  const parts = cleanPath.split('/');
  
  if (parts.length >= 2) {
    // Contains bucket name as first segment
    const bucket = parts[0];
    const objectPath = parts.slice(1).join('/');
    return `${STORAGE_BASE_URL}/object/public/${bucket}/${objectPath}`;
  }

  // Relative object key without bucket prefix
  return `${STORAGE_BASE_URL}/object/public/${defaultBucket}/${cleanPath}`;
}


/**
 * Validates whether a given string is a valid playable audio URL source
 */
export function isValidAudioUrl(url?: string | null): boolean {
  if (!url || typeof url !== 'string') return false;
  const trimmed = url.trim();
  if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://') && !trimmed.startsWith('blob:') && !trimmed.startsWith('data:audio')) {
    return false;
  }
  const lower = trimmed.toLowerCase();
  if (
    lower.includes('supabase.com/dashboard') ||
    lower.includes('google.com/url') ||
    lower.includes('share.google') ||
    lower.includes('github.com') ||
    lower.endsWith('.html') ||
    lower.endsWith('.htm') ||
    lower.endsWith('.php')
  ) {
    return false;
  }
  const hasAudioExtension = /\.(mp3|m4a|wav|ogg|aac|webm|flac|opus)(\?.*)?$/i.test(trimmed);
  const isAudioDomain = /mp3quran\.net|everyayah\.com|quranicaudio\.com|qurancdn\.com|audio\.qurancdn\.com|archive\.org/i.test(trimmed);
  const isStorageAudio = trimmed.includes('/storage/v1/object/public/') && (trimmed.includes('audio') || trimmed.includes('.mp3') || trimmed.includes('.m4a'));
  const isBlobOrData = trimmed.startsWith('blob:') || trimmed.startsWith('data:audio');

  return hasAudioExtension || isAudioDomain || isStorageAudio || isBlobOrData;
}

/**
 * Returns a high-availability fallback Quran audio stream matching the surah number.
 */
export function getFallbackQuranAudioUrl(surahNumber?: number | string | null): string {
  const num = Number(surahNumber) || 1;
  const validNum = num >= 1 && num <= 114 ? num : 1;
  const pad = validNum.toString().padStart(3, '0');
  return `https://server8.mp3quran.net/afs/${pad}.mp3`;
}

/**
 * Safely resolves audio URL for a recitation record.
 */
export function normalizeAudioUrl(record?: {
  audio_storage_path?: string | null;
  audioStoragePath?: string | null;
  external_audio_url?: string | null;
  externalAudioUrl?: string | null;
  audio_url?: string | null;
  audioUrl?: string | null;
  surah_number?: number | string | null;
  surahNumber?: number | string | null;
  [key: string]: any;
}): string {
  if (!record) return getFallbackQuranAudioUrl(1);

  const surah = record.surah_number || record.surahNumber || record.surahNum || 1;

  // 1. Check external audio URL
  const external = record.external_audio_url || record.externalAudioUrl;
  if (isValidAudioUrl(external)) {
    return (external as string).trim();
  }

  // 2. Check storage path
  const storagePath = record.audio_storage_path || record.audioStoragePath;
  if (storagePath && typeof storagePath === 'string' && storagePath.trim() && storagePath.trim() !== 'recitation-audio/sample.mp3') {
    const cleanPath = storagePath.startsWith('/') ? storagePath.slice(1) : storagePath;
    const parts = cleanPath.split('/');
    let storageUrl = '';
    if (parts.length >= 2) {
      storageUrl = `${STORAGE_BASE_URL}/object/public/${parts[0]}/${parts.slice(1).join('/')}`;
    } else {
      storageUrl = `${STORAGE_BASE_URL}/object/public/recitation-audio/${cleanPath}`;
    }

    if (isValidAudioUrl(storageUrl)) {
      return storageUrl;
    }
  }

  // 3. Check audio_url direct field
  const directAudioUrl = record.audio_url || record.audioUrl;
  if (isValidAudioUrl(directAudioUrl)) {
    return (directAudioUrl as string).trim();
  }

  // 4. Default high-availability CDN
  return getFallbackQuranAudioUrl(surah);
}
