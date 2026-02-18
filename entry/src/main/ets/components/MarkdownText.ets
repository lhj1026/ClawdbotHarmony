// Lightweight Markdown renderer for ArkUI
// Supports: headers, code blocks, lists, bold, italic, inline code, HR, clickable URLs

import { common, Want } from '@kit.AbilityKit';

// ---------- Data interfaces ----------

interface MdSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  url: string;  // non-empty if this span is a clickable URL
  filePath: string;  // non-empty if this span is a clickable file path
  key: string;
}

interface MdBlock {
  type: string; // 'paragraph' | 'header' | 'code' | 'list_item' | 'hr' | 'table'
  level: number;
  content: string;
  spans: MdSpan[];
  ordered: boolean;
  index: number;
  key: string;
  tableHeaders: string[];
  tableRows: string[][];
}

// ---------- File path detection ----------

// Known file extensions for path detection (lowercase, without dot)
const FILE_EXTENSIONS: string[] = [
  'md', 'txt', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'csv', 'ppt', 'pptx',
  'jpg', 'jpeg', 'png', 'gif', 'bmp', 'svg', 'webp',
  'zip', 'tar', 'gz', 'rar', '7z', 'bz2',
  'json', 'xml', 'html', 'htm', 'css',
  'py', 'js', 'ts', 'java', 'c', 'cpp', 'h', 'hpp', 'go', 'rs', 'sh', 'bat',
  'log', 'cfg', 'ini', 'yaml', 'yml', 'toml', 'conf',
  'mp3', 'mp4', 'wav', 'aac', 'ogg', 'flac', 'avi', 'mkv', 'mov',
  'apk', 'hap', 'ipa', 'deb', 'rpm',
  'sql', 'db', 'sqlite',
];

function hasFileExtension(path: string): boolean {
  let dotIdx = path.lastIndexOf('.');
  if (dotIdx <= 0 || dotIdx >= path.length - 1) return false;
  let ext = path.substring(dotIdx + 1).toLowerCase();
  // Handle .tar.gz
  if (ext === 'gz') {
    let prevDot = path.lastIndexOf('.', dotIdx - 1);
    if (prevDot > 0) {
      let prevExt = path.substring(prevDot + 1, dotIdx).toLowerCase();
      if (prevExt === 'tar') return true;
    }
  }
  return FILE_EXTENSIONS.indexOf(ext) >= 0;
}

function isPathChar(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') || '-_.~/'.includes(c) ||
    (c >= '\u4e00' && c <= '\u9fa5'); // Chinese characters in paths
}

function isWinPathChar(c: string): boolean {
  return isPathChar(c) || c === '\\' || c === ':';
}

