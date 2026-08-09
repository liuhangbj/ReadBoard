#!/usr/bin/env node
// readboard 自有全文抓取引擎（收编自 ~/tools/defuddle-cli/clip_core.js 的 defuddle+Jina 主路径）
// 封闭项目：不依赖任何外部脚本，node_modules 与本文件同目录（engine/node_modules）。
//
// 收编范围（选项 3）：defuddle 提取 + Jina fallback + 虎嗅预处理 + frontmatter。
// CDP/微信浏览器渲染暂未收编——遇需 CDP 的源返回特殊标记，由 Swift 侧降级 summary。
//
// 用法:
//   node fetch_engine.js url <url>   → 抓取 url 全文(defuddle→Jina Free→Jina Pro), stdout 输出 markdown
//   node fetch_engine.js html        → 从 stdin 读 HTML, 用 defuddle 转 markdown, stdout 输出
// 退出码: 0 成功; 1 抓取/解析失败; 2 参数错误; 3 需 CDP（未收编，调用方应降级 summary）
const { execFileSync } = require('child_process');
const https = require('https');
const http = require('http');
const path = require('path');
const yaml = require('js-yaml');
const { parseHTML } = require('linkedom');

// ── 路径：node 与 defuddle CLI 都相对本脚本解析，不写死绝对路径 ──
// NODE_BIN 优先环境变量（Swift 侧 DependencyPaths 传入），否则用 PATH 的 node。
const NODE_BIN = process.env.READBOARD_NODE_BIN || 'node';
// defuddle CLI 在 engine/node_modules 内（随 App 打包，自包含）。
const DEFUDDLE_CLI = path.join(__dirname, 'node_modules', 'defuddle', 'dist', 'cli.js');

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ── URL 清洗：去 RSS 跟踪参数 / 修协议 / 解 HTML 实体 ──
function cleanUrl(url) {
  if (!url) return url;
  let cleaned = url;
  cleaned = cleaned.replace(/&amp;/g, '&');
  cleaned = cleaned.replace(/&lt;/g, '<');
  cleaned = cleaned.replace(/&gt;/g, '>');
  cleaned = cleaned.replace(/&quot;/g, '"');
  cleaned = cleaned.replace(/&#39;/g, "'");
  cleaned = cleaned.replace(/&#x27;/g, "'");
  cleaned = cleaned.replace(/^(https?):\/(?!\/)/i, '$1://');
  cleaned = cleaned.replace(/[\/"']*(https?:\/\/)/i, '$1');
  cleaned = cleaned.replace(/\?f=rss$/, '');
  cleaned = cleaned.replace(/[?&]f=rss(&|$)/, '$1');
  cleaned = cleaned.replace(/[?&]utm_source=rss(&|$)/, '$1');
  cleaned = cleaned.replace(/[?&]feed=1(&|$)/, '$1');
  cleaned = cleaned.replace(/\?$/, '');
  cleaned = cleaned.replace(/&$/, '');
  return cleaned;
}

// ── 需 CDP 浏览器渲染的域名（未收编——返回标记让调用方降级）──
function needsBrowser(url) {
  try {
    const hostname = new URL(url).hostname;
    return hostname === 'mp.weixin.qq.com' || hostname.endsWith('.mp.weixin.qq.com') ||
           hostname === 'cubox.pro' || hostname.endsWith('.cubox.pro') ||
           hostname === 'jiqizhixin.com' || hostname.endsWith('.jiqizhixin.com');
  } catch {
    return false;
  }
}

// ── 需 HTML 预处理的域名（虎嗅去 AI 摘要）──
function needsHtmlPreprocess(url) {
  try {
    const hostname = new URL(url).hostname;
    return hostname === 'www.huxiu.com' || hostname === 'huxiu.com';
  } catch {
    return false;
  }
}

function fetchHtml(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https') ? https : http;
    const req = client.get(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
      }
    }, res => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return fetchHtml(new URL(res.headers.location, url).href).then(resolve, reject);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return reject(new Error(`HTTP ${res.statusCode}`));
      }
      let data = '';
      res.setEncoding('utf8');
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data));
    });
    req.on('error', reject);
    req.setTimeout(30000, () => reject(new Error('Request timeout')));
  });
}

