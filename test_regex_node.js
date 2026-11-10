const text = `以下是 9/1(周二)到今天 9/2(周三)14:30 收到的邮件汇总,按重要程度分类整理。今天下午正是 E@B 和 Neurotech 的 Info session 时间,多个截止日期都很集中,请留意。

**一、今天(9/2)当天需要处理的事项**

- **Berkeley Connect in PHILOS 首次小组合【今天】**:mentor Jennifer Marsh 通知首次小组会就在今天周三,两场可选:5-6pm 在 Dwinelle 262,或 6-7pm 在 Dwinelle 134。Berkeley Connect 是 Pass/Fail 只需考勤;若不能到需提前告知她以免被记缺勤 [11, 19-27]`;
const numRegex = /\[\s*(\d+)(?:\s*,\s*(\d+)(?:\s*[,\-]\s*(\d+))?)?\s*\]/g;
const matches = [...text.matchAll(numRegex)];
console.log('Matches:', matches.length);
if (matches.length > 0) {
  console.log(matches[0][0]);
}