/** Try to extract a Unix file path starting at idx. Returns path string or empty. */
function extractUnixPath(text: string, idx: number): string {
  // Must start with / and next char must be alphanumeric (avoid // comments, /n etc.)
  if (idx + 1 >= text.length) return '';
  let next = text.charAt(idx + 1);
  if (!((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') ||
    (next >= '0' && next <= '9') || (next >= '\u4e00' && next <= '\u9fa5'))) return '';

  let end = idx + 1;
  while (end < text.length && (isPathChar(text.charAt(end)) || text.charAt(end) === '-')) {
    end++;
  }
  // Must contain at least one / separator beyond the leading /
  let path = text.substring(idx, end);
  if (path.indexOf('/', 1) < 0) return '';
  // Must end with a known file extension
  // Remove trailing punctuation
  while (path.length > 1 && '.,;:!?)\'\"'.includes(path.charAt(path.length - 1))) {
    path = path.substring(0, path.length - 1);
  }
  if (!hasFileExtension(path)) return '';
  return path;
}

/** Try to extract a Windows file path starting at idx (e.g. C:\path\file.ext). Returns path or empty. */
function extractWindowsPath(text: string, idx: number): string {
  // Must match pattern: letter + :\ or letter + :/
  if (idx + 2 >= text.length) return '';
  let drive = text.charAt(idx);
  if (!((drive >= 'a' && drive <= 'z') || (drive >= 'A' && drive <= 'Z'))) return '';
  if (text.charAt(idx + 1) !== ':') return '';
  let sep = text.charAt(idx + 2);
  if (sep !== '\\' && sep !== '/') return '';

  let end = idx + 3;
  while (end < text.length && (isWinPathChar(text.charAt(end)) || text.charAt(end) === ' ')) {
    // Stop at double space or end-of-word punctuation
    if (text.charAt(end) === ' ' && end + 1 < text.length && text.charAt(end + 1) === ' ') break;
    end++;
  }
  let path = text.substring(idx, end).trimEnd();
  // Remove trailing punctuation
  while (path.length > 3 && '.,;:!?)\'\"'.includes(path.charAt(path.length - 1))) {
    path = path.substring(0, path.length - 1);
  }
  if (!hasFileExtension(path)) return '';
  return path;
}

// ---------- URL detection ----------

function isUrlChar(c: string): boolean {
  // Characters that can appear in URLs
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') || '-_.~:/?#[]@!$&\'()*+,;=%'.includes(c);
}

function extractUrl(text: string, startIdx: number): string {
  // Extract URL starting from startIdx (after http:// or https://)
  let end = startIdx;
  let parenDepth = 0;
  while (end < text.length) {
    let c = text.charAt(end);
    if (c === '(') parenDepth++;
    else if (c === ')') {
      if (parenDepth > 0) parenDepth--;
      else break; // Unmatched closing paren - end of URL
    }
    if (!isUrlChar(c)) break;
    end++;
  }
  // Remove trailing punctuation that's likely not part of URL
  while (end > startIdx && '.,;:!?)\'\"'.includes(text.charAt(end - 1))) {
    if (text.charAt(end - 1) === ')' && parenDepth >= 0) break; // Keep matched parens
    end--;
  }
  return text.substring(startIdx, end);
}

function findUrlStart(text: string, fromIdx: number): number {
  // Find next http:// or https://
  let httpIdx = text.indexOf('http://', fromIdx);
  let httpsIdx = text.indexOf('https://', fromIdx);
  if (httpIdx < 0 && httpsIdx < 0) return -1;
  if (httpIdx < 0) return httpsIdx;
  if (httpsIdx < 0) return httpIdx;
  return Math.min(httpIdx, httpsIdx);
}

// ---------- Inline parser ----------

function parseInline(text: string): MdSpan[] {
  let spans: MdSpan[] = [];
  let i = 0;
  let buf = '';
  let bold = false;
  let italic = false;
  let inCode = false;
  let idx = 0;

  while (i < text.length) {
    let ch = text.charAt(i);

    // backtick → toggle code
    if (ch === '`') {
      if (buf.length > 0) {
        let s: MdSpan = {
          text: buf, bold: inCode ? false : bold,
          italic: inCode ? false : italic, code: inCode, url: '', filePath: '', key: '' + idx++
        };
        spans.push(s);
        buf = '';
      }
      inCode = !inCode;
      i++;
      continue;
    }

    if (inCode) {
      buf += ch;
      i++;
      continue;
    }

    // Check for URL (http:// or https://)
    if ((ch === 'h' && text.substring(i, i + 7) === 'http://') ||
        (ch === 'h' && text.substring(i, i + 8) === 'https://')) {
      // Flush buffer before URL
      if (buf.length > 0) {
        let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, url: '', filePath: '', key: '' + idx++ };
        spans.push(s);
        buf = '';
      }
      // Extract full URL
      let urlEnd = i + (text.charAt(i + 4) === 's' ? 8 : 7); // past http:// or https://
      let urlPath = extractUrl(text, urlEnd);
      let fullUrl = text.substring(i, urlEnd) + urlPath;
      let urlSpan: MdSpan = { text: fullUrl, bold: false, italic: false, code: false, url: fullUrl, filePath: '', key: '' + idx++ };
      spans.push(urlSpan);
      i += fullUrl.length;
      continue;
    }

    // Check for Unix file path (/path/to/file.ext)
    if (ch === '/' && !inCode) {
      let fp = extractUnixPath(text, i);
      if (fp.length > 0) {
        if (buf.length > 0) {
          let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, url: '', filePath: '', key: '' + idx++ };
          spans.push(s);
          buf = '';
        }
        let fpSpan: MdSpan = { text: fp, bold: false, italic: false, code: false, url: '', filePath: fp, key: '' + idx++ };
        spans.push(fpSpan);
        i += fp.length;
        continue;
      }
    }

    // Check for Windows file path (C:\path\to\file.ext)
    if (((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) && !inCode) {
      let wp = extractWindowsPath(text, i);
      if (wp.length > 0) {
        if (buf.length > 0) {
          let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, url: '', filePath: '', key: '' + idx++ };
          spans.push(s);
          buf = '';
        }
        let wpSpan: MdSpan = { text: wp, bold: false, italic: false, code: false, url: '', filePath: wp, key: '' + idx++ };
        spans.push(wpSpan);
        i += wp.length;
        continue;
      }
    }

    // ** → toggle bold
    if (ch === '*' && i + 1 < text.length && text.charAt(i + 1) === '*') {
      if (buf.length > 0) {
        let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, url: '', filePath: '', key: '' + idx++ };
        spans.push(s);
        buf = '';
      }
      bold = !bold;
      i += 2;
      continue;
    }

    // single * → toggle italic
    if (ch === '*') {
      if (buf.length > 0) {
        let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, url: '', filePath: '', key: '' + idx++ };
        spans.push(s);
        buf = '';
      }
      italic = !italic;
      i++;
      continue;
    }

    buf += ch;
    i++;
  }

  if (buf.length > 0) {
    let s: MdSpan = { text: buf, bold: bold, italic: italic, code: inCode, url: '', filePath: '', key: '' + idx++ };
    spans.push(s);
  }

  if (spans.length === 0) {
    let empty: MdSpan = { text: '', bold: false, italic: false, code: false, url: '', filePath: '', key: '0' };
    spans.push(empty);
  }
  return spans;
}