function removeHuxiuAiSummary(html) {
  return html.replace(/<div[^>]*id=["']ai-summary["'][^>]*>[\s\S]*?<\/div>/gi, '');
}

// ── 懒加载图片归一化 ──
// 新闻站常把真实地址放在 data-src / data-flickity-lazyload / srcset，src 仅是透明
// SVG/GIF。Defuddle 会忠实保留 src，导致入库后只剩占位图。进入正文提取前先把
// 最可靠的真实候选提升到 src；这一步同时覆盖普通 img 与 picture/source。
const LAZY_SRC_ATTRIBUTES = [
  'data-flickity-lazyload',
  'data-src',
  'data-lazy-src',
  'data-original',
  'data-url',
  'data-image',
  'data-image-src',
];
const LAZY_SRCSET_ATTRIBUTES = [
  'data-flickity-lazyload-srcset',
  'data-srcset',
  'data-lazy-srcset',
  'srcset',
];

function isPlaceholderImageUrl(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (!normalized) return true;
  return normalized.startsWith('data:image/') ||
    normalized === 'about:blank' ||
    normalized.startsWith('javascript:') ||
    /(?:^|[\/_-])(transparent|spacer|placeholder)(?:[\/_\-.]|$)/i.test(normalized);
}

function usableImageUrl(value) {
  const normalized = String(value || '').trim();
  return normalized && !isPlaceholderImageUrl(normalized) &&
    !normalized.toLowerCase().startsWith('blob:');
}

function bestSrcsetCandidate(value) {
  const candidates = String(value || '').split(',').map((part, order) => {
    const match = part.trim().match(/^(\S+)(?:\s+([0-9.]+)(w|x))?$/i);
    if (!match || !usableImageUrl(match[1])) return null;
    const amount = Number(match[2] || 0);
    const unitWeight = match[3]?.toLowerCase() === 'w' ? 10_000 : 1;
    return { url: match[1], score: amount * unitWeight, order };
  }).filter(Boolean);
  candidates.sort((a, b) => b.score - a.score || b.order - a.order);
  return candidates[0]?.url || '';
}

function absoluteImageUrl(value, baseUrl) {
  const normalized = String(value || '').trim();
  if (!usableImageUrl(normalized)) return '';
  if (!baseUrl) return normalized;
  try {
    return new URL(normalized, baseUrl).href;
  } catch {
    return normalized;
  }
}

function lazyImageCandidate(img) {
  for (const attribute of LAZY_SRC_ATTRIBUTES) {
    const value = img.getAttribute(attribute);
    if (usableImageUrl(value)) return value.trim();
  }
  for (const attribute of LAZY_SRCSET_ATTRIBUTES) {
    const value = bestSrcsetCandidate(img.getAttribute(attribute));
    if (value) return value;
  }
  const picture = img.closest?.('picture');
  if (picture) {
    for (const source of picture.querySelectorAll('source')) {
      for (const attribute of LAZY_SRCSET_ATTRIBUTES) {
        const value = bestSrcsetCandidate(source.getAttribute(attribute));
        if (value) return value;
      }
    }
  }
  const current = img.getAttribute('src');
  return usableImageUrl(current) ? current.trim() : '';
}

function normalizeLazyImages(html, baseUrl = '') {
  try {
    const { document } = parseHTML(html);
    for (const img of document.querySelectorAll('img')) {
      const candidate = absoluteImageUrl(lazyImageCandidate(img), baseUrl);
      if (!candidate) continue;
      img.setAttribute('src', candidate);
      // 防止 Defuddle 再从旧 srcset 选回透明图；真实地址已固定在 src。
      img.removeAttribute('srcset');
    }
    return document.toString();
  } catch (error) {
    console.error(`Lazy image normalization skipped: ${error.message?.slice(0, 120)}`);
    return html;
  }
}

function markdownImageStats(markdown) {
  const matches = [...String(markdown || '').matchAll(/!\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+["'][^"']*["'])?\s*\)/g)];
  const placeholders = matches.filter(match => isPlaceholderImageUrl(match[1])).length;
  return { total: matches.length, placeholders, usable: matches.length - placeholders };
}

