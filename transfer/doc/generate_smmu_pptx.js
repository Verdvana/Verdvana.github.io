#!/usr/bin/env node
'use strict';

const path = require('path');
const PptxGenJS = require('/tmp/smmu-pptx-tool/node_modules/pptxgenjs');

const pptx = new PptxGenJS();
pptx.layout = 'LAYOUT_WIDE';
pptx.author = 'Codex';
pptx.company = 'IC Project';
pptx.subject = 'Smart MMU RTL technical review';
pptx.title = 'Smart MMU RTL 深度解析';
pptx.lang = 'zh-CN';
pptx.theme = {
  headFontFace: 'Microsoft YaHei',
  bodyFontFace: 'Microsoft YaHei',
  lang: 'zh-CN'
};
pptx.defineSlideMaster({
  title: 'SMMU_MASTER',
  background: { color: 'F7F9FC' },
  objects: [
    { rect: { x: 0, y: 0, w: 13.333, h: 0.13, fill: { color: '00A6A6' }, line: { color: '00A6A6' } } },
    { line: { x: 0.55, y: 7.14, w: 12.23, h: 0, line: { color: 'D8E0EA', width: 0.8 } } },
    { text: { text: 'Smart MMU RTL Design Review', options: { x: 0.56, y: 7.17, w: 3.5, h: 0.2, fontFace: 'Microsoft YaHei', fontSize: 8, color: '7A8798', margin: 0 } } }
  ],
  slideNumber: { x: 12.26, y: 7.14, w: 0.5, h: 0.22, color: '7A8798', fontSize: 9, align: 'right', margin: 0 }
});

const S = pptx.ShapeType;
const C = {
  navy: '16324F', navy2: '254B6E', teal: '00A6A6', tealLite: 'E2F6F5',
  orange: 'F59E0B', orangeLite: 'FFF3D6', green: '22C55E', greenLite: 'E8F8ED',
  purple: '8B5CF6', purpleLite: 'F0EAFE', red: 'EF4444', redLite: 'FDEBEC',
  gray: '64748B', gray2: '94A3B8', gray3: 'D8E0EA', light: 'F7F9FC',
  white: 'FFFFFF', black: '182230', ink2: '334155', cyan: '38BDF8'
};
const FONT = 'Microsoft YaHei';
const MONO = 'Consolas';
const W = 13.333, H = 7.5;

function addText(slide, text, x, y, w, h, opts = {}) {
  slide.addText(text, {
    x, y, w, h, fontFace: opts.fontFace || FONT, fontSize: opts.fontSize || 18,
    color: opts.color || C.black, bold: !!opts.bold, align: opts.align || 'left',
    valign: opts.valign || 'mid', margin: opts.margin === undefined ? 0.08 : opts.margin,
    breakLine: false, fit: opts.fit || 'shrink', isTextBox: true,
    bullet: opts.bullet, paraSpaceAfterPt: opts.paraSpaceAfterPt,
    ...opts
  });
}

function box(slide, x, y, w, h, text, fill = C.white, line = C.gray3, opts = {}) {
  slide.addShape(opts.shape || S.roundRect, {
    x, y, w, h, rectRadius: 0.06,
    fill: { color: fill, transparency: opts.transparency || 0 },
    line: { color: line, width: opts.lineWidth || 1.1 },
    shadow: opts.shadow ? { type: 'outer', color: 'AAB6C4', opacity: 0.16, blur: 1, angle: 45, distance: 1 } : undefined
  });
  if (text !== undefined && text !== '') addText(slide, text, x + 0.08, y + 0.04, w - 0.16, h - 0.08, opts.text || {});
}

function line(slide, x1, y1, x2, y2, color = C.gray, width = 1.5, arrow = false, dash = 'solid') {
  slide.addShape(S.line, {
    x: x1, y: y1, w: x2 - x1, h: y2 - y1,
    line: { color, width, dashType: dash, endArrowType: arrow ? 'triangle' : undefined }
  });
}

function circle(slide, x, y, d, text, fill, opts = {}) {
  slide.addShape(S.ellipse, { x, y, w: d, h: d, fill: { color: fill }, line: { color: opts.line || fill, width: 1.1 } });
  addText(slide, text, x, y, d, d, { fontSize: opts.fontSize || 16, bold: true, color: opts.color || C.white, align: 'center', margin: 0 });
}

function header(slide, title, section, takeaway, notes = '') {
  addText(slide, title, 0.57, 0.29, 10.6, 0.49, { fontSize: 27, bold: true, color: C.navy, margin: 0 });
  box(slide, 11.5, 0.31, 1.25, 0.35, section, C.navy, C.navy, { text: { fontSize: 11, bold: true, color: C.white, align: 'center', margin: 0 } });
  if (takeaway) {
    slide.addShape(S.roundRect, { x: 0.57, y: 6.66, w: 11.95, h: 0.36, fill: { color: C.tealLite }, line: { color: C.tealLite } });
    addText(slide, `结论：${takeaway}`, 0.75, 6.69, 11.55, 0.27, { fontSize: 13, bold: true, color: C.navy, margin: 0 });
  }
  if (notes && typeof slide.addNotes === 'function') slide.addNotes(notes);
}

function newSlide(title, section, takeaway, notes = '') {
  const slide = pptx.addSlide('SMMU_MASTER');
  header(slide, title, section, takeaway, notes);
  return slide;
}

function pill(slide, x, y, w, text, fill, color = C.white) {
  box(slide, x, y, w, 0.34, text, fill, fill, { text: { fontSize: 11, bold: true, color, align: 'center', margin: 0 } });
}

function addBullets(slide, items, x, y, w, h, opts = {}) {
  const runs = [];
  items.forEach((it, i) => {
    runs.push({ text: `• ${it}${i === items.length - 1 ? '' : '\n'}`, options: { breakLine: false, bullet: false } });
  });
  slide.addText(runs, { x, y, w, h, fontFace: FONT, fontSize: opts.fontSize || 18, color: opts.color || C.black, margin: opts.margin || 0.04, breakLine: false, valign: 'top', fit: 'shrink', paraSpaceAfterPt: opts.space || 8 });
}

function addTable(slide, rows, x, y, w, h, widths, opts = {}) {
  slide.addTable(rows, {
    x, y, w, h, colW: widths, rowH: opts.rowH,
    border: { type: 'solid', color: C.gray3, pt: 0.8 },
    fill: C.white, color: C.black, fontFace: FONT, fontSize: opts.fontSize || 13,
    margin: 0.07, valign: 'mid', breakLine: false,
    bold: false, autoFit: false,
    ...opts
  });
}

function chain(slide, x, y, labels, color, opts = {}) {
  const d = opts.d || 0.48, gap = opts.gap || 0.36;
  labels.forEach((lab, i) => {
    const xx = x + i * (d + gap);
    circle(slide, xx, y, d, lab, color, { fontSize: opts.fontSize || 13 });
    if (i < labels.length - 1) line(slide, xx + d, y + d / 2, xx + d + gap - 0.04, y + d / 2, color, 1.8, true);
  });
}

function digitalWave(slide, rows, x, y, w, rowH = 0.37) {
  const labelW = 1.65, cycles = rows[0].values.length;
  const cw = (w - labelW) / cycles;
  for (let c = 0; c <= cycles; c++) line(slide, x + labelW + c * cw, y, x + labelW + c * cw, y + rowH * rows.length, 'DDE4ED', 0.55, false, 'dash');
  rows.forEach((row, ri) => {
    const yy = y + ri * rowH;
    addText(slide, row.name, x, yy + 0.02, labelW - 0.1, rowH - 0.04, { fontSize: 11, color: C.ink2, align: 'right', margin: 0 });
    const hi = yy + 0.08, lo = yy + rowH - 0.08;
    for (let c = 0; c < cycles; c++) {
      const v = row.values[c];
      const nx = x + labelW + c * cw;
      if (typeof v === 'number') {
        const py = v ? hi : lo;
        line(slide, nx, py, nx + cw, py, row.color || C.teal, 1.5);
        if (c > 0 && typeof row.values[c - 1] === 'number' && row.values[c - 1] !== v) line(slide, nx, hi, nx, lo, row.color || C.teal, 1.5);
      } else {
        box(slide, nx + 0.02, yy + 0.045, cw - 0.04, rowH - 0.09, String(v), row.fill || 'EEF3F8', row.color || C.gray3, { shape: S.rect, text: { fontSize: 10, bold: true, color: C.navy, align: 'center', margin: 0 } });
      }
    }
  });
}

