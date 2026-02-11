// Lightweight Markdown renderer for ArkUI
// Supports: headers, code blocks, lists, bold, italic, inline code, HR

// ---------- Data interfaces ----------

interface MdSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  key: string;
}

interface MdBlock {
  type: string; // 'paragraph' | 'header' | 'code' | 'list_item' | 'hr'
  level: number;
  content: string;
  spans: MdSpan[];
  ordered: boolean;
  index: number;
  key: string;
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
          italic: inCode ? false : italic, code: inCode, key: '' + idx++
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

    // ** → toggle bold
    if (ch === '*' && i + 1 < text.length && text.charAt(i + 1) === '*') {
      if (buf.length > 0) {
        let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, key: '' + idx++ };
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
        let s: MdSpan = { text: buf, bold: bold, italic: italic, code: false, key: '' + idx++ };
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
    let s: MdSpan = { text: buf, bold: bold, italic: italic, code: inCode, key: '' + idx++ };
    spans.push(s);
  }

  if (spans.length === 0) {
    let empty: MdSpan = { text: '', bold: false, italic: false, code: false, key: '0' };
    spans.push(empty);
  }
  return spans;
}

// ---------- Block parser ----------

function parseMarkdown(text: string): MdBlock[] {
  let blocks: MdBlock[] = [];
  let lines = text.split('\n');
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
          spans: [], ordered: false, index: 0, key: '' + bIdx++
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

    // HR
    if (trimmed === '---' || trimmed === '***' || trimmed === '___') {
      let b: MdBlock = {
        type: 'hr', level: 0, content: '',
        spans: [], ordered: false, index: 0, key: '' + bIdx++
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
          spans: parseInline(hText), ordered: false, index: 0, key: '' + bIdx++
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
        spans: parseInline(content), ordered: false, index: 0, key: '' + bIdx++
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
          spans: parseInline(content), ordered: true, index: num, key: '' + bIdx++
        };
        blocks.push(b);
        continue;
      }
    }

    // paragraph
    let b: MdBlock = {
      type: 'paragraph', level: 0, content: trimmed,
      spans: parseInline(trimmed), ordered: false, index: 0, key: '' + bIdx++
    };
    blocks.push(b);
  }

  // unclosed code block
  if (inCode && codeBuf.length > 0) {
    let b: MdBlock = {
      type: 'code', level: 0, content: codeBuf,
      spans: [], ordered: false, index: 0, key: '' + bIdx++
    };
    blocks.push(b);
  }

  return blocks;
}

// ---------- Component ----------

@Component
export struct MarkdownText {
  content: string = '';
  textColor: ResourceColor = '#1A1A1A';
  baseFontSize: number = 15;

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
          // paragraph
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
      }, (block: MdBlock): string => block.key)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