// ---------- Table helpers ----------

function splitTableCells(line: string): string[] {
  let s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return s.split('|');
}

function isTableSeparator(line: string): boolean {
  let trimmed = line.trim();
  if (!trimmed.startsWith('|')) return false;
  let cells = splitTableCells(trimmed);
  if (cells.length === 0) return false;
  for (let i = 0; i < cells.length; i++) {
    let cell = cells[i].trim();
    if (cell.length === 0) return false;
    let hasDash = false;
    for (let j = 0; j < cell.length; j++) {
      let c = cell.charAt(j);
      if (c === '-') {
        hasDash = true;
      } else if (c !== ':' && c !== ' ') {
        return false;
      }
    }
    if (!hasDash) return false;
  }
  return true;
}

function parseTableRow(line: string): string[] {
  let cells = splitTableCells(line);
  let result: string[] = [];
  for (let i = 0; i < cells.length; i++) {
    result.push(cells[i].trim());
  }
  return result;
}

// ---------- Block parser ----------

function parseMarkdown(text: string): MdBlock[] {
  let blocks: MdBlock[] = [];
  // Normalize line endings: \r\n → \n, \r → \n
  let normalized = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  let lines = normalized.split('\n');
  let inCode = false;
  let codeBuf = '';
  let bIdx = 0;

  for (let li = 0; li < lines.length; li++) {
    let line = lines[li];
    let trimmed = line.trim();

    // code fence
    if (trimmed.startsWith('```')) {
      if (inCode) {
        let b: MdBlock = {
          type: 'code', level: 0, content: codeBuf,
          spans: [], ordered: false, index: 0, key: '' + bIdx++,
          tableHeaders: [], tableRows: []
        };
        blocks.push(b);
        codeBuf = '';
        inCode = false;
      } else {
        inCode = true;
        codeBuf = '';
      }
      continue;
    }

    if (inCode) {
      if (codeBuf.length > 0) codeBuf += '\n';
      codeBuf += line;
      continue;
    }

    // empty line
    if (trimmed.length === 0) continue;

    // table
    if (trimmed.startsWith('|') && li + 1 < lines.length && isTableSeparator(lines[li + 1])) {
      let headers = parseTableRow(trimmed);
      li++; // skip separator line
      let rows: string[][] = [];
      while (li + 1 < lines.length) {
        let nextLine = lines[li + 1].trim();
        if (nextLine.startsWith('|') && nextLine.indexOf('|', 1) >= 0) {
          rows.push(parseTableRow(nextLine));
          li++;
        } else {
          break;
        }
      }
      let b: MdBlock = {
        type: 'table', level: 0, content: '',
        spans: [], ordered: false, index: 0, key: '' + bIdx++,
        tableHeaders: headers, tableRows: rows
      };
      blocks.push(b);
      continue;
    }

    // HR
    if (trimmed === '---' || trimmed === '***' || trimmed === '___') {
      let b: MdBlock = {
        type: 'hr', level: 0, content: '',
        spans: [], ordered: false, index: 0, key: '' + bIdx++,
        tableHeaders: [], tableRows: []
      };
      blocks.push(b);
      continue;
    }

    // header
    if (trimmed.startsWith('#')) {
      let lvl = 0;
      while (lvl < trimmed.length && trimmed.charAt(lvl) === '#') lvl++;
      if (lvl <= 6 && lvl < trimmed.length && trimmed.charAt(lvl) === ' ') {
        let hText = trimmed.substring(lvl + 1);
        let b: MdBlock = {
          type: 'header', level: lvl, content: hText,
          spans: parseInline(hText), ordered: false, index: 0, key: '' + bIdx++,
          tableHeaders: [], tableRows: []
        };
        blocks.push(b);
        continue;
      }
    }

    // unordered list
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
      let content = trimmed.substring(2);
      let b: MdBlock = {
        type: 'list_item', level: 0, content: content,
        spans: parseInline(content), ordered: false, index: 0, key: '' + bIdx++,
        tableHeaders: [], tableRows: []
      };
      blocks.push(b);
      continue;
    }

    // ordered list (e.g. "1. text")
    let dotIdx = trimmed.indexOf('. ');
    if (dotIdx > 0 && dotIdx <= 3) {
      let numPart = trimmed.substring(0, dotIdx);
      let isNum = true;
      for (let j = 0; j < numPart.length; j++) {
        let c = numPart.charAt(j);
        if (c < '0' || c > '9') {
          isNum = false;
          break;
        }
      }
      if (isNum) {
        let num = parseInt(numPart);
        let content = trimmed.substring(dotIdx + 2);
        let b: MdBlock = {
          type: 'list_item', level: 0, content: content,
          spans: parseInline(content), ordered: true, index: num, key: '' + bIdx++,
          tableHeaders: [], tableRows: []
        };
        blocks.push(b);
        continue;
      }
    }

    // paragraph
    let b: MdBlock = {
      type: 'paragraph', level: 0, content: trimmed,
      spans: parseInline(trimmed), ordered: false, index: 0, key: '' + bIdx++,
      tableHeaders: [], tableRows: []
    };
    blocks.push(b);
  }

  // unclosed code block
  if (inCode && codeBuf.length > 0) {
    let b: MdBlock = {
      type: 'code', level: 0, content: codeBuf,
      spans: [], ordered: false, index: 0, key: '' + bIdx++,
      tableHeaders: [], tableRows: []
    };
    blocks.push(b);
  }

  return blocks;
}