function stateNode(slide, x, y, w, text, color, sub = '') {
  box(slide, x, y, w, sub ? 0.72 : 0.52, '', C.white, color, { lineWidth: 1.8, shadow: true });
  addText(slide, text, x + 0.08, y + 0.06, w - 0.16, 0.25, { fontSize: 15, bold: true, color, align: 'center', margin: 0 });
  if (sub) addText(slide, sub, x + 0.08, y + 0.34, w - 0.16, 0.24, { fontSize: 10.5, color: C.gray, align: 'center', margin: 0 });
}

// 1. Cover
{
  const s = pptx.addSlide(); s.background = { color: C.navy };
  s.addShape(S.rect, { x: 0, y: 0, w: W, h: H, fill: { color: C.navy }, line: { color: C.navy } });
  addText(s, 'Smart MMU RTL 深度解析', 0.72, 0.8, 8.4, 0.72, { fontSize: 36, bold: true, color: C.white, margin: 0 });
  addText(s, '共享 SRAM 地址管理、链表流水与零复制多播', 0.75, 1.6, 8.6, 0.48, { fontSize: 21, color: 'CFE5F3', margin: 0 });
  chain(s, 1.05, 3.05, ['A', 'F', 'C', '9', '…'], C.teal, { d: 0.64, gap: 0.58, fontSize: 16 });
  pill(s, 0.95, 4.24, 1.85, '统一空闲池', C.green);
  pill(s, 3.2, 4.24, 2.15, '32 条单播链', C.orange);
  pill(s, 5.78, 4.24, 2.15, '1 条多播链', C.purple);
  box(s, 9.55, 1.05, 2.8, 4.35, '', '1D4262', '3C6381', { shadow: true });
  addText(s, '4 × 8', 9.9, 1.42, 2.1, 0.7, { fontSize: 34, bold: true, color: C.white, align: 'center', margin: 0 });
  addText(s, 'Ports × TCs', 9.9, 2.08, 2.1, 0.32, { fontSize: 13, color: 'B8D2E4', align: 'center', margin: 0 });
  addText(s, '8192', 9.9, 2.65, 2.1, 0.7, { fontSize: 34, bold: true, color: C.white, align: 'center', margin: 0 });
  addText(s, '256 B Cells', 9.9, 3.3, 2.1, 0.32, { fontSize: 13, color: 'B8D2E4', align: 'center', margin: 0 });
  addText(s, '1R1W', 9.9, 3.85, 2.1, 0.7, { fontSize: 34, bold: true, color: C.white, align: 'center', margin: 0 });
  addText(s, '后继指针 SRAM', 9.9, 4.5, 2.1, 0.32, { fontSize: 13, color: 'B8D2E4', align: 'center', margin: 0 });
  addText(s, 'RTL Design Review', 0.75, 6.6, 3.2, 0.3, { fontSize: 13, bold: true, color: C.teal, margin: 0 });
  if (typeof s.addNotes === 'function') s.addNotes('SMMU 不是地址翻译 IOMMU，而是 QM 下方的共享 SRAM cell 地址与链表管理器。');
}

// 2. What it solves
{
  const s = newSlide('一句话结论：它解决什么问题', '定位', '外部一拍，内部靠预取维持链表流水', '一拍接口依赖队头和两级前瞻寄存器隐藏同步 SRAM 读延迟。');
  const cols = [0.72, 4.55, 8.58];
  [['请求', C.teal, ['分配请求', '出队请求', '回收请求']], ['SMMU', C.navy, ['链表引擎', '占用管理', '多播与老化']], ['结果', C.orange, ['一拍分配地址', '一拍队头地址', '流控与告警']]].forEach((g, i) => {
    box(s, cols[i], 1.22, 3.2, 2.15, '', i === 1 ? 'EAF1F7' : C.white, g[1], { lineWidth: 1.7, shadow: true });
    pill(s, cols[i] + 0.55, 1.45, 2.1, g[0], g[1]);
    addBullets(s, g[2], cols[i] + 0.38, 2.02, 2.45, 1.05, { fontSize: 16, space: 7 });
    if (i < 2) line(s, cols[i] + 3.25, 2.28, cols[i + 1] - 0.12, 2.28, C.gray2, 2, true);
  });
  const caps = [['动态共享', '突发流量按需占用整片 SRAM', C.teal], ['满吞吐', '常见路径支持 1 cell/cycle', C.orange], ['零复制多播', '一份数据，多端口独立读取', C.purple], ['完整生命周期', '空闲→分配→出队→回收', C.green]];
  caps.forEach((c, i) => box(s, 0.72 + i * 3.05, 4.0, 2.75, 1.35, `${c[0]}\n${c[1]}`, 'FFFFFF', c[2], { lineWidth: 1.4, text: { fontSize: 15, bold: true, color: C.navy, align: 'center' } }));
}

