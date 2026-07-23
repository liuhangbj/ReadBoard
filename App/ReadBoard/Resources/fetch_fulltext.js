#!/usr/bin/env node
// readboard 全文引擎 CLI：包装 clip_core（defuddle + CDP 浏览器渲染）
// 用法:
//   node fetch_fulltext.js url <url>     → 抓取 url 全文(自动按域名路由 defuddle/CDP/预处理), stdout 输出 markdown
//   node fetch_fulltext.js html          → 从 stdin 读 HTML, 用 defuddle 转 markdown, stdout 输出
// 退出码: 0 成功; 1 抓取/解析失败; 2 参数错误
const { fetchMarkdown, parseHtmlViaDefuddle } = require('/Users/hangbits/tools/defuddle-cli/clip_core.js');

const mode = process.argv[2];

(async () => {
  try {
    if (mode === 'url') {
      const url = process.argv[3];
      if (!url) { console.error('usage: node fetch_fulltext.js url <url>'); process.exit(2); }
      const md = await fetchMarkdown(url);
      process.stdout.write(md);
    } else if (mode === 'html') {
      let html = '';
      process.stdin.setEncoding('utf8');
      for await (const chunk of process.stdin) html += chunk;
      if (!html.trim()) { console.error('empty html on stdin'); process.exit(2); }
      const md = parseHtmlViaDefuddle(html);
      process.stdout.write(md);
    } else {
      console.error('usage: node fetch_fulltext.js url <url> | node fetch_fulltext.js html');
      process.exit(2);
    }
  } catch (e) {
    console.error('FETCH_FAIL: ' + e.message);
    process.exit(1);
  }
})();