// ---------- Component ----------

@Component
export struct MarkdownText {
  @Prop content: string = '';
  textColor: ResourceColor = '#1A1A1A';
  baseFontSize: number = 15;
  onLinkClick: (url: string) => void = (url: string) => {
    // Default: open URL in browser
    try {
      let ctx = getContext() as common.UIAbilityContext;
      let want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      ctx.startAbility(want);
    } catch (e) {
      console.error('Failed to open URL: ' + url);
    }
  };
  onFilePathClick: (filePath: string) => void = () => {};

  // Check if spans contain any URLs or file paths
  private hasLinks(spans: MdSpan[]): boolean {
    for (let i = 0; i < spans.length; i++) {
      if (spans[i].url.length > 0 || spans[i].filePath.length > 0) return true;
    }
    return false;
  }

  build() {
    Column({ space: 2 }) {
      ForEach(parseMarkdown(this.content), (block: MdBlock) => {
        if (block.type === 'code') {
          Scroll() {
            Text(block.content)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor('#EEFFFF')
              .lineHeight(18)
                        }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding(10)
          .backgroundColor('#263238')
          .borderRadius(8)
        } else if (block.type === 'header') {
          Text() {
            ForEach(block.spans, (span: MdSpan) => {
              Span(span.text)
                .fontWeight(FontWeight.Bold)
                .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(span.code ? 'monospace' : '')
            }, (span: MdSpan): string => span.key)
          }
          .fontSize(block.level <= 1 ? 20 : block.level === 2 ? 18 : 16)
          .fontColor(this.textColor)
          .fontWeight(FontWeight.Bold)
          .lineHeight(block.level <= 1 ? 28 : 24)
          .margin({ top: 4, bottom: 2 })
          .width('100%')
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_ALL)
        } else if (block.type === 'table') {
          // Table rendering: horizontal scroll for wide tables
          Scroll() {
            Column() {
              // Header row
              if (block.tableHeaders.length > 0) {
                Row() {
                  ForEach(block.tableHeaders, (header: string, colIdx: number) => {
                    Text() {
                      ForEach(parseInline(header), (span: MdSpan) => {
                        Span(span.text)
                          .fontWeight(FontWeight.Bold)  // headers always bold
                          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                          .fontFamily(span.code ? 'monospace' : '')
                      }, (span: MdSpan): string => span.key)
                    }
                      .fontSize(this.baseFontSize - 1)
                      .fontColor('#333333')
                      .textAlign(TextAlign.Start)
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .borderWidth({ right: colIdx < block.tableHeaders.length - 1 ? 1 : 0 })
                      .borderColor('#D0D0D0')
                      .constraintSize({ minWidth: 80 })
                      .layoutWeight(1)
                  }, (header: string, idx: number): string => 'h_' + idx)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .backgroundColor('#E8E8E8')
                .borderWidth({ bottom: 1 })
                .borderColor('#CCCCCC')
              }
              // Data rows
              ForEach(block.tableRows, (row: string[], rowIdx: number) => {
                Row() {
                  ForEach(row, (cell: string, colIdx: number) => {
                    Text() {
                      ForEach(parseInline(cell), (span: MdSpan) => {
                        Span(span.text)
                          .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
                          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                          .fontFamily(span.code ? 'monospace' : '')
                          .backgroundColor(span.code ? '#E8E8E8' : Color.Transparent)
                      }, (span: MdSpan): string => span.key)
                    }
                      .fontSize(this.baseFontSize - 1)
                      .fontColor(this.textColor)
                      .textAlign(TextAlign.Start)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderWidth({ right: colIdx < row.length - 1 ? 1 : 0 })
                      .borderColor('#E8E8E8')
                      .constraintSize({ minWidth: 80 })
                      .layoutWeight(1)
                  }, (cell: string, idx: number): string => 'c_' + idx)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .backgroundColor(rowIdx % 2 === 0 ? '#FAFAFA' : '#FFFFFF')
                .borderWidth({ bottom: rowIdx < block.tableRows.length - 1 ? 1 : 0 })
                .borderColor('#EEEEEE')
              }, (row: string[], idx: number): string => 'r_' + idx)
            }
            .constraintSize({ minWidth: '100%' })
            .borderWidth(1)
            .borderColor('#D0D0D0')
            .borderRadius(6)
            .clip(true)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        } else if (block.type === 'hr') {
          Divider().color('#D0D0D0').margin({ top: 6, bottom: 6 })
        } else if (block.type === 'list_item') {
          Row() {
            Text(block.ordered ? block.index + '. ' : '\u2022 ')
              .fontSize(this.baseFontSize)
              .fontColor(this.textColor)
              .lineHeight(22)
            Text() {
              ForEach(block.spans, (span: MdSpan) => {
                Span(span.text)
                  .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                  .fontFamily(span.code ? 'monospace' : '')
                  .backgroundColor(span.code ? '#E0E0E0' : Color.Transparent)
              }, (span: MdSpan): string => span.key)
            }
            .fontSize(this.baseFontSize)
            .fontColor(this.textColor)
            .lineHeight(22)
            .layoutWeight(1)
            .wordBreak(WordBreak.BREAK_ALL)
                      }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          // paragraph - check if it has URLs or file paths
          if (this.hasLinks(block.spans)) {
            // Use Flex layout for clickable URLs / file paths
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(block.spans, (span: MdSpan) => {
                if (span.url.length > 0) {
                  Text(span.text)
                    .fontSize(this.baseFontSize)
                    .fontColor('#007AFF')
                    .decoration({ type: TextDecorationType.Underline, color: '#007AFF' })
                    .lineHeight(22)
                    .onClick(() => { this.onLinkClick(span.url); })
                } else if (span.filePath.length > 0) {
                  Text('\uD83D\uDCC1 ' + span.text)
                    .fontSize(this.baseFontSize)
                    .fontColor('#007AFF')
                    .decoration({ type: TextDecorationType.Underline, color: '#007AFF' })
                    .lineHeight(22)
                    .onClick(() => { this.onFilePathClick(span.filePath); })
                } else {
                  Text(span.text)
                    .fontSize(this.baseFontSize)
                    .fontColor(this.textColor)
                    .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
                    .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                    .fontFamily(span.code ? 'monospace' : '')
                    .backgroundColor(span.code ? '#E0E0E0' : Color.Transparent)
                    .lineHeight(22)
                }
              }, (span: MdSpan): string => span.key)
            }
            .width('100%')
          } else {
            // No URLs - use regular Text with Span (more efficient)
            Text() {
              ForEach(block.spans, (span: MdSpan) => {
                Span(span.text)
                  .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                  .fontFamily(span.code ? 'monospace' : '')
                  .backgroundColor(span.code ? '#E0E0E0' : Color.Transparent)
              }, (span: MdSpan): string => span.key)
            }
            .fontSize(this.baseFontSize)
            .fontColor(this.textColor)
            .lineHeight(22)
            .width('100%')
            .textAlign(TextAlign.Start)
            .wordBreak(WordBreak.BREAK_ALL)
          }
        }
      }, (block: MdBlock): string => '' + this.content.length + '_' + block.key)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