// 3. Scale
{
  const s = newSlide('默认规模与派生参数', '定位', '32 条调度队列共享 8192 个物理 cell', '默认参数来自 smmu.sv 与 lle.sv。');
  const rows = [
    [{ text: '项目', options: { bold: true, color: C.white, fill: C.navy } }, { text: '默认值', options: { bold: true, color: C.white, fill: C.navy } }, { text: '设计含义', options: { bold: true, color: C.white, fill: C.navy } }],
    ['cell 总数', '8192', '2 MiB / 256 B'], ['cell 地址宽度', '13 bit', '覆盖全部物理 cell'],
    ['端口 × TC', '4 × 8', '32 条常规调度队列'], ['业务队列总数', '33', '32 单播 + 1 多播'],
    ['后继指针链表项', '15 bit', '13 bit 地址 + 包头/包尾'], ['回收 FIFO', '8 项', '接收与落链解耦'], ['多播单槽', '1 帧 / 8 cells', '地址镜像，不复制 payload']
  ];
  addTable(s, rows, 0.7, 1.1, 7.2, 4.85, [2.3, 1.35, 3.55], { fontSize: 13.5, rowH: 0.58 });
  box(s, 8.35, 1.12, 4.25, 4.83, '', 'EDF4F8', C.gray3, { shadow: true });
  addText(s, '派生关系', 8.72, 1.44, 3.45, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center', margin: 0 });
  const formulas = ['业务队列 = 端口 × TC + 1', '单播队列号 = 端口 × TC数 + TC', '占用计数宽度 = 地址宽度 + 1', '引用计数宽度 = ⌈log₂(端口数+1)⌉'];
  formulas.forEach((f, i) => box(s, 8.75, 2.05 + i * 0.76, 3.45, 0.53, f, C.white, i === 1 ? C.teal : C.gray3, { text: { fontSize: 14, color: C.navy, align: 'center', bold: i === 1 } }));
  pill(s, 9.05, 5.28, 0.9, '32+1', C.teal); pill(s, 10.15, 5.28, 0.9, '1R1W', C.orange); pill(s, 11.25, 5.28, 0.9, '1/cycle', C.purple);
}

// 4. Not IOMMU
{
  const s = newSlide('系统边界：不是 IOMMU', '定位', '管理的是 cell 生命周期，不是虚拟地址', '名称容易误导：这里的地址是共享数据 SRAM 的 cell index。');
  box(s, 0.72, 1.22, 5.55, 4.75, '', C.redLite, 'F5A6AA', { shadow: true });
  addText(s, '传统 IOMMU', 1.1, 1.53, 4.8, 0.43, { fontSize: 22, bold: true, color: C.red, align: 'center', margin: 0 });
  const l1 = ['设备', '虚拟地址', 'TLB / 页表', '物理地址'];
  l1.forEach((t, i) => { box(s, 1.05 + i * 1.25, 2.35, 1.0, 0.7, t, C.white, C.red, { text: { fontSize: 12, bold: true, align: 'center', color: C.navy } }); if (i < 3) line(s, 2.05 + i * 1.25, 2.7, 2.25 + i * 1.25, 2.7, C.red, 1.5, true); });
  addText(s, '不做：地址翻译、页表遍历、权限检查', 1.1, 4.25, 4.75, 0.55, { fontSize: 17, bold: true, color: C.red, align: 'center' });
  line(s, 3.1, 3.45, 4.0, 4.05, C.red, 5); line(s, 4.0, 3.45, 3.1, 4.05, C.red, 5);
  box(s, 7.05, 1.22, 5.55, 4.75, '', C.greenLite, '8DD9A6', { shadow: true });
  addText(s, '本设计的 Smart MMU', 7.43, 1.53, 4.8, 0.43, { fontSize: 22, bold: true, color: '15803D', align: 'center', margin: 0 });
  const l2 = ['QM', 'Cell地址管理', '共享数据SRAM'];
  l2.forEach((t, i) => { box(s, 7.52 + i * 1.65, 2.35, 1.35, 0.7, t, C.white, C.green, { text: { fontSize: 13, bold: true, align: 'center', color: C.navy } }); if (i < 2) line(s, 8.87 + i * 1.65, 2.7, 9.12 + i * 1.65, 2.7, C.green, 1.8, true); });
  addText(s, '完成：分配、挂链、取址、回收、流控', 7.5, 4.25, 4.65, 0.55, { fontSize: 17, bold: true, color: '15803D', align: 'center' });
}

// 5. Architecture
{
  const s = newSlide('模块架构：链表引擎是唯一 SRAM 访问者', '定位', '链表权威状态和 SRAM 仲裁集中在一处', '控制器负责命令与结果流水；LLE 集中维护权威状态。');
  box(s, 0.55, 1.0, 2.25, 4.95, '', 'EEF3F8', C.gray3);
  addText(s, 'QM / 调度器', 0.8, 1.25, 1.75, 0.4, { fontSize: 18, bold: true, color: C.navy, align: 'center' });
  [['分配控制', C.teal], ['出队控制', C.orange], ['回收控制', C.green]].forEach((v, i) => box(s, 0.86, 2.0 + i * 0.88, 1.65, 0.58, v[0], C.white, v[1], { text: { fontSize: 14, bold: true, color: C.navy, align: 'center' } }));
  box(s, 3.45, 1.25, 3.2, 3.95, '', 'EAF1F7', C.teal, { lineWidth: 2.4, shadow: true });
  addText(s, '链表引擎 LLE', 3.88, 1.58, 2.35, 0.45, { fontSize: 24, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['队列/空闲链权威状态', '后继指针 SRAM 仲裁', '两级预取与旁路', '多播与老化冲刷'], 3.95, 2.25, 2.2, 2.1, { fontSize: 15 });
  box(s, 7.35, 1.4, 2.25, 1.25, '1R1W\n后继指针 SRAM', 'F0F3F7', C.gray, { text: { fontSize: 17, bold: true, align: 'center', color: C.navy } });
  box(s, 7.35, 3.15, 2.25, 1.25, '占用管理\nPAUSE / PFC', C.tealLite, C.teal, { text: { fontSize: 17, bold: true, align: 'center', color: C.navy } });
  box(s, 10.25, 1.4, 2.25, 1.25, '配置 / 初始化\n统计 / 中断', 'EEF3F8', C.navy2, { text: { fontSize: 17, bold: true, align: 'center', color: C.navy } });
  box(s, 10.25, 3.15, 2.25, 1.25, '老化控制\n计时 / 轮询', C.orangeLite, C.orange, { text: { fontSize: 17, bold: true, align: 'center', color: C.navy } });
  [2.28, 3.16, 4.04].forEach(yy => line(s, 2.52, yy, 3.4, 2.95, C.gray2, 1.6, true));
  line(s, 6.66, 2.18, 7.28, 2.02, C.gray, 2.2, true); line(s, 7.28, 2.28, 6.66, 3.25, C.gray, 1.5, true);
  line(s, 6.66, 3.5, 7.28, 3.75, C.teal, 1.8, true); line(s, 9.6, 3.75, 10.18, 3.75, C.gray2, 1.4, true);
  line(s, 10.18, 2.05, 9.65, 2.05, C.gray2, 1.4, true); line(s, 10.18, 3.75, 9.65, 3.2, C.orange, 1.4, true);
}

// 6. Interfaces
{
  const s = newSlide('顶层接口全景：六类接口', '定位', '接口按请求、策略和反馈三类即可读懂', '配置值在顶层广播到所有队列、端口和 TC。');
  const rows = [
    [{ text: '接口组', options: { bold: true, color: C.white, fill: C.navy } }, { text: '方向', options: { bold: true, color: C.white, fill: C.navy } }, { text: '专业语义', options: { bold: true, color: C.white, fill: C.navy } }, { text: '关键时序', options: { bold: true, color: C.white, fill: C.navy } }],
    ['初始化', 'CSR → MMU', '初始化触发 / 完成', '空闲链建成后开放业务'], ['分配', 'QM ↔ MMU', '分配请求 / 分配结果', 'T0 请求，T1 结果'],
    ['出队', 'QM ↔ MMU', '出队请求 / 队头返回', 'T0 请求，T1 结果'], ['回收', 'QM ↔ MMU', '回收请求 / 接收确认', '确认不等于落链完成'],
    ['策略', 'CSR / MAC / CPU', '配置 / PAUSE / PFC / 统计', '同一时钟域采样一拍'], ['调度反馈', 'MMU → QM', 'cell 判空 / 完整包判空 / 最大占用', '服务不同调度语义']
  ];
  addTable(s, rows, 0.68, 1.05, 12.0, 5.35, [1.5, 2.0, 4.0, 4.5], { fontSize: 14, rowH: 0.73 });
}

// 7. Why linked list
{
  const s = newSlide('为什么选择链表 + 共享池', '数据结构', '链表换来高利用率和突发吸收能力', '固定分区简单但浪费；共享链表按需伸缩。');
  box(s, 0.65, 1.15, 5.55, 4.8, '', C.redLite, 'F5A6AA', { shadow: true });
  addText(s, '固定分区', 0.95, 1.45, 4.95, 0.42, { fontSize: 22, bold: true, color: C.red, align: 'center' });
  const used = [0.92, 0.18, 0.27];
  used.forEach((u, i) => { box(s, 1.0, 2.15 + i * 0.82, 4.45, 0.48, '', C.white, C.gray3, { shape: S.rect }); s.addShape(S.rect, { x: 1.0, y: 2.15 + i * 0.82, w: 4.45 * u, h: 0.48, fill: { color: i === 0 ? C.red : C.gray2 }, line: { color: i === 0 ? C.red : C.gray2 } }); addText(s, `队列 ${i}`, 5.55, 2.16 + i * 0.82, 0.45, 0.43, { fontSize: 11, color: C.gray, margin: 0 }); });
  addText(s, '热点队列溢出，其他分区仍大量空闲', 1.0, 4.85, 4.75, 0.42, { fontSize: 16, bold: true, color: C.red, align: 'center' });
  box(s, 7.1, 1.15, 5.55, 4.8, '', C.greenLite, '8DD9A6', { shadow: true });
  addText(s, '链表 + 统一共享池', 7.4, 1.45, 4.95, 0.42, { fontSize: 22, bold: true, color: '15803D', align: 'center' });
  const coords = [[7.7,2.25],[8.65,3.2],[9.45,2.25],[10.4,3.2],[11.25,2.25]];
  coords.forEach((p,i)=>circle(s,p[0],p[1],0.52,String([2,17,5,29,8][i]),[C.teal,C.orange,C.teal,C.purple,C.green][i],{fontSize:12}));
  [[0,2],[2,4]].forEach(pair=>line(s,coords[pair[0]][0]+0.52,coords[pair[0]][1]+0.26,coords[pair[1]][0]-0.04,coords[pair[1]][1]+0.26,C.teal,1.8,true));
  line(s, coords[1][0]+0.52, coords[1][1]+0.26, coords[3][0]-0.04, coords[3][1]+0.26, C.orange, 1.8, true);
  addText(s, '物理离散，逻辑连续；回收后重新共享', 7.65, 4.85, 4.45, 0.42, { fontSize: 16, bold: true, color: '15803D', align: 'center' });
}

// 8. Data structure
{
  const s = newSlide('链表权威状态与后继指针项', '数据结构', '队头与两级前瞻隐藏同步读延迟', '当前队尾属性保存在寄存器；成为旧队尾时才随地址写 SRAM。');
  addText(s, '15 bit 后继指针链表项', 0.75, 1.05, 4.2, 0.36, { fontSize: 18, bold: true, color: C.navy, margin: 0 });
  box(s, 0.75, 1.55, 6.2, 0.82, '', C.white, C.navy, { shape: S.rect });
  s.addShape(S.rect, { x: 0.75, y: 1.55, w: 5.35, h: 0.82, fill: { color: C.tealLite }, line: { color: C.teal } });
  addText(s, '后继地址 [12:0]', 0.75, 1.55, 5.35, 0.82, { fontSize: 19, bold: true, color: C.navy, align: 'center', margin: 0 });
  s.addShape(S.rect, { x: 6.1, y: 1.55, w: 0.425, h: 0.82, fill: { color: C.orangeLite }, line: { color: C.orange } });
  s.addShape(S.rect, { x: 6.525, y: 1.55, w: 0.425, h: 0.82, fill: { color: C.purpleLite }, line: { color: C.purple } });
  addText(s, '头', 6.1, 1.55, 0.425, 0.82, { fontSize: 13, bold: true, color: C.orange, align: 'center', margin: 0 });
  addText(s, '尾', 6.525, 1.55, 0.425, 0.82, { fontSize: 13, bold: true, color: C.purple, align: 'center', margin: 0 });
  addText(s, '业务链两级前瞻', 0.75, 2.9, 4.2, 0.36, { fontSize: 18, bold: true, color: C.navy, margin: 0 });
  chain(s, 0.95, 3.58, ['A','B','C','D'], C.orange, { d: 0.58, gap: 0.88 });
  ['当前队头','一级后继','二级后继','当前队尾'].forEach((t,i)=>addText(s,t,0.68+i*1.46,4.26,1.15,0.38,{fontSize:12,bold:true,color:i===3?C.purple:C.navy,align:'center',margin:0}));
  box(s, 7.6, 1.15, 4.85, 4.65, '', 'EEF3F8', C.gray3, { shadow: true });
  addText(s, '每条业务链', 8.0, 1.47, 4.05, 0.4, { fontSize: 21, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['队头 / 队尾 / cell 数量', '一级后继 / 二级后继', '队头与队尾的包边界属性'], 8.05, 2.05, 3.9, 1.35, { fontSize: 16 });
  addText(s, '空闲链', 8.0, 3.55, 4.05, 0.4, { fontSize: 21, bold: true, color: C.green, align: 'center' });
  addBullets(s, ['空闲链头 + 两级前瞻', '空闲链尾 + 空闲数量', '分配从头取，回收向尾追加'], 8.05, 4.05, 3.9, 1.35, { fontSize: 16 });
}

// 9. Initialization
{
  const s = newSlide('上电初始化：把所有 cell 串成空闲链', '数据结构', '先建空闲链，再开放所有业务请求', '初始化核心约需 8192 个 SRAM 写周期，外加状态机收尾。');
  stateNode(s, 0.8, 1.4, 1.7, '空闲', C.gray, '等待初始化');
  stateNode(s, 3.25, 1.4, 2.05, '连续建链', C.teal, '每周期写一项');
  stateNode(s, 6.15, 1.4, 1.85, '完成返回', C.green, '完成脉冲');
  line(s, 2.5, 1.76, 3.18, 1.76, C.teal, 2, true); line(s, 5.3, 1.76, 6.08, 1.76, C.green, 2, true); line(s, 8.0, 1.76, 8.65, 1.76, C.gray, 1.5, true);
  addText(s, '收到初始化请求', 2.48, 1.19, 0.95, 0.28, { fontSize: 10, color: C.gray, align: 'center', margin: 0 });
  box(s, 8.7, 1.15, 3.65, 1.25, '初始化未完成\n分配与出队关闭', C.redLite, C.red, { text: { fontSize: 18, bold: true, color: C.red, align: 'center' } });
  addText(s, '完成后的空闲链', 0.8, 3.0, 3.0, 0.38, { fontSize: 19, bold: true, color: C.navy, margin: 0 });
  chain(s, 1.05, 3.75, ['0','1','2','…','8191'], C.green, { d: 0.58, gap: 0.62 });
  line(s, 6.6, 4.03, 6.95, 4.03, C.green, 1.6, true);
  line(s, 6.95, 4.03, 6.95, 4.72, C.green, 1.2); line(s, 6.95, 4.72, 1.0, 4.72, C.green, 1.2); line(s, 1.0, 4.72, 1.0, 4.38, C.green, 1.2, true);
  box(s, 8.0, 3.1, 4.2, 2.4, '', C.greenLite, '8DD9A6');
  addBullets(s, ['空闲链头 = 0', '一级前瞻 = 1，二级前瞻 = 2', '空闲链尾 = 8191', '空闲数量 = 8192', '所有业务队列占用 = 0'], 8.45, 3.45, 3.35, 1.75, { fontSize: 16, space: 5 });
}

// 10. Enqueue decision
{
  const s = newSlide('入队判决：先保证整包可落地', '数据路径', 'SOF 先预判，失败后一直丢到 EOF', '当前 RTL 没有独立共享区总上限。');
  const steps = [['初始化与引擎就绪', C.navy2], ['物理空闲量', C.green], ['静态保障区', C.teal], ['最大占用', C.orange], ['多播单槽', C.purple]];
  steps.forEach((st, i) => { const xx = 0.65 + i * 2.35; box(s, xx, 1.15, 1.95, 0.7, st[0], C.white, st[1], { text: { fontSize: 13, bold: true, color: C.navy, align: 'center' } }); if (i < 4) line(s, xx + 1.95, 1.5, xx + 2.25, 1.5, C.gray2, 1.4, true); });
  addText(s, '任一失败', 5.25, 2.1, 1.4, 0.32, { fontSize: 13, bold: true, color: C.red, align: 'center' });
  line(s, 5.95, 1.87, 5.95, 2.5, C.red, 2, true);
  box(s, 4.55, 2.55, 2.8, 0.68, '丢弃指示', C.redLite, C.red, { text: { fontSize: 20, bold: true, color: C.red, align: 'center' } });
  addText(s, '整帧丢弃状态机', 0.72, 3.4, 3.0, 0.38, { fontSize: 18, bold: true, color: C.navy, margin: 0 });
  stateNode(s, 0.9, 4.08, 2.15, '正常接收', C.teal, '逐 cell 判决');
  stateNode(s, 4.5, 4.08, 2.15, '整帧丢弃', C.red, '持续到 EOF');
  line(s, 3.05, 4.38, 4.43, 4.38, C.red, 2, true); addText(s, '本 cell 丢弃且未到帧尾', 3.1, 3.96, 1.3, 0.3, { fontSize: 10, color: C.red, align: 'center', margin: 0 });
  line(s, 4.5, 4.72, 3.05, 4.72, C.teal, 1.8, true); addText(s, '收到 EOF', 3.25, 4.8, 0.9, 0.28, { fontSize: 10, color: C.teal, align: 'center', margin: 0 });
  box(s, 8.0, 3.55, 4.25, 2.15, '', 'FFF8E7', C.orange);
  addText(s, 'SOF 整包容量预测', 8.35, 3.86, 3.55, 0.38, { fontSize: 19, bold: true, color: C.orange, align: 'center' });
  addBullets(s, ['检查整包 cell 数', '同时检查空闲 / 队列 / 端口 / 全局容量', '避免形成半包残链'], 8.5, 4.35, 3.2, 1.05, { fontSize: 15 });
}

// 11. Linking
{
  const s = newSlide('挂链：空队列与非空队列只差一次旧队尾写入', '数据路径', '分配取空闲链头，非空队列只写旧队尾', '新队尾的链表项在未来成为旧队尾时才写。');
  box(s, 0.7, 1.1, 5.75, 4.95, '', C.tealLite, C.teal, { shadow: true });
  addText(s, '空队列：第一次挂链', 1.05, 1.38, 5.05, 0.38, { fontSize: 20, bold: true, color: C.teal, align: 'center' });
  addText(s, '操作前', 1.0, 2.0, 0.8, 0.3, { fontSize: 12, bold: true, color: C.gray });
  box(s, 1.8, 1.93, 1.25, 0.5, '队列5：空', C.white, C.gray3, { text: { fontSize: 12, align: 'center' } }); chain(s, 3.45, 1.93, ['A','B','C'], C.green, { d: 0.5, gap: 0.38 });
  line(s, 3.15, 2.75, 3.15, 3.2, C.teal, 2, true);
  addText(s, '操作后', 1.0, 3.35, 0.8, 0.3, { fontSize: 12, bold: true, color: C.gray });
  box(s, 1.8, 3.28, 1.25, 0.5, '队列5：A', C.white, C.teal, { text: { fontSize: 12, bold: true, align: 'center' } }); chain(s, 3.45, 3.28, ['B','C'], C.green, { d: 0.5, gap: 0.38 });
  addText(s, '无需写旧队尾', 1.35, 4.55, 4.4, 0.42, { fontSize: 18, bold: true, color: C.teal, align: 'center' });
  box(s, 6.88, 1.1, 5.75, 4.95, '', C.orangeLite, C.orange, { shadow: true });
  addText(s, '非空队列：尾插', 7.2, 1.38, 5.05, 0.38, { fontSize: 20, bold: true, color: C.orange, align: 'center' });
  addText(s, '操作前', 7.18, 2.0, 0.8, 0.3, { fontSize: 12, bold: true, color: C.gray }); chain(s, 8.05, 1.93, ['X','Y'], C.orange, { d: 0.5, gap: 0.38 }); chain(s, 10.35, 1.93, ['A','B'], C.green, { d: 0.5, gap: 0.38 });
  line(s, 9.42, 2.75, 9.42, 3.2, C.orange, 2, true);
  addText(s, '操作后', 7.18, 3.35, 0.8, 0.3, { fontSize: 12, bold: true, color: C.gray }); chain(s, 8.05, 3.28, ['X','Y','A'], C.orange, { d: 0.5, gap: 0.38 }); chain(s, 11.25, 3.28, ['B'], C.green, { d: 0.5, gap: 0.38 });
  box(s, 7.65, 4.35, 4.2, 0.78, '写旧队尾 Y：后继 = A\n队尾前进到 A', C.white, C.orange, { text: { fontSize: 15, bold: true, color: C.navy, align: 'center' } });
}

// 12. Enqueue timing
{
  const s = newSlide('分配 T0/T1 与连续分配旁路', '数据路径', '返回原空闲链头，后台同时补充前瞻', '分配结果有效并不等于一定成功；丢弃时地址字段无意义。');
  addText(s, '示意时序', 0.72, 1.02, 2.0, 0.32, { fontSize: 17, bold: true, color: C.navy, margin: 0 });
  digitalWave(s, [
    { name: '分配请求', values: [0,1,1,0,0], color: C.teal }, { name: '分配就绪', values: [1,1,1,1,1], color: C.navy2 },
    { name: '实际分配', values: [0,1,1,0,0], color: C.teal }, { name: '空闲链头', values: ['A','A','B','C','C'], color: C.green },
    { name: 'SRAM前瞻返回', values: ['—','—','前瞻','前瞻','前瞻'], color: C.gray }, { name: '分配结果有效', values: [0,0,1,1,0], color: C.orange },
    { name: '分配地址', values: ['—','—','A','B','—'], color: C.orange }
  ], 0.72, 1.45, 11.95, 0.56);
  ['T0','T1','T2','T3','T4'].forEach((t,i)=>pill(s,2.39+i*2.06,5.62,0.55,t,i===1?C.orange:C.navy2));
  box(s, 0.9, 5.62, 1.2, 0.36, '周期', C.white, C.gray3, { text: { fontSize: 11, color: C.gray, align: 'center', margin: 0 } });
}

// 13. Dequeue
{
  const s = newSlide('出队：两级预取和同队列旁路', '数据路径', '队长≥3 才读；同队列连续出队走旁路', '外部 T1 返回不等待 SRAM；SRAM 读在后台维持前瞻。');
  box(s, 0.72, 1.02, 3.55, 1.15, '实际出队 = 请求有效\nAND 初始化完成\nAND 队列非空 AND 无背压', C.orangeLite, C.orange, { text: { fontSize: 17, bold: true, color: C.navy, align: 'center' } });
  [['队长=1','出队后为空\n不读 SRAM'],['队长=2','一级后继已预取\n不读 SRAM'],['队长≥3','读取后继项\n补充二级前瞻']].forEach((v,i)=>box(s,4.65+i*2.55,1.02,2.25,1.15,v[0]+'\n'+v[1],C.white,i===2?C.orange:C.gray3,{text:{fontSize:14,bold:true,color:C.navy,align:'center'}}));
  digitalWave(s, [
    { name: '出队请求', values: [0,1,1,1,0,0], color: C.orange }, { name: '实际出队', values: [0,1,1,1,0,0], color: C.orange },
    { name: '当前队头', values: ['C0','C0','C1','C2','—','—'], color: C.orange }, { name: 'SRAM读使能', values: [0,1,1,1,0,0], color: C.gray },
    { name: 'SRAM前瞻返回', values: ['—','—','C3','C4','C5','—'], color: C.gray }, { name: '同队连续旁路', values: [0,0,1,1,0,0], color: C.teal },
    { name: '队头返回有效', values: [0,0,1,1,1,0], color: C.orange }, { name: '队头地址', values: ['—','—','C0','C1','C2','—'], color: C.orange }
  ], 0.72, 2.55, 11.95, 0.45);
}

// 14. metadata
{
  const s = newSlide('T1 出队元数据：当前边界与下一包尾前瞻', '数据路径', '当前包尾与下一包尾前瞻各司其职', '当前实现存在下一包尾前瞻；源码端口名只在答疑时说明。');
  box(s, 0.75, 1.15, 5.05, 4.65, '', 'EEF3F8', C.gray3, { shadow: true });
  addText(s, 'T1 返回内容', 1.15, 1.52, 4.25, 0.42, { fontSize: 22, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['队头返回有效', '队头 cell 地址', '当前 cell 是否为包头', '当前 cell 是否为包尾', '下一连续 cell 是否为包尾'], 1.25, 2.15, 4.0, 2.55, { fontSize: 19, space: 10 });
  addText(s, '连续出队示例', 6.55, 1.35, 5.2, 0.42, { fontSize: 22, bold: true, color: C.navy, align: 'center' });
  circle(s, 7.25, 2.42, 1.05, 'C1', C.orange, { fontSize: 20 });
  circle(s, 10.25, 2.42, 1.05, 'C2', C.purple, { fontSize: 20 });
  line(s, 8.3, 2.95, 10.15, 2.95, C.gray, 2.4, true);
  pill(s, 7.02, 3.75, 1.5, '当前包尾：否', C.orange);
  pill(s, 9.35, 3.75, 2.0, '下一包尾前瞻：是', C.purple);
  box(s, 6.75, 4.55, 4.95, 0.78, '当前已是包尾时\n下一包尾前瞻强制无效', C.redLite, C.red, { text: { fontSize: 16, bold: true, color: C.red, align: 'center' } });
}

// 15. recycle
{
  const s = newSlide('还链：接收确认与空闲链尾写入是两阶段', '数据路径', '接收确认不等于 SRAM 落链完成', '释放计数在 FIFO 压入时更新，空闲链尾在 FIFO 弹出时更新。');
  box(s, 0.75, 1.05, 5.55, 1.25, '阶段 1｜接收\n回收请求 → 地址/引用判定 → 压入回收 FIFO', C.greenLite, C.green, { text: { fontSize: 18, bold: true, color: C.navy, align: 'center' } });
  box(s, 7.0, 1.05, 5.55, 1.25, '阶段 2｜落链\nFIFO 队头 → 写旧空闲链尾 → 空闲链尾前进', C.white, C.green, { text: { fontSize: 18, bold: true, color: C.navy, align: 'center' } });
  line(s, 6.3, 1.68, 6.92, 1.68, C.green, 2.4, true);
  digitalWave(s, [
    { name: '回收请求', values: [0,1,0,0,0], color: C.green }, { name: '接收确认', values: [0,1,0,0,0], color: C.green },
    { name: 'FIFO压入', values: [0,1,0,0,0], color: C.green }, { name: '空闲数量增加', values: [0,0,1,0,0], color: C.green },
    { name: 'FIFO非空', values: [0,0,1,0,0], color: C.gray }, { name: 'FIFO弹出', values: [0,0,1,0,0], color: C.green },
    { name: 'SRAM写使能', values: [0,0,1,0,0], color: C.gray }, { name: '空闲链尾', values: ['旧','旧','旧','回收地址','回收地址'], color: C.green }
  ], 0.72, 2.72, 11.95, 0.42);
}

// 16. multicast model
{
  const s = newSlide('多播：单槽、零复制、每端口私有读索引', '数据路径', '一份物理链，多端口以私有索引独立读取', '多播必须等 EOF 锁定整帧 cell 数后才可见，是 store-and-forward。');
  addText(s, '共享 cell 地址镜像', 3.9, 1.02, 5.2, 0.38, { fontSize: 20, bold: true, color: C.purple, align: 'center' });
  chain(s, 4.15, 2.35, ['A','B','C'], C.purple, { d: 0.78, gap: 1.12, fontSize: 18 });
  [['端口 0',5.95,1.55],['端口 1',4.05,3.45],['端口 3',8.0,3.45]].forEach((p,i)=>{pill(s,p[1],p[2],1.15,p[0],[C.orange,C.teal,C.green][i]); line(s,p[1]+0.58,p[2]+(i===0?0.35:0),p[1]+0.58,p[2]+(i===0?0.75:-0.35),[C.orange,C.teal,C.green][i],1.8,true);});
  box(s, 0.65, 1.25, 2.75, 4.55, '', 'F0EAFE', C.purple);
  addText(s, '零复制语义', 1.0, 1.58, 2.05, 0.38, { fontSize: 20, bold: true, color: C.purple, align: 'center' });
  addBullets(s, ['payload 只存一份', '地址镜像只作读加速', '不推进多播物理队头', '不占后继指针 SRAM 读口'], 0.98, 2.2, 2.1, 2.45, { fontSize: 15 });
  box(s, 9.85, 1.25, 2.75, 4.55, '', C.white, C.purple);
  addText(s, '引用余量', 10.2, 1.58, 2.05, 0.38, { fontSize: 20, bold: true, color: C.purple, align: 'center' });
  [['A','1'],['B','2'],['C','1']].forEach((v,i)=>{circle(s,10.18,2.35+i*0.82,0.48,v[0],C.purple,{fontSize:12}); addText(s,`剩余 ${v[1]} 次归还`,10.82,2.36+i*0.82,1.35,0.43,{fontSize:14,bold:true,color:C.navy,margin:0});});
  pill(s, 10.15, 5.05, 2.15, '单槽上限：8 cells', C.navy2);
}

// 17. multicast transaction
{
  const s = newSlide('多播完整事务：两端口、三 cell', '数据路径', '最后一个引用归还时，cell 才真正回空闲链', '引用计数只按地址和次数递减，不识别归还来源端口。');
  const lanes = ['多播分配','端口0读取','端口1读取','引用计数','回收 FIFO'];
  lanes.forEach((l,i)=>{addText(s,l,0.65,1.25+i*0.92,1.45,0.35,{fontSize:13,bold:true,color:C.navy,align:'right',margin:0}); line(s,2.3,1.43+i*0.92,12.45,1.43+i*0.92,'D8E0EA',1);});
  const xs=[2.65,3.85,5.05,6.25,7.45,8.65,9.85,11.05];
  ['A','B','C'].forEach((a,i)=>circle(s,xs[i],1.18,0.5,a,C.purple,{fontSize:12}));
  ['A','B','C'].forEach((a,i)=>circle(s,xs[2+i],2.10,0.5,a,C.orange,{fontSize:12}));
  ['A','B','C'].forEach((a,i)=>circle(s,xs[4+i],3.02,0.5,a,C.teal,{fontSize:12}));
  [['A 2→1',xs[4]],['A 1→0',xs[6]],['B/C →0',xs[7]]].forEach(v=>pill(s,v[1]-0.18,3.98,1.15,v[0],C.purple));
  [['A',xs[6]],['B/C',xs[7]]].forEach(v=>pill(s,v[1]-0.1,4.90,0.9,v[0],C.green));
  addText(s, '时间 →', 11.35, 5.85, 1.0, 0.28, { fontSize: 12, color: C.gray, align: 'right', margin: 0 });
}

// 18. arbitration
{
  const s = newSlide('仲裁与并发：不是简单的全串行优先级', '策略', '是否能并发取决于当拍占用读口还是写口', '长链出队与回收落链被当前 RTL 保守禁止同拍。');
  box(s, 0.65, 1.05, 4.2, 4.95, '', 'EEF3F8', C.gray3);
  addText(s, '授权语义', 1.0, 1.35, 3.5, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['出队：无包级入队锁', '分配：出队不需要 SRAM 读口', '回收落链：FIFO 非空且写口空闲', '老化读取：正常业务不占读口'], 1.0, 2.05, 3.55, 2.15, { fontSize: 16, space: 10 });
  box(s, 1.05, 4.65, 3.4, 0.72, '1R1W：读口与写口可并行\n同一端口内仍需仲裁', C.white, C.navy2, { text: { fontSize: 14, bold: true, color: C.navy, align: 'center' } });
  const rows = [
    [{ text: '同拍组合', options: { bold: true, color: C.white, fill: C.navy } }, { text: '允许', options: { bold: true, color: C.white, fill: C.navy } }, { text: '原因', options: { bold: true, color: C.white, fill: C.navy } }],
    ['长链出队 + 分配', '×', '竞争唯一读口'], ['短链出队 + 分配', '✓', '短链不读 SRAM'], ['多播读取 + 分配', '✓', '多播走寄存器镜像'],
    ['长链出队 + 回收落链', '×', '当前 RTL 保守禁止'], ['短链/多播 + 回收落链', '✓', '回收只用写口'], ['分配 + 回收落链', '×', '分配优先占写口'], ['回收落链 + 老化读取', '✓', '分别占写/读口']
  ];
  addTable(s, rows, 5.15, 1.05, 7.48, 5.1, [3.2, 0.85, 3.43], { fontSize: 13, rowH: 0.61 });
}

// 19. occupancy
{
  const s = newSlide('占用管理：同一份计数驱动丢弃与流控', '策略', '丢弃与流控共享计数，但使用不同阈值', '双池是计数抽象，当前 RTL 未设置独立共享区总上限。');
  box(s, 0.65, 1.1, 2.8, 4.95, '', 'EEF3F8', C.gray3);
  addText(s, '计数源', 1.0, 1.43, 2.1, 0.38, { fontSize: 21, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['队列占用', '静态保障占用', '端口占用', '全局占用', '空闲数量'], 1.02, 2.15, 2.05, 2.35, { fontSize: 17 });
  box(s, 4.05, 1.15, 3.65, 2.1, '', C.redLite, C.red, { shadow: true });
  addText(s, '路径 A｜是否接收', 4.4, 1.48, 2.95, 0.36, { fontSize: 19, bold: true, color: C.red, align: 'center' });
  addBullets(s, ['先使用静态保障区', '超出后检查队列/端口/全局最大占用', 'SOF 做整包容量预测'], 4.4, 2.0, 2.9, 0.95, { fontSize: 14 });
  box(s, 4.05, 3.72, 3.65, 2.1, '', C.tealLite, C.teal, { shadow: true });
  addText(s, '路径 B｜是否反压', 4.4, 4.05, 2.95, 0.36, { fontSize: 19, bold: true, color: C.teal, align: 'center' });
  addBullets(s, ['PAUSE：端口 + 全局水位', 'PFC：端口 × TC 水位', 'XOFF 置位、XON 清除'], 4.4, 4.55, 2.9, 0.95, { fontSize: 14 });
  box(s, 8.4, 1.15, 3.75, 4.67, '', C.white, C.gray3, { shadow: true });
  addText(s, '队列水位模型', 8.75, 1.48, 3.05, 0.36, { fontSize: 19, bold: true, color: C.navy, align: 'center' });
  s.addShape(S.rect, { x: 9.35, y: 2.02, w: 1.95, h: 3.1, fill: { color: 'E9F1F7' }, line: { color: C.navy2, width: 1.5 } });
  s.addShape(S.rect, { x: 9.35, y: 3.65, w: 1.95, h: 1.47, fill: { color: C.tealLite }, line: { color: C.teal, width: 1.1 } });
  line(s, 9.15, 2.35, 11.55, 2.35, C.red, 2); addText(s, '最大占用', 11.58, 2.18, 0.5, 0.35, { fontSize: 11, bold: true, color: C.red, margin: 0 });
  line(s, 9.15, 3.65, 11.55, 3.65, C.teal, 2); addText(s, '保障额度', 11.58, 3.48, 0.5, 0.35, { fontSize: 11, bold: true, color: C.teal, margin: 0 });
  addText(s, '动态共享区', 9.52, 2.7, 1.6, 0.35, { fontSize: 13, bold: true, color: C.navy, align: 'center' });
  addText(s, '静态保障区', 9.52, 4.15, 1.6, 0.35, { fontSize: 13, bold: true, color: C.teal, align: 'center' });
}

// 20. hysteresis
{
  const s = newSlide('PAUSE / PFC 迟滞与统计告警', '策略', '双阈值把流控从临界点抖动中解耦', 'PAUSE 置位采用 OR，清除采用 AND；PFC 按端口×TC 独立判断。');
  box(s, 0.65, 1.0, 4.15, 5.1, '', 'EEF3F8', C.gray3);
  addText(s, '端口级 PAUSE', 1.0, 1.35, 3.45, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center' });
  addBullets(s, ['置位：端口达到 XOFF 或全局达到 XOFF', '清除：端口低于 XON 且全局低于 XON', '中间区域保持原状态'], 1.0, 2.05, 3.4, 1.55, { fontSize: 16 });
  addText(s, '逐端口逐 TC PFC', 1.0, 4.0, 3.45, 0.38, { fontSize: 20, bold: true, color: C.teal, align: 'center' });
  addText(s, '每个 TC 独立使用 XOFF / XON 双阈值', 1.05, 4.62, 3.35, 0.65, { fontSize: 16, bold: true, color: C.teal, align: 'center' });
  box(s, 5.3, 1.0, 7.3, 5.1, '', C.white, C.gray3, { shadow: true });
  addText(s, '水位与 PAUSE 请求示意', 5.68, 1.28, 6.55, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center' });
  const x0=5.85,y0=4.25,ww=5.75,hh=2.15;
  line(s,x0,y0,x0+ww,y0,C.gray,1.4,true); line(s,x0,y0,x0,y0-hh,C.gray,1.4,true);
  const yOff=y0-1.65,yOn=y0-0.75; line(s,x0,yOff,x0+ww,yOff,C.red,1.4,false,'dash'); line(s,x0,yOn,x0+ww,yOn,C.green,1.4,false,'dash');
  addText(s,'XOFF',x0+ww+0.05,yOff-0.15,0.5,0.3,{fontSize:10,bold:true,color:C.red,margin:0}); addText(s,'XON',x0+ww+0.05,yOn-0.15,0.5,0.3,{fontSize:10,bold:true,color:C.green,margin:0});
  const pts=[[0,0.35],[0.75,0.65],[1.4,1.05],[2.1,1.8],[2.8,1.45],[3.5,1.15],[4.2,0.55],[5.1,0.9]];
  for(let i=0;i<pts.length-1;i++) line(s,x0+pts[i][0],y0-pts[i][1],x0+pts[i+1][0],y0-pts[i+1][1],C.orange,2.6);
  addText(s,'PAUSE 请求',5.85,4.62,1.1,0.28,{fontSize:11,bold:true,color:C.navy,margin:0});
  line(s,7.92,4.93,9.98,4.93,C.red,2); line(s,9.98,4.93,9.98,5.28,C.red,2); line(s,9.98,5.28,11.25,5.28,C.gray,2); line(s,7.0,5.28,7.92,5.28,C.gray,2); line(s,7.92,5.28,7.92,4.93,C.red,2);
}

// 21. aging
{
  const s = newSlide('老化：计时、轮询选择与逐 cell 冲刷', '策略', '低优先级逐 cell 冲刷，必须防止误清活动多播', '活动多播的端口服务不能直接喂狗多播物理队列。');
  addText(s, '老化轮询控制', 0.72, 1.0, 5.25, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center' });
  stateNode(s, 0.85, 1.72, 1.45, '等待触发', C.gray); stateNode(s, 2.95, 1.72, 1.45, '发起冲刷', C.orange); stateNode(s, 5.05, 1.72, 1.45, '等待完成', C.teal);
  line(s,2.3,1.98,2.88,1.98,C.orange,1.8,true); line(s,4.4,1.98,4.98,1.98,C.teal,1.8,true); line(s,5.75,2.26,1.6,2.85,C.gray2,1.2,true);
  addText(s, '触发条件：连续未被服务达到超时，或软件强制', 0.95, 3.12, 5.35, 0.5, { fontSize: 16, bold: true, color: C.navy, align: 'center' });
  addText(s, '链表引擎逐 cell 冲刷', 6.85, 1.0, 5.65, 0.38, { fontSize: 20, bold: true, color: C.navy, align: 'center' });
  const st=[['空闲',C.gray],['读取后继',C.orange],['压入回收 FIFO',C.green],['完成',C.teal]];
  st.forEach((v,i)=>{stateNode(s,6.88+i*1.45,1.72,1.18,v[0],v[1]); if(i<3) line(s,8.06+i*1.45,1.98,8.28+i*1.45,1.98,C.gray2,1.5,true);});
  line(s,10.35,2.32,8.18,3.0,C.gray2,1.2,true); addText(s,'还有 cell',8.92,2.72,1.15,0.28,{fontSize:10,color:C.gray,align:'center',margin:0});
  box(s, 0.85, 4.05, 5.55, 1.35, '计时清零条件\n未使能 / 未初始化 / 队列空 / 本队列被服务 / 正在冲刷', C.white, C.gray3, { text: { fontSize: 15, bold: true, color: C.navy, align: 'center' } });
  box(s, 6.88, 4.05, 5.25, 1.35, '冲刷等待来源\n正常分配、长链出队、回收 FIFO 满', C.orangeLite, C.orange, { text: { fontSize: 15, bold: true, color: C.navy, align: 'center' } });
  box(s, 3.65, 5.75, 6.0, 0.5, '风险：多播物理队列可能在仍被服务时超时', C.redLite, C.red, { text: { fontSize: 16, bold: true, color: C.red, align: 'center' } });
}

// 22. lifecycle
{
  const s = newSlide('三 cell 单播：把完整生命周期串起来', '验证', '出队与释放解耦，中间存在外部持有阶段', '地址生命周期验证必须包含 QM/EPS 外部持有集合。');
  const stages=[['空闲',C.green],['已入队',C.teal],['已出队',C.orange],['外部持有',C.purple],['回收/重新空闲',C.green]];
  stages.forEach((st,i)=>{box(s,0.55+i*2.55,1.1,2.05,0.65,st[0],C.white,st[1],{text:{fontSize:16,bold:true,color:C.navy,align:'center'}}); if(i<4) line(s,2.6+i*2.55,1.43,3.0+i*2.55,1.43,C.gray2,1.7,true);});
  const rows=[['A','包头'],['B','中间'],['C','包尾']];
  rows.forEach((r,ri)=>{addText(s,r[0],0.55,2.35+ri*0.95,0.5,0.48,{fontSize:16,bold:true,color:C.navy,align:'center'}); for(let i=0;i<5;i++){const active=i===0?C.green:i===1?C.teal:i===2?C.orange:i===3?C.purple:C.green; circle(s,1.1+i*2.55,2.3+ri*0.95,0.55,i===1?r[0]:'',active,{fontSize:12}); if(i<4) line(s,1.65+i*2.55,2.58+ri*0.95,3.45+i*2.55,2.58+ri*0.95,'CBD5E1',1.2,true);}});
  box(s, 1.0, 5.4, 3.4, 0.7, '分配 A/B/C\n形成 A → B → C 业务链', C.tealLite, C.teal, { text: { fontSize: 14, bold: true, color: C.navy, align: 'center' } });
  box(s, 4.95, 5.4, 3.4, 0.7, '逐 cell 出队\n仅从业务链视图摘除', C.orangeLite, C.orange, { text: { fontSize: 14, bold: true, color: C.navy, align: 'center' } });
  box(s, 8.9, 5.4, 3.4, 0.7, '回收 A/B/C\n依次追加到空闲链尾', C.greenLite, C.green, { text: { fontSize: 14, bold: true, color: C.navy, align: 'center' } });
}

// 23. risks
{
  const s = newSlide('实现约束与高风险边界', '验证', '风险集中在并发互斥、空池边界和多播生命周期', '区分系统协议保证与 RTL 自身防护；协议保证应转化为 assertion。');
  const rows=[
    [{text:'优先级',options:{bold:true,color:C.white,fill:C.navy}},{text:'风险条件',options:{bold:true,color:C.white,fill:C.navy}},{text:'可能后果',options:{bold:true,color:C.white,fill:C.navy}}],
    ['P0','老化冲刷与同队列正常业务无硬互斥','多个时序分支更新同一队列状态'],
    ['P0','多播物理队列没有端口服务喂狗','活动多播被误冲刷'],
    ['P0','多播引用只计次数，不识别来源端口','重复归还可提前释放'],
    ['P1','多播后续 cell 的目的位图必须一致','不同 cell 引用初值不一致'],
    ['P1','空闲池从 0 恢复时未显式重建前瞻','空池边界链表风险'],
    ['P1','入队包永远不来 EOF','包级入队锁不释放，出队暂停']
  ];
  addTable(s,rows,0.65,1.05,12.0,4.95,[1.0,5.5,5.5],{fontSize:14,rowH:0.69});
  pill(s,1.15,6.15,2.3,'协议保证',C.navy2); pill(s,5.45,6.15,2.3,'RTL 防护',C.teal); pill(s,9.75,6.15,2.3,'验证覆盖',C.orange);
}

// 24. verification
{
  const s = newSlide('验证计划：用不变量证明地址不会丢、不会重用', '验证', '以地址生命周期模型为主，局部计数断言为辅', '不要只用链表引擎空闲数量加所有队列链长做全局守恒。');
  const st=[['空闲',C.green],['已入队',C.teal],['已出队/外部持有',C.orange],['已回收/重新空闲',C.green]];
  st.forEach((v,i)=>{box(s,0.65+i*3.05,1.05,2.5,0.72,v[0],C.white,v[1],{text:{fontSize:15,bold:true,color:C.navy,align:'center'}}); if(i<3) line(s,3.15+i*3.05,1.41,3.55+i*3.05,1.41,C.gray2,1.8,true);});
  box(s,0.65,2.25,5.75,3.75,'',C.white,C.teal,{shadow:true}); addText(s,'关键断言',1.05,2.55,4.95,0.4,{fontSize:21,bold:true,color:C.teal,align:'center'});
  addBullets(s,['空闲数量 + 全局占用 = cell 总数','已分配地址在回收前不得再次分配','连续同队列出队必须匹配后继链','整帧丢弃期间不得实际分配','初始化完成前不得分配或出队','多播引用归零前不得进入空闲链'],1.0,3.15,5.0,2.4,{fontSize:15,space:5});
  box(s,6.9,2.25,5.75,3.75,'',C.white,C.orange,{shadow:true}); addText(s,'关键覆盖',7.3,2.55,4.95,0.4,{fontSize:21,bold:true,color:C.orange,align:'center'});
  addBullets(s,['队长 1 / 2 / 3 / 4 连续出队','短链出队与分配同拍','长链出队资源竞争','空闲剩余 0 / 1 / 2','多播目的端口数 1 / 2 / 4','老化被持续阻塞后最终完成'],7.25,3.15,5.0,2.4,{fontSize:15,space:5});
}

// 25. summary
{
  const s = pptx.addSlide(); s.background={color:C.navy};
  s.addShape(S.rect,{x:0,y:0,w:W,h:H,fill:{color:C.navy},line:{color:C.navy}});
  addText(s,'总结',0.75,0.72,3.0,0.65,{fontSize:34,bold:true,color:C.white,margin:0});
  const points=[['01','8192 个 cell 由空闲链和 33 条业务链动态组织',C.green],['02','队头与两级前瞻把同步 SRAM 读延迟藏在后台',C.teal],['03','多播使用一份物理链、私有读索引和逐 cell 引用计数',C.purple],['04','占用管理、仲裁与老化共同决定吞吐和安全边界',C.orange]];
  points.forEach((p,i)=>{circle(s,0.9,1.7+i*1.05,0.62,p[0],p[2],{fontSize:13}); addText(s,p[1],1.75,1.7+i*1.05,8.7,0.62,{fontSize:20,bold:true,color:C.white,margin:0});});
  chain(s,8.95,5.25,['A','F','C','…'],C.teal,{d:0.58,gap:0.55});
  addText(s,'Q & A',9.35,1.75,2.45,1.15,{fontSize:36,bold:true,color:C.teal,align:'center',margin:0});
  addText(s,'一拍接口来自预取、旁路和集中仲裁的共同设计',0.9,6.45,8.6,0.38,{fontSize:18,bold:true,color:'CFE5F3',margin:0});
}

// 26 Appendix A
{
  const s=newSlide('附录 A｜专业术语语义速查','附录','主讲使用专业语义，源码答疑再映射具体接口','本页不展示 RTL 标识符。');
  const rows=[
    [{text:'专业术语',options:{bold:true,color:C.white,fill:C.navy}},{text:'精确定义',options:{bold:true,color:C.white,fill:C.navy}}],
    ['分配结果有效','上一周期有被接收的分配请求；结果可能成功，也可能丢弃'],['实际分配','请求真正取得 cell 地址并完成挂链'],
    ['队头返回有效','上一周期发生真实出队，当前返回内容可用'],['下一包尾前瞻','下一连续 cell 是否为包尾；当前已是包尾时无效'],
    ['回收接收确认','请求已进入回收路径，不代表已写入空闲链尾'],['回收落链完成','回收 FIFO 队头已经追加到空闲链'],
    ['cell 级非空','业务链含 cell，或存在尚未读完的多播'],['完整包级非空','至少存在一个已经接收完 EOF 的完整包'],
    ['整包丢弃预测','根据整包 cell 数、占用阈值和多播槽状态进行组合预测']
  ];
  addTable(s,rows,0.7,1.02,11.95,5.35,[3.0,8.95],{fontSize:13.5,rowH:0.53});
}

// 27 Appendix B
{
  const s=newSlide('附录 B｜源码索引','附录','从专业术语快速定位到实现模块','文件路径相对 project/cores/smmu/design。');
  const rows=[
    [{text:'主题',options:{bold:true,color:C.white,fill:C.navy}},{text:'实现文件',options:{bold:true,color:C.white,fill:C.navy}},{text:'核心职责',options:{bold:true,color:C.white,fill:C.navy}}],
    ['顶层参数与互连','rtl/smmu.sv','接口分组、参数派生、子模块连接'],['分配控制','rtl/enqueue_ctrl.sv','整帧丢弃、分配 T1 返回'],
    ['出队控制','rtl/dequeue_ctrl.sv','背压、队头与包边界 T1 返回'],['回收控制','rtl/recycle_ctrl.sv','统一回收接口薄适配'],
    ['链表引擎','rtl/lle.sv','仲裁、SRAM、预取、多播、老化冲刷'],['占用管理','rtl/occupancy_pool_mgr.sv','双池、最大占用、PAUSE/PFC、统计'],
    ['老化控制','rtl/aging_ctrl.sv','逐队列计时与轮询选择'],['配置与初始化','rtl/csr_stats_init.sv','配置采样、统计寄存、初始化状态机']
  ];
  addTable(s,rows,0.7,1.05,11.95,5.25,[2.3,3.6,6.05],{fontSize:13.5,rowH:0.58});
}

// 28 Appendix C
{
  const s=newSlide('附录 C｜更完整的并发与边界测试表','附录','边界测试围绕预取切换、空池恢复和多播生命周期','本表可直接转成 directed test 清单。');
  const rows=[
    [{text:'场景',options:{bold:true,color:C.white,fill:C.navy}},{text:'主要观察点',options:{bold:true,color:C.white,fill:C.navy}}],
    ['队长 1/2/3/4 连续出队','队长≥3 的读口切换、包边界属性对齐'],['同队列与不同队列连续出队','同队连续旁路只在队列号一致时生效'],
    ['短链出队 + 分配','同拍允许且占用计数正确'],['长链出队 + 分配','出队占读口，分配侧出现反压'],
    ['短链/多播出队 + 回收落链','SRAM 读口与写口并行'],['空闲剩余 0/1/2','空池恢复、链头与两级前瞻一致'],
    ['多播目的端口数 1/2/4','引用初值、交错读取、交错回收'],['新多播遇到单槽占用','从 SOF 到 EOF 整帧丢弃'],
    ['老化 + 回收 FIFO 满','压入等待、最终完成、计数同步'],['软件强制老化保持多周期','是否重复触发冲刷']
  ];
  addTable(s,rows,0.7,1.0,11.95,5.55,[4.2,7.75],{fontSize:13.5,rowH:0.51});
}

const out = path.resolve(process.argv[2] || path.join(__dirname, 'SMMU_RTL_TECHNICAL_REVIEW.pptx'));
pptx.writeFile({ fileName: out, compression: true })
  .then(() => console.log(`WROTE ${out}`))
  .catch(err => { console.error(err); process.exit(1); });
