#!/usr/bin/env node
// 由 lunar-javascript 1.7.0 预生成农历/节气基础表。
// 用法：
//   node tools/gen_lunar_table.js           生成 data/lunar-table.json
//   node tools/gen_lunar_table.js --check   生成后与现有文件比对（CI 复现性校验）
//   node tools/gen_lunar_table.js 2020 2050 指定年份范围
//
// 注意：不使用 LunarYear.getMonths() 的分组结果。2033/2034 闰冬月等特殊年份里
// 该 API 的 15 项窗口边界会错位。改为逐公历日扫描「农历初一」，再按正月切年，
// 月长由相邻月首做差得出，全程由上游库保证正确性。
const fs = require('fs');
const path = require('path');
const L = require('./vendor/lunar-javascript-1.7.0.js');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'data', 'lunar-table.json');
const args = process.argv.slice(2);
const check = args.includes('--check');
const nums = args.filter(a => /^\d{4}$/.test(a)).map(Number);
const START = nums.length >= 2 ? nums[0] : 2020;
const END = nums.length >= 2 ? nums[1] : 2050;

const JIEQI_ORDER = [
  '小寒', '大寒', '立春', '雨水', '惊蛰', '春分', '清明', '谷雨',
  '立夏', '小满', '芒种', '夏至', '小暑', '大暑', '立秋', '处暑',
  '白露', '秋分', '寒露', '霜降', '立冬', '小雪', '大雪', '冬至'
];

function pad(n) { return String(n).padStart(2, '0'); }
function daysInMonth(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate(); }
function ymd(y, m, d) { return `${y}-${pad(m)}-${pad(d)}`; }
function toUtc(s) { const [y, m, d] = s.split('-').map(Number); return Date.UTC(y, m - 1, d); }
function diffDays(a, b) { return Math.round((toUtc(a) - toUtc(b)) / 86400000); }

function collectMonthStarts(fromY, toY) {
  const starts = [];
  for (let y = fromY; y <= toY; y++) {
    for (let mo = 1; mo <= 12; mo++) {
      const dim = daysInMonth(y, mo);
      for (let d = 1; d <= dim; d++) {
        const l = L.Solar.fromYmd(y, mo, d).getLunar();
        if (l.getDay() !== 1) continue;
        const raw = l.getMonth();
        starts.push({ m: Math.abs(raw), leap: raw < 0, start: ymd(y, mo, d) });
      }
    }
  }
  return starts;
}

function collectJieQi(y) {
  const jieqi = [];
  for (let mo = 1; mo <= 12; mo++) {
    const dim = daysInMonth(y, mo);
    for (let d = 1; d <= dim; d++) {
      const name = L.Solar.fromYmd(y, mo, d).getLunar().getJieQi();
      if (name) jieqi.push({ name, date: `${pad(mo)}-${pad(d)}` });
    }
  }
  if (jieqi.length !== 24) throw new Error(`${y}: 节气数 ${jieqi.length} != 24`);
  if (jieqi.map(j => j.name).join(',') !== JIEQI_ORDER.join(',')) {
    throw new Error(`${y}: 节气顺序异常`);
  }
  return jieqi;
}

function buildYears() {
  const starts = collectMonthStarts(START - 1, END + 2);
  const springs = [];
  starts.forEach((s, i) => { if (s.m === 1 && !s.leap) springs.push(i); });
  if (springs.length < 2) throw new Error('月首序列中没有足够的正月');

  const years = [];
  for (let k = 0; k < springs.length - 1; k++) {
    const i0 = springs[k], i1 = springs[k + 1];
    const spring = starts[i0].start;
    const y = Number(spring.slice(0, 4));
    if (y < START || y > END) continue;

    const months = [];
    for (let i = i0; i < i1; i++) {
      months.push({
        m: starts[i].m,
        leap: starts[i].leap,
        days: diffDays(starts[i + 1].start, starts[i].start),
        start: starts[i].start
      });
    }

    if (months.length !== 12 && months.length !== 13) {
      throw new Error(`${y}: 农历月数异常 ${months.length}`);
    }
    if (months[months.length - 1].m !== 12) throw new Error(`${y}: 末月不是腊月`);
    for (const m of months) {
      if (m.days !== 29 && m.days !== 30) throw new Error(`${y}: 月长异常 ${m.days}`);
    }

    const [sy, sm, sd] = spring.split('-').map(Number);
    const springLunar = L.Solar.fromYmd(sy, sm, sd).getLunar();
    years.push({
      y,
      spring,
      ganzhi: springLunar.getYearInGanZhi(),
      shengxiao: springLunar.getYearShengXiao(),
      months,
      jieqi: collectJieQi(y)
    });
  }
  if (years.length !== END - START + 1) {
    throw new Error(`年份数 ${years.length} != ${END - START + 1}`);
  }
  return years;
}

const years = buildYears();
const doc = {
  meta: {
    source: 'lunar-javascript 1.7.0 (npm, MIT)',
    generated_by: 'tools/gen_lunar_table.js',
    range: [START, END],
    jieqi_order: JIEQI_ORDER,
    note: '预生成静态表；运行时不依赖 JS 库。范围外降级为不显示农历/节气。'
  },
  years
};

const text = JSON.stringify(doc, null, 1) + '\n';
if (check) {
  const current = fs.readFileSync(OUT, 'utf8');
  if (current !== text) {
    console.error('FAIL: data/lunar-table.json 与生成器输出不一致，请重新生成或检查手改。');
    process.exit(1);
  }
  console.log(`OK: 复现性校验通过（${START}-${END}，${years.length} 年）`);
} else {
  fs.writeFileSync(OUT, text, 'utf8');
  const leap = years.filter(v => v.months.length === 13).map(v => v.y).join(',');
  const y2026 = years.find(v => v.y === 2026);
  console.log(`生成 ${OUT}`);
  console.log(`范围 ${START}-${END}，${years.length} 年，${(text.length / 1024).toFixed(1)} KiB`);
  console.log(`闰月年份: ${leap || '无'}`);
  console.log(`2026 春节 ${y2026.spring}，2026 冬至 ${y2026.jieqi[23].date}`);
  console.log(`2033 春节 ${years.find(v => v.y === 2033).spring}，2034 春节 ${years.find(v => v.y === 2034).spring}`);
}
