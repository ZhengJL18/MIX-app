/// 对应 `ref/hermes-agent/tools/binary_extensions.py`（像素级复刻）。
///
/// 文本操作要跳过的二进制文件扩展名。
/// 这些文件无法有意义的作为文本比较，且通常很大。
/// Ported from free-code src/constants/files.ts。
library;

/// 二进制扩展名集合。
const Set<String> binaryExtensions = {
  // Images
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.tiff', '.tif',
  // Videos
  '.mp4', '.mov', '.avi', '.mkv', '.webm', '.wmv', '.flv', '.m4v', '.mpeg',
  '.mpg',
  // Audio
  '.mp3', '.wav', '.ogg', '.flac', '.aac', '.m4a', '.wma', '.aiff', '.opus',
  // Archives
  '.zip', '.tar', '.gz', '.bz2', '.7z', '.rar', '.xz', '.z', '.tgz', '.iso',
  // Executables/binaries
  '.exe', '.dll', '.so', '.dylib', '.bin', '.o', '.a', '.obj', '.lib',
  '.app', '.msi', '.deb', '.rpm',
  // Documents (exclude .pdf — text-based, agents may want to inspect)
  '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.odt', '.ods', '.odp',
  // Fonts
  '.ttf', '.otf', '.woff', '.woff2', '.eot',
  // Bytecode / VM artifacts
  '.pyc', '.pyo', '.class', '.jar', '.war', '.ear', '.node', '.wasm', '.rlib',
  // Database files
  '.sqlite', '.sqlite3', '.db', '.mdb', '.idx',
  // Design / 3D
  '.psd', '.ai', '.eps', '.sketch', '.fig', '.xd', '.blend', '.3ds', '.max',
  // Flash
  '.swf', '.fla',
  // Lock/profiling data
  '.lockb', '.dat', '.data',
};

/// 检查文件路径是否有二进制扩展名。纯字符串检查，无 I/O。
bool hasBinaryExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1) {
    return false;
  }
  return binaryExtensions.contains(path.substring(dot).toLowerCase());
}