// ── defuddle：调官方 CLI，url 模式与 stdin html 模式 ──
function fetchViaDefuddle(url) {
  if (!/^https?:\/\/[^\s]+$/i.test(url)) {
    throw new Error(`Invalid URL for defuddle fetch: ${url.slice(0, 120)}`);
  }
  return execFileSync(NODE_BIN, [DEFUDDLE_CLI, 'parse', url, '--markdown', '--frontmatter'], {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    timeout: 120000
  });
}

async function fetchViaDefuddleWithRetry(url, retries = 3) {
  let lastError;
  for (let i = 0; i < retries; i++) {
    try {
      if (i > 0) console.error(`Retrying defuddle fetch (${i + 1}/${retries})...`);
      return fetchViaDefuddle(url);
    } catch (err) {
      lastError = err;
      const output = (err.stdout || '') + (err.stderr || '');
      const isContentError = output.includes('No content could be extracted');
      const isNetworkError = output.includes('fetch failed') || output.includes('timed out');
      const isForbidden = output.includes('403') || output.includes('Forbidden');
      if (!(isContentError || isNetworkError || isForbidden)) throw err;
      if (i < retries - 1) {
        const delay = 2000 * (i + 1);
        console.error(`Defuddle ${isNetworkError ? 'network' : 'content'} error, waiting ${delay}ms before retry...`);
        await sleep(delay);
      }
    }
  }
  throw lastError;
}

function parseHtmlViaDefuddle(html, baseUrl = '') {
  return execFileSync(NODE_BIN, [DEFUDDLE_CLI, 'parse', '-', '--markdown', '--frontmatter'], {
    input: normalizeLazyImages(html, baseUrl),
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    timeout: 120000
  });
}

// ── Jina Reader 兜底：云端渲染穿反爬。Free 无 key(20 RPM) / Pro 有 key(500 RPM+) ──
// 按域名定制 target-selector：这些站点 readability 自动提取会被 consent 墙/导航干扰，
// 指定正文容器直接锁定（拿到干净正文，哪怕到付费墙截断点也比摘要丰富）。
const JINA_TARGET_SELECTOR_BY_HOST = {
  'www.nytimes.com': 'section[name="articleBody"]',
  'nytimes.com': 'section[name="articleBody"]',
};

function jinaTargetSelectorFor(url) {
  try {
    const host = new URL(url).hostname;
    return JINA_TARGET_SELECTOR_BY_HOST[host] || null;
  } catch {
    return null;
  }
}

function fetchViaJina(url, usePro = false) {
  const apiKey = usePro ? (process.env.JINA_API_KEY || '') : '';
  const jinaUrl = 'https://r.jina.ai/' + url;
  const label = usePro ? 'Jina Pro' : 'Jina Free';
  console.error(`${label}: fetching ${jinaUrl.slice(0, 120)}`);

  return new Promise((resolve, reject) => {
    const options = {
      headers: {
        'Accept': 'text/plain',
        // readability 自动提取正文（Jina 默认行为），只保留链接文本不占篇幅
        'x-retain-links': 'text',
        // 延长超时——让 Jina 加载更多内容（展开按钮/懒加载）
        'x-timeout': '30',
      },
      timeout: 45000,
    };
    // 按域名加 target-selector（NYT 等 consent 墙站点锁定正文容器）
    const targetSelector = jinaTargetSelectorFor(url);
    if (targetSelector) {
      options.headers['x-target-selector'] = targetSelector;
    }
    if (apiKey) options.headers['Authorization'] = `Bearer ${apiKey}`;
    https.get(jinaUrl, options, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        console.error(`${label} redirect: ${res.statusCode} -> ${res.headers.location.slice(0, 120)}`);
        https.get(res.headers.location, options, (res2) => {
          readJinaResponse(res2, resolve, reject, label);
        }).on('error', reject);
        return;
      }
      readJinaResponse(res, resolve, reject, label);
    }).on('error', reject);
  });
}

function readJinaResponse(res, resolve, reject, label = 'Jina') {
  if (res.statusCode !== 200) {
    let body = '';
    res.on('data', (chunk) => body += chunk);
    res.on('end', () => reject(new Error(`${label} HTTP ${res.statusCode}: ${body.slice(0, 200)}`)));
    return;
  }
  let body = '';
  res.on('data', (chunk) => body += chunk);
  res.on('end', () => {
    if (!body || body.trim().length < 50) {
      reject(new Error(`${label} returned empty or too-short content`));
      return;
    }
    console.error(`${label} OK: ${body.length} chars`);
    resolve(body);
  });
}

