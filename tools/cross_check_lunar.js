#!/usr/bin/env node
// 双实现交叉核对：lunar-javascript 逐日独立计算 vs Rust 核心 CLI 输出。
// 目的不是"表自洽"（生成器已校验），而是验证 Rust 的区间定位、闰月、
// 跨年、节气归档与权威算法逐日一致。
//
// 用法：node tools/cross_check_lunar.js <cn_cal_cli 路径>
const { spawnSync } = require('child_process');
const L = require('./vendor/lunar-javascript-1.7.0.js');

const cli = process.argv[2];
if (!cli) {
  console.error('用法: node tools/cross_check_lunar.js <cn_cal_cli 路径>');
  process.exit(1);
}

const START = '2020-01-25'; // 农历表实际覆盖起点（2020 年春节）
const END_YEAR = 2050;

function callMonth(y, m) {
  const r = spawnSync(cli, ['month', String(y), String(m)], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (r.status !== 0) {
    throw new Error(`CLI 失败 ${y}-${m}: ${r.stderr || r.error}`);
  }
  return JSON.parse(r.stdout);
}

let days = 0;
const diffCounts = {};
const samples = [];
let cliErrors = 0;

for (let y = 2020; y <= END_YEAR; y++) {
  for (let m = 1; m <= 12; m++) {
    let rows;
    try {
      rows = callMonth(y, m);
    } catch (e) {
      cliErrors++;
      if (samples.length < 20) samples.push({ date: `${y}-${m}`, field: 'cli', detail: String(e) });
      continue;
    }
    for (const row of rows) {
      if (row.date < START) continue;
      days++;
      const [yy, mm, dd] = row.date.split('-').map(Number);
      const lunar = L.Solar.fromYmd(yy, mm, dd).getLunar();
      const raw = lunar.getMonth();
      // JS 月名不带「月」字（八/正/冬/腊/闰六），Rust 文本去掉「月」后即可对齐
      const jsText = lunar.getMonthInChinese() + lunar.getDayInChinese();
      const rustText = row.lunar ? row.lunar.text.replace('月', '') : null;
      const checks = [
        ['lunar.month', row.lunar ? row.lunar.month : null, Math.abs(raw)],
        ['lunar.day', row.lunar ? row.lunar.day : null, lunar.getDay()],
        ['lunar.leap', row.lunar ? row.lunar.leap : null, raw < 0],
        ['lunar.text', rustText, jsText],
        ['jieqi', row.jieqi, lunar.getJieQi() || null],
        ['ganzhi', row.ganzhi, lunar.getYearInGanZhi()],
        ['shengxiao', row.shengxiao, lunar.getYearShengXiao()],
      ];
      for (const [field, rust, js] of checks) {
        if (rust !== js) {
          diffCounts[field] = (diffCounts[field] || 0) + 1;
          if (samples.length < 20) {
            samples.push({ date: row.date, field, rust: String(rust), js: String(js) });
          }
        }
      }
    }
  }
}

console.log(`交叉核对范围 ${START} ~ ${END_YEAR}-12-31，共 ${days} 天，${(END_YEAR - 2020 + 1) * 12} 次 CLI 调用`);
console.log(`CLI 调用失败 ${cliErrors} 次`);
const fields = ['lunar.month', 'lunar.day', 'lunar.leap', 'lunar.text', 'jieqi', 'ganzhi', 'shengxiao'];
for (const f of fields) {
  console.log(`  ${f.padEnd(14)} 差异 ${diffCounts[f] || 0}`);
}
const total = Object.values(diffCounts).reduce((a, b) => a + b, 0);
if (samples.length) {
  console.log('差异示例：');
  for (const s of samples.slice(0, 12)) console.log('  ', JSON.stringify(s));
}
console.log(total === 0 && cliErrors === 0 ? 'OK: 双实现逐日一致' : `FAIL: 共 ${total} 处差异`);
process.exit(total === 0 && cliErrors === 0 ? 0 : 1);