// ── frontmatter：注入 source/url（readboard MarkdownRenderer 会折叠显示）──
const TEXT_FRONTMATTER_KEYS = new Set(['title', 'description', 'summary', 'excerpt', 'author', 'authors', 'note']);

// 剥掉 Jina 正文里的广告位/订阅引导残留（NYT 等付费墙站点文内嵌广告 + 结尾订阅提示）
function cleanJinaBodyNoise(text) {
  return text
    // 「Advertisement」「SKIP ADVERTISEMENT」独立成段的广告位标记
    .replace(/\n\s*Advertisement\s*\n/gi, '\n')
    .replace(/\n\s*SKIP ADVERTISEMENT\s*\n/gi, '\n')
    // 结尾订阅引导（NYT「Subscribe to ... to read as many articles as you like.」）
    .replace(/\n\s*Subscribe to [^\n]*read as many articles as you like\.?\s*$/i, '\n')
    // 压缩多余空行
    .replace(/\n{3,}/g, '\n\n');
}

function isQuoted(v) { return (v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")); }
function quoteYamlValue(v) { return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }

function sanitizeFrontmatterTextFields(yamlText) {
  return yamlText.split('\n').map(rawLine => {
    const match = rawLine.match(/^(\p{L}[\p{L}\p{N}_-]*):\s*(.*)$/u);
    if (!match) return rawLine;
    const key = match[1];
    let value = match[2];
    if (TEXT_FRONTMATTER_KEYS.has(key) && value && !isQuoted(value)) {
      value = quoteYamlValue(value.trim());
    }
    return `${key}: ${value}`;
  }).join('\n');
}

function splitFrontmatter(content) {
  const trimmed = content.trimStart();
  if (!trimmed.startsWith('---')) return { frontmatter: {}, body: content };
  const end = trimmed.indexOf('---', 3);
  if (end === -1) return { frontmatter: {}, body: content };
  const rawYamlText = trimmed.slice(3, end).trim();
  const body = trimmed.slice(end + 3).trimStart();
  const yamlText = sanitizeFrontmatterTextFields(rawYamlText);
  try {
    return { frontmatter: yamlText ? yaml.load(yamlText) || {} : {}, body };
  } catch {
    const frontmatter = {};
    for (const line of yamlText.split('\n')) {
      const match = line.match(/^(\p{L}[\p{L}\p{N}_-]*):\s*(.*)$/u);
      if (match) {
        let value = match[2].trim();
        if (isQuoted(value)) value = value.slice(1, -1);
        frontmatter[match[1].trim()] = value;
      }
    }
    return { frontmatter, body };
  }
}

function stringifyFrontmatter(frontmatter) {
  const clean = Object.fromEntries(Object.entries(frontmatter).filter(([_, v]) => v !== undefined && v !== null));
  if (Object.keys(clean).length === 0) return '';
  const yamlText = yaml.dump(clean, { lineWidth: -1, noRefs: true, sortKeys: false, quotingType: '"', forceQuotes: false });
  return `---\n${yamlText}---\n\n`;
}

// ── 主流程：url → markdown（defuddle → Jina Free → Jina Pro）──
// 返回 { markdown, engine }——engine 是实际抓取成功的引擎（defuddle/jina_free/jina_pro），
// 让 Swift 侧正确记录 fetch_engine（黑盒内部 fallback 后，标签要反映真实路径）。
async function fetchMarkdownWithEngine(dirtyUrl) {
  const url = cleanUrl(dirtyUrl);
  if (url !== dirtyUrl) console.error(`Cleaned URL: ${dirtyUrl} -> ${url}`);

  // 需 CDP 的源——未收编，抛特殊错误让 Swift 侧降级 summary
  if (needsBrowser(url)) {
    const err = new Error(`NEEDS_CDP: ${new URL(url).hostname} requires browser rendering (not yet incorporated into readboard)`);
    err.code = 'NEEDS_CDP';
    throw err;
  }

  let markdown;
  let engine = 'defuddle';
  if (needsHtmlPreprocess(url)) {
    console.error('Huxiu article detected, pre-processing HTML...');
    const html = await fetchHtml(url);
    markdown = parseHtmlViaDefuddle(removeHuxiuAiSummary(html), url);
    engine = 'defuddle';
  } else {
    try {
      markdown = await fetchViaDefuddleWithRetry(url);
      engine = 'defuddle';

      // Defuddle 的 URL 模式不会提升站点私有的懒加载字段。只在结果明确包含透明
      // 占位图时额外抓取原始 HTML，避免让所有文章都承担第二次网络请求。
      const directStats = markdownImageStats(markdown);
      if (directStats.placeholders > 0) {
        console.error(`Repairing ${directStats.placeholders} lazy-loaded image placeholder(s)...`);
        try {
          const html = await fetchHtml(url);
          const repaired = parseHtmlViaDefuddle(html, url);
          const repairedStats = markdownImageStats(repaired);
          if (repairedStats.usable > directStats.usable ||
              repairedStats.placeholders < directStats.placeholders) {
            markdown = repaired;
            console.error(`Lazy image repair OK: ${directStats.usable} -> ${repairedStats.usable} usable image(s)`);
          }
        } catch (repairError) {
          // 图片修复失败不能推翻已经成功的正文抓取。
          console.error(`Lazy image repair skipped: ${repairError.message?.slice(0, 120)}`);
        }
      }
    } catch (defuddleErr) {
      const jinaFreeEnabled = process.env.JINA_FREE_ENABLED === '1';
      const hasProKey = !!process.env.JINA_API_KEY;
      if (!jinaFreeEnabled && !hasProKey) throw defuddleErr;
      console.error(`Defuddle failed (${defuddleErr.message?.slice(0, 80)})`);
      if (jinaFreeEnabled) {
        try {
          markdown = await fetchViaJina(url, false);
          engine = 'jina_free';
        } catch (jinaFreeErr) {
          const is429 = jinaFreeErr.message?.includes('429') || jinaFreeErr.message?.includes('rate');
          if (is429 && !hasProKey) throw jinaFreeErr;
          if (hasProKey) {
            console.error(`${is429 ? 'Jina Free rate limited' : `Jina Free failed (${jinaFreeErr.message?.slice(0, 80)})`}, trying Jina Pro...`);
            markdown = await fetchViaJina(url, true);
            engine = 'jina_pro';
          } else {
            throw jinaFreeErr;
          }
        }
      } else if (hasProKey) {
        console.error('Jina Free disabled, trying Jina Pro...');
        markdown = await fetchViaJina(url, true);
        engine = 'jina_pro';
      }
    }
  }

  let { frontmatter, body } = splitFrontmatter(markdown);
  // Jina 拿到的正文剥广告位/订阅引导残留（NYT 等付费墙站点）
  if (engine === 'jina_free' || engine === 'jina_pro') {
    body = cleanJinaBodyNoise(body);
  }
  frontmatter.source = url;
  if (!frontmatter.url) frontmatter.url = url;
  // 注入真实抓取引擎——Swift 侧解析此字段记录 fetch_engine（识别哪些源在烧 Jina token）
  frontmatter.rb_fetch_engine = engine;
  return { markdown: stringifyFrontmatter(frontmatter) + body.trimStart(), engine };
}

// ── CLI 入口 ──
(async () => {
  const mode = process.argv[2];
  try {
    if (mode === 'url') {
      const url = process.argv[3];
      if (!url) { console.error('usage: node fetch_engine.js url <url>'); process.exit(2); }
      const { markdown, engine } = await fetchMarkdownWithEngine(url);
      process.stdout.write(markdown);
      // 真实引擎标记写 stderr 最后一行（固定前缀，Swift 侧解析；不污染 stdout 的 markdown）
      console.error(`RB_FETCH_ENGINE:${engine}`);
    } else if (mode === 'html') {
      let html = '';
      process.stdin.setEncoding('utf8');
      for await (const chunk of process.stdin) html += chunk;
      if (!html.trim()) { console.error('empty html on stdin'); process.exit(2); }
      process.stdout.write(parseHtmlViaDefuddle(html));
    } else {
      console.error('usage: node fetch_engine.js url <url> | node fetch_engine.js html');
      process.exit(2);
    }
  } catch (e) {
    if (e.code === 'NEEDS_CDP') { console.error(e.message); process.exit(3); }
    console.error('FETCH_FAIL: ' + e.message);
    process.exit(1);
  }
})();
